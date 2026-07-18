-- ==========================================================================
-- AHLAS — İlk migration
-- veri-modeli.md dosyasındaki şemanın birebir uygulanması + RLS politikaları
--
-- Nasıl çalıştırılır:
--   Supabase Dashboard > SQL Editor > "New query"
--   Bu dosyanın tamamını yapıştırıp "Run" bas.
--   (Tekrar çalıştırılabilir — tüm tablolar "if not exists" ile korunur.)
-- ==========================================================================

-- ==========================================================
-- 1) user_profiles  (Supabase auth.users'ı genişletir)
-- ==========================================================
create table if not exists public.user_profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    full_name text,
    display_name text default 'Kullanıcı',
    avatar_url text,
    preferred_language text default 'tr',
    voice_enabled boolean default true,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

-- ==========================================================
-- 2) conversations
-- ==========================================================
create table if not exists public.conversations (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references auth.users(id) on delete cascade,
    title text default 'Yeni Sohbet',
    is_archived boolean default false,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);
create index if not exists conversations_user_updated_idx
    on public.conversations (user_id, updated_at desc);

-- ==========================================================
-- 3) media_items  (messages'tan önce; messages ona bağımlı)
-- ==========================================================
create table if not exists public.media_items (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references auth.users(id) on delete cascade,
    conversation_id uuid references public.conversations(id) on delete set null,
    file_type text check (file_type in ('image','video','audio')) not null,
    storage_path text not null,
    original_filename text,
    file_size_bytes bigint,
    duration_seconds numeric,
    thumbnail_path text,
    analysis_status text check (analysis_status in ('pending','processing','completed','failed')) default 'pending',
    created_at timestamptz default now()
);
create index if not exists media_items_user_idx on public.media_items (user_id);
create index if not exists media_items_conversation_idx on public.media_items (conversation_id);

-- ==========================================================
-- 4) messages
-- ==========================================================
create table if not exists public.messages (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid references public.conversations(id) on delete cascade,
    role text check (role in ('user','assistant','system')) not null,
    content text,
    content_type text check (content_type in ('text','voice','image','video')) default 'text',
    media_id uuid references public.media_items(id) on delete set null,
    ai_model_used text,
    token_count integer,
    created_at timestamptz default now()
);
create index if not exists messages_conversation_created_idx
    on public.messages (conversation_id, created_at asc);

-- ==========================================================
-- 5) media_analysis
-- ==========================================================
create table if not exists public.media_analysis (
    id uuid primary key default gen_random_uuid(),
    media_id uuid references public.media_items(id) on delete cascade,
    summary text,
    detailed_analysis text,
    detected_objects jsonb,
    detected_text text,
    sentiment text,
    ai_model_used text,
    raw_response jsonb,
    created_at timestamptz default now()
);
create index if not exists media_analysis_media_idx on public.media_analysis (media_id);

-- ==========================================================
-- 6) reports
-- ==========================================================
create table if not exists public.reports (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references auth.users(id) on delete cascade,
    conversation_id uuid references public.conversations(id) on delete set null,
    title text not null,
    report_type text check (report_type in ('media_analysis','conversation_summary','custom')) default 'custom',
    content_markdown text,
    pdf_storage_path text,
    source_media_ids uuid[],
    created_at timestamptz default now()
);
create index if not exists reports_user_idx on public.reports (user_id);

-- ==========================================================
-- 7) voice_sessions  (Faz 2 hazırlığı)
-- ==========================================================
create table if not exists public.voice_sessions (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid references public.conversations(id) on delete cascade,
    stt_model text,
    tts_model text,
    total_duration_seconds numeric,
    created_at timestamptz default now()
);

-- ==========================================================
-- updated_at trigger fonksiyonu
-- ==========================================================
create or replace function public.set_updated_at()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_user_profiles_updated on public.user_profiles;
create trigger trg_user_profiles_updated
    before update on public.user_profiles
    for each row execute function public.set_updated_at();

drop trigger if exists trg_conversations_updated on public.conversations;
create trigger trg_conversations_updated
    before update on public.conversations
    for each row execute function public.set_updated_at();

-- ==========================================================
-- Row Level Security (RLS) — her kullanıcı sadece kendi verisini görür
--
-- Not: Backend, "service_role" anahtarıyla çalışıyorsa bu politikalar bypass
-- edilir; buna rağmen istemcinin (Flutter) anon key ile doğrudan Supabase'e
-- eriştiği yerlerde koruma sağlar. İki katmanlı savunma prensibi.
-- ==========================================================

