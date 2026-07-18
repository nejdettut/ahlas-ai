enum MediaAnalysisStatus { pending, processing, completed, failed }

MediaAnalysisStatus parseMediaAnalysisStatus(String? value) {
  switch (value) {
    case 'processing':
      return MediaAnalysisStatus.processing;
    case 'completed':
      return MediaAnalysisStatus.completed;
    case 'failed':
      return MediaAnalysisStatus.failed;
    case 'pending':
    default:
      return MediaAnalysisStatus.pending;
  }
}

class MediaUpload {
  final String mediaId;
  final MediaAnalysisStatus status;

  const MediaUpload({required this.mediaId, required this.status});

  factory MediaUpload.fromJson(Map<String, dynamic> json) {
    return MediaUpload(
      mediaId: json['media_id'] as String,
      status: parseMediaAnalysisStatus(json['analysis_status'] as String?),
    );
  }
}

class MediaAnalysis {
  final String mediaId;
  final String? summary;
  final String? detailedAnalysis;
  final List<String> detectedObjects;
  final String? detectedText;
  final String? sentiment;
  final String? aiModelUsed;

  const MediaAnalysis({
    required this.mediaId,
    this.summary,
    this.detailedAnalysis,
    required this.detectedObjects,
    this.detectedText,
    this.sentiment,
    this.aiModelUsed,
  });

  factory MediaAnalysis.fromJson(Map<String, dynamic> json) {
    final rawObjects = json['detected_objects'];
    final objects = <String>[];
    if (rawObjects is List) {
      for (final item in rawObjects) {
        if (item != null) objects.add(item.toString());
      }
    }
    return MediaAnalysis(
      mediaId: json['media_id'] as String,
      summary: json['summary'] as String?,
      detailedAnalysis: json['detailed_analysis'] as String?,
      detectedObjects: objects,
      detectedText: json['detected_text'] as String?,
      sentiment: json['sentiment'] as String?,
      aiModelUsed: json['ai_model_used'] as String?,
    );
  }
}
