class ApiError implements Exception {
  final String code;
  final String message;
  final String? detail;
  final int? statusCode;

  const ApiError({
    required this.code,
    required this.message,
    this.detail,
    this.statusCode,
  });

  factory ApiError.fromJson(Map<String, dynamic> json, {int? statusCode}) {
    final error = json['error'];
    if (error is Map<String, dynamic>) {
      return ApiError(
        code: error['code']?.toString() ?? 'UNKNOWN',
        message: error['message']?.toString() ?? 'Bilinmeyen hata',
        detail: error['detail']?.toString(),
        statusCode: statusCode,
      );
    }
    return ApiError(
      code: 'UNKNOWN',
      message: 'Bilinmeyen hata',
      statusCode: statusCode,
    );
  }

  factory ApiError.network(String message) =>
      ApiError(code: 'NETWORK_ERROR', message: message);

  @override
  String toString() => '[$code] $message';
}
