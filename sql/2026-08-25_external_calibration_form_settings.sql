-- 2026-08-25  The printed form stops being hardcoded, and NO stops skipping numbers.
--
-- Two changes, both forced by the same thing: the 2024-2025 sheet is being loaded alongside the
-- 2025-2026 one, and three instruments that appear on the older form do not appear on the newer
-- one. The moment the masterlist can hold a retired instrument, two things that used to be
-- obviously right stop being right.
--
-- 1. THE RUNNING NUMBER MUST COUNT ONLY WHAT IS PRINTED.
--    v_ext_cal_masterlist.line_no numbered every row. It is documented as "the running NO on the
--    printed form" and the printed form is the ACTIVE instruments - REC-QAS010-05 has never
--    listed a scrapped gauge. With three obsolete rows in the table, a form printed from that
--    numbering would run 1, 2, 4, 5, 8... which is not a clerical annoyance: an auditor counting
--    a form that jumps from 6 to 9 has to establish whether two records are missing or two
--    numbers are.
--
--    So line_no now numbers ACTIVE equipment only, 1..N with no gaps, and is null for anything
--    retired. Null is the honest answer: a scrapped instrument has no line on the form.
--
-- 2. THE NAMES ON THE FORM ARE DATA, NOT MARKUP.
--    The 2025-2026 sheet is signed NAME: FARIANA and NAME: AYYUB. The 2024-2025 sheet is signed
--    by JESS LIM, and dated 21/12/2024. Those change, and they change without anybody wanting to
--    edit an HTML file to do it - which is exactly how the printed form ends up carrying the name
--    of somebody who left. The document number and effective date are the same kind of fact: they
--    belong to the quality system, not to a page.
--
--    One row, id = 1, enforced by CHECK for the same reason ext_cal_alert_config is - a settings
--    table that can hold two rows will eventually hold two rows and nothing will say which is live.
--
-- Safe to re-run.
--
-- Run as the table owner, AFTER sql/2026-08-25_external_calibration.sql:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-25_external_calibration_form_settings.sql

begin;

-- ---------------------------------------------------------------------
-- 1. What the printed form says
-- ---------------------------------------------------------------------
--
-- Every default here is transcribed from the header and footer of
-- MASTERLIST EXTERNAL CALIBRATION 2025 - 2026.xlsx, so a form printed before anybody opens the
-- settings is already the form they had.

create table if not exists ext_cal_form_settings (
    id               int primary key default 1,
    company_line     text not null default 'FAMAX TECHNOLOGY (M) SDN. BHD.     200601028954 (748710-K)',
    form_title       text not null default 'Inspection, Measuring & Test Equipment  Master List (EXTERNAL)',
    doc_no           text not null default 'REC-QAS010-05',
    effective_date   text not null default '01 MARCH 2024',
    retention_period text not null default '2 YEARS',
    prepared_by      text default 'FARIANA',
    approved_by      text default 'AYYUB',
    rows_per_page    int  not null default 10,
    updated_at       timestamptz not null default now(),
    updated_by       text,
    constraint ext_cal_form_settings_singleton_ck check (id = 1),
    -- Below 1 the form paginates forever; much above 12 and the rows stop fitting the landscape
    -- A4 the sheet is set up for. The real value is 10 and always has been - see the comment.
    constraint ext_cal_form_settings_rows_ck check (rows_per_page between 1 and 20)
);

insert into ext_cal_form_settings (id) values (1) on conflict (id) do nothing;

comment on table ext_cal_form_settings is
    'Single row. The masthead, signatures and footer of REC-QAS010-05, so the printed form can be '
    'corrected without editing a page. Defaults are transcribed from the 2025-2026 workbook.';
comment on column ext_cal_form_settings.rows_per_page is
    '10, because that is what the source workbook does. Both sheets break after ten instruments: '
    'in the 2025-2026 file page 1 is rows 6-25 and page 2 starts at row 39, which is ten items of '
    'two rows each. Changing this changes where the form breaks, nothing else.';
comment on column ext_cal_form_settings.prepared_by is
    'Printed under PREPARED BY. Null prints a blank rule to sign by hand, which is what the '
    '2024-2025 sheet does - its Name field was left empty and signed in ink.';
comment on column ext_cal_form_settings.effective_date is
    'Text, not a date. It is a label on a controlled document ("01 MARCH 2024") and reprinting it '
    'through a date formatter is how it would silently start reading 1 Mar 2024 or 03/01/2024.';

