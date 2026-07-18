"""Gemini Live API wrapper — duplex ses + video streaming.

Not: `google-genai` (yeni SDK) kullanılır. Eski `google-generativeai` Live'ı desteklemez.
"""
from contextlib import asynccontextmanager
from typing import AsyncIterator, Optional

from google import genai
from google.genai import types

from app.core.config import settings
from app.core.errors import AhlasError

_client: Optional[genai.Client] = None


def _get_client() -> genai.Client:
    global _client
    if _client is None:
        if not settings.GEMINI_API_KEY:
            raise AhlasError(
                code="AI_CONFIG_MISSING",
                message="Gemini API anahtarı yapılandırılmamış.",
                status_code=503,
            )
        _client = genai.Client(api_key=settings.GEMINI_API_KEY)
    return _client


def _build_config(
    voice_name: Optional[str] = None,
    system_instruction: Optional[str] = None,
) -> types.LiveConnectConfig:
    voice = (voice_name or settings.GEMINI_LIVE_VOICE).strip() or "Puck"
    instr = (system_instruction or settings.AHLAS_SYSTEM_INSTRUCTION).strip()
    return types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        system_instruction=types.Content(
            parts=[types.Part(text=instr)],
        ),
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(
                    voice_name=voice,
                ),
            ),
        ),
        # Transkript alanları: client hem sesi çalar hem metni gösterir
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
    )


@asynccontextmanager
async def open_session(
    voice_name: Optional[str] = None,
    system_instruction: Optional[str] = None,
) -> AsyncIterator["genai.live.AsyncSession"]:
    """Async context manager — Gemini Live oturumu açar ve kapatır."""
    client = _get_client()
    config = _build_config(voice_name, system_instruction)
    try:
        async with client.aio.live.connect(
            model=settings.GEMINI_LIVE_MODEL,
            config=config,
        ) as session:
            yield session
    except Exception as exc:
        raise AhlasError(
            code="AI_UPSTREAM_ERROR",
            message="Canlı oturum başlatılamadı.",
            status_code=502,
            detail=str(exc),
        )
