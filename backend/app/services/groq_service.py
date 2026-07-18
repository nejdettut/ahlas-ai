"""Groq (Llama) — Gemini rate-limit / erişim hatasında devreye giren fallback servisi."""
from typing import List, Optional, Tuple

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


def _to_groq_messages(user_message: str, history: List[dict]) -> List[dict]:
    """OpenAI/Groq uyumlu mesaj listesi üretir."""
    messages: List[dict] = []
    for m in history:
        role = m.get("role")
        content = m.get("content") or ""
        if role not in ("user", "assistant", "system") or not content:
            continue
        messages.append({"role": role, "content": content})
    messages.append({"role": "user", "content": user_message})
    return messages


def generate_reply(user_message: str, history: List[dict]) -> str:
    """Fallback yanıt üretimi. Hatalar AhlasError olarak fırlar."""
    client = _get_client()
    try:
        completion = client.chat.completions.create(
            model=settings.GROQ_MODEL,
            messages=_to_groq_messages(user_message, history),
        )
        text = (completion.choices[0].message.content or "").strip()
        if not text:
            raise AhlasError(
                code="AI_EMPTY_RESPONSE",
                message="Yedek yapay zeka servisi boş yanıt döndürdü.",
                status_code=502,
            )
        return text
    except RateLimitError as exc:
        raise AhlasError(
            code="AI_RATE_LIMIT",
            message="Yapay zeka servisi şu an yoğun, lütfen birazdan tekrar deneyin.",
            status_code=429,
            detail=str(exc),
        )
    except APIError as exc:
        raise AhlasError(
            code="AI_UPSTREAM_ERROR",
            message="Yedek yapay zeka servisine erişilemiyor.",
            status_code=502,
            detail=str(exc),
        )


def check_health() -> Tuple[bool, Optional[str]]:
    try:
        client = _get_client()
        completion = client.chat.completions.create(
            model=settings.GROQ_MODEL,
            messages=[{"role": "user", "content": "ping"}],
            max_tokens=5,
        )
        text = (completion.choices[0].message.content or "").strip()
        if text:
            return True, None
        return False, "boş yanıt"
    except Exception as exc:
        return False, str(exc)
