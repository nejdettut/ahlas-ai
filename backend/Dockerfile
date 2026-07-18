# Ahlas backend — FastAPI + Gemini + Groq + Edge-TTS
FROM python:3.12-slim

# Sistem bağımlılıkları (edge-tts ses üretimi için ekstra bir şey gerekmez;
# ffmpeg vb. Şu an kullanılmıyor)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Bağımlılık cache'ini korumak için önce requirements
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# Uygulama kodu
COPY app ./app
COPY migrations ./migrations

# Railway/Fly $PORT env variable'ı iletir; local için 8000 fallback
ENV PORT=8000
EXPOSE 8000

# Prod: --reload YOK; workers=1 (aiohttp/edge-tts + Groq client global tutuluyor,
# çoklu worker'da state paylaşımı sorun yapabilir; ileride optimize edilir)
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1"]
