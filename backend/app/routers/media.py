"""Medya endpoint'leri.

Kapsam:
- POST /media/upload                → dosya yükle, arka planda analizi tetikle
- GET  /media/{id}/status           → analiz durumu (polling için)
- GET  /media/{id}/analysis         → tamamlanan analiz sonucu
- POST /media/{id}/ask              → medya + soru → Gemini yanıt
                                       (conversation_id varsa mesajlar geçmişe kaydedilir)
"""
from typing import Optional
from urllib.parse import urlparse, unquote

import httpx
from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, Query, UploadFile

from app.core.auth import get_current_user
from app.core.config import settings
from app.core.errors import AhlasError
from app.core.supabase_client import get_supabase
from app.models.schemas import (
    MediaAnalysisOut,
    MediaAskIn,
    MediaAskOut,
    MediaFromUrlIn,
    MediaStatusOut,
    MediaUploadOut,
)
import base64

from app.services import gemini_service, storage_service, tts_service

router = APIRouter(prefix="/media", tags=["media"])


# ----------------------------------------------------------
# Yardımcılar
# ----------------------------------------------------------
def _verify_media_ownership(media_id: str, user_id: str) -> dict:
    """media_items kaydını çekip sahiplik doğrular; ilgili satırı döner."""
    supabase = get_supabase()
    try:
        result = (
            supabase.table("media_items")
            .select("*")
            .eq("id", media_id)
            .limit(1)
            .execute()
        )
    except Exception as exc:
        raise AhlasError(
            code="DB_ERROR",
            message="Medya bilgisi getirilemedi.",
            status_code=500,
            detail=str(exc),
        )
    rows = result.data or []
    if not rows or rows[0].get("user_id") != user_id:
        raise AhlasError(
            code="NOT_FOUND",
            message="Medya bulunamadı.",
            status_code=404,
        )
    return rows[0]


