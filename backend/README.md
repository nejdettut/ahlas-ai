---
title: Ahlas Backend
emoji: 🤖
colorFrom: indigo
colorTo: purple
sdk: docker
app_port: 8000
pinned: false
---

# Ahlas Backend

JARVIS'ten esinlenilmiş çok modlu kişisel AI asistanı — arka uç.

## Özellikler

- **Metin sohbet** — Gemini 2.5 Flash + Groq Llama fallback
- **Medya analiz** — Görsel/video/ses/URL, Gemini vision + OCR
- **Sesli sohbet** — Groq Whisper STT + Edge-TTS TTS (Türkçe)
- **Otomatik TTS** — Tüm assistant cevapları mp3 base64 olarak gömülü
- **Auth** — Supabase JWT

## API

Base URL: bu Space'in URL'i (örn. `https://nejdettut-ahlas-backend.hf.space`)

- `GET /api/v1/health` — servis durumu
- `POST /api/v1/conversations` — yeni sohbet
- `POST /api/v1/conversations/{id}/messages` — metin mesaj
- `POST /api/v1/conversations/{id}/voice-message` — sesli mesaj
- `POST /api/v1/media/upload` — medya yükle + analiz
- `POST /api/v1/media/{id}/ask` — medyaya soru

Detay: [`docs/api-endpoints.md`](https://github.com/nejdettut/ahlas-ai/blob/master/docs/api-endpoints.md)

## Environment Variables (Space Secrets)

Zorunlu:
- `SUPABASE_URL`
- `SUPABASE_KEY` (service_role)
- `GEMINI_API_KEY`
- `GROQ_API_KEY`

Opsiyonel:
- `TTS_VOICE` (default: `tr-TR-EmelNeural`)
- `GEMINI_MODEL`, `GROQ_MODEL`, `GROQ_STT_MODEL`
- `MAX_UPLOAD_MB`, `MAX_HISTORY_MESSAGES`, `STORAGE_BUCKET`

Kaynak: [github.com/nejdettut/ahlas-ai](https://github.com/nejdettut/ahlas-ai)
