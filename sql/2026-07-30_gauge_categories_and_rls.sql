-- 2026-07-30  Gauge categories become data, and the masterlist becomes readable.
--
-- Two problems with the masterlist schema as loaded.
--
-- 1. CATEGORIES WERE WELDED SHUT.
--    gauge_type was a PostgreSQL enum of exactly 'TPG','TRG','PIN'. Three things
--    hardcoded those values: the enum itself, spec_shape_ck (which branched on
--    `gauge_type = 'PIN'`), and both partial unique indexes. Recording a snap
--    gauge, a bore gauge or a plain plug gauge therefore meant a DDL migration
--    plus a hand-rewritten check constraint — a DBA task, for what is really
--    just "QA bought a new kind of gauge".
--
--    Categories are now rows in out_gauge_category. Adding one is an INSERT the
--    QA admin can make from the masterlist page.
--
--    The shape rule keys off measurement_kind, not the category code:
--
--      'thread'    a size and a pitch/TPI      TPG, TRG, taper thread ...
--      'diameter'  a single diameter          PIN, plain plug, bore, snap ...
--      'other'     neither                    radius, thread wires, anything new
--
--    A CHECK constraint cannot query another table, so measurement_kind is
--    stored ON THE SPEC. It cannot drift from its category, because the FK is
--    composite — (gauge_type, measurement_kind) must match a real
--    (code, measurement_kind) pair. A trigger fills it in so callers can keep
--    sending just the category code.
--
--    Anything a future category needs that has no column gets a home in the new
--    `attributes` jsonb, so category number four does not mean migration number
--    four.
--
-- 2. NOTHING COULD READ THE TABLES.
--    Part H granted select `to authenticated`. This application does not use
--    Supabase Auth — it signs in against AdminCredential and keeps the result in
--    sessionStorage — so every request arrives on the shared anon key and
--    auth.jwt() is null. Every policy evaluated false: reads returned [] and
--    writes returned 401. The masterlist was invisible to the app that owns it.
--
--    Policies now grant anon, matching Parts / JobOrder / TeamsLog and the rest
--    of the system. Authorisation stays where this app has always put it: the
--    AdminCredential access-level check in the page. That is a deliberate
--    trade, not an oversight — see the note at the end.
--
-- Idempotent: safe to re-run. Preserves existing rows.

begin;

-- ---------------------------------------------------------------------
-- 1. Category lookup
-- ---------------------------------------------------------------------

create table if not exists out_gauge_category (
  code              text primary key,
  name              text not null,
  measurement_kind  text not null
                    check (measurement_kind in ('thread','diameter','other')),
  description       text,
  sort_order        int  not null default 100,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  -- lets out_gauge_spec carry a composite FK, which is what stops
  -- measurement_kind on a spec from disagreeing with its category
  unique (code, measurement_kind)
);

insert into out_gauge_category (code, name, measurement_kind, description, sort_order) values
  ('TPG', 'Thread Plug Gauge',  'thread',   'Checks an internal thread. GO / NOGO plug.', 10),
  ('TRG', 'Thread Ring Gauge',  'thread',   'Checks an external thread. GO / NOGO ring.', 20),
  ('PIN', 'Pin Gauge',          'diameter', 'Checks a hole or slot. Single diameter.',    30)
on conflict (code) do nothing;

alter table out_gauge_category enable row level security;

-- ---------------------------------------------------------------------
-- 2. Spec: enum -> text FK, kind-driven shape rule, jsonb escape hatch
-- ---------------------------------------------------------------------

-- Views and indexes depend on the column, so they come down first.
drop view if exists out_v_gauge_masterlist      cascade;
drop view if exists out_v_pin_gauge_coverage    cascade;
drop view if exists out_v_incomplete_ring_sets  cascade;
drop view if exists out_v_calibration_due_soon  cascade;

drop index if exists out_gauge_spec_pin_uq;
drop index if exists out_gauge_spec_thread_uq;
drop index if exists out_gauge_spec_size_idx;

alter table out_gauge_spec drop constraint if exists spec_shape_ck;

-- enum -> text. `using` preserves every existing value verbatim.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_name = 'out_gauge_spec' and column_name = 'gauge_type'
      and data_type = 'USER-DEFINED'
  ) then
    alter table out_gauge_spec
      alter column gauge_type type text using gauge_type::text;
  end if;
end $$;