alter table ext_cal_form_settings enable row level security;
drop policy if exists ext_cal_form_settings_read  on ext_cal_form_settings;
drop policy if exists ext_cal_form_settings_write on ext_cal_form_settings;
create policy ext_cal_form_settings_read on ext_cal_form_settings
    for select to anon, authenticated using (true);
create policy ext_cal_form_settings_write on ext_cal_form_settings
    for all to anon, authenticated using (true) with check (true);
grant select, insert, update, delete on ext_cal_form_settings to anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. line_no counts the form, not the table
-- ---------------------------------------------------------------------
--
-- Identical to the view in 2026-08-25_external_calibration.sql except for line_no. Repeated in
-- full rather than patched, because `create or replace view` cannot change a column's type and a
-- half-stated view is worse to read than a whole one.
--
-- partition by (e.status = 'ACTIVE'): the active rows form one partition and are numbered 1..N;
-- everything else is numbered in its own partition and then thrown away by the case. Filtering
-- the rows out instead would drop retired equipment from the masterlist entirely, and the page
-- needs to show it - that is where the history of a scrapped gauge is read.

drop view if exists v_ext_cal_masterlist;

create view v_ext_cal_masterlist
  with (security_invoker = true) as
with latest as (
    select distinct on (equipment_id)
           equipment_id, id as event_id, cal_date, due_date, cert_no, lab,
           result, condition as event_condition, cert_url, remarks as event_remarks
      from ext_cal_event
     order by equipment_id, cal_date desc, id desc
),
cfg as (
    select lead_days, second_lead_days from ext_cal_alert_config where id = 1
)
select e.id,
       case when e.status = 'ACTIVE'
            then row_number() over (partition by (e.status = 'ACTIVE')
                                    order by e.sort_order, e.id)
       end                          as line_no,
       e.equipment_code,
       e.type_code,
       t.name                       as type_name,
       e.description,
       e.serial_no,
       e.brand,
       e.location,
       e.accepted_criteria,
       e.condition,
       e.cal_interval_months,
       e.calibration_required,
       e.status,
       e.sort_order,
       e.remarks,
       l.event_id,
       l.cal_date                   as last_cal_date,
       l.due_date                   as next_due_date,
       l.cert_no,
       l.lab,
       l.result                     as last_result,
       l.cert_url,
       (select count(*) from ext_cal_event x where x.equipment_id = e.id)::int as event_count,

       case when e.calibration_required and l.due_date is not null
            then (l.due_date - current_date)::int end as days_to_due,

       case
           when not e.calibration_required          then 'NOT_REQUIRED'
           when e.status <> 'ACTIVE'                then 'INACTIVE'
           when l.due_date is null                  then 'NEVER_CALIBRATED'
           when l.due_date <  current_date          then 'OVERDUE'
           when l.due_date <= current_date + (select second_lead_days from cfg) then 'DUE_URGENT'
           when l.due_date <= current_date + (select lead_days        from cfg) then 'DUE_SOON'
           else 'VALID'
       end as cal_status
  from ext_cal_equipment e
  left join ext_cal_equipment_type t on t.code = e.type_code
  left join latest l on l.equipment_id = e.id;

comment on view v_ext_cal_masterlist is
    'REC-QAS010-05 as one row per instrument: the equipment, its newest certificate, and which '
    'bucket that puts it in. The only thing that should answer "what is due" - the page, the alert '
    'endpoint and the scheduled task all read this, so none of them can disagree about what '
    'overdue means.';
comment on column v_ext_cal_masterlist.line_no is
    'The running NO on the printed form: 1..N across ACTIVE equipment in sort_order, and NULL for '
    'anything obsolete or scrapped. Derived, never stored, so retiring an instrument closes the '
    'gap instead of leaving the form numbered 1, 2, 4, 5.';
comment on column v_ext_cal_masterlist.cal_status is
    'NOT_REQUIRED - never calibrated by design (the lamp). INACTIVE - obsolete or scrapped. '
    'NEVER_CALIBRATED - due a first certificate. OVERDUE / DUE_URGENT / DUE_SOON / VALID against '
    'ext_cal_alert_config. Thresholds live in that one row so the page badge and the alert cannot '
    'drift apart.';

grant select on v_ext_cal_masterlist to anon, authenticated;

commit;

notify pgrst, 'reload schema';
