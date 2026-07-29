-- 2026-07-28  Job Traveler Card: per-shift production output
-- Extend the existing Daily_Output table (write-only today) instead of creating a parallel table.
-- A row now represents one machine's net output for one (production_date, shift, jo_number, process).
--
-- Shift definition is a UI constant (not a DB table), shared by daily_output.html and
-- jobTravelerCard.html:
--   Day   = 08:00-18:00  (overtime counted through 19:00)
--   Night = 19:00-05:00  (crosses midnight)
-- For a night shift, the form stamps production_date = the date the shift STARTED, so a
-- 19:00-05:00 shift is attributed to its start date.

alter table "Daily_Output" add column if not exists shift    text;   -- 'Day' | 'Night'
alter table "Daily_Output" add column if not exists operator text;   -- PIC / machine operator

create index if not exists idx_dailyoutput_jo on "Daily_Output" (jo_number);
