enum MessageRole { user, assistant, system }

MessageRole _parseRole(String? value) {
  switch (value) {
    case 'user':
      return MessageRole.user;
    case 'assistant':
      return MessageRole.assistant;
    case 'system':
      return MessageRole.system;
    default:
      return MessageRole.assistant;
  }
}

class Message {
  final String id;
  final String? conversationId;
  final MessageRole role;
  final String? content;
  final String contentType;
  final String? aiModelUsed;
  final DateTime createdAt;
  /// Assistant metninin TTS (Edge-TTS mp3) base64'ü. Sadece bazı endpoint
  /// yanıtlarında dolar (yeni gelen assistant mesajı için). Geçmiş çekilirken
  /// null gelir — kayıtlı değil.
  final String? audioBase64;

  const Message({
    required this.id,
    this.conversationId,
    required this.role,
    this.content,
    required this.contentType,
    this.aiModelUsed,
    required this.createdAt,
    this.audioBase64,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String?,
      role: _parseRole(json['role'] as String?),
      content: json['content'] as String?,
      contentType: json['content_type'] as String? ?? 'text',
      aiModelUsed: json['ai_model_used'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      audioBase64: json['audio_base64'] as String?,
    );
  }
}
