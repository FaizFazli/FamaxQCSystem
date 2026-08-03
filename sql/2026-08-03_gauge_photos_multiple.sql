-- 2026-08-03  More than one identification photo per gauge.
--
-- gauges.image_path holds exactly one URL, so photographing a gauge from a second angle meant
-- overwriting the first. One picture is often not enough to answer the question the photo exists
-- to answer — "is this the gauge in my hand?" — for a thread gauge with markings on the collar,
-- or a set where the GO and NOGO ends look alike.
--
-- A child table rather than an array column or a widened image_path, following subcon_do_image
-- from sql/2026-08-03_subcon_do_images_and_receipt_edit.sql: same shape, same reasons. It gives
-- each photo its own storage_path so a delete can remove the object rather than orphan it, and
-- room for a caption, which is what makes a second angle useful ("collar marking", "GO end").
--
-- ON image_path
--   Left in place and backfilled into this table, NOT dropped and NOT kept in sync. Two columns
--   claiming to hold the same photo is how they end up disagreeing. Nothing outside
--   gauge_verification_form.html ever read it, and that page now reads gauge_image, so the old
--   column is inert - retained only so a rollback still has the original single photo to fall
--   back on. The comment on it says so, for whoever finds it next.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-03_gauge_photos_multiple.sql
-- Idempotent: safe to re-run.

begin;

create table if not exists gauge_image (
    id            bigint generated always as identity primary key,
    -- Cascade: a photo of a deleted gauge identifies nothing.
    gauge_id      bigint not null references gauges (id) on delete cascade,
    image_url     text not null,          -- public URL, as gauges.image_path did
    storage_path  text,                   -- object key inside the bucket, so deletes can clean up
    caption       text,                   -- "COLLAR MARKING", "GO END" - optional
    sort_order    int  not null default 0,
    uploaded_at   timestamptz not null default now(),
    uploaded_by   text
);

-- Every read is "the photos for this gauge, in display order".
create index if not exists idx_gauge_image_gauge on gauge_image (gauge_id, sort_order, id);

alter table gauge_image enable row level security;
grant select, insert, update, delete on gauge_image to anon, authenticated;

-- Same arrangement as the other gauge_* tables on this install: the app arrives as anon because
-- it holds no Supabase Auth session, so the policies name that role explicitly.
drop policy if exists gauge_image_read  on gauge_image;
drop policy if exists gauge_image_write on gauge_image;
create policy gauge_image_read  on gauge_image
    for select to anon, authenticated using (true);
create policy gauge_image_write on gauge_image
    for all to anon, authenticated using (true) with check (true);

-- Backfill the single existing photo as each gauge's first image.
--
-- Guarded on image_url rather than on a row count, so re-running cannot duplicate a photo, and so
-- a gauge that has since had photos added and the original deleted does not get it resurrected.
-- The ?v= cache-buster the old replace path appended is stripped: it was a display concern, and
-- keeping it would make the same file look like a different URL to the not-exists test below.
insert into gauge_image (gauge_id, image_url, storage_path, caption, sort_order)
select g.id,
       g.image_path,
       nullif(split_part(regexp_replace(g.image_path, '\?v=\d+$', ''),
                         '/object/public/gauge/', 2), ''),
       'ORIGINAL PHOTO',
       0
from gauges g
where coalesce(btrim(g.image_path), '') <> ''
  and not exists (
      select 1 from gauge_image i
      where i.gauge_id = g.id
        and regexp_replace(i.image_url, '\?v=\d+$', '') = regexp_replace(g.image_path, '\?v=\d+$', '')
  );

comment on table gauge_image is
    'Identification photographs of a gauge, many per gauge. Reference only - the controlled '
    'document remains the drawing PDF in gauges.drawing_path, which verification is performed '
    'against.';
comment on column gauge_image.storage_path is
    'Object key inside the `gauge` bucket. Kept so deleting a photo can delete the file too '
    'instead of leaving it orphaned in storage.';

comment on column gauges.image_path is
    'SUPERSEDED by the gauge_image table, which holds many photos per gauge. Backfilled there '
    'and no longer read or written by the app. Retained only as a rollback fallback - do not '
    'add code that depends on it, and do not expect it to track gauge_image.';

commit;

-- PostgREST caches the schema; without this the new table 404s until the container restarts.
notify pgrst, 'reload schema';
