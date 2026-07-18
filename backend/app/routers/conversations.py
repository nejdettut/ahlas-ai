"""Sohbet ve mesaj endpoint'leri.

Kapsam:
- POST   /conversations                              → yeni sohbet oluştur
- GET    /conversations                              → sohbet listesi
- POST   /conversations/{id}/messages                → mesaj gönder (Gemini + Groq fallback)
- POST   /conversations/{id}/voice-message           → ses → transcript → yanıt → TTS
"""
import base64
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, File, Query, UploadFile

from app.core.auth import get_current_user
from app.core.config import settings
from app.core.errors import AhlasError
from app.core.supabase_client import get_supabase
from app.models.schemas import (
    ConversationCreate,
    ConversationOut,
    MessageCreate,
    MessageOut,
    VoiceMessageOut,
)
from app.services import gemini_service, groq_service, stt_service, tts_service

router = APIRouter(prefix="/conversations", tags=["conversations"])


# ----------------------------------------------------------
# Yardımcı: sohbetin ilgili kullanıcıya ait olduğunu doğrula
# ----------------------------------------------------------
def _verify_conversation_ownership(conversation_id: str, user_id: str) -> None:
    supabase = get_supabase()
    try:
        result = (
            supabase.table("conversations")
            .select("id, user_id")
            .eq("id", conversation_id)
            .limit(1)
            .execute()
        )
    except Exception as exc:
        raise AhlasError(
            code="DB_ERROR",
            message="Sohbet doğrulanamadı.",
            status_code=500,
            detail=str(exc),
        )
    rows = result.data or []
    # Bilgi sızdırmamak için başkasına ait sohbet de "bulunamadı" olarak döner
    if not rows or rows[0].get("user_id") != user_id:
        raise AhlasError(
            code="NOT_FOUND",
            message="Sohbet bulunamadı.",
            status_code=404,
        )


# ----------------------------------------------------------
# POST /conversations — yeni sohbet oluştur
# ----------------------------------------------------------
@router.post("", response_model=ConversationOut, status_code=201)
async def create_conversation(
    payload: ConversationCreate,
    user: dict = Depends(get_current_user),
) -> ConversationOut:
    supabase = get_supabase()
    title = (payload.title or "").strip() or "Yeni Sohbet"
    try:
        result = (
            supabase.table("conversations")
            .insert({"user_id": user["id"], "title": title})
            .execute()
        )
    except Exception as exc:
        raise AhlasError(
            code="DB_ERROR",
            message="Sohbet oluşturulamadı.",
            status_code=500,
            detail=str(exc),
        )

    if not result.data:
        raise AhlasError(
            code="DB_ERROR",
            message="Sohbet oluşturulamadı.",
            status_code=500,
        )
    return ConversationOut(**result.data[0])


# ----------------------------------------------------------
# GET /conversations — kullanıcının sohbetlerini listele
# ----------------------------------------------------------
@router.get("", response_model=List[ConversationOut])
async def list_conversations(
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    user: dict = Depends(get_current_user),
) -> List[ConversationOut]:
    supabase = get_supabase()
    try:
        result = (
            supabase.table("conversations")
            .select("*")
            .eq("user_id", user["id"])
            .order("updated_at", desc=True)
            .range(offset, offset + limit - 1)
            .execute()
        )
    except Exception as exc:
        raise AhlasError(
            code="DB_ERROR",
            message="Sohbetler getirilemedi.",
            status_code=500,
            detail=str(exc),
        )
    return [ConversationOut(**row) for row in (result.data or [])]


# ----------------------------------------------------------
# GET /conversations/{conversation_id}/messages — mesaj geçmişi
# ----------------------------------------------------------
@router.get(
    "/{conversation_id}/messages",
    response_model=List[MessageOut],
)
async def list_messages(
    conversation_id: str,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    user: dict = Depends(get_current_user),
) -> List[MessageOut]:
    _verify_conversation_ownership(conversation_id, user["id"])
    supabase = get_supabase()
    try:
        result = (
            supabase.table("messages")
            .select("*")
            .eq("conversation_id", conversation_id)
            .order("created_at", desc=False)
            .range(offset, offset + limit - 1)
            .execute()
        )
    except Exception as exc:
        raise AhlasError(
            code="DB_ERROR",
            message="Mesajlar getirilemedi.",
            status_code=500,
            detail=str(exc),
        )
    return [MessageOut(**row) for row in (result.data or [])]


# ----------------------------------------------------------
# POST /conversations/{conversation_id}/messages — mesaj gönder
# ----------------------------------------------------------
async def _synthesize_or_none(
    text: str,
    voice: Optional[str] = None,
) -> tuple[Optional[str], Optional[str]]:
    """TTS yap, base64 döndür. Hata olursa (None, None) — metin cevap yeterli."""
    try:
        audio, voice_used = await tts_service.synthesize(text, voice=voice)
        return base64.b64encode(audio).decode("ascii"), voice_used
    except Exception:
        return None, None


