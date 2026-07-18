"""Ahlas FastAPI uygulaması — giriş noktası.

Çalıştırmak için:
    cd backend
    uvicorn app.main:app --reload
"""
from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.core.errors import (
    AhlasError,
    ahlas_error_handler,
    generic_exception_handler,
    validation_error_handler,
)
from app.routers import conversations, health, media

app = FastAPI(
    title="Ahlas API",
    description="JARVIS'ten esinlenilmiş çok modlu kişisel AI asistanı — arka uç.",
    version="0.1.0",
)

# ---- CORS ----
# MVP: geliştirme için tüm origin'lere açık. Prod'da ahlas.nejdettut.com ile kısıtlanacak.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---- Standart hata formatı ----
app.add_exception_handler(AhlasError, ahlas_error_handler)
app.add_exception_handler(RequestValidationError, validation_error_handler)
app.add_exception_handler(Exception, generic_exception_handler)

# ---- Router'lar ----
app.include_router(health.router, prefix=settings.API_PREFIX)
app.include_router(conversations.router, prefix=settings.API_PREFIX)
app.include_router(media.router, prefix=settings.API_PREFIX)


@app.get("/")
async def root() -> dict:
    return {
        "name": "Ahlas API",
        "version": "0.1.0",
        "env": settings.APP_ENV,
        "docs": "/docs",
        "health": f"{settings.API_PREFIX}/health",
    }