def _verify_conversation_ownership(conversation_id: str, user_id: str) -> None:
    supabase = get_supabase()
    try:
        r = (
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
    rows = r.data or []
    if not rows or rows[0].get("user_id") != user_id:
        raise AhlasError(
            code="NOT_FOUND",
            message="Sohbet bulunamadı.",
            status_code=404,
        )


def _run_analysis(media_id: str, storage_path: str, mime_type: str) -> None:
    """Arka plan görevi — kendi hata yönetimini yapmalı; HTTP context yok.

    Akış:
      pending → processing → (completed | failed)
    """
    supabase = get_supabase()

    # 1) status = processing
    try:
        supabase.table("media_items").update(
            {"analysis_status": "processing"}
        ).eq("id", media_id).execute()
    except Exception:
        pass  # kritik değil

    try:
        # 2) dosyayı indir
        data = storage_service.download_bytes(storage_path)
        # 3) Gemini'ye analiz için gönder
        analysis = gemini_service.analyze_media(data, mime_type)
        # 4) media_analysis tablosuna yaz
        supabase.table("media_analysis").insert(
            {
                "media_id": media_id,
                "summary": analysis["summary"],
                "detailed_analysis": analysis["detailed_analysis"],
                "detected_objects": analysis["detected_objects"],
                "detected_text": analysis["detected_text"],
                "sentiment": analysis["sentiment"],
                "ai_model_used": analysis["ai_model_used"],
                "raw_response": analysis["raw_response"],
            }
        ).execute()
        # 5) status = completed
        supabase.table("media_items").update(
            {"analysis_status": "completed"}
        ).eq("id", media_id).execute()
    except Exception as exc:
        # Hata → status failed + hata özetini raw_response'a yaz
        try:
            supabase.table("media_items").update(
                {"analysis_status": "failed"}
            ).eq("id", media_id).execute()
            supabase.table("media_analysis").insert(
                {
                    "media_id": media_id,
                    "detected_objects": [],
                    "raw_response": {"error": str(exc)},
                }
            ).execute()
        except Exception:
            pass


# ----------------------------------------------------------
# POST /media/upload
# ----------------------------------------------------------
@router.post("/upload", response_model=MediaUploadOut, status_code=201)
async def upload_media(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    conversation_id: Optional[str] = Form(default=None),
    user: dict = Depends(get_current_user),
) -> MediaUploadOut:
    data = await file.read()
    filename = file.filename or "file"

    # Dosya tipi + MIME
    file_type, mime_type = storage_service.detect_file_type(file.content_type, filename)
    storage_service.check_size(len(data))

    # Conversation sahipliği (opsiyonel)
    if conversation_id:
        _verify_conversation_ownership(conversation_id, user["id"])

    # Storage upload
    storage_path = storage_service.upload_bytes(
        user_id=user["id"],
        file_type=file_type,
        filename=filename,
        data=data,
        content_type=mime_type,
    )

    # media_items kaydı
    supabase = get_supabase()
    try:
        result = (
            supabase.table("media_items")
            .insert(
                {
                    "user_id": user["id"],
                    "conversation_id": conversation_id,
                    "file_type": file_type,
                    "storage_path": storage_path,
                    "original_filename": filename,
                    "file_size_bytes": len(data),
                    "analysis_status": "pending",
                }
            )
            .execute()
        )
    except Exception as exc:
        # DB başarısızsa storage'a yüklenen dosyayı sil (yalnız kalan dosya olmasın)
        try:
            storage_service.delete_object(storage_path)
        except Exception:
            pass
        raise AhlasError(
            code="DB_ERROR",
            message="Medya kaydedilemedi.",
            status_code=500,
            detail=str(exc),
        )

    if not result.data:
        try:
            storage_service.delete_object(storage_path)
        except Exception:
            pass
        raise AhlasError(
            code="DB_ERROR",
            message="Medya kaydedilemedi.",
            status_code=500,
        )

    media = result.data[0]
    media_id = media["id"]

    # Arka plan: Gemini analizini tetikle
    background_tasks.add_task(_run_analysis, media_id, storage_path, mime_type)

    return MediaUploadOut(media_id=media_id, analysis_status="pending")


# ----------------------------------------------------------
# POST /media/from-url
# ----------------------------------------------------------
@router.post("/from-url", response_model=MediaUploadOut, status_code=201)
async def upload_media_from_url(
    payload: MediaFromUrlIn,
    background_tasks: BackgroundTasks,
    user: dict = Depends(get_current_user),
) -> MediaUploadOut:
    """URL'den dosya indirip storage'a koyar, arka planda analizi tetikler."""
    # 1) URL doğrulama — sadece http/https + iç ağa istek yapmaya izin verme
    parsed = urlparse(payload.url.strip())
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise AhlasError(
            code="VALIDATION_ERROR",
            message="Geçerli bir http/https bağlantısı girin.",
            status_code=400,
        )
    host = parsed.hostname or ""
    lowered = host.lower()
    if (
        lowered in ("localhost", "127.0.0.1", "0.0.0.0", "::1")
        or lowered.endswith(".local")
        or lowered.startswith("10.")
        or lowered.startswith("192.168.")
        or lowered.startswith("169.254.")
        or lowered.startswith("172.")
    ):
        raise AhlasError(
            code="VALIDATION_ERROR",
            message="İç ağ adresleri desteklenmez.",
            status_code=400,
        )

    # 2) İndir (boyut limitine dikkat)
    max_bytes = settings.MAX_UPLOAD_MB * 1024 * 1024
    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=30.0) as client:
            resp = await client.get(payload.url)
            resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise AhlasError(
            code="STORAGE_DOWNLOAD_FAILED",
            message="Bağlantı indirilemedi.",
            status_code=400,
            detail=str(exc),
        )

    data = resp.content
    if len(data) > max_bytes:
        raise AhlasError(
            code="MEDIA_TOO_LARGE",
            message=f"Dosya boyutu limiti aşıldı (en fazla {settings.MAX_UPLOAD_MB} MB).",
            status_code=413,
        )

    # 3) MIME + dosya adı çıkar
    content_type_header = resp.headers.get("content-type", "").split(";")[0].strip()
    path_name = unquote(parsed.path.rsplit("/", 1)[-1]) or "download"
    file_type, mime_type = storage_service.detect_file_type(
        content_type_header or None, path_name
    )

    # 4) Sohbet sahipliği (opsiyonel)
    if payload.conversation_id:
        _verify_conversation_ownership(payload.conversation_id, user["id"])

    # 5) Storage upload
    storage_path = storage_service.upload_bytes(
        user_id=user["id"],
        file_type=file_type,
        filename=path_name,
        data=data,
        content_type=mime_type,
    )

    # 6) media_items kaydı
    supabase = get_supabase()
    try:
        result = (
            supabase.table("media_items")
            .insert(
                {
                    "user_id": user["id"],
                    "conversation_id": payload.conversation_id,
                    "file_type": file_type,
                    "storage_path": storage_path,
                    "original_filename": path_name,
                    "file_size_bytes": len(data),
                    "analysis_status": "pending",
                }
            )
            .execute()
        )
    except Exception as exc:
        try:
            storage_service.delete_object(storage_path)
        except Exception:
            pass
        raise AhlasError(
            code="DB_ERROR",
            message="Medya kaydedilemedi.",
            status_code=500,
            detail=str(exc),
        )

    if not result.data:
        try:
            storage_service.delete_object(storage_path)
        except Exception:
            pass
        raise AhlasError(
            code="DB_ERROR",
            message="Medya kaydedilemedi.",
            status_code=500,
        )

    media_id = result.data[0]["id"]
    background_tasks.add_task(_run_analysis, media_id, storage_path, mime_type)
    return MediaUploadOut(media_id=media_id, analysis_status="pending")


