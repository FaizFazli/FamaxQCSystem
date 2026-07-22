-- ============================================================================
-- vw_inspection_dashboard
-- One clean, flat row per InspectionRecord for Power BI (or any BI tool).
-- Pre-joins the matched InspectionSchedule (via InspectionRecord.schedule_id),
-- adds the month/day attribution date (eff_date = actual_finished, fallback
-- created_at) used by the dashboard + QA performance report, the pass/reject/
-- rework rates, and overdue flags.
--
-- Run once in the Supabase SQL editor. Safe to re-run (CREATE OR REPLACE).
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW "vw_inspection_dashboard" AS
SELECT
  r.id                                                   AS record_id,

  -- ---- dates ----
  r."created_at",
  r."actual_finished",
  COALESCE(r."actual_finished", r."created_at")          AS eff_datetime,
  (COALESCE(r."actual_finished", r."created_at"))::date  AS eff_date,     -- use this on the date axis
  to_char(COALESCE(r."actual_finished", r."created_at"), 'YYYY-MM') AS eff_month,

  -- ---- part / job / inspector ----
  r."part_no",
  r."Part_Name",
  r."JO_Number",
  r."Parameter",
  r."Inspection_Type",
  r."InspectBy"                                          AS inspector,
  r."remark_finished",

  -- ---- quantities (null-safe) ----
  COALESCE(r."TotalCheck", 0)                            AS total_check,
  COALESCE(r."AcceptQty", 0)                             AS accept_qty,
  COALESCE(r."RejectQty", 0)                             AS reject_qty,
  COALESCE(r."ScrapQty", 0)                              AS scrap_qty,
  COALESCE(r."ReworkQty", 0)                             AS rework_qty,

  -- ---- rates (guard divide-by-zero; leave NULL when no checks) ----
  CASE WHEN COALESCE(r."TotalCheck", 0) > 0
       THEN round(r."AcceptQty"::numeric / r."TotalCheck", 4) END AS pass_rate,
  CASE WHEN COALESCE(r."TotalCheck", 0) > 0
       THEN round(r."RejectQty"::numeric / r."TotalCheck", 4) END AS reject_rate,
  CASE WHEN COALESCE(r."TotalCheck", 0) > 0
       THEN round(r."ReworkQty"::numeric / r."TotalCheck", 4) END AS rework_rate,

  -- ---- matched schedule ----
  r.schedule_id,
  s."StartDate"                                          AS sched_start,
  s."EstFinished"                                        AS sched_est_finished,
  s."AssignTo"                                           AS assigned_to,
  s."Replacement"                                        AS replacement,
  s."Status"                                             AS sched_status,

  -- ---- overdue: finished later than the estimate ----
  CASE
    WHEN s."EstFinished" IS NOT NULL AND r."actual_finished" IS NOT NULL
    THEN (r."actual_finished" > s."EstFinished")
  END                                                    AS is_overdue,
  CASE
    WHEN s."EstFinished" IS NOT NULL AND r."actual_finished" IS NOT NULL
         AND r."actual_finished" > s."EstFinished"
    THEN round(GREATEST(0, extract(epoch FROM (r."actual_finished" - s."EstFinished")) / 60.0))
  END                                                    AS overdue_minutes

FROM "InspectionRecord" r
LEFT JOIN "InspectionSchedule" s ON s.id = r.schedule_id;

-- Let the app's anon role and (if created) the read-only BI role read the view.
GRANT SELECT ON "vw_inspection_dashboard" TO anon;
-- GRANT SELECT ON "vw_inspection_dashboard" TO bi_readonly;   -- uncomment if you made this role

COMMIT;

-- Quick check:
-- SELECT eff_month, SUM(total_check) AS checks, SUM(accept_qty) AS passed,
--        SUM(reject_qty) AS rejected, SUM(scrap_qty) AS scrap
-- FROM vw_inspection_dashboard
-- GROUP BY eff_month ORDER BY eff_month;
