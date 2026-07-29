-- 2026-07-29  Actual gauge photograph, alongside the technical drawing.
--
-- drawing_path holds the PDF the gauge is verified AGAINST. That is not the same thing as a
-- picture of the gauge itself, which QA wants for identification: "is this the part in my hand?"
-- Different question, different file, so it gets its own column rather than overloading the PDF.
--
-- The photo is uploaded to the same storage bucket under the same base filename as the drawing
-- (GAUGE_NO-<timestamp>.pdf / GAUGE_NO-<timestamp>.png) so the pair stays obvious on disk.
--
-- Nullable on purpose: 339 gauges already exist without a photo, and a registration should not
-- be blocked because nobody had a camera to hand.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-07-29_gauge_image.sql
-- Re-running is safe.

alter table gauges add column if not exists image_path text;

comment on column gauges.image_path is
    'Public URL of the gauge photograph (PNG/JPEG). Reference only - the drawing PDF in '
    'drawing_path remains the controlled document that verification is performed against.';
