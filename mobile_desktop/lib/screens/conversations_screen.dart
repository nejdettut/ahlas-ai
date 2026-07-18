import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/api_error.dart';
import '../models/conversation.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../utils/date_format.dart';
import 'chat_screen.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  List<Conversation>? _conversations;
  ApiError? _error;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final api = context.read<ApiService>();
      final response = await api.listConversations();
      final data = response.data;
      if (data is! List) {
        throw const ApiError(
          code: 'UNEXPECTED_RESPONSE',
          message: 'Beklenmeyen sunucu yanıtı.',
        );
      }
      final items = data
          .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _conversations = items;
        _isLoading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.error is ApiError
            ? e.error as ApiError
            : ApiError.network('Sohbetler getirilemedi.');
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiError
            ? e
            : ApiError.network('Beklenmeyen bir hata oluştu.');
        _isLoading = false;
      });
    }
  }

  Future<void> _createConversation() async {
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => _NewConversationDialog(),
    );
    if (title == null || !mounted) return;

    try {
      final api = context.read<ApiService>();
      await api.createConversation(title: title.isEmpty ? null : title);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Yeni sohbet oluşturuldu.')),
      );
      await _load();
    } on DioException catch (e) {
      if (!mounted) return;
      final message = e.error is ApiError
          ? (e.error as ApiError).message
          : 'Sohbet oluşturulamadı.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sohbetlerim'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Yenile',
            onPressed: _isLoading ? null : _load,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'logout') auth.signOut();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'email',
                enabled: false,
                child: Text(
                  auth.user?.email ?? '',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 20),
                    SizedBox(width: 12),
                    Text('Çıkış yap'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createConversation,
        icon: const Icon(Icons.add),
        label: const Text('Yeni sohbet'),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _conversations == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _conversations == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _error!.message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Yeniden dene'),
              ),
            ],
          ),
        ),
      );
    }
    final items = _conversations ?? const [];
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.25),
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 64,
                      color: Colors.grey,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Henüz sohbetin yok',
                      style: TextStyle(fontSize: 18),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Sağ alttaki butonla ilk sohbetini başlat.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final c = items[index];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                Icons.chat_bubble_outline,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            title: Text(
              c.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(formatRelativeTr(c.updatedAt)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatScreen(conversation: c),
                ),
              );
              if (!mounted) return;
              // Refresh so updated_at ordering reflects new activity
              _load();
            },
          );
        },
      ),
    );
  }
}

class _NewConversationDialog extends StatefulWidget {
  @override
  State<_NewConversationDialog> createState() => _NewConversationDialogState();
}

class _NewConversationDialogState extends State<_NewConversationDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Yeni sohbet'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 200,
        decoration: const InputDecoration(
          labelText: 'Başlık (opsiyonel)',
          hintText: 'Yeni Sohbet',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Oluştur'),
        ),
      ],
    );
  }
}
