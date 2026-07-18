# AHLAS — Backend API Endpoint Tasarımı (FastAPI)

Base URL (dev): `http://localhost:8000/api/v1`
Base URL (prod): `https://ahlas.nejdettut.com/api/v1`

Kimlik doğrulama: Supabase Auth JWT → her istekte `Authorization: Bearer <token>` header'ı.

---

## 1. Auth
Supabase Auth SDK istemci tarafında (Flutter) doğrudan kullanılır; backend'de ayrı auth endpoint'i gerekmez. Backend sadece gelen JWT'yi doğrular (middleware).

```
GET /api/v1/me
```
Giriş yapan kullanıcının profil bilgisini döner.
**Response:**
```json
{ "id": "uuid", "display_name": "Nejdet", "preferred_language": "tr" }
```

---

## 2. Sohbet (Chat)

### 2.1 Yeni sohbet oluştur
```
POST /api/v1/conversations
```
**Body:** `{ "title": "Yeni Sohbet" }` (opsiyonel)
**Response:** `{ "id": "uuid", "title": "...", "created_at": "..." }`

### 2.2 Sohbet listesi
```
GET /api/v1/conversations?limit=20&offset=0
```

### 2.3 Mesaj gönder (ana chat endpoint)
```
POST /api/v1/conversations/{conversation_id}/messages
```
**Body:**
```json
{
  "content": "Bugün hava nasıl olacak?",
  "content_type": "text"
}
```
**İşlem akışı (backend):**
1. Kullanıcı mesajını `messages` tablosuna kaydet
2. Sohbet geçmişini çek (son N mesaj, context için)
3. Gemini 2.5 Flash'a gönder → hata/rate-limit olursa Groq'a fallback
4. Asistan yanıtını `messages` tablosuna kaydet
5. Yanıtı döndür

**Response:**
```json
{
  "id": "uuid",
  "role": "assistant",
  "content": "Bugün Ankara'da...",
  "ai_model_used": "gemini-2.5-flash",
  "created_at": "..."
}
```

### 2.4 Sohbet geçmişini getir
```
GET /api/v1/conversations/{conversation_id}/messages?limit=50
```

### 2.5 Sohbeti sil / arşivle
```
DELETE /api/v1/conversations/{conversation_id}
PATCH  /api/v1/conversations/{conversation_id}   { "is_archived": true }
```

---

## 3. Medya Analizi

### 3.1 Medya yükle
```
POST /api/v1/media/upload
```
**Content-Type:** `multipart/form-data`
**Form alanları:** `file`, `conversation_id` (opsiyonel)

**İşlem akışı:**
1. Dosyayı Supabase Storage'a yükle
2. `media_items` kaydı oluştur (`analysis_status: pending`)
3. Arka planda (background task / queue) analiz işlemini tetikle
4. Hemen `media_id` döndür (kullanıcı bekletilmez)

**Response:**
```json
{ "media_id": "uuid", "analysis_status": "pending" }
```

### 3.2 Analiz durumunu sorgula (polling)
```
GET /api/v1/media/{media_id}/status
```
**Response:** `{ "analysis_status": "completed" }`

### 3.3 Analiz sonucunu getir
```
GET /api/v1/media/{media_id}/analysis
```
**Response:**
```json
{
  "summary": "Fotoğrafta bir sınıf ortamı, öğrenciler robotik proje üzerinde çalışıyor.",
  "detailed_analysis": "...",
  "detected_objects": ["öğrenci", "robot kiti", "tahta"],
  "detected_text": null,
  "ai_model_used": "gemini-2.5-flash"
}
```

### 3.4 Medya + soru birlikte (görsel hakkında soru sor)
```
POST /api/v1/media/{media_id}/ask
```
**Body:** `{ "question": "Bu görüntüdeki hata neydi?" }`
Gemini'ye medya + soru birlikte gönderilir, doğrudan yanıt döner (mesaj geçmişine de eklenir).

---

## 4. Ses (Faz 2 — MVP sonrası ama endpoint iskeleti şimdiden hazırlanabilir)

### 4.1 Ses → metin
```
POST /api/v1/voice/transcribe
```
**Form:** `audio_file`
**Response:** `{ "text": "..." }`  (Groq Whisper)

### 4.2 Metin → ses
```
POST /api/v1/voice/synthesize
```
**Body:** `{ "text": "...", "voice": "tr-TR-Standard" }`
**Response:** audio/mpeg stream veya storage URL

---

## 5. Raporlar

### 5.1 Rapor oluştur
```
POST /api/v1/reports/generate
```
**Body:**
```json
{
  "conversation_id": "uuid",
  "report_type": "media_analysis",
  "source_media_ids": ["uuid1", "uuid2"],
  "instructions": "Öğrenci projelerini karşılaştırarak özetle"
}
```
**İşlem:** İlgili medya analizleri + sohbet geçmişi Gemini'ye gönderilir, yapılandırılmış rapor (markdown) üretilir, `reports` tablosuna kaydedilir.

**Response:** `{ "report_id": "uuid", "content_markdown": "# Rapor..." }`

### 5.2 Rapor listesi / detay
```
GET /api/v1/reports?limit=20
GET /api/v1/reports/{report_id}
```

### 5.3 Rapor PDF export
```
POST /api/v1/reports/{report_id}/export-pdf
```
**Response:** `{ "pdf_url": "https://.../report.pdf" }`

---

## 6. Sağlık kontrolü
```
GET /api/v1/health
```
Backend + Gemini + Groq + Supabase bağlantı durumunu döner (izleme için).

---

## Hata Yönetimi (Standart Format)
Tüm hatalar aynı yapıda döner:
```json
{
  "error": {
    "code": "AI_RATE_LIMIT",
    "message": "Yapay zeka servisi şu an yoğun, lütfen birazdan tekrar deneyin.",
    "detail": null
  }
}
```

**Önemli hata kodları:**
| Kod | Anlamı | Davranış |
|---|---|---|
| `AI_RATE_LIMIT` | Gemini free tier limiti doldu | Otomatik Groq'a geç, kullanıcıya sezdirme |
| `MEDIA_TOO_LARGE` | Dosya boyutu limiti aşıldı | Yükleme öncesi Flutter tarafında da kontrol |
| `UNAUTHORIZED` | JWT geçersiz/süresi dolmuş | Flutter otomatik refresh dener |

---

## Sıradaki Adım
Bu üç doküman (`CLAUDE.md`, `veri-modeli.md`, `api-endpoints.md`) `docs/` klasörüne konup Claude Code açıldığında ilk okunacak referans olacak. Claude Code'a şu şekilde başlangıç promptu verilebilir:

> "CLAUDE.md, veri-modeli.md ve api-endpoints.md dosyalarını oku. Backend iskeletini (FastAPI + Supabase bağlantısı) bu dokümanlara göre kur, önce `/health` ve `/conversations` endpoint'leriyle başla."
