import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ahlas'ın konuştuğu Edge-TTS sesi. Kullanıcı chat AppBar'ından değiştirebilir;
/// tercih SharedPreferences'ta saklanır.
class VoicePreference extends ChangeNotifier {
  static const _prefKey = 'ahlas.tts_voice';

  static const String defaultVoice = 'tr-TR-EmelNeural';

  /// UI'da gösterilecek etiketler.
  static const Map<String, String> availableVoices = {
    'tr-TR-EmelNeural': 'Kadın (Emel)',
    'tr-TR-AhmetNeural': 'Erkek (Ahmet)',
  };

  String _voice = defaultVoice;
  String get voice => _voice;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefKey);
    if (stored != null && availableVoices.containsKey(stored)) {
      _voice = stored;
      notifyListeners();
    }
  }

  Future<void> setVoice(String value) async {
    if (!availableVoices.containsKey(value) || value == _voice) return;
    _voice = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, value);
  }
}
