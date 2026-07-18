"""Standart hata formatı — api-endpoints.md'deki şemaya birebir uyar.

Tüm hatalar aşağıdaki yapıda döner:
{
  "error": {
    "code": "AI_RATE_LIMIT",
    "message": "Yapay zeka servisi şu an yoğun...",
    "detail": null
  }
}
"""
from typing import Any, Optional

from fastapi import Request
from fastapi.responses import JSONResponse


class AhlasError(Exception):
    """Uygulama içi standart hata sınıfı."""

    def __init__(
        self,
        code: str,
        message: str,
        status_code: int = 400,
        detail: Optional[Any] = None,
    ) -> None:
        self.code = code
        self.message = message
        self.status_code = status_code
        self.detail = detail
        super().__init__(message)


def _error_payload(code: str, message: str, detail: Optional[Any] = None) -> dict:
    return {"error": {"code": code, "message": message, "detail": detail}}


async def ahlas_error_handler(request: Request, exc: AhlasError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content=_error_payload(exc.code, exc.message, exc.detail),
    )


async def validation_error_handler(request: Request, exc: Exception) -> JSONResponse:
    # Pydantic doğrulama hataları için okunabilir Türkçe mesaj
    return JSONResponse(
        status_code=422,
        content=_error_payload(
            code="VALIDATION_ERROR",
            message="Gönderilen veri geçersiz. Lütfen alanları kontrol edin.",
            detail=str(exc),
        ),
    )


async def generic_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    return JSONResponse(
        status_code=500,
        content=_error_payload(
            code="INTERNAL_ERROR",
            message="Sunucuda beklenmeyen bir hata oluştu. Lütfen daha sonra tekrar deneyin.",
            detail=None,
        ),
    )