-- user_profiles
alter table public.user_profiles enable row level security;
drop policy if exists profiles_select_own on public.user_profiles;
drop policy if exists profiles_insert_own on public.user_profiles;
drop policy if exists profiles_update_own on public.user_profiles;
create policy profiles_select_own on public.user_profiles
    for select using (auth.uid() = id);
create policy profiles_insert_own on public.user_profiles
    for insert with check (auth.uid() = id);
create policy profiles_update_own on public.user_profiles
    for update using (auth.uid() = id);

-- conversations
alter table public.conversations enable row level security;
drop policy if exists conversations_select_own on public.conversations;
drop policy if exists conversations_insert_own on public.conversations;
drop policy if exists conversations_update_own on public.conversations;
drop policy if exists conversations_delete_own on public.conversations;
create policy conversations_select_own on public.conversations
    for select using (auth.uid() = user_id);
create policy conversations_insert_own on public.conversations
    for insert with check (auth.uid() = user_id);
create policy conversations_update_own on public.conversations
    for update using (auth.uid() = user_id);
create policy conversations_delete_own on public.conversations
    for delete using (auth.uid() = user_id);

-- messages (kullanıcı erişimi conversation üzerinden)
alter table public.messages enable row level security;
drop policy if exists messages_select_via_conv on public.messages;
drop policy if exists messages_insert_via_conv on public.messages;
create policy messages_select_via_conv on public.messages
    for select using (
        exists (
            select 1 from public.conversations c
            where c.id = messages.conversation_id
              and c.user_id = auth.uid()
        )
    );
create policy messages_insert_via_conv on public.messages
    for insert with check (
        exists (
            select 1 from public.conversations c
            where c.id = messages.conversation_id
              and c.user_id = auth.uid()
        )
    );

-- media_items
alter table public.media_items enable row level security;
drop policy if exists media_items_select_own on public.media_items;
drop policy if exists media_items_insert_own on public.media_items;
drop policy if exists media_items_update_own on public.media_items;
drop policy if exists media_items_delete_own on public.media_items;
create policy media_items_select_own on public.media_items
    for select using (auth.uid() = user_id);
create policy media_items_insert_own on public.media_items
    for insert with check (auth.uid() = user_id);
create policy media_items_update_own on public.media_items
    for update using (auth.uid() = user_id);
create policy media_items_delete_own on public.media_items
    for delete using (auth.uid() = user_id);

-- media_analysis (media_items sahibi görsün)
alter table public.media_analysis enable row level security;
drop policy if exists media_analysis_select_via_media on public.media_analysis;
drop policy if exists media_analysis_insert_via_media on public.media_analysis;
create policy media_analysis_select_via_media on public.media_analysis
    for select using (
        exists (
            select 1 from public.media_items m
            where m.id = media_analysis.media_id
              and m.user_id = auth.uid()
        )
    );
create policy media_analysis_insert_via_media on public.media_analysis
    for insert with check (
        exists (
            select 1 from public.media_items m
            where m.id = media_analysis.media_id
              and m.user_id = auth.uid()
        )
    );

-- reports
alter table public.reports enable row level security;
drop policy if exists reports_select_own on public.reports;
drop policy if exists reports_insert_own on public.reports;
drop policy if exists reports_update_own on public.reports;
drop policy if exists reports_delete_own on public.reports;
create policy reports_select_own on public.reports
    for select using (auth.uid() = user_id);
create policy reports_insert_own on public.reports
    for insert with check (auth.uid() = user_id);
create policy reports_update_own on public.reports
    for update using (auth.uid() = user_id);
create policy reports_delete_own on public.reports
    for delete using (auth.uid() = user_id);

-- voice_sessions (conversation sahibi görsün)
alter table public.voice_sessions enable row level security;
drop policy if exists voice_sessions_select_via_conv on public.voice_sessions;
drop policy if exists voice_sessions_insert_via_conv on public.voice_sessions;
create policy voice_sessions_select_via_conv on public.voice_sessions
    for select using (
        exists (
            select 1 from public.conversations c
            where c.id = voice_sessions.conversation_id
              and c.user_id = auth.uid()
        )
    );
create policy voice_sessions_insert_via_conv on public.voice_sessions
    for insert with check (
        exists (
            select 1 from public.conversations c
            where c.id = voice_sessions.conversation_id
              and c.user_id = auth.uid()
        )
    );

-- ==========================================================
-- Bittiği zaman doğrulama:
--   select table_name from information_schema.tables
--     where table_schema='public' order by table_name;
-- ==========================================================
