import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../config/env.dart';
import '../models/api_error.dart';
import 'auth_service.dart';

class ApiService {
  final Dio _dio;
  final AuthService _auth;

  ApiService(this._auth)
      : _dio = Dio(
          BaseOptions(
            baseUrl: Env.apiBaseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
            sendTimeout: const Duration(seconds: 60),
            headers: {'Content-Type': 'application/json'},
          ),
        ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = _auth.accessToken;
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) {
          handler.reject(_transformError(error));
        },
      ),
    );
  }

  Dio get dio => _dio;

  DioException _transformError(DioException error) {
    final response = error.response;

    if (response != null && response.data is Map<String, dynamic>) {
      final apiError = ApiError.fromJson(
        response.data as Map<String, dynamic>,
        statusCode: response.statusCode,
      );
      return error.copyWith(error: apiError);
    }

    String message;
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        message = 'Sunucuya bağlanılamadı: zaman aşımı';
        break;
      case DioExceptionType.connectionError:
        message = 'İnternet bağlantısı yok veya sunucu ulaşılamıyor';
        break;
      case DioExceptionType.badCertificate:
        message = 'Güvenli bağlantı hatası';
        break;
      case DioExceptionType.cancel:
        message = 'İstek iptal edildi';
        break;
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
      default:
        message = 'Beklenmeyen bir hata oluştu';
    }

    return error.copyWith(error: ApiError.network(message));
  }

  Future<Response<dynamic>> listConversations() =>
      _dio.get('/api/v1/conversations');

  Future<Response<dynamic>> createConversation({String? title}) =>
      _dio.post('/api/v1/conversations', data: {'title': title});

  Future<Response<dynamic>> listMessages(String conversationId) =>
      _dio.get('/api/v1/conversations/$conversationId/messages');

  Future<Response<dynamic>> sendMessage(
    String conversationId,
    String content, {
    String? voice,
  }) =>
      _dio.post(
        '/api/v1/conversations/$conversationId/messages',
        data: {'content': content},
        queryParameters: voice == null ? null : {'voice': voice},
      );

  Future<Response<dynamic>> uploadMedia({
    required Uint8List bytes,
    required String filename,
    String? conversationId,
    String? contentType,
  }) {
    // Backend detects MIME from filename; contentType kept for future use.
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
      if (conversationId != null) 'conversation_id': conversationId,
    });
    return _dio.post('/api/v1/media/upload', data: formData);
  }

  Future<Response<dynamic>> uploadMediaFromUrl({
    required String url,
    String? conversationId,
  }) =>
      _dio.post(
        '/api/v1/media/from-url',
        data: {
          'url': url,
          if (conversationId != null) 'conversation_id': conversationId,
        },
      );

  Future<Response<dynamic>> mediaStatus(String mediaId) =>
      _dio.get('/api/v1/media/$mediaId/status');

  Future<Response<dynamic>> mediaAnalysis(String mediaId) =>
      _dio.get('/api/v1/media/$mediaId/analysis');

  Future<Response<dynamic>> askMedia(
    String mediaId,
    String question, {
    String? conversationId,
    String? voice,
  }) =>
      _dio.post(
        '/api/v1/media/$mediaId/ask',
        data: {
          'question': question,
          if (conversationId != null) 'conversation_id': conversationId,
        },
        queryParameters: voice == null ? null : {'voice': voice},
      );

  Future<Response<dynamic>> sendVoiceMessage(
    String conversationId, {
    required Uint8List bytes,
    required String filename,
    String? mimeType,
    String? voice,
  }) {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    return _dio.post(
      '/api/v1/conversations/$conversationId/voice-message',
      data: formData,
      queryParameters: voice == null ? null : {'voice': voice},
      options: Options(
        // TTS + STT + LLM: 60s yetmeyebilir, cömert ol.
        receiveTimeout: const Duration(seconds: 120),
        sendTimeout: const Duration(seconds: 60),
      ),
    );
  }

  Future<Response<dynamic>> health() => _dio.get('/api/v1/health');
}
