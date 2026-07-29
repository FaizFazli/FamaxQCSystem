-- 2026-07-28  Job Traveler Card: JO production progress + auto "production done" flag
-- Lets a Job Order row auto-flag production completion WITHOUT disturbing the manual QC Status
-- ("Status"/"completed_at" remain the QC-completion flag; these two are the PRODUCTION flag).
--
-- produced_qty is a cached running total per JobOrder row (JO_Number + Process). The authoritative
-- value is always SUM(Daily_Output.output_count) for that JO+process; daily_output.html recomputes
-- and PATCHes this column after each output save (idempotent). production_completed_at is set the
-- first time produced_qty >= Quantity.

alter table "JobOrder" add column if not exists produced_qty            numeric default 0;
alter table "JobOrder" add column if not exists production_completed_at  timestamptz;
