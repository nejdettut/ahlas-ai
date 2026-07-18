"""Supabase istemcisi — backend genelinde tek örnek olarak kullanılır."""
from typing import Optional

from supabase import create_client, Client

from app.core.config import settings

_client: Optional[Client] = None


def get_supabase() -> Client:
    """Tembel yükleme ile Supabase client'ını döner.

    Not: Backend'de SUPABASE_KEY olarak "service_role" anahtarının kullanılması önerilir.
    RLS bu durumda bypass edilir; kullanıcı bazlı filtreleme kodda user_id ile yapılır.
    """
    global _client
    if _client is None:
        if not settings.is_supabase_configured:
            raise RuntimeError(
                "Supabase yapılandırılmamış. .env dosyasında SUPABASE_URL ve SUPABASE_KEY tanımlı olmalı."
            )
        _client = create_client(settings.SUPABASE_URL, settings.SUPABASE_KEY)
    return _client
