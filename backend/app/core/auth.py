"""JWT doğrulama — her istekteki Authorization header'ı Supabase üzerinden çözülür."""
from typing import Optional

from fastapi import Header

from app.core.errors import AhlasError
from app.core.supabase_client import get_supabase


async def get_current_user(authorization: Optional[str] = Header(default=None)) -> dict:
    """Bearer token'ı doğrular; kullanıcıyı {id, email} olarak döner.

    Geçersiz/eksik token için UNAUTHORIZED hatası fırlatır.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise AhlasError(
            code="UNAUTHORIZED",
            message="Kimlik doğrulama başlığı eksik veya geçersiz.",
            status_code=401,
        )

    token = authorization[7:].strip()
    if not token:
        raise AhlasError(
            code="UNAUTHORIZED",
            message="Kimlik doğrulama başlığı eksik veya geçersiz.",
            status_code=401,
        )

    supabase = get_supabase()
    try:
        response = supabase.auth.get_user(token)
    except Exception as exc:
        raise AhlasError(
            code="UNAUTHORIZED",
            message="Oturum doğrulanamadı. Lütfen tekrar giriş yapın.",
            status_code=401,
            detail=str(exc),
        )

    user = getattr(response, "user", None)
    if user is None or not getattr(user, "id", None):
        raise AhlasError(
            code="UNAUTHORIZED",
            message="Oturum geçersiz. Lütfen tekrar giriş yapın.",
            status_code=401,
        )

    return {"id": user.id, "email": getattr(user, "email", None)}
