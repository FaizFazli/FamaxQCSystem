-- 2026-08-17  A resignation takes somebody off the dropdowns without erasing them.
--
-- EmployeeTable is the HR roster. Nine screens read it to fill a name list — QA/QC staff for
-- the inspection forms, anyone with TECHNICIAN in their position for the IPQC Machine Stop
-- report, everybody for the Quality Hub Users panel. Until now the only way to take a leaver
-- off those lists was to delete the row.
--
-- WHY NOT JUST DELETE THE ROW.
--   A delete is silent and unrecoverable, and it destroys more than the dropdown entry:
--
--   * empID and pin go with it. Four people hold a PIN, and a PIN is what proves identity when
--     a special accept is granted (2026-08-04_ipqc_reject_record.sql) or a tool movement is
--     recorded (2026-08-05_tooling_access.sql). Those records store the NAME and never the PIN,
--     so after a delete there is nothing left to check a historical signature against.
--   * History does survive a delete — Data_IPQC.Person, InspectionRecord.InspectBy,
--     tools_txn.txn_by and sa_by are all denormalised text, not foreign keys — but the name in
--     those records stops resolving to a person. "Who was that, and what was their empID?"
--     becomes unanswerable.
--   * Somebody who resigns and returns has to be re-keyed, with a new id, and their earlier
--     service is gone.
--
--   Marking is reversible, keeps the evidence, and costs one column.
--
-- WHAT THIS DOES NOT DO.
--   Adding the column changes nothing on its own — every existing screen keeps returning every
--   employee until its query is given the filter below. The nine call sites are updated in the
--   same commit as this file. The rule they all use:
--
--       resigned_on is null      -- PostgREST: &resigned_on=is.null
--
--   Deliberately a DATE and not a boolean. "Has this person left" and "when did they leave" are
--   the same question asked twice, and a boolean can only answer the first — which is the one
--   nobody needs six months later.
--
-- Idempotent: safe to re-run. Preserves every existing row, and leaves every existing employee
-- active (resigned_on defaults to null).
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-17_employee_resigned.sql

begin;

alter table "EmployeeTable" add column if not exists resigned_on date;
alter table "EmployeeTable" add column if not exists resigned_by text;

comment on column "EmployeeTable".resigned_on is
    'The date this person left. NULL means still employed, which is what every name dropdown in '
    'the system filters on (resigned_on is null). Set from the Employee Register page rather '
    'than by deleting the row, so empID and pin survive and a historical signature can still be '
    'traced to a person. Clearing it reinstates them.';

comment on column "EmployeeTable".resigned_by is
    'Who recorded the resignation, copied by the page from the signed-in user. The same '
    'denormalised-name pattern as Data_IPQC.sa_by and tools_txn.txn_by, and for the same reason: '
    'this application has no Supabase Auth session.';

-- Partial, because every dropdown query in the system asks the same narrow question — the
-- active roster — and none of them ever scan the leavers.
create index if not exists idx_employeetable_active
    on "EmployeeTable" (name) where resigned_on is null;

-- Departments are picked from a list on the page rather than typed, but the page builds that
-- list from what is already stored. This index keeps that read cheap and, more usefully, makes
-- the existing spread visible to anyone looking at the table.
create index if not exists idx_employeetable_department
    on "EmployeeTable" (department);

commit;

notify pgrst, 'reload schema';

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - the nine reads that must carry the filter. All updated alongside this file; listed
--   here so a tenth one added later is easy to check against.
--
--     quality-hub.app.js:466                             Users panel, everybody
--     screen_page/buy_off/BUYOFF-page1.html:805          inspector combobox
--     screen_page/ipqc/IPQC-page1.html:1479              checker list, QA/QC
--     screen_page/ipqc/IPQC-page.html:778                Machine Stop person, *TECHNICIAN*
--     screen_page/iqc/IQC-page1.html:1446                checker list, QA/QC
--     screen_page/inspection/inspectionCheckerForm.html:977
--     screen_page/inspection/inspectionDailyReport.html:598
--     screen_page/inspection/inspectionSchedule.html:1061
--     screen_page/inspection/inspectionDashboard.html:1660
--
-- NOTE 2 - RLS is deliberately untouched.
--   EmployeeTable carries no row level security today, in common with Parts, JobOrder and the
--   rest of the original tables, so the page writes on the anon key exactly as every other
--   screen does. Enabling RLS here would be a change to how nine working screens read the
--   table, which is a bigger decision than this feature and does not belong in it.
--
-- NOTE 3 - the position spellings are not cleaned up here.
--   The roster holds both 'PRODUCTION OPERATORS' (20 rows) and 'PRODUCTION OPERATOR' (8), which
--   are one job title stored two ways. Nothing branches on the difference today — the only
--   position match in the system is IPQC-page.html's `position=ilike.*TECHNICIAN*`, which is
--   unaffected — so rewriting somebody's job title is not this migration's business. The
--   Employee Register offers the existing spellings as you type, which stops a third variant
--   being created; merging the two that exist is a decision for whoever owns the roster.
--
-- NOTE 4 - verify:
--   select count(*) from "EmployeeTable";                          -- 58, unchanged
--   select count(*) from "EmployeeTable" where resigned_on is null;-- 58, all still active
--   \d "EmployeeTable"                                             -- resigned_on, resigned_by
--
--   -- a round trip, on a row you do not mind touching:
--   update "EmployeeTable" set resigned_on = current_date, resigned_by = 'tester'
--    where id = <pick one>;
--   select count(*) from "EmployeeTable" where resigned_on is null;-- 57
--   update "EmployeeTable" set resigned_on = null, resigned_by = null where id = <same>;
--   select count(*) from "EmployeeTable" where resigned_on is null;-- 58 again
