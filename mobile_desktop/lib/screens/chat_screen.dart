import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../models/api_error.dart';
import '../models/chat_item.dart';
import '../models/conversation.dart';
import '../models/media.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/voice_preference.dart';
import '../utils/date_format.dart';
import 'attachment_sheet.dart';
import 'audio_record_screen.dart';
import 'live_screen.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  const ChatScreen({super.key, required this.conversation});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  List<ChatItem>? _items;
  ApiError? _loadError;
  bool _isLoading = false;
  bool _isSending = false;
  String? _sendError;
  String? _lastAttemptedText;

  final Map<String, Timer> _pollTimers = {};
  int _tempCounter = 0;

  final AudioPlayer _ttsPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHistory());
  }

  @override
  void dispose() {
    for (final t in _pollTimers.values) {
      t.cancel();
    }
    _pollTimers.clear();
    _ttsPlayer.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  String _nextTempKey() {
    _tempCounter++;
    return 't${DateTime.now().microsecondsSinceEpoch}_$_tempCounter';
  }

  // --------------------------- History ---------------------------

  Future<void> _loadHistory() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final api = context.read<ApiService>();
      final response = await api.listMessages(widget.conversation.id);
      final data = response.data;
      if (data is! List) {
        throw const ApiError(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Beklenmeyen sunucu yanıtı.',
        );
      }
      final items = data
          .map((e) => MessageItem(Message.fromJson(e as Map<String, dynamic>)))
          .cast<ChatItem>()
          .toList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _isLoading = false;
      });
      _scrollToBottom(animated: false);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.error is ApiError
            ? e.error as ApiError
            : ApiError.network('Mesajlar getirilemedi.');
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e is ApiError
            ? e
            : ApiError.network('Beklenmeyen bir hata oluştu.');
        _isLoading = false;
      });
    }
  }

  // --------------------------- Send text ---------------------------

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isSending) return;

    final now = DateTime.now();
    final optimisticMsg = Message(
      id: 'local_${now.microsecondsSinceEpoch}',
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: text,
      contentType: 'text',
      createdAt: now,
    );

    setState(() {
      _items = [...?_items, MessageItem(optimisticMsg)];
      _isSending = true;
      _sendError = null;
      _lastAttemptedText = text;
    });
    _inputController.clear();
    _scrollToBottom();

    try {
      final api = context.read<ApiService>();
      final voice = context.read<VoicePreference>().voice;
      final response = await api.sendMessage(
        widget.conversation.id,
        text,
        voice: voice,
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw const ApiError(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Beklenmeyen sunucu yanıtı.',
        );
      }
      final assistantMsg = Message.fromJson(data);
      if (!mounted) return;
      setState(() {
        _items = [...?_items, MessageItem(assistantMsg)];
        _isSending = false;
        _lastAttemptedText = null;
      });
      _scrollToBottom();
      _inputFocusNode.requestFocus();
      _playIfAudio(assistantMsg.audioBase64);
    } on DioException catch (e) {
      if (!mounted) return;
      final err = e.error is ApiError
          ? e.error as ApiError
          : ApiError.network('Mesaj gönderilemedi.');
      setState(() {
        _isSending = false;
        _sendError = err.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _sendError = 'Beklenmeyen bir hata oluştu.';
      });
    }
  }

  void _retryText() {
    final text = _lastAttemptedText;
    if (text == null) return;
    setState(() {
      final list = _items;
      if (list != null &&
          list.isNotEmpty &&
          list.last is MessageItem &&
          (list.last as MessageItem).message.role == MessageRole.user) {
        _items = list.sublist(0, list.length - 1);
      }
      _sendError = null;
    });
    _inputController.text = text;
    _send();
  }

  void _dismissError() {
    setState(() {
      _sendError = null;
      _lastAttemptedText = null;
    });
  }

  // --------------------------- Attachments ---------------------------

  Future<void> _openAttachment() async {
    _inputFocusNode.unfocus();
    final result = await showAttachmentSheet(context);
    if (!mounted || result == null) return;

    if (result is FileAttachment) {
      await _uploadFileAttachment(result);
    } else if (result is UrlAttachment) {
      await _uploadUrlAttachment(result);
    } else if (result is RequestAudioRecord) {
      await _openAudioRecorder();
    }
  }

  Future<void> _openAudioRecorder() async {
    final result = await Navigator.of(context).push<AudioRecordResult>(
      MaterialPageRoute(builder: (_) => const AudioRecordScreen()),
    );
    if (!mounted || result == null) return;
    await _sendVoiceMessage(result);
  }

  // --------------------------- Voice message (STT + TTS) ---------------------------

  Future<void> _sendVoiceMessage(AudioRecordResult record) async {
    // Optimistic kullanıcı bubble'ı — content_type "voice" ki UI ayırt edebilsin
    final now = DateTime.now();
    final placeholderId = 'voice_local_${now.microsecondsSinceEpoch}';
    final placeholder = Message(
      id: placeholderId,
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: '🎤 Sesli mesaj gönderiliyor…',
      contentType: 'voice',
      createdAt: now,
    );

    setState(() {
      _items = [...?_items, MessageItem(placeholder)];
      _isSending = true;
      _sendError = null;
    });
    _scrollToBottom();

    try {
      final api = context.read<ApiService>();
      final voice = context.read<VoicePreference>().voice;
      final response = await api.sendVoiceMessage(
        widget.conversation.id,
        bytes: record.bytes,
        filename: record.filename,
        mimeType: record.mimeType,
        voice: voice,
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw const ApiError(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Beklenmeyen sunucu yanıtı.',
        );
      }
      final transcript = (data['transcript'] as String?)?.trim() ?? '';
      final messageJson = data['message'] as Map<String, dynamic>?;

      if (messageJson == null) {
        throw const ApiError(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Yanıt mesajı eksik.',
        );
      }
      final assistantMsg = Message.fromJson(messageJson);

      // Transcript'i placeholder'ın yerine yaz + asistan yanıtını ekle
      if (!mounted) return;
      setState(() {
        final list = _items;
        if (list != null) {
          final idx = list.indexWhere(
            (it) => it is MessageItem && it.message.id == placeholderId,
          );
          if (idx != -1) {
            final replaced = Message(
              id: placeholderId,
              conversationId: widget.conversation.id,
              role: MessageRole.user,
              content: transcript.isEmpty ? '🎤 (boş)' : transcript,
              contentType: 'voice',
              createdAt: now,
            );
            final updated = List<ChatItem>.from(list);
            updated[idx] = MessageItem(replaced);
            updated.add(MessageItem(assistantMsg));
            _items = updated;
          } else {
            _items = [...list, MessageItem(assistantMsg)];
          }
        }
        _isSending = false;
      });
      _scrollToBottom();

      // TTS çal (message.audio_base64 backend'de dolar)
      _playIfAudio(assistantMsg.audioBase64);
    } on DioException catch (e) {
      if (!mounted) return;
      final err = e.error is ApiError
          ? e.error as ApiError
          : ApiError.network('Sesli mesaj gönderilemedi.');
      setState(() {
        _isSending = false;
        _sendError = err.message;
        // Placeholder'ı listeden çıkar
        final list = _items;
        if (list != null) {
          _items = list
              .where((it) =>
                  !(it is MessageItem && it.message.id == placeholderId))
              .toList();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _sendError = 'Beklenmeyen bir hata oluştu.';
        final list = _items;
        if (list != null) {
          _items = list
              .where((it) =>
                  !(it is MessageItem && it.message.id == placeholderId))
              .toList();
        }
      });
    }
  }

  Future<void> _playTtsBytes(Uint8List bytes) async {
    try {
      await _ttsPlayer.stop();
      await _ttsPlayer.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
    } catch (_) {
      // Ses çalınamadıysa sessiz geç — metin cevap zaten görünüyor
    }
  }

  void _playIfAudio(String? audioBase64) {
    if (audioBase64 == null || audioBase64.isEmpty) return;
    try {
      final bytes = base64Decode(audioBase64);
      _playTtsBytes(bytes);
    } catch (_) {
      // base64 bozuksa yut
    }
  }

  Future<void> _uploadFileAttachment(FileAttachment attach) async {
    final mediaItem = MediaItem(
      tempKey: _nextTempKey(),
      filename: attach.filename,
      fileType: attach.fileType,
      previewBytes: attach.fileType == 'image' ? attach.bytes : null,
      status: MediaAnalysisStatus.pending,
    );

    setState(() {
      _items = [...?_items, mediaItem];
    });
    _scrollToBottom();

    try {
      final api = context.read<ApiService>();
      final response = await api.uploadMedia(
        bytes: attach.bytes,
        filename: attach.filename,
        conversationId: widget.conversation.id,
        contentType: attach.mimeType,
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw const ApiError(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Beklenmeyen sunucu yanıtı.',
        );
      }
      final upload = MediaUpload.fromJson(data);
      if (!mounted) return;
      setState(() {
        mediaItem.mediaId = upload.mediaId;
        mediaItem.status = upload.status;
      });
      _startPolling(mediaItem);
    } on DioException catch (e) {
      if (!mounted) return;
      final err = e.error is ApiError
          ? e.error as ApiError
          : ApiError.network('Yükleme başarısız.');
      setState(() {
        mediaItem.status = MediaAnalysisStatus.failed;
        mediaItem.errorMessage = err.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        mediaItem.status = MediaAnalysisStatus.failed;
        mediaItem.errorMessage = 'Yükleme sırasında hata oluştu.';
      });
    }
  }

  Future<void> _uploadUrlAttachment(UrlAttachment attach) async {
    final mediaItem = MediaItem(
      tempKey: _nextTempKey(),
      filename: attach.url,
      fileType: null,
      sourceUrl: attach.url,
      status: MediaAnalysisStatus.pending,
    );

    setState(() {
      _items = [...?_items, mediaItem];
    });
    _scrollToBottom();

    try {
      final api = context.read<ApiService>();
      final response = await api.uploadMediaFromUrl(
        url: attach.url,
        conversationId: widget.conversation.id,
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw const ApiError(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Beklenmeyen sunucu yanıtı.',
        );
      }
      final upload = MediaUpload.fromJson(data);
      if (!mounted) return;
      setState(() {
        mediaItem.mediaId = upload.mediaId;
        mediaItem.status = upload.status;
      });
      _startPolling(mediaItem);
    } on DioException catch (e) {
      if (!mounted) return;
      final err = e.error is ApiError
          ? e.error as ApiError
          : ApiError.network('Bağlantı işlenemedi.');
      setState(() {
        mediaItem.status = MediaAnalysisStatus.failed;
        mediaItem.errorMessage = err.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        mediaItem.status = MediaAnalysisStatus.failed;
        mediaItem.errorMessage = 'Beklenmeyen hata.';
      });
    }
  }

  // --------------------------- Polling ---------------------------

  void _startPolling(MediaItem item) {
    final mediaId = item.mediaId;
    if (mediaId == null) return;
    _pollTimers[item.tempKey]?.cancel();

    Future<void> pollOnce() async {
      if (!mounted) return;
      try {
        final api = context.read<ApiService>();
        final resp = await api.mediaStatus(mediaId);
        final data = resp.data;
        if (data is Map<String, dynamic>) {
          final status =
              parseMediaAnalysisStatus(data['analysis_status'] as String?);
          if (!mounted) return;
          setState(() {
            item.status = status;
          });
          if (status == MediaAnalysisStatus.completed) {
            _pollTimers.remove(item.tempKey)?.cancel();
            await _fetchAnalysis(item);
          } else if (status == MediaAnalysisStatus.failed) {
            _pollTimers.remove(item.tempKey)?.cancel();
            setState(() {
              item.errorMessage = 'Analiz başarısız oldu.';
            });
          }
        }
      } catch (_) {
        // Ağ hatası — sonraki tick tekrar dener
      }
    }

    // İlk kontrolü hemen yap, sonra 2sn'de bir
    pollOnce();
    _pollTimers[item.tempKey] = Timer.periodic(
      const Duration(seconds: 2),
      (_) => pollOnce(),
    );
  }

  Future<void> _fetchAnalysis(MediaItem item) async {
    final mediaId = item.mediaId;
    if (mediaId == null) return;
    try {
      final api = context.read<ApiService>();
      final resp = await api.mediaAnalysis(mediaId);
      final data = resp.data;
      if (data is Map<String, dynamic>) {
        final analysis = MediaAnalysis.fromJson(data);
        if (!mounted) return;
        setState(() {
          item.analysis = analysis;
        });
      }
    } catch (_) {
      // Analiz çekilemedi — bir sonraki tick'te tekrar denenir
    }
  }

  // --------------------------- Ask about media ---------------------------

  Future<void> _askAboutMedia(MediaItem item) async {
    final mediaId = item.mediaId;
    if (mediaId == null) return;
    final question = await showDialog<String>(
      context: context,
      builder: (_) => _AskDialog(filename: item.filename),
    );
    if (!mounted || question == null || question.isEmpty) return;

    final now = DateTime.now();
    final userMsg = Message(
      id: 'local_${now.microsecondsSinceEpoch}',
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: question,
      contentType: item.fileType ?? 'text',
      createdAt: now,
    );

    setState(() {
      _items = [...?_items, MessageItem(userMsg)];
      _isSending = true;
    });
    _scrollToBottom();

    try {
      final api = context.read<ApiService>();
      final voice = context.read<VoicePreference>().voice;
      final response = await api.askMedia(
        mediaId,
        question,
        conversationId: widget.conversation.id,
        voice: voice,
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw const ApiError(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Beklenmeyen sunucu yanıtı.',
        );
      }
      final content = data['content'] as String? ?? '';
      final modelUsed = data['ai_model_used'] as String?;
      final audioBase64 = data['audio_base64'] as String?;
      final assistantMsg = Message(
        id: 'ask_${DateTime.now().microsecondsSinceEpoch}',
        conversationId: widget.conversation.id,
        role: MessageRole.assistant,
        content: content,
        contentType: 'text',
        aiModelUsed: modelUsed,
        createdAt: DateTime.now(),
        audioBase64: audioBase64,
      );
      if (!mounted) return;
      setState(() {
        _items = [...?_items, MessageItem(assistantMsg)];
        _isSending = false;
      });
      _scrollToBottom();
      _playIfAudio(audioBase64);
    } on DioException catch (e) {
      if (!mounted) return;
      final err = e.error is ApiError
          ? e.error as ApiError
          : ApiError.network('Yanıt alınamadı.');
      setState(() {
        _isSending = false;
        _sendError = err.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _sendError = 'Beklenmeyen bir hata oluştu.';
      });
    }
  }

  void _showAnalysisDetails(MediaItem item) {
    final analysis = item.analysis;
    if (analysis == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AnalysisDetailsSheet(analysis: analysis, item: item),
    );
  }

  // --------------------------- Scroll ---------------------------

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animated) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  // --------------------------- Build ---------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            tooltip: 'Canlı Ahlas',
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LiveScreen(conversation: widget.conversation),
              ));
            },
          ),
          Consumer<VoicePreference>(
            builder: (context, pref, _) {
              return PopupMenuButton<String>(
                icon: const Icon(Icons.record_voice_over_outlined),
                tooltip: 'Ahlas\'ın sesi',
                onSelected: (v) => pref.setVoice(v),
                itemBuilder: (_) => VoicePreference.availableVoices.entries
                    .map(
                      (e) => PopupMenuItem<String>(
                        value: e.key,
                        child: Row(
                          children: [
                            Icon(
                              pref.voice == e.key
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Text(e.value),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildMessagesArea()),
            if (_sendError != null) _buildErrorBanner(),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildMessagesArea() {
    if (_isLoading && _items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _items == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _loadError!.message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadHistory,
                icon: const Icon(Icons.refresh),
                label: const Text('Yeniden dene'),
              ),
            ],
          ),
        ),
      );
    }
    final items = _items ?? const <ChatItem>[];
    if (items.isEmpty && !_isSending) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'Bu sohbette henüz mesaj yok',
                style: TextStyle(fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                'Ahlas ile konuşmaya başla.',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }
    final showTyping = _isSending;
    final childCount = items.length + (showTyping ? 1 : 0);
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: childCount,
      itemBuilder: (context, index) {
        if (showTyping && index == items.length) {
          return const _TypingIndicator();
        }
        final item = items[index];
        if (item is MessageItem) {
          return _MessageBubble(
            message: item.message,
            onReplay: () => _playIfAudio(item.message.audioBase64),
          );
        }
        if (item is MediaItem) {
          return _MediaBubble(
            item: item,
            onAsk: () => _askAboutMedia(item),
            onShowDetails: () => _showAnalysisDetails(item),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildErrorBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _sendError ?? '',
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
              ),
            ),
            if (_lastAttemptedText != null)
              TextButton(
                onPressed: _retryText,
                child: const Text('Tekrar dene'),
              ),
            IconButton(
              icon: Icon(Icons.close, color: scheme.onErrorContainer, size: 18),
              onPressed: _dismissError,
              tooltip: 'Kapat',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            onPressed: _isSending ? null : _openAttachment,
            icon: const Icon(Icons.attach_file),
            tooltip: 'Ekle',
          ),
          IconButton(
            onPressed: _isSending ? null : _openAudioRecorder,
            icon: const Icon(Icons.mic),
            tooltip: 'Sesle sor',
          ),
          Expanded(
            child: TextField(
              controller: _inputController,
              focusNode: _inputFocusNode,
              enabled: !_isSending,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: 'Mesajını yaz…',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          _SendButton(
            enabled: !_isSending && _inputController.text.trim().isNotEmpty,
            isSending: _isSending,
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}

// =========================================================
// Widgets
// =========================================================

class _SendButton extends StatelessWidget {
  final bool enabled;
  final bool isSending;
  final VoidCallback onPressed;

  const _SendButton({
    required this.enabled,
    required this.isSending,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: enabled ? onPressed : null,
      style: FilledButton.styleFrom(
        shape: const CircleBorder(),
        padding: const EdgeInsets.all(14),
      ),
      child: isSending
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.send, size: 20),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final VoidCallback? onReplay;
  const _MessageBubble({required this.message, this.onReplay});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final scheme = Theme.of(context).colorScheme;
    final bgColor = isUser ? scheme.primary : scheme.surfaceContainerHigh;
    final textColor = isUser ? scheme.onPrimary : scheme.onSurface;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final hasReplay =
        !isUser && message.audioBase64 != null && message.audioBase64!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isUser ? 16 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 16),
              ),
            ),
            child: isUser
                ? SelectableText(
                    message.content ?? '',
                    style: TextStyle(color: textColor, fontSize: 15),
                  )
                : MarkdownBody(
                    data: message.content ?? '',
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(
                      Theme.of(context),
                    ).copyWith(
                      p: TextStyle(color: textColor, fontSize: 15, height: 1.4),
                      code: TextStyle(
                        color: textColor,
                        backgroundColor: scheme.surface,
                        fontFamily: 'monospace',
                        fontSize: 14,
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatTimeTr(message.createdAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
                if (hasReplay) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: onReplay,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.volume_up_outlined,
                        size: 16,
                        color: scheme.outline,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaBubble extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onAsk;
  final VoidCallback onShowDetails;

  const _MediaBubble({
    required this.item,
    required this.onAsk,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPreview(scheme),
                const SizedBox(height: 8),
                _buildFileInfo(scheme),
                const SizedBox(height: 8),
                _buildStatusRow(scheme),
                if (item.analysis != null) ...[
                  const SizedBox(height: 10),
                  _buildAnalysisSummary(scheme),
                ],
                if (item.errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    item.errorMessage!,
                    style: TextStyle(
                      color: scheme.onPrimary.withOpacity(0.9),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
            child: Text(
              formatTimeTr(item.createdAt),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(ColorScheme scheme) {
    final onColor = scheme.onPrimary;
    if (item.previewBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          item.previewBytes!,
          fit: BoxFit.cover,
          height: 160,
          width: double.infinity,
        ),
      );
    }
    return Container(
      height: 90,
      decoration: BoxDecoration(
        color: onColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Icon(_iconForType(), size: 44, color: onColor),
      ),
    );
  }

  IconData _iconForType() {
    switch (item.fileType) {
      case 'image':
        return Icons.image_outlined;
      case 'video':
        return Icons.movie_outlined;
      case 'audio':
        return Icons.mic_outlined;
      default:
        return Icons.link_outlined;
    }
  }

  Widget _buildFileInfo(ColorScheme scheme) {
    final onColor = scheme.onPrimary;
    final label = item.sourceUrl ?? item.filename;
    return Row(
      children: [
        Icon(_iconForType(), color: onColor, size: 18),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: onColor,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusRow(ColorScheme scheme) {
    final onColor = scheme.onPrimary;
    final (icon, text) = _statusIconAndText();
    final isSpin = item.status == MediaAnalysisStatus.pending ||
        item.status == MediaAnalysisStatus.processing;
    return Row(
      children: [
        if (isSpin)
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: onColor),
          )
        else
          Icon(icon, color: onColor, size: 16),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(color: onColor, fontSize: 12),
        ),
      ],
    );
  }

  (IconData, String) _statusIconAndText() {
    switch (item.status) {
      case MediaAnalysisStatus.pending:
        return (Icons.cloud_upload_outlined, 'Yükleniyor…');
      case MediaAnalysisStatus.processing:
        return (Icons.psychology_outlined, 'Ahlas analiz ediyor…');
      case MediaAnalysisStatus.completed:
        return (Icons.check_circle_outline, 'Analiz tamam');
      case MediaAnalysisStatus.failed:
        return (Icons.error_outline, 'Başarısız');
    }
  }

  Widget _buildAnalysisSummary(ColorScheme scheme) {
    final onColor = scheme.onPrimary;
    final analysis = item.analysis!;
    final summary = analysis.summary?.trim();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: onColor.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (summary != null && summary.isNotEmpty)
            Text(
              summary,
              style: TextStyle(color: onColor, fontSize: 13, height: 1.35),
            )
          else
            Text(
              'Analiz tamamlandı.',
              style: TextStyle(color: onColor, fontSize: 13),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ActionChip(
                avatar: Icon(Icons.info_outline,
                    size: 16, color: scheme.primary),
                label: const Text('Detaylar'),
                onPressed: onShowDetails,
              ),
              ActionChip(
                avatar: Icon(Icons.question_answer_outlined,
                    size: 16, color: scheme.primary),
                label: const Text('Bu medyayı sor'),
                onPressed: onAsk,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AnalysisDetailsSheet extends StatelessWidget {
  final MediaAnalysis analysis;
  final MediaItem item;

  const _AnalysisDetailsSheet({required this.analysis, required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      builder: (context, controller) {
        return SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.filename,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              if (analysis.summary != null) ...[
                Text('Özet', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(analysis.summary!),
                const SizedBox(height: 12),
              ],
              if (analysis.detailedAnalysis != null) ...[
                Text('Ayrıntılı analiz',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                MarkdownBody(data: analysis.detailedAnalysis!),
                const SizedBox(height: 12),
              ],
              if (analysis.detectedObjects.isNotEmpty) ...[
                Text('Tespit edilen nesneler',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: analysis.detectedObjects
                      .map((o) => Chip(label: Text(o)))
                      .toList(),
                ),
                const SizedBox(height: 12),
              ],
              if (analysis.detectedText != null &&
                  analysis.detectedText!.isNotEmpty) ...[
                Text('Tespit edilen metin',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(analysis.detectedText!),
                ),
                const SizedBox(height: 12),
              ],
              if (analysis.sentiment != null) ...[
                Text('Duygu / ton',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(analysis.sentiment!),
                const SizedBox(height: 12),
              ],
              if (analysis.aiModelUsed != null)
                Text(
                  'Model: ${analysis.aiModelUsed}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _AskDialog extends StatefulWidget {
  final String filename;
  const _AskDialog({required this.filename});

  @override
  State<_AskDialog> createState() => _AskDialogState();
}

class _AskDialogState extends State<_AskDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Bu medyayı sor'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.filename,
            style: Theme.of(context).textTheme.labelMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Sorun',
              hintText: 'Örn: Bu görselde ne var?',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isEmpty) return;
            Navigator.of(context).pop(text);
          },
          child: const Text('Sor'),
        ),
      ],
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(16),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Ahlas düşünüyor',
                style: TextStyle(color: scheme.onSurface, fontSize: 14),
              ),
              const SizedBox(width: 8),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(3, (i) {
                      final phase = (_controller.value + i * 0.15) % 1.0;
                      final opacity =
                          (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
                              .clamp(0.25, 1.0);
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.5),
                        child: Opacity(
                          opacity: opacity,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: scheme.onSurface,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      );
                    }),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Unused-warning stopper — kept in case future imports drop
// ignore: unused_element
Uint8List _keepImport(Uint8List b) => b;