def _run_reply_pipeline(
    conversation_id: str,
    user_content: str,
    user_content_type: str,
) -> dict:
    """Ortak yanıt üretim akışı: kullanıcı mesajı kaydet → geçmiş çek →
    Gemini→Groq fallback → asistan mesajı kaydet → updated_at tazele.

    Dönüş: assistant mesaj satırı (dict). Hatalar AhlasError olarak fırlar.
    """
    supabase = get_supabase()

    # 1) Kullanıcı mesajını kaydet
    try:
        supabase.table("messages").insert(
            {
                "conversation_id": conversation_id,
                "role": "user",
                "content": user_content,
                "content_type": user_content_type,
            }
        ).execute()
    except Exception as exc:
        raise AhlasError(
            code="DB_ERROR",
            message="Mesaj kaydedilemedi.",
            status_code=500,
            detail=str(exc),
        )

    # 2) Sohbet geçmişini çek (son N mesaj, kronolojik sırada)
    try:
        history_result = (
            supabase.table("messages")
            .select("role, content, content_type, created_at")
            .eq("conversation_id", conversation_id)
            .order("created_at", desc=True)
            .limit(settings.MAX_HISTORY_MESSAGES + 1)
            .execute()
        )
    except Exception as exc:
        raise AhlasError(
            code="DB_ERROR",
            message="Sohbet geçmişi getirilemedi.",
            status_code=500,
            detail=str(exc),
        )

    all_rows = list(reversed(history_result.data or []))
    history = all_rows[:-1] if all_rows else []

    # 3) Gemini → hata olursa Groq fallback
    ai_model_used = settings.GEMINI_MODEL
    reply_text: str
    try:
        reply_text = gemini_service.generate_reply(user_content, history)
    except AhlasError as gemini_err:
        fallback_codes = {
            "AI_RATE_LIMIT",
            "AI_UPSTREAM_ERROR",
            "AI_CONFIG_MISSING",
            "AI_EMPTY_RESPONSE",
        }
        if gemini_err.code in fallback_codes:
            try:
                reply_text = groq_service.generate_reply(user_content, history)
                ai_model_used = settings.GROQ_MODEL
            except AhlasError:
                raise gemini_err
        else:
            raise

    # 4) Asistan yanıtını kaydet
    try:
        assistant_msg = (
            supabase.table("messages")
            .insert(
                {
                    "conversation_id": conversation_id,
                    "role": "assistant",
                    "content": reply_text,
                    "content_type": "text",
                    "ai_model_used": ai_model_used,
                }
            )
            .execute()
        )
        if not assistant_msg.data:
            raise AhlasError(
                code="DB_ERROR",
                message="Asistan yanıtı kaydedilemedi.",
                status_code=500,
            )
    except AhlasError:
        raise
    except Exception as exc:
        raise AhlasError(
            code="DB_ERROR",
            message="Asistan yanıtı kaydedilemedi.",
            status_code=500,
            detail=str(exc),
        )

    # 5) Sohbetin updated_at değerini tazele
    try:
        supabase.table("conversations").update(
            {"updated_at": datetime.now(timezone.utc).isoformat()}
        ).eq("id", conversation_id).execute()
    except Exception:
        pass

    return assistant_msg.data[0]


@router.post(
    "/{conversation_id}/messages",
    response_model=MessageOut,
    status_code=201,
)
async def send_message(
    conversation_id: str,
    payload: MessageCreate,
    voice: Optional[str] = Query(default=None),
    user: dict = Depends(get_current_user),
) -> MessageOut:
    """Kullanıcı mesajını kaydeder, Gemini'ye sorar (hata → Groq fallback), yanıtı döner.
    Assistant metnini Edge-TTS ile seslendirir; base64 mp3 mesajla birlikte döner.
    Query param ?voice=tr-TR-AhmetNeural ile ses değiştirilebilir."""
    _verify_conversation_ownership(conversation_id, user["id"])
    assistant_row = _run_reply_pipeline(
        conversation_id=conversation_id,
        user_content=payload.content,
        user_content_type=payload.content_type,
    )
    audio_b64, _ = await _synthesize_or_none(
        assistant_row.get("content") or "",
        voice=voice,
    )
    assistant_row["audio_base64"] = audio_b64
    return MessageOut(**assistant_row)


# ----------------------------------------------------------
# POST /conversations/{conversation_id}/voice-message
# ----------------------------------------------------------
@router.post(
    "/{conversation_id}/voice-message",
    response_model=VoiceMessageOut,
    status_code=201,
)
async def send_voice_message(
    conversation_id: str,
    file: UploadFile = File(...),
    voice: Optional[str] = Query(default=None),
    user: dict = Depends(get_current_user),
) -> VoiceMessageOut:
    """Ses dosyasını transcribe eder, sohbete kullanıcı mesajı olarak yazar,
    Ahlas yanıtını üretir ve mp3 olarak (base64) döndürür."""
    _verify_conversation_ownership(conversation_id, user["id"])

    audio_bytes = await file.read()
    if not audio_bytes:
        raise AhlasError(
            code="VALIDATION_ERROR",
            message="Ses dosyası boş.",
            status_code=400,
        )
    max_bytes = settings.MAX_UPLOAD_MB * 1024 * 1024
    if len(audio_bytes) > max_bytes:
        raise AhlasError(
            code="MEDIA_TOO_LARGE",
            message=f"Ses dosyası {settings.MAX_UPLOAD_MB}MB sınırını aşıyor.",
            status_code=413,
        )

    # 1) STT
    transcript, stt_model = stt_service.transcribe(
        audio_bytes,
        file.filename or "voice.m4a",
    )

    # 2) Chat pipeline (kullanıcı mesajı content_type="voice")
    assistant_row = _run_reply_pipeline(
        conversation_id=conversation_id,
        user_content=transcript,
        user_content_type="voice",
    )

    # 3) TTS — mesajın içine göm
    reply_text = assistant_row.get("content") or ""
    audio_b64, voice_used = await _synthesize_or_none(reply_text, voice=voice)
    assistant_row["audio_base64"] = audio_b64

    return VoiceMessageOut(
        transcript=transcript,
        message=MessageOut(**assistant_row),
        stt_model_used=stt_model,
        tts_voice=voice_used,
    )
