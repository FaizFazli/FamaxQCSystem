-- 2026-08-05  IQC measures against the IPQC checkpoints.
--
-- The IQC screens read their checkpoints from the "IQC" table, and that table has never had a
-- row in it. Pick any part and the process dropdown says "No processes available" — the flow has
-- always dead-ended on its first step. Meanwhile "IPQC" holds 4,119 active checkpoints covering
-- every process the factory runs.
--
-- Filling "IQC" in by hand was never going to work, and not because it is tedious. Which process
-- goes out to a subcontractor is not a property of the part: the same STEM can be turned here
-- this month and sent out for the same turning next month, depending on load. A separate IQC
-- catalogue would have to anticipate every process that might ever be subcontracted, which is
-- every process — at which point it is a second copy of "IPQC" that can silently disagree with
-- it about what a good part measures.
--
-- So the screens now read "IPQC" for the checkpoints, and this migration gives Data_IQC the
-- columns to record a reading judged against those checkpoints.
--
-- WHAT CHANGES
--   LSL_OK / USL_NG / SC   The spec as IPQC states it. Data_IQC was built around Min/Nominal/Max,
--                          which is a different way of saying the same thing and cannot be
--                          compared with an IPQC limit without a conversion nobody would maintain.
--   Subcon_Name / Return_DO
--                          Where the parts came back from. The IPQC equivalent of this field is
--                          Machine, which records nothing about work done at a subcontractor's
--                          premises. Both are free text holding what subcon_delivery_out.subcon_name
--                          and subcon_delivery_in.return_do_number said at the time — a snapshot,
--                          not a foreign key, so re-numbering a DO later cannot rewrite an
--                          inspection record.
--   is_ng                  The same stored verdict Data_IPQC carries, from the same function, so
--                          an out-of-spec IQC reading means exactly what an out-of-spec IPQC one
--                          does. Nothing consumes it yet; sign-off and the Rejected Product
--                          Record are IPQC-only for now, and this is what they would read.
--
-- Min / Nominal / Max, Reading_4, Reading_5 and Machine are left in place and unused rather than
-- dropped. The table is empty, so dropping them would cost nothing today — but they are also the
-- shape of the OQC flow, which still works that way, and a dropped column is the one change here
-- that could not be undone by re-running this file.
--
-- Safe on an empty table, which Data_IQC is (0 rows at the time of writing) — no backfill, and
-- the generated column has nothing to compute.
--
-- Run as the table owner, AFTER 2026-08-03_ipqc_verification.sql, which defines ipqc_reading_ng():
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-05_iqc_from_ipqc.sql
-- Re-running is safe.

alter table "Data_IQC" add column if not exists "LSL_OK"    text;
alter table "Data_IQC" add column if not exists "USL_NG"    text;
alter table "Data_IQC" add column if not exists "SC"        text;
alter table "Data_IQC" add column if not exists "Subcon_Name" text;
alter table "Data_IQC" add column if not exists "Return_DO"   text;
alter table "Data_IQC" add column if not exists "Remarks"     text;

comment on column "Data_IQC"."LSL_OK" is
    'Lower limit, copied from the IPQC checkpoint this reading was taken against. Same column '
    'name and same meaning as Data_IPQC."LSL_OK" so one spec rule serves both.';
comment on column "Data_IQC"."USL_NG" is
    'Upper limit, copied from the IPQC checkpoint. See "LSL_OK".';
comment on column "Data_IQC"."Subcon_Name" is
    'Subcontractor the parts came back from, as subcon_delivery_out.subcon_name read it at the '
    'time. Free text on purpose: an inspection record must not change because a master row was '
    'later renamed.';
comment on column "Data_IQC"."Return_DO" is
    'The subcontractor''s return DO these parts arrived on, from subcon_delivery_in.'
    'return_do_number. Snapshot, not a foreign key - see "Subcon_Name".';
comment on column "Data_IQC"."Remarks" is
    'The inspection remark: a standardised category, optionally followed by " | " and free '
    'detail, exactly as Data_IPQC."Remarks" carries it. Distinct from "QC_Remark", which is a '
    'note on the visual condition of the delivery rather than on the measuring.';

-- Dropped and rebuilt rather than patched, for the reason given at length in
-- 2026-08-03_ipqc_verification.sql: a stored generated column is computed at write time and
-- never revisited, so changing the rule under it leaves old rows holding the old verdict with
-- nothing to say they are stale. Dropping forces a full recompute.
alter table "Data_IQC" drop column if exists is_ng;
alter table "Data_IQC" add column is_ng boolean
    generated always as (
        ipqc_reading_ng("Reading_1", "LSL_OK", "USL_NG")
     or ipqc_reading_ng("Reading_2", "LSL_OK", "USL_NG")
     or ipqc_reading_ng("Reading_3", "LSL_OK", "USL_NG")
    ) stored;

comment on column "Data_IQC".is_ng is
    'True when any of the three readings is outside spec. Maintained by the database - never '
    'write to it. Same function as Data_IPQC.is_ng, so the two tables agree on what out-of-spec '
    'means. Reading_4 and Reading_5 are deliberately not considered: the IQC form records three '
    'readings per point, as IPQC does.';

-- The screens ask "which processes exist for this part" and "which checkpoints for this part and
-- process", both against "IPQC" filtered to Active. Nothing indexed that pair before, because the
-- IPQC screens ask it once per inspection and 4,119 rows scan in no time; it is cheap to serve
-- properly now that a second pair of screens asks the same question.
create index if not exists idx_ipqc_part_process_active
  on "IPQC" ("Part_Name", "Process")
  where "Status" = 'Active';

-- PostgREST caches the schema; without this the new columns 404 until the container restarts.
notify pgrst, 'reload schema';
