"""Gemini 2.5 Flash — metin ve görsel/video sohbet servisi.

Rate limit veya erişilebilirlik hatalarında AhlasError fırlatır;
çağıran router (metin için) bu durumda Groq'a otomatik fallback yapar.

Medya analizi Groq'a devredilemez (Groq görsel/video anlamıyor), o yüzden
media endpoint'lerinde fallback yoktur.
"""
import json
from typing import Any, Dict, List, Optional, Tuple

import google.generativeai as genai
from google.api_core import exceptions as google_exceptions

from app.core.config import settings
from app.core.errors import AhlasError

_configured: bool = False


def _configure() -> None:
    """Modülü ilk kullanımda genai.configure ile hazırla."""
    global _configured
    if not settings.GEMINI_API_KEY:
        raise AhlasError(
            code="AI_CONFIG_MISSING",
            message="Gemini API anahtarı yapılandırılmamış.",
            status_code=503,
        )
    if not _configured:
        genai.configure(api_key=settings.GEMINI_API_KEY)
        _configured = True


def _to_gemini_history(messages: List[dict]) -> List[dict]:
    """DB mesaj listesini Gemini'nin beklediği role/parts formatına çevirir.

    Gemini yalnızca 'user' ve 'model' rollerini kabul eder; 'system' mesajları
    varsa şimdilik user olarak dahil edilir.
    """
    history: List[dict] = []
    for m in messages:
        role = m.get("role")
        content = m.get("content") or ""
        if not content:
            continue
        gemini_role = "user" if role in ("user", "system") else "model"
        history.append({"role": gemini_role, "parts": [content]})
    return history


def generate_reply(user_message: str, history: List[dict]) -> str:
    """Sohbet geçmişi + yeni kullanıcı mesajı → asistan yanıtı (metin).

    Hatalarda AhlasError fırlatır (AI_RATE_LIMIT, AI_UPSTREAM_ERROR, AI_EMPTY_RESPONSE).
    """
    _configure()
    model = genai.GenerativeModel(settings.GEMINI_MODEL)
    try:
        chat = model.start_chat(history=_to_gemini_history(history))
        response = chat.send_message(user_message)
        text = (getattr(response, "text", None) or "").strip()
        if not text:
            raise AhlasError(
                code="AI_EMPTY_RESPONSE",
                message="Yapay zeka boş yanıt döndürdü.",
                status_code=502,
            )
        return text
    except google_exceptions.ResourceExhausted as exc:
        # Free tier / dakikalık limit doldu
        raise AhlasError(
            code="AI_RATE_LIMIT",
            message="Yapay zeka servisi şu an yoğun, lütfen birazdan tekrar deneyin.",
            status_code=429,
            detail=str(exc),
        )
    except google_exceptions.GoogleAPIError as exc:
        raise AhlasError(
            code="AI_UPSTREAM_ERROR",
            message="Yapay zeka servisine erişilemiyor.",
            status_code=502,
            detail=str(exc),
        )


def check_health() -> Tuple[bool, Optional[str]]:
    """Gemini bağlantısını hafif bir istekle doğrular."""
    try:
        _configure()
        model = genai.GenerativeModel(settings.GEMINI_MODEL)
        response = model.generate_content("ping")
        text = (getattr(response, "text", None) or "").strip()
        if text:
            return True, None
        return False, "boş yanıt"
    except Exception as exc:  # health check hiç bir zaman uygulamayı çökertmemeli
        return False, str(exc)


# ==========================================================
# Medya analizi (görsel / video / ses)
# ==========================================================
_MEDIA_ANALYSIS_PROMPT = """Verilen medyayı analiz et ve TAM OLARAK aşağıdaki JSON şemasında bir yanıt üret:

{{
  "summary": "1-2 cümlelik kısa özet",
  "detailed_analysis": "Detaylı açıklama; bağlam, dikkat çeken unsurlar, olası anlam",
  "detected_objects": ["nesne1", "nesne2"],
  "detected_text": "OCR ile çıkarılan görünür metin — yoksa boş string",
  "sentiment": "positive | neutral | negative — video/ses tonu için, uygun değilse null"
}}

Kurallar:
- Tüm metin alanları Türkçe olmalı.
- "detected_objects" en fazla 12 madde, her biri kısa Türkçe kelime.
- Yanıtın SADECE geçerli JSON olsun; kod bloğu (```) veya açıklama ekleme.

{extra}"""


