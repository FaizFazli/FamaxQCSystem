-- 2026-08-07  affected_qty is one answer per inspection, not one per point.
--
-- Comments only. No column changes, no data changes.
--
-- 2026-08-04_ipqc_reject_record.sql introduced affected_qty and said, under WHY NOT A SEPARATE
-- TABLE, that it is "per point - two zones drifting in the same round can affect different
-- quantities". That was reasoning from the shape of the table rather than from the work, and the
-- people doing the work say it is wrong: a dimension going out is the REASON, and what gets
-- rejected is the part. The same run is at risk whichever zone drifted, so apportioning a
-- quantity between zones describes something nobody does.
--
-- The IPQC entry screen therefore asks for it once, beside the remark that explains the
-- rejection, and writes the same value onto every row of the submission. That is not a new
-- pattern: Remarks has always been repeated across a batch, and verify_status is stamped on each
-- row for exactly the reason given in 2026-08-03_ipqc_verification.sql - Data_IPQC has no batch
-- key a per-inspection fact could hang off, so the fact goes on every row of the group and the
-- rows move together.
--
-- WHAT THAT COSTS, STATED PLAINLY.
--   Summing affected_qty across rows multiplies one rejection by the number of points measured.
--   A twelve-point inspection that rejected 500 parts reads as 6,000 to anything that adds the
--   column up. The per-inspection figure is one value repeated, so the aggregate that means
--   anything is a maximum over the rows of a submission, never a sum:
--
--     select "JO_Number", "Part_Name", "Process", "Machine", created_at,
--            max(affected_qty_num) as affected_qty
--       from "Data_IPQC"
--      where affected_qty is not null
--      group by 1,2,3,4,5;
--
--   created_at is the submission key here rather than the Malaysian day v_ipqc_batch uses,
--   because the whole submission goes in as one multi-row INSERT and shares one timestamp. A part
--   measured five times in a shift is five rejections that can differ, and grouping them by day
--   would collapse five answers into one.
--
-- The Rejected Product Record is deliberately left alone. Its per-zone boxes match the paper form
-- REC-QAS020-04, whose Affected Qty column lines up one-for-one with the zones - so a figure set
-- once at inspection appears against each of that inspection's points, and can still be adjusted
-- on a single zone if one genuinely differs. The screen offering the common case first and the
-- exception second is the right way round.
--
-- Safe to re-run.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-07_ipqc_affected_qty_per_inspection.sql

begin;

comment on column "Data_IPQC".affected_qty is
    'How many parts one inspection''s rejection covers, as the person wrote it - a count, or ALL '
    'when the run was not segregated. A PER-INSPECTION fact repeated on every row of the '
    'submission, the same way Remarks and verify_status are, because this table has no batch key. '
    'NEVER SUM IT: adding the column across rows multiplies one rejection by its point count. Take '
    'max(affected_qty_num) grouped by created_at with the job, part, process and machine. Null '
    'still means nobody has answered, which is neither 0 nor ALL.';

comment on column "Data_IPQC".affected_qty_num is
    'affected_qty as an integer when it is purely a number, null otherwise - including for ALL, '
    'because ALL is a quantity nobody has counted. Generated and unwritable, so it cannot drift '
    'from the text it comes from. Read it with max() over a submission, not sum() over rows: the '
    'value is repeated across the submission, not divided between its points.';

commit;

notify pgrst, 'reload schema';

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - what would make sum() safe, and why it is not done here.
--   A real batch key on Data_IPQC - one id shared by every row of a submission - would let the
--   quantity live once instead of N times, and then a sum would be correct by construction. That
--   is the change 2026-08-03_ipqc_verification.sql wanted and did not make, for the same reason
--   it is not made here: it means backfilling a key across 75,419 existing rows and changing
--   every screen that writes them. Repeating the value is the cheaper half of that trade, and the
--   cost is entirely in how it is read - which is what the comments above exist to say.
--
-- NOTE 2 - verify (comments only; nothing else should differ):
--   select col_description('"Data_IPQC"'::regclass, attnum)
--     from pg_attribute
--    where attrelid = '"Data_IPQC"'::regclass and attname in ('affected_qty','affected_qty_num');
--   select count(*) from "Data_IPQC";                                  -- 75419, unchanged
--   select count(*) from "Data_IPQC" where affected_qty is not null;   -- unchanged
