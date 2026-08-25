-- 2026-08-25  The external calibration masterlist stops being a spreadsheet.
--
-- REC-QAS010-05, "Inspection, Measuring & Test Equipment Master List (EXTERNAL)", has lived in
-- MASTERLIST EXTERNAL CALIBRATION 2025 - 2026.xlsx: one sheet, two printed pages, 18 pieces of
-- equipment, and a DUE DATE column that nothing watches. Item 11 - the WEIGHCOM counting scale,
-- serial A08326347 - fell due on 24 JUL 2026 and is a month overdue as this file is written. That
-- is the whole argument for moving it: a due date in a spreadsheet is a date nobody is told about.
--
-- Three things this file settles, and nothing else. No UI decisions are encoded here.
--
-- 1. DATES ARE DERIVED, NOT STORED TWICE.
--    The spreadsheet holds CALIBRATION and DUE DATE on the equipment row, and overwrites both
--    every time the equipment comes back from the lab. The previous certificate's dates are then
--    gone - there is no history, and no way to answer "when was the CMM last out of tolerance".
--
--    So the equipment table carries NO dates at all. Every calibration is a row in ext_cal_event,
--    and v_ext_cal_masterlist reads the latest one. This is the same reasoning that made
--    tools_item.qty_on_hand inert in 2026-08-05_tooling_access.sql: two columns claiming to hold
--    the same fact is how they end up disagreeing.
--
--    Note what is NOT derived. ext_cal_equipment.condition is the condition NOW; ext_cal_event
--    .condition is the condition recorded AT that calibration. Those are different facts about
--    different moments, not one fact stored twice - an instrument can be dropped in March and be
--    out of spec long before its next certificate says so. Item 3, the M23 x 1.25 6g thread ring,
--    is exactly that case: calibrated 4 DEC 2025 and carrying OUT OF SPEC today.
--
-- 2. THE DUE DATE IS ENTERED, NOT COMPUTED.
--    It is tempting to write next_due = cal_date + interval and be done. The certificates say
--    otherwise. The MAGODA floor scale went 15 DEC 2025 -> 14 DEC 2026 and both counting scales
--    23 JUL 2026 -> 22 JUL 2027: a day short of a year, because the lab dates the certificate,
--    not us. The six MICRON block gauges run 7 DEC 2021 -> 7 DEC 2026, a five-year interval.
--
--    So due_date is a stored, required column on the event, and cal_interval_months on the
--    equipment is only what the form pre-fills the date picker with. A computed due date would
--    have silently corrected six certificates into being wrong.
--
-- 3. "NA" IS A STATE, NOT A MISSING VALUE.
--    Item 18, the CHENXI microscope lamp, reads NA in both date columns. It is not overdue and it
--    is not awaiting its first calibration - it is a lamp, and it is never calibrated at all.
--    calibration_required = false says so, and the masterlist view reports it NOT_REQUIRED rather
--    than letting it sit in the overdue bucket forever.
--
-- Also here: NotificationRecipient gains a CALIBRATION role, so the alert reuses the mention
-- machinery in assets/teams-recipients.js rather than growing a second list of people to keep in
-- step with the first.
--
-- Safe to re-run. The seed is keyed on (equipment_code, serial_no) and will not double-load.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-25_external_calibration.sql

begin;

-- ---------------------------------------------------------------------
-- 1. Equipment types
-- ---------------------------------------------------------------------
--
-- The spreadsheet's EQUIPMENT column is two things at once. Rows 1-7 hold a type code (PP, PG,
-- TRG...); row 8 holds VMM02, which is not a type but the second video measuring machine. Keeping
-- them in one column is what makes the sheet impossible to group by.
--
-- So they are split: type_code is what this is, equipment_code is the marking on the asset and on
-- the printed form. For 17 of the 18 rows they are the same string, and for VMM02 they are not -
-- which is the entire reason the split exists.

create table if not exists ext_cal_equipment_type (
    code        text primary key,
    name        text not null,
    sort_order  int  not null default 0,
    is_active   boolean not null default true
);

comment on table ext_cal_equipment_type is
    'Lookup behind the EQUIPMENT column of REC-QAS010-05. Drives the type dropdown on the entry '
    'form so a new instrument cannot invent a fourth spelling of "block gauge".';

