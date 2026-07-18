"""Sağlık kontrolü endpoint'i — Supabase, Gemini, Groq bağlantı durumunu döner."""
from fastapi import APIRouter

from app.core.supabase_client import get_supabase
from app.models.schemas import HealthComponent, HealthOut
from app.services import gemini_service, groq_service

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthOut)
async def health_check() -> HealthOut:
    components: list[HealthComponent] = []

    # ---- Supabase ----
    try:
        supabase = get_supabase()
        # Hafif bir sorgu — tablo yoksa yine yakalanır, bağlantı kurulabildiği doğrulanır
        supabase.table("conversations").select("id").limit(1).execute()
        components.append(HealthComponent(name="supabase", status="ok"))
    except Exception as exc:
        components.append(
            HealthComponent(name="supabase", status="error", detail=str(exc))
        )

    # ---- Gemini ----
    ok, detail = gemini_service.check_health()
    components.append(
        HealthComponent(name="gemini", status="ok" if ok else "error", detail=detail)
    )

    # ---- Groq ----
    ok, detail = groq_service.check_health()
    components.append(
        HealthComponent(name="groq", status="ok" if ok else "error", detail=detail)
    )

    # Genel durum
    statuses = [c.status for c in components]
    if all(s == "ok" for s in statuses):
        overall = "ok"
    elif any(s == "ok" for s in statuses):
        overall = "degraded"
    else:
        overall = "down"

    return HealthOut(status=overall, components=components)
