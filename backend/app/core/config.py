"""Uygulama ayarları — .env üzerinden okunur, tek yerden yönetilir."""
import os
from dotenv import load_dotenv

# .env dosyasını yükle (proje kök dizininden çalıştırılırsa otomatik bulur)
load_dotenv()


class Settings:
    # Ortam
    APP_ENV: str = os.getenv("APP_ENV", "development")
    API_PREFIX: str = "/api/v1"

    # Supabase — NEXT_PUBLIC_/SERVICE_ROLE_ isimlerine de fallback (paylaşımlı .env kolaylığı)
    SUPABASE_URL: str = (
        os.getenv("SUPABASE_URL")
        or os.getenv("NEXT_PUBLIC_SUPABASE_URL", "")
    )
    SUPABASE_KEY: str = (
        os.getenv("SUPABASE_KEY")
        or os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
    )

    # AI anahtarları
    GEMINI_API_KEY: str = os.getenv("GEMINI_API_KEY", "")
    GROQ_API_KEY: str = os.getenv("GROQ_API_KEY", "")

    # Model adları
    GEMINI_MODEL: str = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
    GROQ_MODEL: str = os.getenv("GROQ_MODEL", "llama-3.3-70b-versatile")
    GROQ_STT_MODEL: str = os.getenv("GROQ_STT_MODEL", "whisper-large-v3")

    # TTS — Edge-TTS Türkçe ses
    TTS_VOICE: str = os.getenv("TTS_VOICE", "tr-TR-EmelNeural")

    # Gemini Live (WebSocket, duplex ses + kamera)
    GEMINI_LIVE_MODEL: str = os.getenv(
        "GEMINI_LIVE_MODEL", "models/gemini-2.5-flash-native-audio-preview-09-2025"
    )
    # Live API prebuilt voices: Puck, Charon, Kore, Fenrir, Aoede, Leda, Orus, Zephyr
    # Multilingual — Puck nötr ve akıcı.
    GEMINI_LIVE_VOICE: str = os.getenv("GEMINI_LIVE_VOICE", "Puck")

    # Ahlas persona
    AHLAS_SYSTEM_INSTRUCTION: str = os.getenv(
        "AHLAS_SYSTEM_INSTRUCTION",
        (
            "Sen Ahlas'sın — Iron Man'in JARVIS'inden esinlenilmiş kişisel "
            "yapay zeka asistanısın. Sahibin Nejdet Tut. Türkçe konuşursun. "
            "Kısa, doğal, samimi ve nazik cevaplar verirsin. Kamera açıksa "
            "gördüğün sahneyi analiz eder, kullanıcının sorularını yanıtlarsın."
        ),
    )

    # Sohbet geçmişi context boyutu (Gemini/Groq'a taşınacak mesaj sayısı)
    MAX_HISTORY_MESSAGES: int = int(os.getenv("MAX_HISTORY_MESSAGES", "20"))

    # Storage
    STORAGE_BUCKET: str = os.getenv("STORAGE_BUCKET", "ahlas-media")
    # Gemini inline data limiti 20MB — üstü için File API gerekir (şimdilik desteklenmiyor)
    MAX_UPLOAD_MB: int = int(os.getenv("MAX_UPLOAD_MB", "20"))
    SIGNED_URL_EXPIRES_SECONDS: int = int(os.getenv("SIGNED_URL_EXPIRES_SECONDS", "3600"))

    @property
    def is_supabase_configured(self) -> bool:
        return bool(self.SUPABASE_URL and self.SUPABASE_KEY)


settings = Settings()
