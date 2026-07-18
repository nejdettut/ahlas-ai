"""Uçtan uca chat akışı testi.

Test adımları:
1) Supabase Auth REST üzerinden test kullanıcısı ile JWT al
2) POST /api/v1/conversations → yeni sohbet oluştur
3) POST /api/v1/conversations/{id}/messages → Türkçe soru gönder, Gemini yanıtını al
4) GET /api/v1/conversations → listede yeni sohbet göründüğünü doğrula

Çalıştırma (backend/ dizininden):
    ./.venv/Scripts/python.exe scripts/e2e_test.py
"""
import os
import sys

# Windows'ta cp1254 terminal ok/emoji karakterlerini basamaz — UTF-8'e sabitle
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

import httpx
from dotenv import load_dotenv

# .env dosyasını backend/ kökünden yükle
_HERE = os.path.dirname(os.path.abspath(__file__))
_BACKEND_ROOT = os.path.dirname(_HERE)
load_dotenv(os.path.join(_BACKEND_ROOT, ".env"))


SUPABASE_URL = os.getenv("SUPABASE_URL") or os.getenv("NEXT_PUBLIC_SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY") or os.getenv("SUPABASE_SERVICE_ROLE_KEY")
BACKEND_URL = os.getenv("BACKEND_URL", "http://127.0.0.1:8000/api/v1")
EMAIL = os.getenv("TEST_EMAIL", "test@ahlas.dev")
PASSWORD = os.getenv("TEST_PASSWORD", "AhlasTest2026!")


def die(msg: str, code: int = 1) -> None:
    print(f"\n❌ {msg}")
    sys.exit(code)


def main() -> None:
    if not SUPABASE_URL or not SUPABASE_KEY:
        die(".env dosyasında SUPABASE_URL ve SUPABASE_KEY eksik.")

    # 1) JWT
    print(f"→ Supabase auth: {EMAIL}")
    auth_resp = httpx.post(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
        headers={
            "apikey": SUPABASE_KEY,
            "Content-Type": "application/json",
        },
        json={"email": EMAIL, "password": PASSWORD},
        timeout=15,
    )
    if auth_resp.status_code != 200:
        die(f"Auth başarısız ({auth_resp.status_code}): {auth_resp.text}")
    token = auth_resp.json().get("access_token")
    if not token:
        die("Auth yanıtında access_token yok.")
    print(f"✅ JWT alındı ({len(token)} karakter)")

    auth_headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    # 2) Yeni sohbet
    print("\n→ POST /conversations")
    conv_resp = httpx.post(
        f"{BACKEND_URL}/conversations",
        headers=auth_headers,
        json={"title": "E2E Test Sohbeti"},
        timeout=15,
    )
    if conv_resp.status_code != 201:
        die(f"Conversation oluşturulamadı ({conv_resp.status_code}): {conv_resp.text}")
    conv = conv_resp.json()
    conv_id = conv["id"]
    print(f"✅ Sohbet oluşturuldu — id: {conv_id}")
    print(f"   title: {conv['title']}, created_at: {conv['created_at']}")

    # 3) Mesaj gönder
    question = (
        "Merhaba! Sen JARVIS'ten esinlenilmiş, Ahlas adında bir kişisel yapay zeka "
        "asistanısın. Kısaca kendini tanıt (en fazla 3 cümle)."
    )
    print(f"\n→ POST /conversations/{conv_id}/messages")
    print(f'   soru: "{question}"')
    msg_resp = httpx.post(
        f"{BACKEND_URL}/conversations/{conv_id}/messages",
        headers=auth_headers,
        json={"content": question, "content_type": "text"},
        timeout=90,
    )
    if msg_resp.status_code != 201:
        die(f"Mesaj gönderilemedi ({msg_resp.status_code}): {msg_resp.text}")
    msg = msg_resp.json()
    print(f"✅ Kullanılan model: {msg.get('ai_model_used')}")
    print("\n----- Ahlas'ın yanıtı -----")
    print(msg["content"])
    print("---------------------------\n")

    # 4) Liste
    print("→ GET /conversations")
    list_resp = httpx.get(f"{BACKEND_URL}/conversations", headers=auth_headers, timeout=15)
    if list_resp.status_code != 200:
        die(f"Liste alınamadı ({list_resp.status_code}): {list_resp.text}")
    items = list_resp.json()
    print(f"✅ Liste alındı — toplam {len(items)} sohbet")

    print("\n🎯 E2E test başarılı.")


if __name__ == "__main__":
    main()