insert into ext_cal_equipment_type (code, name, sort_order) values
    ('PP',  'Profile Projector',             10),
    ('PG',  'Push Pull Gauge',               20),
    ('TRG', 'Thread Ring Gauge',             30),
    ('TPG', 'Thread Plug Gauge',             40),
    ('FS',  'Floor Scale',                   50),
    ('CMM', 'Coordinate Measuring Machine',  60),
    ('VMM', 'Video Measuring Machine',       70),
    ('CS',  'Counting Scale',                80),
    ('WM',  'Weighing Machine',              90),
    ('BG',  'Block Gauge',                  100),
    ('DLM', 'Dimmable LED Microscope Lamp', 110)
on conflict (code) do update
    set name = excluded.name, sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- 2. The equipment
-- ---------------------------------------------------------------------

create table if not exists ext_cal_equipment (
    id                   bigint generated by default as identity primary key,
    equipment_code       text not null,
    type_code            text references ext_cal_equipment_type(code),
    description          text not null,
    serial_no            text,
    brand                text,
    location             text,
    accepted_criteria    text,
    condition            text not null default 'GOOD',
    cal_interval_months  int  not null default 12,
    calibration_required boolean not null default true,
    status               text not null default 'ACTIVE',
    sort_order           int  not null default 0,
    remarks              text,
    created_at           timestamptz not null default now(),
    created_by           text,
    updated_at           timestamptz not null default now(),
    updated_by           text,
    constraint ext_cal_equipment_condition_ck
        check (condition in ('GOOD', 'OUT OF SPEC', 'UNDER REPAIR', 'DAMAGED')),
    constraint ext_cal_equipment_status_ck
        check (status in ('ACTIVE', 'OBSOLETE', 'SCRAPPED')),
    constraint ext_cal_equipment_interval_ck
        check (cal_interval_months between 1 and 120)
);

-- Serial numbers identify a physical asset, but four of the eighteen rows read N/A or nothing at
-- all, and NULLs do not collide in a unique index. Partial, so the constraint binds only where
-- there is actually a serial to bind on.
create unique index if not exists ext_cal_equipment_ident_uq
    on ext_cal_equipment (equipment_code, serial_no)
    where serial_no is not null and serial_no <> '' and upper(serial_no) <> 'N/A';

create index if not exists ext_cal_equipment_active_idx
    on ext_cal_equipment (status, sort_order) where status = 'ACTIVE';

comment on table ext_cal_equipment is
    'One row per externally calibrated instrument on REC-QAS010-05. Carries no dates on purpose - '
    'last calibration and next due are read from ext_cal_event through v_ext_cal_masterlist. See '
    'the header of sql/2026-08-25_external_calibration.sql.';
comment on column ext_cal_equipment.equipment_code is
    'The marking on the asset, printed in the EQUIPMENT column. VMM and VMM02 are two machines of '
    'one type; that is why this is separate from type_code.';
comment on column ext_cal_equipment.condition is
    'Condition NOW, not at the last calibration. An instrument can be found out of spec between '
    'certificates - ext_cal_event.condition is the historical snapshot and this is the live state.';
comment on column ext_cal_equipment.cal_interval_months is
    'What the entry form pre-fills the next-due picker with. NOT the due date: the lab dates the '
    'certificate, and six block gauges run a 60-month interval while a floor scale came back one '
    'day short of twelve months. The stored due date always wins.';
comment on column ext_cal_equipment.calibration_required is
    'False means this instrument is never calibrated - the microscope lamp, which the spreadsheet '
    'wrote as NA. It reports NOT_REQUIRED rather than sitting overdue forever.';

-- ---------------------------------------------------------------------
-- 3. The calibration history
-- ---------------------------------------------------------------------

create table if not exists ext_cal_event (
    id                   bigint generated by default as identity primary key,
    equipment_id         bigint not null references ext_cal_equipment(id) on delete cascade,
    cal_date             date not null,
    due_date             date not null,
    cert_no              text,
    lab                  text,
    result               text,
    condition            text,
    criteria             text,
    cert_url             text,
    remarks              text,
    recorded_by          text,
    recorded_by_position text,
    created_at           timestamptz not null default now(),
    constraint ext_cal_event_result_ck
        check (result is null or result in ('PASS', 'FAIL', 'LIMITED')),
    constraint ext_cal_event_condition_ck
        check (condition is null or condition in ('GOOD', 'OUT OF SPEC', 'UNDER REPAIR', 'DAMAGED')),
    -- A certificate that expires before it was issued is a typo, every time.
    constraint ext_cal_event_dates_ck check (due_date >= cal_date)
);

