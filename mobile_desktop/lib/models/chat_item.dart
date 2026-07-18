import 'dart:typed_data';

import 'media.dart';
import 'message.dart';

/// Chat ekranında listelenen bir öğe — ya text mesajı ya da medya kartı.
sealed class ChatItem {
  DateTime get createdAt;
  String get itemKey;
}

class MessageItem extends ChatItem {
  final Message message;

  MessageItem(this.message);

  @override
  DateTime get createdAt => message.createdAt;

  @override
  String get itemKey => 'msg_${message.id}';
}

class MediaItem extends ChatItem {
  final String tempKey;
  String? mediaId;
  final String filename;
  String? fileType; // 'image' | 'video' | 'audio' | null (URL için önceden bilinmez)
  final Uint8List? previewBytes;
  final String? sourceUrl;
  MediaAnalysisStatus status;
  MediaAnalysis? analysis;
  String? errorMessage;
  final DateTime _createdAt;

  MediaItem({
    required this.tempKey,
    this.mediaId,
    required this.filename,
    this.fileType,
    this.previewBytes,
    this.sourceUrl,
    this.status = MediaAnalysisStatus.pending,
    this.analysis,
    this.errorMessage,
    DateTime? createdAt,
  }) : _createdAt = createdAt ?? DateTime.now();

  @override
  DateTime get createdAt => _createdAt;

  @override
  String get itemKey => 'media_$tempKey';
}