alter table out_gauge_spec add column if not exists measurement_kind text;
alter table out_gauge_spec add column if not exists attributes jsonb not null default '{}'::jsonb;

-- Backfill for rows that predate this migration.
update out_gauge_spec s
   set measurement_kind = c.measurement_kind
  from out_gauge_category c
 where c.code = s.gauge_type
   and s.measurement_kind is distinct from c.measurement_kind;

-- Any spec whose category was never registered gets one, so the FK can be
-- added without dropping data. 'other' is the safe kind: it constrains nothing.
insert into out_gauge_category (code, name, measurement_kind, description, sort_order)
select distinct s.gauge_type, s.gauge_type, 'other',
       'Auto-registered by the 2026-07-30 migration — review name and kind.', 900
from out_gauge_spec s
where not exists (select 1 from out_gauge_category c where c.code = s.gauge_type)
on conflict (code) do nothing;

update out_gauge_spec s
   set measurement_kind = c.measurement_kind
  from out_gauge_category c
 where c.code = s.gauge_type and s.measurement_kind is null;

alter table out_gauge_spec alter column measurement_kind set not null;

alter table out_gauge_spec drop constraint if exists out_gauge_spec_category_fk;
alter table out_gauge_spec
  add constraint out_gauge_spec_category_fk
  foreign key (gauge_type, measurement_kind)
  references out_gauge_category (code, measurement_kind)
  on update cascade;

-- Keep measurement_kind in step with the category without asking callers for it.
create or replace function out_gauge_spec_fill_kind() returns trigger
language plpgsql as $$
declare k text;
begin
  select measurement_kind into k from out_gauge_category where code = new.gauge_type;
  if k is null then
    raise exception 'Unknown gauge category %. Add it to out_gauge_category first.', new.gauge_type;
  end if;
  new.measurement_kind := k;   -- always authoritative, never trusted from the caller
  return new;
end $$;

drop trigger if exists out_gauge_spec_kind on out_gauge_spec;
create trigger out_gauge_spec_kind before insert or update of gauge_type on out_gauge_spec
  for each row execute function out_gauge_spec_fill_kind();

-- The shape rule, now generic. 'other' deliberately constrains nothing —
-- that is what makes an unforeseen category recordable on day one.
alter table out_gauge_spec add constraint spec_shape_ck check (
  case measurement_kind
    when 'diameter' then pin_dia_mm is not null
                     and pitch_mm is null
                     and threads_per_inch is null
    when 'thread'   then pin_dia_mm is null
    else true
  end
);

create unique index if not exists out_gauge_spec_dia_uq
  on out_gauge_spec (gauge_type, pin_dia_mm) where measurement_kind = 'diameter';
create unique index if not exists out_gauge_spec_designation_uq
  on out_gauge_spec (gauge_type, designation) where measurement_kind <> 'diameter';
create index if not exists out_gauge_spec_size_idx
  on out_gauge_spec (gauge_type, nominal_size_mm, pitch_mm);
create index if not exists out_gauge_spec_kind_idx
  on out_gauge_spec (measurement_kind, gauge_type);

-- The old enum is now unreferenced. Dropped only if nothing else uses it.
do $$
begin
  drop type if exists gauge_type;
exception when dependent_objects_still_exist then
  raise notice 'enum gauge_type still referenced elsewhere; left in place';
end $$;

-- ---------------------------------------------------------------------
-- 3. Views rebuilt against the category table
-- ---------------------------------------------------------------------

create or replace view out_v_gauge_masterlist as
select s.gauge_type,
       c.name             as category_name,
       s.measurement_kind,
       s.designation      as description,
       i.owner_dept,
       i.member,
       i.serial_number,
       i.brand,
       coalesce(i.location, i.storage_box) as location,
       count(*) over (partition by s.id, i.owner_dept,
                      coalesce(i.location, i.storage_box)) as quantity,
       i.date_received,
       i.marking,
       i.status,
       i.calibration_due,
       i.source_ref,
       s.id               as spec_id,
       i.id               as item_id
from out_gauge_item i
join out_gauge_spec s     on s.id = i.spec_id
join out_gauge_category c on c.code = s.gauge_type;

-- was out_v_pin_gauge_coverage; now covers every diameter-kind category
create or replace view out_v_diameter_gauge_coverage as
select s.gauge_type, s.pin_dia_mm,
       count(*) filter (where i.owner_dept = 'QA'   and i.status = 'active') as qa_qty,
       count(*) filter (where i.owner_dept = 'PROD' and i.status = 'active') as prod_qty