create index if not exists ext_cal_event_equipment_idx
    on ext_cal_event (equipment_id, cal_date desc, id desc);

-- The same instrument cannot be calibrated twice on one day. Catches the double-submit, which is
-- the realistic way a duplicate certificate gets entered.
create unique index if not exists ext_cal_event_one_per_day_uq
    on ext_cal_event (equipment_id, cal_date);

comment on table ext_cal_event is
    'One row per calibration certificate. The masterlist CALIBRATION and DUE DATE columns are the '
    'newest row here, which is why re-calibrating something no longer erases what it used to read.';
comment on column ext_cal_event.criteria is
    'The accepted criteria as they stood on THIS certificate, copied rather than joined. Criteria '
    'get revised; a certificate signed against the old ones must keep saying so.';
comment on column ext_cal_event.recorded_by is
    'Name from EmployeeTable of whoever keyed the certificate in. Same pattern as tools_txn.txn_by '
    'and Data_IPQC.sa_by - this application has no Supabase Auth session.';

-- ---------------------------------------------------------------------
-- 4. Alert settings
-- ---------------------------------------------------------------------
--
-- One row, id = 1, enforced by a CHECK rather than by convention - a settings table that can hold
-- two rows will eventually hold two rows, and nothing will say which one is live.
--
-- The Teams webhook URL is deliberately NOT here. A webhook URL is a bearer credential: anyone
-- holding it can post to the channel, and everything in this schema is readable with the anon key
-- that ships in assets/app-config.js. It lives server-side in config/config.js, exactly where
-- TEAMS_WEBHOOK_URL already lives. What lives here is what changes often and safely: how many days
-- of warning, and which channels are on.

create table if not exists ext_cal_alert_config (
    id                 int primary key default 1,
    lead_days          int  not null default 30,
    second_lead_days   int  not null default 7,
    teams_enabled      boolean not null default true,
    email_enabled      boolean not null default true,
    include_not_due    boolean not null default false,
    last_run_at        timestamptz,
    last_run_summary   text,
    updated_at         timestamptz not null default now(),
    updated_by         text,
    constraint ext_cal_alert_config_singleton_ck check (id = 1),
    constraint ext_cal_alert_config_lead_ck check (lead_days between 1 and 365),
    constraint ext_cal_alert_config_second_lead_ck
        check (second_lead_days between 1 and 365 and second_lead_days <= lead_days)
);

insert into ext_cal_alert_config (id) values (1) on conflict (id) do nothing;

comment on table ext_cal_alert_config is
    'Single row. How far ahead the calibration alert warns, and which channels it uses. The Teams '
    'webhook URL is NOT here - it is a credential and lives in config/config.js.';
comment on column ext_cal_alert_config.lead_days is
    'First warning: equipment falling due within this many days is DUE_SOON.';
comment on column ext_cal_alert_config.second_lead_days is
    'Second, louder warning. Inside this many days the alert marks the item urgent. Must not '
    'exceed lead_days, or the urgent window would open before the first warning was ever sent.';
comment on column ext_cal_alert_config.include_not_due is
    'Off by default. On, the alert also lists equipment that is comfortably in date - useful for a '
    'monthly status mail, noise for a daily one.';

-- ---------------------------------------------------------------------
-- 5. What was sent, and when
-- ---------------------------------------------------------------------
--
-- Without this the daily task cannot tell "nothing is due" from "I already said so this morning",
-- and a scheduler that retries would chase the same people repeatedly. It is also the only
-- evidence, at audit, that the overdue instrument was actually escalated.

create table if not exists ext_cal_alert_log (
    id             bigint generated by default as identity primary key,
    sent_at        timestamptz not null default now(),
    trigger_source text not null default 'MANUAL',
    channel        text not null,
    ok             boolean not null,
    overdue_count  int not null default 0,
    due_soon_count int not null default 0,
    detail         jsonb,
    sent_by        text,
    constraint ext_cal_alert_log_trigger_ck
        check (trigger_source in ('MANUAL', 'SCHEDULED')),
    constraint ext_cal_alert_log_channel_ck
        check (channel in ('TEAMS', 'EMAIL'))
);

