# AHLAS — Veri Modeli Tasarımı (Supabase / PostgreSQL)

## 1. `users`
Supabase Auth zaten `auth.users` tablosunu otomatik yönetir. Bu, ek profil bilgisi için genişletme tablosu.

```sql
create table public.user_profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    full_name text,
    display_name text default 'Kullanıcı',
    avatar_url text,
    preferred_language text default 'tr',
    voice_enabled boolean default true,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);
```

## 2. `conversations`
Her sohbet oturumu (Jarvis ile açılan bir konuşma penceresi).

```sql
create table public.conversations (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references auth.users(id) on delete cascade,
    title text default 'Yeni Sohbet',
    is_archived boolean default false,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);
```

## 3. `messages`
Sohbet içindeki tekil mesajlar (kullanıcı veya asistan).

```sql
create table public.messages (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid references public.conversations(id) on delete cascade,
    role text check (role in ('user', 'assistant', 'system')) not null,
    content text,
    content_type text check (content_type in ('text', 'voice', 'image', 'video')) default 'text',
    media_id uuid references public.media_items(id),  -- nullable, ses/görsel varsa
    ai_model_used text,  -- 'gemini-2.5-flash' | 'groq-llama-3.3' vb.
    token_count integer,
    created_at timestamptz default now()
);
```

## 4. `media_items`
Yüklenen fotoğraf/video/ses dosyaları (Supabase Storage referansı).

```sql
create table public.media_items (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references auth.users(id) on delete cascade,
    conversation_id uuid references public.conversations(id),
    file_type text check (file_type in ('image', 'video', 'audio')) not null,
    storage_path text not null,        -- Supabase Storage'daki yol
    original_filename text,
    file_size_bytes bigint,
    duration_seconds numeric,          -- video/ses için
    thumbnail_path text,               -- video için önizleme görseli
    analysis_status text check (analysis_status in ('pending', 'processing', 'completed', 'failed')) default 'pending',
    created_at timestamptz default now()
);
```

## 5. `media_analysis`
Gemini'nin medya üzerinden ürettiği analiz sonucu (ayrı tabloda tutmak, sohbet geçmişinden bağımsız sorgulanabilir raporlar için önemli).

```sql
create table public.media_analysis (
    id uuid primary key default gen_random_uuid(),
    media_id uuid references public.media_items(id) on delete cascade,
    summary text,                      -- kısa özet
    detailed_analysis text,            -- detaylı analiz metni
    detected_objects jsonb,            -- ör: ["kişi", "araba", "tahta"]
    detected_text text,                -- OCR sonucu varsa
    sentiment text,                    -- video/ses için ton analizi
    ai_model_used text,
    raw_response jsonb,                -- Gemini'nin ham yanıtı (debug için)
    created_at timestamptz default now()
);
```

## 6. `reports`
Kullanıcının talep ettiği raporlar (bir veya birden fazla medya/sohbetten üretilen).

```sql
create table public.reports (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references auth.users(id) on delete cascade,
    conversation_id uuid references public.conversations(id),
    title text not null,
    report_type text check (report_type in ('media_analysis', 'conversation_summary', 'custom')) default 'custom',
    content_markdown text,             -- rapor içeriği (markdown)
    pdf_storage_path text,             -- export edilmiş PDF varsa
    source_media_ids uuid[],           -- hangi medyalardan üretildi
    created_at timestamptz default now()
);
```

## 7. `voice_sessions` (Faz 2 için hazır altyapı)
```sql
create table public.voice_sessions (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid references public.conversations(id) on delete cascade,
    stt_model text,          -- 'groq-whisper-large-v3'
    tts_model text,          -- 'edge-tts-tr'
    total_duration_seconds numeric,
    created_at timestamptz default now()
);
```

## İlişki Şeması (Özet)
```
auth.users ──1:1── user_profiles
auth.users ──1:N── conversations
conversations ──1:N── messages
conversations ──1:N── media_items
media_items ──1:1── media_analysis
conversations ──1:N── reports
conversations ──1:N── voice_sessions
messages ──N:1── media_items (opsiyonel bağlantı)
```

## Row Level Security (RLS) — Kritik
Supabase free tier'da bile RLS mutlaka açılmalı; her tabloda kullanıcı sadece kendi verisini görebilmeli:

```sql
alter table public.conversations enable row level security;
create policy "Kullanıcı kendi sohbetlerini görür"
    on public.conversations for select
    using (auth.uid() = user_id);

create policy "Kullanıcı kendi sohbetini oluşturur"
    on public.conversations for insert
    with check (auth.uid() = user_id);

-- Aynı pattern messages, media_items, reports için de uygulanmalı
-- (messages tablosunda user_id yok, conversation_id üzerinden join ile kontrol edilmeli)
```

## Storage Bucket Yapısı (Supabase Storage)
```
ahlas-media/
  ├── {user_id}/
  │   ├── images/
  │   ├── videos/
  │   ├── audio/
  │   └── thumbnails/
ahlas-reports/
  ├── {user_id}/
  │   └── {report_id}.pdf
```

Free tier 1GB sınırını aşmamak için: video dosyaları belirli süre sonra otomatik silinip sadece analiz sonucu (media_analysis) saklanabilir — bu bir sonraki fazda "veri saklama politikası" olarak eklenebilir.
