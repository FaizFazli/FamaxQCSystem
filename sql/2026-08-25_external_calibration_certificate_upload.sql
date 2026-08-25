-- 2026-08-25  The calibration certificate stops being a link somebody has to keep alive.
--
-- ext_cal_event.cert_url was a free-text field: you typed a path to wherever the scan happened to
-- be. That works exactly as long as nobody reorganises the share, renames the folder or leaves the
-- company - and a calibration record whose evidence is a dead \\FAMAX\... path is a record that
-- cannot be produced at audit. The certificate now uploads into a bucket the application owns.
--
-- WHY cert_url IS NOT REPLACED.
--   It stays, and it is still the one column that answers "where is the certificate". An upload
--   fills it with the object's public URL; a typed link fills it with a link. One field, one
--   question, and nothing already recorded stops working.
--
--   What is new is cert_storage_path: the object key inside the bucket, kept ONLY when the file
--   was uploaded here. It is not a second copy of the URL - it is the answer to a different
--   question, "is this ours to delete". Without it, replacing a certificate leaves the old image
--   in the bucket forever with nothing pointing at it and no way to tell it from a file somebody
--   else put there. The same reasoning, and the same column name, as subcon_do_image.storage_path.
--
-- WHY THE BUCKET IS RESTRICTED AND THE OTHERS ARE NOT.
--   The six buckets already on this install accept anything of any size. This one declares a size
--   limit and an image allow-list, because the page validating a file in JavaScript is a courtesy
--   to the person choosing it, not a control - anyone holding the anon key can POST straight at
--   storage. Declaring it on the bucket is the only place the rule actually binds.
--
--   That does mean a PDF certificate is refused. See NOTE 1 - it is one line to change, and it is
--   left out because "upload image" is what was asked for.
--
-- Safe to re-run.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-25_external_calibration_certificate_upload.sql

begin;

-- ---------------------------------------------------------------------
-- 1. Where an uploaded certificate lives
-- ---------------------------------------------------------------------

alter table ext_cal_event add column if not exists cert_storage_path text;

comment on column ext_cal_event.cert_storage_path is
    'Object key inside the calibration_certificate bucket, set only when the certificate was '
    'uploaded through the entry form. NULL means cert_url points at something this application '
    'does not own - a typed link - and must not be deleted with the row. Not a duplicate of '
    'cert_url: that says where the certificate is, this says whether it is ours to remove.';

comment on column ext_cal_event.cert_url is
    'Where the certificate is: the public URL of an uploaded image, or a link typed by hand. '
    'Read this to show the certificate; read cert_storage_path to decide whether deleting the '
    'row should also delete the file.';

-- Only the uploaded ones, and only where there is a path to find - the index exists to answer
-- "which objects in the bucket are still referenced", which is the question an orphan sweep asks.
create index if not exists ext_cal_event_cert_path_idx
    on ext_cal_event (cert_storage_path)
 where cert_storage_path is not null;

-- ---------------------------------------------------------------------
-- 2. The bucket
-- ---------------------------------------------------------------------
--
-- Public, and scoped by bucket_id on all four verbs - the same arrangement the existing
-- iqc / ipqc / oqc / obsolete / subcon buckets use on this install. The app arrives as anon (it
-- has no Supabase Auth session), which is why the role is `public` rather than `authenticated`.
--
-- 10 MB matches what the subcon upload screen enforces in the browser, so a file that page would
-- accept is a file this bucket accepts. A phone photo of an A4 certificate is 2-5 MB.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('calibration_certificate', 'calibration_certificate', true, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update
    set public             = excluded.public,
        file_size_limit    = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

do $$
declare
    verb text;
    pol  text;
begin
    foreach verb in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE']
    loop
        pol := 'calibration_certificate_objects_' || lower(verb);
        execute format('drop policy if exists %I on storage.objects', pol);
        if verb = 'INSERT' then
            -- INSERT takes WITH CHECK; there is no USING clause on an insert policy.
            execute format(
                'create policy %I on storage.objects for insert to public '
                'with check (bucket_id = ''calibration_certificate'')', pol);
        else
            execute format(
                'create policy %I on storage.objects for %s to public '
                'using (bucket_id = ''calibration_certificate'')', pol, verb);
        end if;
    end loop;
end $$;

commit;

notify pgrst, 'reload schema';

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - accepting PDF certificates.
--   Most labs issue a PDF. This bucket refuses one, because the request was for image upload and
--   an allow-list that quietly accepts more than it says is worse than one that is narrow. To
--   widen it, add the type here AND to ACCEPT_TYPES in the entry form - both, or the page will
--   offer a file the bucket rejects, or the bucket will accept one the page never offers:
--
--     update storage.buckets
--        set allowed_mime_types = allowed_mime_types || array['application/pdf']
--      where id = 'calibration_certificate';
--
--   The form previews an image inline; a PDF would need a link instead of a thumbnail.
--
-- NOTE 2 - what happens to the file when a certificate is deleted.
--   Nothing, yet. ext_cal_event rows cascade from ext_cal_equipment, and a cascade cannot reach
--   into object storage - so deleting an instrument leaves its certificate images behind. That is
--   deliberate for now: the files are small, and an orphaned image is a great deal less costly
--   than a delete path that removes evidence somebody still needed. cert_storage_path is what
--   makes the sweep possible when it is wanted:
--
--     select o.name from storage.objects o
--      where o.bucket_id = 'calibration_certificate'
--        and not exists (select 1 from ext_cal_event e where e.cert_storage_path = o.name);
--
-- NOTE 3 - verify:
--   select id, public, file_size_limit, allowed_mime_types from storage.buckets
--    where id = 'calibration_certificate';
--   select policyname, cmd from pg_policies
--    where schemaname='storage' and tablename='objects'
--      and policyname like 'calibration_certificate%' order by policyname;   -- 4 rows
