# AHLAS — Proje Context Dosyası (CLAUDE.md)

## Proje Özeti
**Ahlas**, Iron Man'deki JARVIS'ten esinlenilmiş, çok modlu (metin/görsel/ses) bir kişisel yapay zeka asistanı. Kullanıcıyla sohbet eder, yüklenen fotoğraf/video içeriğini analiz eder, gerektiğinde rapor üretir. Android APK önceliklidir, ardından Windows exe ve web (ahlas.nejdettut.com) hedeflenir.

## Sahibi
Nejdet TUT — Bilişim Teknolojileri öğretmeni, Python/AI eğitmeni. Diğer projesi MİHENK.AI ile aynı AI stack'i (Gemini + Groq) paylaşır.

## Platform Stratejisi
- **Tek kod tabanı: Flutter** → Android APK, Windows exe, (ileride) Web
- Backend ayrı bir servis (FastAPI) — tüm platformlar aynı API'yi kullanır

## Faz Planı
1. **Faz 1 (MVP – şu an)**: Metin sohbet + medya yükleyip analiz/rapor
2. **Faz 2**: Sesli sohbet (buton bazlı STT/TTS)
3. **Faz 3**: Canlı kamera analizi + gerçek zamanlı sesli akış
4. **Faz 4**: Windows exe paketleme, web subdomain yayına alma

## Teknoloji Yığını (Tamamı Ücretsiz/Ücretsiz Katman)

| Katman | Teknoloji | Neden / Ücretsiz Katman |
|---|---|---|
| İstemci | Flutter (Dart) | Tek kod tabanı, açık kaynak, tamamen ücretsiz |
| Backend | FastAPI (Python) | Nejdet'in bildiği stack, hızlı |
| AI - Metin/Görsel | Gemini 2.5 Flash (Google AI Studio) | Free tier: dakikada belirli istek limiti, görsel+video analiz destekli |
| AI - Fallback | Groq (Llama 3.1/3.3) | Free tier, çok hızlı inference |
| STT (ses→metin) | Groq Whisper API (whisper-large-v3) | Free tier'da mevcut, hızlı |
| TTS (metin→ses) | Edge-TTS (Microsoft, ücretsiz/unofficial) veya Google Cloud TTS free tier | Ücretsiz, kaliteli Türkçe ses |
| Veritabanı | Supabase (PostgreSQL) | Free tier: 500MB DB + 1GB storage |
| Dosya Storage | Supabase Storage | Aynı free tier içinde |
| Backend Hosting | Railway.app veya Fly.io free tier | MVP için yeterli |
| Kimlik Doğrulama | Supabase Auth | Free tier dahil |
| Domain | ahlas.nejdettut.com | Zaten sahip olunan domain üzerinden subdomain |

> Not: Free tier limitleri değişebilir, canlı kullanıma geçmeden önce güncel limitler kontrol edilmeli.

## Klasör Yapısı (Önerilen)
```
ahlas/
├── backend/                 # FastAPI servisi
│   ├── app/
│   │   ├── main.py
│   │   ├── routers/         # chat.py, media.py, reports.py, auth.py
│   │   ├── models/          # Pydantic + DB modelleri
│   │   ├── services/        # gemini_service.py, groq_service.py, stt_service.py, tts_service.py
│   │   └── core/            # config.py, supabase_client.py
│   ├── requirements.txt
│   └── .env.example
├── mobile_desktop/           # Flutter uygulaması
│   ├── lib/
│   │   ├── main.dart
│   │   ├── screens/          # chat_screen.dart, upload_screen.dart, report_screen.dart
│   │   ├── services/         # api_service.dart
│   │   └── models/
│   └── pubspec.yaml
└── docs/
    ├── veri-modeli.md
    └── api-endpoints.md
```

## Kod Standartları
- Backend: Türkçe değişken adları yerine İngilizce (endüstri standardı), ama yorumlar Türkçe olabilir
- Flutter: Material 3 tasarım, karanlık/aydınlık tema desteği
- Tüm API anahtarları `.env` dosyasında, asla koda gömülmez
- Hata mesajları kullanıcıya Türkçe gösterilir

## Öncelik Sırası (Claude Code ile geliştirirken izlenecek sıra)
1. Backend iskeleti + Supabase bağlantısı + veri modeli
2. `/chat` endpoint'i (Gemini metin sohbet)
3. `/media/analyze` endpoint'i (fotoğraf/video yükle → Gemini analiz)
4. `/reports/generate` endpoint'i
5. Flutter: temel sohbet ekranı → API bağlantısı
6. Flutter: medya yükleme ekranı
7. Rapor görüntüleme/PDF export
8. Faz 2: Sesli sohbet entegrasyonu

## Önemli Kısıtlar
- İlk aşamada canlı kamera akışı YOK — sadece yüklenen medya analiz edilir
- Sesli sohbet ilk aşamada buton ile başlat/durdur şeklinde (push-to-talk), tam duplex canlı akış Faz 3'te
- Rate limit'lere dikkat: Gemini/Groq free tier aşılırsa otomatik fallback mekanizması olmalı
