"""Groq Whisper — ses → metin (Türkçe önerilir, otomatik dil algılama)."""
from typing import Optional, Tuple

from groq import APIError, Groq, RateLimitError

from app.core.config import settings
from app.core.errors import AhlasError

_client: Optional[Groq] = None


def _get_client() -> Groq:
    global _client
    if _client is None:
        if not settings.GROQ_API_KEY:
            raise AhlasError(
                code="AI_CONFIG_MISSING",
                message="Groq API anahtarı yapılandırılmamış.",
                status_code=503,
            )
        _client = Groq(api_key=settings.GROQ_API_KEY)
    return _client


def transcribe(audio_bytes: bytes, filename: str) -> Tuple[str, str]:
    """Sesi metne çevirir. Dönüş: (text, model_used).

    Groq'un multipart Whisper endpoint'i dosya benzeri obje bekliyor;
    file=(filename, bytes) tuple'ı yeterli.
    """
    client = _get_client()
    try:
        transcription = client.audio.transcriptions.create(
            file=(filename, audio_bytes),
            model=settings.GROQ_STT_MODEL,
            language="tr",
            response_format="text",
        )
    except RateLimitError as exc:
        raise AhlasError(
            code="AI_RATE_LIMIT",
            message="Ses tanıma servisi şu an yoğun, lütfen birazdan tekrar dene.",
            status_code=429,
            detail=str(exc),
        )
    except APIError as exc:
        raise AhlasError(
            code="AI_UPSTREAM_ERROR",
            message="Ses tanıma servisine erişilemiyor.",
            status_code=502,
            detail=str(exc),
        )

    # response_format="text" iken SDK doğrudan string döner.
    text = str(transcription).strip() if transcription is not None else ""
    if not text:
        raise AhlasError(
            code="AI_EMPTY_RESPONSE",
            message="Ses tanınamadı. Lütfen daha net konuşup tekrar dene.",
            status_code=422,
        )
    return text, settings.GROQ_STT_MODEL
