"""Medya endpoint'leri uçtan uca testi.

Akış:
1) Supabase Auth ile JWT al
2) Yeni sohbet oluştur (medyayı buna bağlayacağız)
3) POST /media/upload — dosyayı yükle
4) GET /media/{id}/status — analiz tamamlanana kadar polling
5) GET /media/{id}/analysis — yapılandırılmış sonucu al
6) POST /media/{id}/ask — medya hakkında Türkçe soru sor

Çalıştırma (backend/ dizininden):
    ./.venv/Scripts/python.exe scripts/e2e_media_test.py [test_image_path]
"""
import os
import sys
import time

# Windows terminal encoding fix
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

import httpx
from dotenv import load_dotenv

_HERE = os.path.dirname(os.path.abspath(__file__))
_BACKEND_ROOT = os.path.dirname(_HERE)
load_dotenv(os.path.join(_BACKEND_ROOT, ".env"))


SUPABASE_URL = os.getenv("SUPABASE_URL") or os.getenv("NEXT_PUBLIC_SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY") or os.getenv("SUPABASE_SERVICE_ROLE_KEY")
BACKEND_URL = os.getenv("BACKEND_URL", "http://127.0.0.1:8000/api/v1")
EMAIL = os.getenv("TEST_EMAIL", "test@ahlas.dev")
PASSWORD = os.getenv("TEST_PASSWORD", "AhlasTest2026!")

DEFAULT_TEST_IMAGE = r"C:\Users\Nejdet TUT\2.png"


def die(msg: str, code: int = 1) -> None:
    print(f"\n❌ {msg}")
    sys.exit(code)


def main() -> None:
    test_image = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TEST_IMAGE
    if not os.path.isfile(test_image):
        die(f"Test görseli bulunamadı: {test_image}")

    # 1) JWT
    print(f"→ Supabase auth: {EMAIL}")
    auth_resp = httpx.post(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
        headers={"apikey": SUPABASE_KEY, "Content-Type": "application/json"},
        json={"email": EMAIL, "password": PASSWORD},
        timeout=15,
    )
    if auth_resp.status_code != 200:
        die(f"Auth başarısız: {auth_resp.status_code} — {auth_resp.text}")
    token = auth_resp.json()["access_token"]
    auth_headers = {"Authorization": f"Bearer {token}"}
    print("✅ JWT alındı")

    # 2) Yeni sohbet
    print("\n→ POST /conversations")
    conv_resp = httpx.post(
        f"{BACKEND_URL}/conversations",
        headers={**auth_headers, "Content-Type": "application/json"},
        json={"title": "Medya Testi"},
        timeout=15,
    )
    if conv_resp.status_code != 201:
        die(f"Sohbet oluşturulamadı: {conv_resp.status_code} — {conv_resp.text}")
    conv_id = conv_resp.json()["id"]
    print(f"✅ Sohbet: {conv_id}")

    # 3) Upload
    filename = os.path.basename(test_image)
    file_size = os.path.getsize(test_image)
    print(f"\n→ POST /media/upload ({filename}, {file_size / 1024:.1f} KB)")
    with open(test_image, "rb") as f:
        upload_resp = httpx.post(
            f"{BACKEND_URL}/media/upload",
            headers=auth_headers,
            files={"file": (filename, f, "image/png")},
            data={"conversation_id": conv_id},
            timeout=60,
        )
    if upload_resp.status_code != 201:
        die(f"Upload başarısız: {upload_resp.status_code} — {upload_resp.text}")
    upload_data = upload_resp.json()
    media_id = upload_data["media_id"]
    print(f"✅ Yüklendi — media_id: {media_id}, status: {upload_data['analysis_status']}")

    # 4) Status polling
    print(f"\n→ GET /media/{media_id}/status (polling — max 60 sn)")
    final_status = None
    for i in range(30):
        s_resp = httpx.get(
            f"{BACKEND_URL}/media/{media_id}/status",
            headers=auth_headers,
            timeout=10,
        )
        if s_resp.status_code != 200:
            die(f"Status okunamadı: {s_resp.status_code} — {s_resp.text}")
        status = s_resp.json()["analysis_status"]
        print(f"   [{i+1:02d}] status: {status}")
        if status in ("completed", "failed"):
            final_status = status
            break
        time.sleep(2)

    if final_status != "completed":
        die(f"Analiz {final_status or 'zaman aşımına uğradı'} — analiz tablosunu manuel incele.")
    print("✅ Analiz tamamlandı")

    # 5) Analysis
    print(f"\n→ GET /media/{media_id}/analysis")
    a_resp = httpx.get(
        f"{BACKEND_URL}/media/{media_id}/analysis",
        headers=auth_headers,
        timeout=15,
    )
    if a_resp.status_code != 200:
        die(f"Analiz alınamadı: {a_resp.status_code} — {a_resp.text}")
    a = a_resp.json()
    print("\n----- Analiz -----")
    print(f"summary          : {a.get('summary')}")
    print(f"detailed_analysis: {a.get('detailed_analysis')}")
    print(f"detected_objects : {a.get('detected_objects')}")
    print(f"detected_text    : {a.get('detected_text')}")
    print(f"sentiment        : {a.get('sentiment')}")
    print(f"ai_model_used    : {a.get('ai_model_used')}")
    print("------------------")

    # 6) Ask
    question = "Bu görselde ne görüyorsun? Kısa yanıt ver."
    print(f'\n→ POST /media/{media_id}/ask\n   soru: "{question}"')
    ask_resp = httpx.post(
        f"{BACKEND_URL}/media/{media_id}/ask",
        headers={**auth_headers, "Content-Type": "application/json"},
        json={"question": question},
        timeout=60,
    )
    if ask_resp.status_code != 200:
        die(f"Ask başarısız: {ask_resp.status_code} — {ask_resp.text}")
    ask_data = ask_resp.json()
    print(f"✅ Model: {ask_data.get('ai_model_used')}")
    print(f"✅ Mesaj kaydedildi: {ask_data.get('message_id') is not None}")
    print("\n----- Ahlas'ın görsel yanıtı -----")
    print(ask_data["content"])
    print("----------------------------------\n")

    print("🎯 Medya E2E test başarılı.")


if __name__ == "__main__":
    main()