from out_gauge_spec s
left join out_gauge_item i on i.spec_id = s.id
where s.measurement_kind = 'diameter'
group by s.gauge_type, s.pin_dia_mm;

-- kept under the old name so anything already querying it keeps working
create or replace view out_v_pin_gauge_coverage as
select pin_dia_mm, qa_qty, prod_qty
from out_v_diameter_gauge_coverage where gauge_type = 'PIN';

-- any category whose items use GO/NOGO, not just TRG
create or replace view out_v_incomplete_ring_sets as
select s.gauge_type, s.designation,
       count(*) filter (where i.member = 'SET')  as sets,
       count(*) filter (where i.member = 'GO')   as go_only,
       count(*) filter (where i.member = 'NOGO') as nogo_only
from out_gauge_spec s
join out_gauge_item i on i.spec_id = s.id
group by s.gauge_type, s.designation
having count(*) filter (where i.member in ('GO','NOGO')) > 0;

create or replace view out_v_calibration_due_soon as
select s.gauge_type, s.designation, i.owner_dept, i.marking,
       coalesce(i.location, i.storage_box) as location, i.calibration_due
from out_gauge_item i
join out_gauge_spec s on s.id = i.spec_id
where i.status = 'active'
  and i.calibration_due is not null
  and i.calibration_due <= current_date + 60;

-- ---------------------------------------------------------------------
-- 4. RLS: grant the application's anon role
-- ---------------------------------------------------------------------
--
-- Every policy below is `to anon, authenticated`, because the app has no
-- Supabase Auth session and arrives as anon. Read AND write are open at the
-- database, exactly as they are for Parts, JobOrder and TeamsLog. See note 2.

do $$
declare t text;
begin
  foreach t in array array['out_gauge_spec','out_gauge_item','out_gauge_part_usage',
                           'out_gauge_calibration','out_gauge_transaction',
                           'out_gauge_category']
  loop
    execute format('drop policy if exists %I on %I', t || '_read',  t);
    execute format('drop policy if exists %I on %I', t || '_write', t);
    execute format(
      'create policy %I on %I for select to anon, authenticated using (true)',
      t || '_read', t);
    execute format(
      'create policy %I on %I for all to anon, authenticated using (true) with check (true)',
      t || '_write', t);
  end loop;
end $$;

-- the original names from Part H, now superseded
drop policy if exists out_gauge_part_read on out_gauge_part_usage;
drop policy if exists out_gauge_cal_read  on out_gauge_calibration;
drop policy if exists out_gauge_txn_read  on out_gauge_transaction;

commit;

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 — adding a category is now data, not DDL:
--
--   insert into out_gauge_category (code, name, measurement_kind, sort_order)
--   values ('SNAP', 'Snap Gauge', 'diameter', 40);
--
--   It appears as a new tab on the masterlist page immediately. The page can
--   also do this for you (Categories > Add). Pick the kind carefully — it is
--   what decides which fields the form shows and which are required:
--     thread    -> size + pitch/TPI + class + hand; pin_dia_mm must stay null
--     diameter  -> pin_dia_mm required; pitch and TPI must stay null
--     other     -> nothing enforced; use the `attributes` jsonb
--
-- NOTE 2 — what the RLS change actually costs.
--   Anyone holding the anon key (it ships in assets/app-config.js, so: anyone
--   who can load the site) can read and write these tables directly, bypassing
--   the page. That is already true of Parts, JobOrder, SalesOrders and the rest
--   of this system — this migration makes the gauge tables consistent with it,
--   it does not introduce the exposure. If you later want the gauge masterlist
--   held to a higher standard than the rest of the app, the fix is a real
--   Supabase Auth session, and these policies revert to `to authenticated`.
--
-- NOTE 3 — owner_dept is still an enum ('QA','PROD').
--   A third department needs `alter type gauge_owner add value '...'`. Left
--   alone deliberately: it was not asked for, and unlike gauge_type nothing
--   branches on its value. Say the word and it can get the same treatment.
--
-- NOTE 4 — verify:
--   select code, name, measurement_kind from out_gauge_category order by sort_order;
--   select gauge_type, measurement_kind, count(*) from out_gauge_spec group by 1,2;
--   select count(*) from out_v_gauge_masterlist;
