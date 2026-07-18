"""Edge-TTS — metin → mp3 bytes. Türkçe neural ses.

Not: `edge-tts` Microsoft'un dahili servisini kullanır; API anahtarı yok.
"""
from typing import Optional, Tuple

import edge_tts

from app.core.config import settings
from app.core.errors import AhlasError


async def synthesize(text: str, voice: Optional[str] = None) -> Tuple[bytes, str]:
    """Metin → (mp3_bytes, voice_used). Streaming chunk'ları birleştirir."""
    text = (text or "").strip()
    if not text:
        raise AhlasError(
            code="VALIDATION_ERROR",
            message="Seslendirilecek metin boş.",
            status_code=400,
        )

    voice_name = (voice or settings.TTS_VOICE).strip() or "tr-TR-EmelNeural"
    try:
        communicate = edge_tts.Communicate(text=text, voice=voice_name)
        chunks: list[bytes] = []
        async for chunk in communicate.stream():
            if chunk.get("type") == "audio":
                data = chunk.get("data")
                if isinstance(data, (bytes, bytearray)):
                    chunks.append(bytes(data))
    except Exception as exc:  # edge-tts özel hata sınıfı sınırlı
        raise AhlasError(
            code="AI_UPSTREAM_ERROR",
            message="Sesli yanıt üretilemedi.",
            status_code=502,
            detail=str(exc),
        )

    audio = b"".join(chunks)
    if not audio:
        raise AhlasError(
            code="AI_EMPTY_RESPONSE",
            message="Sesli yanıt boş döndü.",
            status_code=502,
        )
    return audio, voice_name