def _parse_json_response(raw: str) -> Dict[str, Any]:
    """Gemini'den gelen JSON metnini toleranslı parse eder."""
    text = (raw or "").strip()
    if not text:
        raise ValueError("boş yanıt")
    # Model bazen ```json``` bloğu ile sarabiliyor — temizle
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:]
        text = text.strip()
    return json.loads(text)


def analyze_media(
    data: bytes,
    mime_type: str,
    instructions: Optional[str] = None,
) -> Dict[str, Any]:
    """Görsel/video/ses'i Gemini'ye gönderip yapılandırılmış analiz döner.

    Dönüş: {
        "summary", "detailed_analysis", "detected_objects", "detected_text",
        "sentiment", "ai_model_used", "raw_response"
    }
    """
    _configure()
    # response_mime_type=application/json → Gemini'nin çıktısını doğrudan JSON'a zorlar
    model = genai.GenerativeModel(
        settings.GEMINI_MODEL,
        generation_config={"response_mime_type": "application/json"},
    )
    extra = f"Ek talimat: {instructions.strip()}" if instructions else ""
    prompt = _MEDIA_ANALYSIS_PROMPT.format(extra=extra)

    try:
        response = model.generate_content(
            [{"mime_type": mime_type, "data": data}, prompt]
        )
        raw_text = getattr(response, "text", None) or ""
        try:
            parsed = _parse_json_response(raw_text)
        except (ValueError, json.JSONDecodeError) as exc:
            raise AhlasError(
                code="AI_UPSTREAM_ERROR",
                message="Yapay zeka analiz sonucunu okuyamadı.",
                status_code=502,
                detail=f"JSON parse hatası: {exc}",
            )

        # Alanları normalize et
        detected_objects = parsed.get("detected_objects") or []
        if not isinstance(detected_objects, list):
            detected_objects = []

        return {
            "summary": (parsed.get("summary") or "").strip(),
            "detailed_analysis": (parsed.get("detailed_analysis") or "").strip(),
            "detected_objects": [str(x) for x in detected_objects][:12],
            "detected_text": parsed.get("detected_text") or None,
            "sentiment": parsed.get("sentiment") or None,
            "ai_model_used": settings.GEMINI_MODEL,
            "raw_response": {"text": raw_text},
        }
    except google_exceptions.ResourceExhausted as exc:
        raise AhlasError(
            code="AI_RATE_LIMIT",
            message="Yapay zeka servisi şu an yoğun, lütfen birazdan tekrar deneyin.",
            status_code=429,
            detail=str(exc),
        )
    except google_exceptions.GoogleAPIError as exc:
        raise AhlasError(
            code="AI_UPSTREAM_ERROR",
            message="Yapay zeka servisine erişilemiyor.",
            status_code=502,
            detail=str(exc),
        )


def ask_about_media(
    data: bytes,
    mime_type: str,
    question: str,
    history: Optional[List[dict]] = None,
) -> str:
    """Medya + soru → serbest metin yanıt (opsiyonel sohbet geçmişi ile).

    Fallback yok: Groq görsel anlamıyor.
    """
    _configure()
    model = genai.GenerativeModel(settings.GEMINI_MODEL)
    parts = [{"mime_type": mime_type, "data": data}, question]

    try:
        if history:
            chat = model.start_chat(history=_to_gemini_history(history))
            response = chat.send_message(parts)
        else:
            response = model.generate_content(parts)
        text = (getattr(response, "text", None) or "").strip()
        if not text:
            raise AhlasError(
                code="AI_EMPTY_RESPONSE",
                message="Yapay zeka boş yanıt döndürdü.",
                status_code=502,
            )
        return text
    except google_exceptions.ResourceExhausted as exc:
        raise AhlasError(
            code="AI_RATE_LIMIT",
            message="Yapay zeka servisi şu an yoğun, lütfen birazdan tekrar deneyin.",
            status_code=429,
            detail=str(exc),
        )
    except google_exceptions.GoogleAPIError as exc:
        raise AhlasError(
            code="AI_UPSTREAM_ERROR",
            message="Yapay zeka servisine erişilemiyor.",
            status_code=502,
            detail=str(exc),
        )
