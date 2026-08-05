-- 2026-08-04  IPQC on the Rejected Product Record (REC-QAS020-04).
--
-- The reject record exists already for Buy-Off, IQC, OQC and customer returns: those all write to
-- InspectionRecord, which carries RejectQty and a Remark breakdown, and inspectionRejectReport.html
-- prints them on the controlled form. IPQC was the one category with a checkbox on that form and
-- nothing behind it, because IPQC does not write to InspectionRecord at all - it measures points
-- into Data_IPQC, and a measurement out of spec is not yet a quantity of parts.
--
-- These two additions are exactly that gap:
--
--   affected_qty  how many parts a single out-of-spec point put at risk. Only a person knows it -
--                 the measurement says a dimension drifted, not how much of the run it reached -
--                 so it is keyed in on the report and stored back on the row that caused it.
--
--   sa_by/_position/_at
--                 who granted the concession that takes a point OFF the record. special_accept has
--                 existed as a bare 0/1 since before this, settable by anyone with the Data Editor
--                 open. A concession that removes a part from a quality record without naming
--                 whoever granted it is not a concession, it is a delete, so granting one now costs
--                 a name and that person's EmployeeTable PIN and is stamped here.
--
-- Nullable on purpose. affected_qty is null until somebody fills the form in, and null is not 0:
-- "nobody has said yet" and "no parts affected" are different answers and the report shows them
-- differently. The sa_ columns are null on a row nobody has special-accepted.
--
-- No backfill is possible or needed: at the time of writing not one of the 75,419 rows has
-- special_accept set, so there is no historical concession whose author has been lost.
--
-- WHY NOT A SEPARATE TABLE
--   Same reason verify_status is on the row (see 2026-08-03_ipqc_verification.sql): Data_IPQC has
--   no batch key a side table could point at, and both of these are facts about one measurement
--   point, not about a group of them. affected_qty in particular is per point - two zones drifting
--   in the same round can affect different quantities.
--
-- Run as the table owner, AFTER 2026-08-03_ipqc_verification.sql:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-04_ipqc_reject_record.sql
-- Re-running is safe.

alter table "Data_IPQC" add column if not exists affected_qty integer;
alter table "Data_IPQC" add column if not exists sa_by        text;
alter table "Data_IPQC" add column if not exists sa_position  text;
alter table "Data_IPQC" add column if not exists sa_at        timestamptz;

-- A negative quantity of affected parts is a typo, not a fact. Null stays allowed - that is the
-- "not answered yet" state the report renders as an empty box.
alter table "Data_IPQC" drop constraint if exists data_ipqc_affected_qty_chk;
alter table "Data_IPQC"
  add constraint data_ipqc_affected_qty_chk
  check (affected_qty is null or affected_qty >= 0);

comment on column "Data_IPQC".affected_qty is
    'Parts put at risk by this out-of-spec point, keyed in on the IPQC Rejected Product Record. '
    'NULL = nobody has filled it in yet, which is not the same as 0.';
comment on column "Data_IPQC".sa_by is
    'Name from EmployeeTable of whoever granted the special accept on this row. Identity was '
    'proven by EmployeeTable.pin - the PIN itself is never stored here. NULL whenever '
    'special_accept is 0; the Data Editor clears all three sa_ columns when the tick comes off.';
comment on column "Data_IPQC".sa_at is
    'When the concession was granted. Distinct from verified_at, which is the countersignature on '
    'the whole part-day rather than the concession on one point.';

-- No index. The report reads one month at a time and idx_data_ipqc_batch_order already leads on
-- created_at, so the range scan is served; the is_ng / special_accept filtering is over ~13k rows
-- and costs nothing next to it. A partial index on is_ng would also be quietly destroyed the next
-- time 2026-08-03_ipqc_verification.sql is re-run, since that file drops and recomputes the
-- column - which is a good reason not to depend on it from here.

-- PostgREST caches the schema; without this the new columns 404 until the container restarts.
notify pgrst, 'reload schema';
