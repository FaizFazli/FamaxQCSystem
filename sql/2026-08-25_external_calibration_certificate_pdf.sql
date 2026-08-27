-- 2026-08-25  The certificate bucket accepts PDF.
--
-- sql/2026-08-25_external_calibration_certificate_upload.sql set the bucket to images only,
-- because "upload image" was what had been asked for, and NOTE 1 in that file said what widening
-- it would take. This is that change. It is a separate file rather than an edit to the original
-- because the original has already been run - editing a migration that has executed somewhere
-- leaves two databases that both claim to be at the same version and are not.
--
-- Most calibration labs issue a PDF. Refusing them meant the certificate for a CMM arrived as a
-- photograph of a printout, or not at all.
--
-- The page's ACCEPT_TYPES in assets/calibration-certificate.js has to match this list. Both move
-- together or one of them lies: a page offering a file the bucket refuses, or a bucket accepting
-- one the page never offers.
--
-- Safe to re-run.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-25_external_calibration_certificate_pdf.sql

begin;

-- Set outright rather than appended. `allowed_mime_types || array['application/pdf']` - which is
-- what NOTE 1 suggested - appends a duplicate every time it runs, and this file is meant to be
-- re-runnable. Stating the whole list also means the list is readable here rather than having to
-- be reconstructed from two migrations.
update storage.buckets
   set allowed_mime_types = array[
           'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif',
           'application/pdf'
       ]
 where id = 'calibration_certificate';

commit;

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - the size limit is unchanged at 10 MB.
--   A scanned A4 certificate is well under it. A PDF that exceeds it is usually a scan at 600 dpi
--   that nobody needed, and the honest failure - "the object exceeded the maximum allowed size" -
--   is better than quietly storing 40 MB per certificate.
--
-- NOTE 2 - what a PDF changes on the page.
--   Nothing can render a PDF in an <img>. The upload preview shows a document tile instead of a
--   thumbnail, and the certificate viewer embeds it rather than showing it as an image. Both are
--   driven off the file's type, not off a separate column, so a certificate that was uploaded as
--   an image before this migration keeps working exactly as it did.
--
-- NOTE 3 - verify:
--   select allowed_mime_types from storage.buckets where id = 'calibration_certificate';
--   -- {image/jpeg,image/png,image/webp,image/heic,image/heif,application/pdf}