create index if not exists ext_cal_alert_log_recent_idx
    on ext_cal_alert_log (sent_at desc);

comment on table ext_cal_alert_log is
    'Every alert attempt, successful or not. The daily task reads it to avoid sending the same '
    'digest twice in one day; the audit reads it to see that an overdue instrument was chased.';
comment on column ext_cal_alert_log.ok is
    'False is recorded, not swallowed. A failed send that leaves no row looks exactly like a day '
    'on which nothing was due.';

-- ---------------------------------------------------------------------
-- 6. The masterlist, as the page and the alert both read it
-- ---------------------------------------------------------------------
--
-- security_invoker so the view is not a way around the policies in section 8.
--
-- distinct on (equipment_id) ordered by cal_date desc, id desc: the newest certificate, with id
-- breaking a same-day tie deterministically. Without the id tiebreaker two certificates entered on
-- one day would swap places between page loads - which is why section 3 also forbids them.

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
       row_number() over (order by e.sort_order, e.id) as line_no,
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

       -- Null for equipment that is never calibrated and for equipment that never has been. Both
       -- are states the buckets below name outright, so nothing has to read a null as a number.
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
    'The running NO on the printed form. Derived from sort_order, never stored, so retiring an '
    'instrument renumbers the sheet instead of leaving a gap at 7.';
comment on column v_ext_cal_masterlist.cal_status is
    'NOT_REQUIRED - never calibrated by design (the lamp). INACTIVE - obsolete or scrapped. '
    'NEVER_CALIBRATED - due a first certificate. OVERDUE / DUE_URGENT / DUE_SOON / VALID against '
    'ext_cal_alert_config. Thresholds live in that one row so the page badge and the alert cannot '
    'drift apart.';

grant select on v_ext_cal_masterlist to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Who gets told
-- ---------------------------------------------------------------------
--
-- Reusing NotificationRecipient rather than starting a second list. assets/teams-recipients.js
-- already builds the three rendered forms of a mention - the plain preview, the <at> token and the
-- msteams entity - from one row, which is what stops a card displaying one name while pinging a
-- different address. A separate calibration recipient table would need all of that again, and
-- would drift the first time somebody resigned.

alter table "NotificationRecipient" drop constraint if exists "NotificationRecipient_role_check";
alter table "NotificationRecipient"
    add constraint "NotificationRecipient_role_check"
    check (role in ('QA', 'ENG', 'MANAGEMENT', 'CALIBRATION'));

comment on constraint "NotificationRecipient_role_check" on "NotificationRecipient" is
    'CALIBRATION was added 2026-08-25 for the external calibration due/overdue alert. A person can '
    'hold two roles by having two rows - that is intended, and is how the QA lead gets both.';

-- ---------------------------------------------------------------------
-- 8. RLS
-- ---------------------------------------------------------------------
--
-- `to anon, authenticated`, using(true), for the same reason every other table in this schema
-- reads that way: the app has no Supabase Auth session and arrives on the shared anon key.
-- Authorisation is the ALL/QUALITY check in the page, exactly as it is for the gauge masterlist.
-- See NOTE 3 of sql/2026-08-05_tooling_access.sql for what that costs and what would fix it.

do $$
declare t text;
begin
  foreach t in array array['ext_cal_equipment_type','ext_cal_equipment','ext_cal_event',
                           'ext_cal_alert_config','ext_cal_alert_log']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t || '_read',  t);
    execute format('drop policy if exists %I on %I', t || '_write', t);
    execute format(
      'create policy %I on %I for select to anon, authenticated using (true)', t || '_read', t);
    execute format(
      'create policy %I on %I for all to anon, authenticated using (true) with check (true)',
      t || '_write', t);
    execute format('grant select, insert, update, delete on %I to anon, authenticated', t);
  end loop;
end $$;

-- Identity columns need the sequence too, or every insert 403s on the sequence rather than the
-- table - which reads as an RLS failure and sends you looking in the wrong place.
grant usage, select on all sequences in schema public to anon, authenticated;

commit;

-- PostgREST caches the schema; without this the new tables and the view 404 until the container
-- restarts.
notify pgrst, 'reload schema';
