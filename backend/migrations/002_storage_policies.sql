-- ==========================================================================
-- AHLAS — Storage RLS politikaları
--
-- Bu migration, "ahlas-media" bucket'ı için Row Level Security politikalarını
-- kurar: her kullanıcı yalnızca kendi {user_id}/ klasörü altındaki dosyalara
-- erişebilir.
--
-- Ön koşul:
--   - Supabase Dashboard > Storage > "ahlas-media" bucket'ı oluşturulmuş olmalı
--     (private).
--
-- Nasıl çalıştırılır:
--   Dashboard > SQL Editor > New query > içeriği yapıştır > Run.
-- ==========================================================================

-- Backend service_role anahtarıyla çalıştığı için bu politikaları bypass eder.
-- Bu politikalar asıl olarak, ileride Flutter istemcisinin doğrudan Supabase
-- Storage'a (anon key ile) erişebildiği durumlarda koruma sağlar.

-- --- Upload: kullanıcı yalnızca kendi klasörüne yazabilir ---
drop policy if exists ahlas_media_insert_own on storage.objects;
create policy ahlas_media_insert_own
on storage.objects for insert
to authenticated
with check (
    bucket_id = 'ahlas-media'
    and (storage.foldername(name))[1] = auth.uid()::text
);

-- --- Read: kullanıcı yalnızca kendi dosyalarını görebilir ---
drop policy if exists ahlas_media_select_own on storage.objects;
create policy ahlas_media_select_own
on storage.objects for select
to authenticated
using (
    bucket_id = 'ahlas-media'
    and (storage.foldername(name))[1] = auth.uid()::text
);

-- --- Update: kullanıcı yalnızca kendi dosyalarını güncelleyebilir ---
drop policy if exists ahlas_media_update_own on storage.objects;
create policy ahlas_media_update_own
on storage.objects for update
to authenticated
using (
    bucket_id = 'ahlas-media'
    and (storage.foldername(name))[1] = auth.uid()::text
);

-- --- Delete: kullanıcı yalnızca kendi dosyalarını silebilir ---
drop policy if exists ahlas_media_delete_own on storage.objects;
create policy ahlas_media_delete_own
on storage.objects for delete
to authenticated
using (
    bucket_id = 'ahlas-media'
    and (storage.foldername(name))[1] = auth.uid()::text
);

-- ==========================================================================
-- Doğrulama:
--   select policyname from pg_policies
--     where schemaname = 'storage' and tablename = 'objects'
--     order by policyname;
-- ==========================================================================