# ----------------------------------------------------------
# GET /media/{id}/status
# ----------------------------------------------------------
@router.get("/{media_id}/status", response_model=MediaStatusOut)
async def get_media_status(
    media_id: str,
    user: dict = Depends(get_current_user),
) -> MediaStatusOut:
    media = _verify_media_ownership(media_id, user["id"])
    return MediaStatusOut(
        media_id=media_id,
        analysis_status=media.get("analysis_status") or "pending",
    )


# ----------------------------------------------------------
# GET /media/{id}/analysis
# ----------------------------------------------------------
@router.get("/{media_id}/analysis", response_model=MediaAnalysisOut)
async def get_media_analysis(
    media_id: str,
    user: dict = Depends(get_current_user),
) -> MediaAnalysisOut:
    media = _verify_media_ownership(media_id, user["id"])
    status = media.get("analysis_status")

    if status in ("pending", "processing"):
        raise AhlasError(
            code="ANALYSIS_NOT_READY",
            message="Analiz henüz tamamlanmadı. Lütfen birkaç saniye sonra tekrar deneyin.",
            status_code=409,
        )
    if status == "failed":
        raise AhlasError(
            code="ANALYSIS_FAILED",
            message="Medya analizi başarısız oldu.",
            status_code=500,
        )

    supabase = get_supabase()
    try:
        r = (
            supabase.table("media_analysis")
            .select("*")
            .eq("media_id", media_id)
            .limit(1)
            .execute()
        )
    except Exception as exc:
        raise AhlasError(
            code="DB_ERROR",
            message="Analiz getirilemedi.",
            status_code=500,
            detail=str(exc),
        )

    rows = r.data or []
    if not rows:
        raise AhlasError(
            code="NOT_FOUND",
            message="Analiz kaydı bulunamadı.",
            status_code=404,
        )
    a = rows[0]
    return MediaAnalysisOut(
        media_id=media_id,
        summary=a.get("summary"),
        detailed_analysis=a.get("detailed_analysis"),
        detected_objects=a.get("detected_objects") or [],
        detected_text=a.get("detected_text"),
        sentiment=a.get("sentiment"),
        ai_model_used=a.get("ai_model_used"),
    )


# ----------------------------------------------------------
# POST /media/{id}/ask
# ----------------------------------------------------------
@router.post("/{media_id}/ask", response_model=MediaAskOut)
async def ask_about_media(
    media_id: str,
    payload: MediaAskIn,
    voice: Optional[str] = Query(default=None),
    user: dict = Depends(get_current_user),
) -> MediaAskOut:
    media = _verify_media_ownership(media_id, user["id"])
    storage_path = media["storage_path"]
    conversation_id = media.get("conversation_id")
    file_type = media["file_type"]
    filename = media.get("original_filename") or storage_path.split("/")[-1]

    # Dosyayı indir + MIME tipini çöz
    data = storage_service.download_bytes(storage_path)
    _, mime_type = storage_service.detect_file_type(None, filename)

    # Sohbet geçmişini çek (varsa)
    supabase = get_supabase()
    history: list = []
    if conversation_id:
        try:
            h = (
                supabase.table("messages")
                .select("role, content")
                .eq("conversation_id", conversation_id)
                .order("created_at", desc=True)
                .limit(settings.MAX_HISTORY_MESSAGES)
                .execute()
            )
            history = list(reversed(h.data or []))
        except Exception:
            history = []

    # Gemini'ye medya + soru gönder
    reply_text = gemini_service.ask_about_media(
        data=data,
        mime_type=mime_type,
        question=payload.question,
        history=history,
    )

    # Sohbete kaydet (varsa)
    message_id: Optional[str] = None
    if conversation_id:
        try:
            supabase.table("messages").insert(
                {
                    "conversation_id": conversation_id,
                    "role": "user",
                    "content": payload.question,
                    "content_type": file_type,
                    "media_id": media_id,
                }
            ).execute()
            assistant_msg = (
                supabase.table("messages")
                .insert(
                    {
                        "conversation_id": conversation_id,
                        "role": "assistant",
                        "content": reply_text,
                        "content_type": "text",
                        "ai_model_used": settings.GEMINI_MODEL,
                    }
                )
                .execute()
            )
            if assistant_msg.data:
                message_id = assistant_msg.data[0]["id"]
        except Exception:
            # Mesaj kaydedilmese de yanıtı döneriz — kritik değil
            pass

    # TTS — hata fatal olmasın
    audio_b64: Optional[str] = None
    try:
        audio_bytes, _ = await tts_service.synthesize(reply_text, voice=voice)
        audio_b64 = base64.b64encode(audio_bytes).decode("ascii")
    except Exception:
        audio_b64 = None

    return MediaAskOut(
        conversation_id=conversation_id,
        message_id=message_id,
        content=reply_text,
        ai_model_used=settings.GEMINI_MODEL,
        audio_base64=audio_b64,
    )
