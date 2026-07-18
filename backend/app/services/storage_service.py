"""Supabase Storage servisi — dosya upload/download/signed URL yardımcıları.

Bucket yapısı (veri-modeli.md):
    {user_id}/images/{uuid}_{filename}
    {user_id}/videos/{uuid}_{filename}
    {user_id}/audio/{uuid}_{filename}
    {user_id}/thumbnails/{uuid}_{filename}

Not: Backend service_role anahtarıyla çalıştığı için RLS bypass edilir; kullanıcı
klasörü izolasyonu kodda user_id üzerinden yapılır (yol prefix'i olarak).
"""
import mimetypes
from typing import Optional, Tuple
from uuid import uuid4

from app.core.config import settings
from app.core.errors import AhlasError
from app.core.supabase_client import get_supabase


# file_type kategorisi → bucket içindeki klasör
_FILE_TYPE_FOLDERS = {
    "image": "images",
    "video": "videos",
    "audio": "audio",
}


def detect_file_type(mime_type: Optional[str], filename: str) -> Tuple[str, str]:
    """MIME veya dosya uzantısından (file_type, content_type) çözer.

    Dönen file_type: 'image' | 'video' | 'audio'.
    """
    guessed = (mime_type or mimetypes.guess_type(filename)[0] or "").lower()
    if guessed.startswith("image/"):
        return "image", guessed
    if guessed.startswith("video/"):
        return "video", guessed
    if guessed.startswith("audio/"):
        return "audio", guessed
    raise AhlasError(
        code="MEDIA_UNSUPPORTED",
        message="Sadece görsel, video veya ses dosyaları desteklenir.",
        status_code=400,
        detail=f"mime={guessed or 'unknown'}",
    )


def check_size(size_bytes: int) -> None:
    """Yükleme boyutu limitini doğrular."""
    max_bytes = settings.MAX_UPLOAD_MB * 1024 * 1024
    if size_bytes > max_bytes:
        raise AhlasError(
            code="MEDIA_TOO_LARGE",
            message=f"Dosya boyutu limiti aşıldı (en fazla {settings.MAX_UPLOAD_MB} MB).",
            status_code=413,
            detail=f"size={size_bytes} bytes",
        )


def build_storage_path(user_id: str, file_type: str, filename: str) -> str:
    """Bucket içi standart yol: {user_id}/{folder}/{uuid}_{safe_name}"""
    folder = _FILE_TYPE_FOLDERS.get(file_type)
    if not folder:
        raise AhlasError(
            code="MEDIA_UNSUPPORTED",
            message="Desteklenmeyen medya kategorisi.",
            status_code=400,
        )
    # Path traversal ve boşluk temizliği
    safe_name = filename.replace("/", "_").replace("\\", "_").replace("..", "_")
    safe_name = safe_name.strip() or "file"
    unique = uuid4().hex[:12]
    return f"{user_id}/{folder}/{unique}_{safe_name}"


def upload_bytes(
    user_id: str,
    file_type: str,
    filename: str,
    data: bytes,
    content_type: Optional[str] = None,
) -> str:
    """Byte içeriğini Supabase Storage'a yükler, storage_path döner."""
    check_size(len(data))

    storage_path = build_storage_path(user_id, file_type, filename)
    resolved_ct = (
        content_type
        or mimetypes.guess_type(filename)[0]
        or "application/octet-stream"
    )

    supabase = get_supabase()
    try:
        supabase.storage.from_(settings.STORAGE_BUCKET).upload(
            path=storage_path,
            file=data,
            file_options={"content-type": resolved_ct, "upsert": "false"},
        )
    except Exception as exc:
        raise AhlasError(
            code="STORAGE_UPLOAD_FAILED",
            message="Dosya yüklenemedi.",
            status_code=500,
            detail=str(exc),
        )
    return storage_path


def download_bytes(storage_path: str) -> bytes:
    """Storage'daki dosyayı byte olarak indirir (backend içi analiz için)."""
    supabase = get_supabase()
    try:
        return supabase.storage.from_(settings.STORAGE_BUCKET).download(storage_path)
    except Exception as exc:
        raise AhlasError(
            code="STORAGE_DOWNLOAD_FAILED",
            message="Dosya indirilemedi.",
            status_code=500,
            detail=str(exc),
        )


def get_signed_url(storage_path: str, expires_in_seconds: Optional[int] = None) -> str:
    """Kullanıcının doğrudan indirebilmesi için imzalı URL üretir."""
    expires_in = expires_in_seconds or settings.SIGNED_URL_EXPIRES_SECONDS
    supabase = get_supabase()
    try:
        result = supabase.storage.from_(settings.STORAGE_BUCKET).create_signed_url(
            path=storage_path,
            expires_in=expires_in,
        )
    except Exception as exc:
        raise AhlasError(
            code="STORAGE_SIGN_FAILED",
            message="İndirme bağlantısı oluşturulamadı.",
            status_code=500,
            detail=str(exc),
        )

    # supabase-py sürüme göre farklı anahtarlar döndürebilir
    if isinstance(result, dict):
        url = result.get("signedURL") or result.get("signed_url") or result.get("signedUrl")
    else:
        url = result
    if not url:
        raise AhlasError(
            code="STORAGE_SIGN_FAILED",
            message="İndirme bağlantısı oluşturulamadı.",
            status_code=500,
        )
    return url


def delete_object(storage_path: str) -> None:
    """Bucket'tan dosyayı siler."""
    supabase = get_supabase()
    try:
        supabase.storage.from_(settings.STORAGE_BUCKET).remove([storage_path])
    except Exception as exc:
        raise AhlasError(
            code="STORAGE_DELETE_FAILED",
            message="Dosya silinemedi.",
            status_code=500,
            detail=str(exc),
        )
