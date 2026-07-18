import 'package:supabase_flutter/supabase_flutter.dart';

String translateAuthError(Object error) {
  if (error is AuthException) {
    final msg = error.message.toLowerCase();
    if (msg.contains('invalid login credentials')) {
      return 'Email veya şifre hatalı.';
    }
    if (msg.contains('user already registered')) {
      return 'Bu email adresi zaten kayıtlı.';
    }
    if (msg.contains('email not confirmed')) {
      return 'Email adresi doğrulanmamış. Gelen kutunu kontrol et.';
    }
    if (msg.contains('password should be at least')) {
      return 'Şifre en az 6 karakter olmalı.';
    }
    if (msg.contains('valid email')) {
      return 'Geçerli bir email adresi gir.';
    }
    if (msg.contains('network') || msg.contains('failed host lookup')) {
      return 'İnternet bağlantısı yok veya sunucuya ulaşılamıyor.';
    }
    return error.message;
  }
  return 'Beklenmeyen bir hata oluştu: $error';
}
