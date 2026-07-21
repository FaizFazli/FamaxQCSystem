-- ============================================================================
-- Add InspectionRecord.schedule_id and backfill existing rows
-- Run once in the Supabase SQL editor (transactional; safe to re-run).
--
-- Mirrors the record -> schedule matching used by the app
-- (inspectionCheckerForm.html resolveScheduleId / inspectionDailyReport.html
--  getScheduleMatch):
--   1. Same JO_Number + Part_Name + Parameter.
--   2. Prefer a schedule whose inspector (AssignTo or Replacement) matches
--      the record's InspectBy.
--   3. Prefer the schedule "run" the operator was on: the latest StartDate
--      that is still on/before the record's finish time; otherwise the
--      schedule whose StartDate is closest to the finish time.
-- ============================================================================

BEGIN;

-- 1. Column + FK (no-ops if they already exist).
--    Use bigint to match InspectionSchedule.id (change to uuid if that PK is uuid).
ALTER TABLE "InspectionRecord"
  ADD COLUMN IF NOT EXISTS schedule_id bigint;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'inspectionrecord_schedule_fk'
  ) THEN
    ALTER TABLE "InspectionRecord"
      ADD CONSTRAINT inspectionrecord_schedule_fk
      FOREIGN KEY (schedule_id) REFERENCES "InspectionSchedule"(id);
  END IF;
END $$;

-- 2. Backfill only rows that are not yet linked.
WITH ranked AS (
  SELECT
    r.id AS record_id,
    s.id AS schedule_id,
    ROW_NUMBER() OVER (
      PARTITION BY r.id
      ORDER BY
        -- (a) inspector match wins
        CASE
          WHEN lower(btrim(s."AssignTo"))    = lower(btrim(r."InspectBy"))
            OR lower(btrim(s."Replacement")) = lower(btrim(r."InspectBy"))
          THEN 0 ELSE 1
        END,
        -- (b) schedules already started by the finish time win
        CASE
          WHEN s."StartDate" <= COALESCE(r.actual_finished, r.created_at)
          THEN 0 ELSE 1
        END,
        -- (c) started -> latest StartDate first; not-started -> closest StartDate first
        abs(extract(epoch FROM (
          COALESCE(r.actual_finished, r.created_at) - s."StartDate"
        ))) ASC
    ) AS rn
  FROM "InspectionRecord" r
  JOIN "InspectionSchedule" s
    ON lower(btrim(s."JO_Number")) = lower(btrim(r."JO_Number"))
   AND lower(btrim(s."Part_Name")) = lower(btrim(r."Part_Name"))
   AND lower(btrim(s."Parameter")) = lower(btrim(
         COALESCE(NULLIF(btrim(r."Parameter"), ''), r."Inspection_Type")
       ))
  WHERE r.schedule_id IS NULL
)
UPDATE "InspectionRecord" r
SET schedule_id = ranked.schedule_id
FROM ranked
WHERE ranked.record_id = r.id
  AND ranked.rn = 1;

COMMIT;

-- 3. (Optional) Review anything still unlinked — no schedule shares its
--    JO + Part + Parameter. These keep using the app's heuristic fallback.
-- SELECT id, "JO_Number", "Part_Name", "Parameter", "Inspection_Type"
-- FROM "InspectionRecord" WHERE schedule_id IS NULL ORDER BY created_at DESC;
