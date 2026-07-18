"""Pydantic modelleri — istek/yanıt şemaları."""
from datetime import datetime
from typing import List, Literal, Optional

from pydantic import BaseModel, Field


# ---------------- Conversations ----------------
class ConversationCreate(BaseModel):
    title: Optional[str] = Field(default="Yeni Sohbet", max_length=200)


class ConversationOut(BaseModel):
    id: str
    user_id: Optional[str] = None
    title: str
    is_archived: bool = False
    created_at: datetime
    updated_at: datetime


# ---------------- Messages ----------------
class MessageCreate(BaseModel):
    content: str = Field(min_length=1, max_length=8000)
    content_type: Literal["text", "voice", "image", "video"] = "text"


class MessageOut(BaseModel):
    id: str
    conversation_id: Optional[str] = None
    role: Literal["user", "assistant", "system"]
    content: Optional[str] = None
    content_type: str = "text"
    ai_model_used: Optional[str] = None
    created_at: datetime
    # Assistant metin cevabının Edge-TTS mp3 base64'ü. Yoksa istemci TTS çalmaz.
    audio_base64: Optional[str] = None


# ---------------- Media ----------------
class MediaUploadOut(BaseModel):
    media_id: str
    analysis_status: Literal["pending", "processing", "completed", "failed"]


class MediaStatusOut(BaseModel):
    media_id: str
    analysis_status: Literal["pending", "processing", "completed", "failed"]


class MediaAnalysisOut(BaseModel):
    media_id: str
    summary: Optional[str] = None
    detailed_analysis: Optional[str] = None
    detected_objects: List[str] = []
    detected_text: Optional[str] = None
    sentiment: Optional[str] = None
    ai_model_used: Optional[str] = None


class MediaFromUrlIn(BaseModel):
    url: str = Field(min_length=8, max_length=2000)
    conversation_id: Optional[str] = None


class MediaAskIn(BaseModel):
    question: str = Field(min_length=1, max_length=2000)


class MediaAskOut(BaseModel):
    conversation_id: Optional[str] = None
    message_id: Optional[str] = None
    content: str
    ai_model_used: str
    audio_base64: Optional[str] = None


# ---------------- Voice ----------------
class VoiceMessageOut(BaseModel):
    transcript: str
    message: "MessageOut"  # audio_base64 message içinde geliyor
    stt_model_used: str
    tts_voice: Optional[str] = None


# ---------------- Health ----------------
class HealthComponent(BaseModel):
    name: str
    status: Literal["ok", "error", "unknown"]
    detail: Optional[str] = None


class HealthOut(BaseModel):
    status: Literal["ok", "degraded", "down"]
    components: List[HealthComponent]
