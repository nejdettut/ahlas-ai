import 'package:flutter_test/flutter_test.dart';

import 'package:ahlas/models/api_error.dart';

void main() {
  group('ApiError', () {
    test('backend hata JSON formatını parse eder', () {
      final err = ApiError.fromJson(
        {
          'error': {
            'code': 'UNAUTHORIZED',
            'message': 'Oturum süresi doldu',
            'detail': null,
          }
        },
        statusCode: 401,
      );
      expect(err.code, 'UNAUTHORIZED');
      expect(err.message, 'Oturum süresi doldu');
      expect(err.statusCode, 401);
    });

    test('geçersiz JSON için UNKNOWN döner', () {
      final err = ApiError.fromJson({'foo': 'bar'});
      expect(err.code, 'UNKNOWN');
      expect(err.message, 'Bilinmeyen hata');
    });

    test('network factory çalışır', () {
      final err = ApiError.network('Bağlantı yok');
      expect(err.code, 'NETWORK_ERROR');
      expect(err.message, 'Bağlantı yok');
    });
  });
}
