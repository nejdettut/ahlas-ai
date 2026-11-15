import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/env.dart';

/// Canlı oturum durumu — UI'a değişimi bildirir.
enum LiveConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// Yükselen olay: assistant yeni PCM chunk gönderdi (24kHz, s16le, mono).
class LiveAudioChunk {
  final Uint8List pcm;
  const LiveAudioChunk(this.pcm);
}

/// Yükselen olay: transcript (kullanıcı veya assistant).
class LiveTranscript {
  final String role; // 'user' | 'assistant'
  final String text;
  const LiveTranscript(this.role, this.text);
}

/// Yükselen olay: turn tamamlandı — assistant bitirdi.
class LiveTurnComplete {}

/// Yükselen olay: kullanıcı kesildi — assistant konuşurken client konuşmaya başladı.
class LiveInterrupted {}

/// Yükselen olay: hata mesajı.
class LiveError {
  final String code;
  final String message;
  const LiveError(this.code, this.message);
}

/// Ahlas canlı sohbet WebSocket köprüsü.
///
/// - `connect(token: ..., voice: ...)` — WS aç, `connected` bekle.
/// - `sendAudioChunk(bytes)` — 16kHz PCM chunk gönder.
/// - `sendVideoFrame(jpegBytes)` — JPEG frame gönder.
/// - `endAudioTurn()` — PTT release, user turn kapansın.
/// - `sendText(text)` — metin ile mesaj.
/// - `close()` — oturumu kapat.
///
/// [events] stream'i UI için tüm event tiplerini yayınlar.
class LiveSession extends ChangeNotifier {
  WebSocketChannel? _channel;
  final _events = StreamController<Object>.broadcast();
  Stream<Object> get events => _events.stream;

  LiveConnectionState _state = LiveConnectionState.disconnected;
  LiveConnectionState get state => _state;
  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool get isConnected => _state == LiveConnectionState.connected;

  // Reconnect için: son kullanılan credential'ları sakla + manuel close bayrağı
  String? _lastToken;
  String? _lastVoice;
  bool _closedByUser = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;

  Future<void> connect({required String token, String? voice}) async {
    if (_state == LiveConnectionState.connecting ||
        _state == LiveConnectionState.connected) {
      return;
    }
    _lastToken = token;
    _lastVoice = voice;
    _closedByUser = false;
    _setState(LiveConnectionState.connecting);

    // baseUrl: http(s)://... → ws(s)://...
    final base = Env.apiBaseUrl;
    final wsBase = base.replaceFirst(RegExp(r'^http'), 'ws');
    final query = <String, String>{
      'token': token,
      if (voice != null && voice.isNotEmpty) 'voice': voice,
    };
    final queryString =
        query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final url = '$wsBase/api/v1/live/session?$queryString';

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
    } catch (e) {
      _errorMessage = 'WS bağlantı hatası: $e';
      _setState(LiveConnectionState.error);
    }
  }

  /// WS beklenmedik düşerse (kullanıcı close demediyse) exponential
  /// backoff ile yeniden bağlanmayı dene. 3 denemeden sonra vazgeç.
  Future<void> _attemptReconnect() async {
    final token = _lastToken;
    if (_closedByUser || token == null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _errorMessage = 'Bağlantı kesildi. Lütfen ekranı yeniden aç.';
      _setState(LiveConnectionState.error);
      return;
    }
    _reconnectAttempts += 1;
    final delaySec = 1 << (_reconnectAttempts - 1); // 1s, 2s, 4s
    await Future<void>.delayed(Duration(seconds: delaySec));
    if (_closedByUser) return;
    await connect(token: token, voice: _lastVoice);
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final msg = json.decode(data) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      switch (type) {
        case 'info':
          if (msg['message'] == 'connected') {
            _setState(LiveConnectionState.connected);
            _reconnectAttempts = 0; // başarılı → sayaç sıfırla
          }
          break;
        case 'audio':
          final b64 = msg['data'] as String?;
          if (b64 != null) {
            final pcm = base64Decode(b64);
            _events.add(LiveAudioChunk(pcm));
          }
          break;
        case 'transcript':
          final role = msg['role'] as String? ?? 'assistant';
          final text = msg['text'] as String? ?? '';
          if (text.isNotEmpty) {
            _events.add(LiveTranscript(role, text));
          }
          break;
        case 'turn_complete':
          _events.add(LiveTurnComplete());
          break;
        case 'interrupted':
          _events.add(LiveInterrupted());
          break;
        case 'error':
          final code = msg['code'] as String? ?? 'UNKNOWN';
          final message = msg['message'] as String? ?? 'Bilinmeyen hata';
          _events.add(LiveError(code, message));
          break;
      }
    } catch (_) {
      // JSON parse hatasını sessizce yut
    }
  }

  void _onError(Object error) {
    _errorMessage = 'WS hatası: $error';
    _setState(LiveConnectionState.error);
  }

  void _onDone() {
    _channel = null;
    _setState(LiveConnectionState.disconnected);
    // Kullanıcı kapatmadıysa yeniden bağlanmayı dene (backend WS düşerse
    // güvenlik ağı). Backend fix'inden sonra bu normalde tetiklenmez.
    if (!_closedByUser) {
      _attemptReconnect();
    }
  }

  void _send(Map<String, dynamic> payload) {
    final ch = _channel;
    if (ch == null || _state != LiveConnectionState.connected) return;
    try {
      ch.sink.add(json.encode(payload));
    } catch (_) {}
  }

  /// 16kHz mono PCM 16-bit chunk gönder.
  void sendAudioChunk(Uint8List pcm) {
    if (pcm.isEmpty) return;
    _send({'type': 'audio', 'data': base64Encode(pcm)});
  }

  /// JPEG video frame gönder.
  void sendVideoFrame(Uint8List jpeg) {
    if (jpeg.isEmpty) return;
    _send({
      'type': 'video',
      'data': base64Encode(jpeg),
      'mime_type': 'image/jpeg',
    });
  }

  /// PTT release — kullanıcı sırasını kapat.
  void endAudioTurn() {
    _send({'type': 'end_audio'});
  }

  /// Metin mesajı gönder (opsiyonel).
  void sendText(String text) {
    if (text.isEmpty) return;
    _send({'type': 'text', 'text': text});
  }

  void _setState(LiveConnectionState s) {
    if (_state == s) return;
    _state = s;
    notifyListeners();
  }

  Future<void> close() async {
    _closedByUser = true;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _setState(LiveConnectionState.disconnected);
  }

  @override
  void dispose() {
    close();
    _events.close();
    super.dispose();
  }
}
