"""Canlı sohbet WebSocket köprüsü — client ↔ Gemini Live.

Protocol (JSON tabanlı; binary olarak da açılabilir ama JSON debug kolaylığı için):

Client → Server:
    {"type": "audio", "data": "<base64 pcm 16khz mono>"}
    {"type": "video", "data": "<base64 jpeg>"}
    {"type": "text", "text": "..."}      # opsiyonel; PTT yok metin varsa
    {"type": "end_audio"}                # PTT release — kullanıcı sırasını kapatır

Server → Client:
    {"type": "info", "message": "connected"}
    {"type": "audio", "data": "<base64 pcm 24khz mono>"}
    {"type": "transcript", "role": "assistant", "text": "..."}
    {"type": "turn_complete"}
    {"type": "interrupted"}
    {"type": "error", "code": "...", "message": "..."}
"""
import asyncio
import base64
import json
import logging
from typing import Optional

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.core.supabase_client import get_supabase
from app.services import live_service

log = logging.getLogger(__name__)

router = APIRouter(prefix="/live", tags=["live"])


async def _verify_token(token: str) -> Optional[dict]:
    """Supabase JWT'yi doğrula; user dict döner, geçersizse None."""
    if not token:
        return None
    try:
        supabase = get_supabase()
        response = supabase.auth.get_user(token)
        user = getattr(response, "user", None)
        if user is None or not getattr(user, "id", None):
            return None
        return {"id": user.id, "email": getattr(user, "email", None)}
    except Exception as exc:
        log.warning("live auth failed: %s", exc)
        return None


@router.websocket("/session")
async def live_session(
    websocket: WebSocket,
    token: str = Query(...),
    voice: Optional[str] = Query(default=None),
):
    """Duplex canlı sohbet. Auth: ?token=<supabase JWT>. Voice: ?voice=Puck."""
    await websocket.accept()

    user = await _verify_token(token)
    if user is None:
        await websocket.send_json(
            {"type": "error", "code": "UNAUTHORIZED", "message": "Oturum geçersiz."}
        )
        await websocket.close(code=1008)
        return

    try:
        async with live_service.open_session(voice_name=voice) as session:
            await websocket.send_json(
                {"type": "info", "message": "connected"}
            )

            async def client_to_gemini():
                """Client'tan gelen mesajları Gemini'ye yönlendir."""
                try:
                    while True:
                        raw = await websocket.receive_text()
                        try:
                            msg = json.loads(raw)
                        except json.JSONDecodeError:
                            continue

                        mtype = msg.get("type")
                        if mtype == "audio":
                            data_b64 = msg.get("data") or ""
                            if not data_b64:
                                continue
                            try:
                                pcm = base64.b64decode(data_b64)
                            except Exception:
                                continue
                            # 16kHz mono PCM 16-bit signed little-endian
                            await session.send_realtime_input(
                                audio={
                                    "data": pcm,
                                    "mime_type": "audio/pcm;rate=16000",
                                }
                            )
                        elif mtype == "video":
                            data_b64 = msg.get("data") or ""
                            mime = msg.get("mime_type") or "image/jpeg"
                            if not data_b64:
                                continue
                            try:
                                img = base64.b64decode(data_b64)
                            except Exception:
                                continue
                            await session.send_realtime_input(
                                video={"data": img, "mime_type": mime}
                            )
                        elif mtype == "text":
                            text = (msg.get("text") or "").strip()
                            if not text:
                                continue
                            await session.send_client_content(
                                turns={"role": "user", "parts": [{"text": text}]},
                                turn_complete=True,
                            )
                        elif mtype == "end_audio":
                            # PTT release — Gemini'ye sıranın bittiğini haber ver
                            await session.send_realtime_input(audio_stream_end=True)
                        # bilinmeyen tipleri sessizce yut
                except WebSocketDisconnect:
                    return
                except Exception as exc:
                    log.warning("client_to_gemini error: %s", exc)

            async def gemini_to_client():
                """Gemini'den gelen mesajları client'a yönlendir."""
                try:
                    async for reply in session.receive():
                        # Ses parçası
                        data = getattr(reply, "data", None)
                        if data:
                            await websocket.send_json({
                                "type": "audio",
                                "data": base64.b64encode(data).decode("ascii"),
                            })
                        # Metin (transcript veya modelin text output'u)
                        text = getattr(reply, "text", None)
                        if text:
                            await websocket.send_json({
                                "type": "transcript",
                                "role": "assistant",
                                "text": text,
                            })
                        # server_content bayrakları + transkript alanları
                        sc = getattr(reply, "server_content", None)
                        if sc is not None:
                            inp_tr = getattr(sc, "input_transcription", None)
                            if inp_tr and getattr(inp_tr, "text", None):
                                await websocket.send_json({
                                    "type": "transcript",
                                    "role": "user",
                                    "text": inp_tr.text,
                                })
                            out_tr = getattr(sc, "output_transcription", None)
                            if out_tr and getattr(out_tr, "text", None):
                                await websocket.send_json({
                                    "type": "transcript",
                                    "role": "assistant",
                                    "text": out_tr.text,
                                })
                            if getattr(sc, "turn_complete", False):
                                await websocket.send_json(
                                    {"type": "turn_complete"}
                                )
                            if getattr(sc, "interrupted", False):
                                await websocket.send_json(
                                    {"type": "interrupted"}
                                )
                except Exception as exc:
                    log.warning("gemini_to_client error: %s", exc)

            # İki yönlü köprü — biri kapanırsa diğerini iptal et
            t1 = asyncio.create_task(client_to_gemini())
            t2 = asyncio.create_task(gemini_to_client())
            done, pending = await asyncio.wait(
                {t1, t2}, return_when=asyncio.FIRST_COMPLETED
            )
            for t in pending:
                t.cancel()

    except WebSocketDisconnect:
        pass
    except Exception as exc:
        log.exception("live session error")
        try:
            await websocket.send_json({
                "type": "error",
                "code": "AI_UPSTREAM_ERROR",
                "message": "Canlı oturum hatası.",
            })
        except Exception:
            pass
    finally:
        try:
            await websocket.close()
        except Exception:
            pass
