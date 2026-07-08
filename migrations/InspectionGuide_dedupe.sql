-- =====================================================================
-- TIDY UP: InspectionGuide + InspectionGuideDetails duplicates
-- Run in Supabase SQL Editor, one section at a time, top to bottom.
-- The app fixes (trim-match, upsert, double-submit guard) stop NEW
-- duplicates; this is the one-time cleanup of existing ones.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 0 — BACKUP (so you can restore if anything looks wrong)
-- ---------------------------------------------------------------------
create table if not exists "InspectionGuideDetails_bak" as
  select * from "InspectionGuideDetails";
create table if not exists "InspectionGuide_bak" as
  select * from "InspectionGuide";
-- To restore later:
--   truncate "InspectionGuideDetails"; insert into "InspectionGuideDetails" select * from "InspectionGuideDetails_bak";
--   truncate "InspectionGuide";        insert into "InspectionGuide"        select * from "InspectionGuide_bak";


-- ---------------------------------------------------------------------
-- STEP 1 — INSPECT (run these SELECTs first; look at what will be merged)
-- ---------------------------------------------------------------------
-- 1a. Duplicate guides: same part_no + process appearing more than once
select part_no, process, count(*) AS copies, array_agg(id order by id) AS ids
from "InspectionGuideDetails"
group by part_no, process
having count(*) > 1
order by copies desc;

-- 1b. Duplicate parameters: same name ignoring case/whitespace
select upper(trim("Parameter")) AS norm_name, count(*) AS copies, array_agg(id order by id) AS ids
from "InspectionGuide"
group by upper(trim("Parameter"))
having count(*) > 1
order by copies desc;


-- ---------------------------------------------------------------------
-- STEP 1c — NORMALIZE process (trim + uppercase) — run BEFORE Step 2 so
-- case/space variants collapse into the same part_no+process for dedup.
-- Drop the guard first: normalizing may create dupes that Step 2 removes,
-- then Step 2 re-creates the index.
-- ---------------------------------------------------------------------
drop index if exists uq_guide_details;

update "InspectionGuideDetails"
set process = upper(trim(process))
where process is distinct from upper(trim(process));


-- ---------------------------------------------------------------------
-- STEP 2 — REMOVE DUPLICATE GUIDE ROWS (part_no + process)
-- Keeps the NEWEST row (highest id) for each part_no+process, deletes the
-- rest. Review STEP 1a first; if you'd rather keep a different row, say so.
-- ---------------------------------------------------------------------
delete from "InspectionGuideDetails" a
using "InspectionGuideDetails" b
where a.part_no = b.part_no
  and a.process = b.process
  and a.id < b.id;

-- Guardrail so it can never happen again (fails if step 2 left dups — good):
create unique index if not exists uq_guide_details
  on "InspectionGuideDetails" (part_no, process);


-- ---------------------------------------------------------------------
-- STEP 3 — NORMALIZE PARAMETER NAMES (trim + uppercase)
-- Makes existing data match how the app now stores/looks them up.
-- ---------------------------------------------------------------------
update "InspectionGuide"
set "Parameter" = upper(trim("Parameter"))
where "Parameter" is distinct from upper(trim("Parameter"));


-- ---------------------------------------------------------------------
-- STEP 4 — DEDUPE PARAMETERS (inspection_ids / cycle_times are jsonb)
-- Key = (Parameter + Details), normalized (trim + uppercase). Keeps the
-- lowest id per group, remaps id references inside inspection_ids, then
-- deletes the duplicates. cycle_times is NEVER touched (stays aligned).
-- Run 4a → 4b → 4c → 4d → 4e in order, in ONE session.
-- ---------------------------------------------------------------------

-- 4a. Build the id → keeper map (keeper = lowest id per normalized Parameter+Details)
drop table if exists param_remap;
create table param_remap as
select id as old_id,
       min(id) over (
         partition by upper(trim("Parameter")), upper(trim(coalesce("Details",'')))
       ) as new_id
from "InspectionGuide";

-- 4b. PREVIEW (optional) — how many parameter rows will be merged away:
select count(*) as params_to_remove from param_remap where old_id <> new_id;

-- 4c. Remap the id VALUES inside inspection_ids (order preserved; cycle_times untouched)
update "InspectionGuideDetails" d
set inspection_ids = r.arr
from (
    select d2.id,
           jsonb_agg(coalesce(m.new_id, e.val::int) order by e.ord) as arr
    from "InspectionGuideDetails" d2
    cross join lateral jsonb_array_elements_text(d2.inspection_ids) with ordinality as e(val, ord)
    left join param_remap m on m.old_id = e.val::int
    where jsonb_typeof(d2.inspection_ids) = 'array'
    group by d2.id
) r
where d.id = r.id
  and d.inspection_ids is distinct from r.arr;

-- 4d. Delete the now-unreferenced duplicate parameter rows
delete from "InspectionGuide" g
using param_remap m
where g.id = m.old_id and m.old_id <> m.new_id;

-- 4e. Guard against future dupes + clean up the map
create unique index if not exists uq_guide_param
  on "InspectionGuide" (upper(trim("Parameter")), upper(trim(coalesce("Details",''))));
drop table param_remap;


-- ---------------------------------------------------------------------
-- STEP 4f — COLLAPSE REPEATED (inspection_id, cycle_time) PAIRS IN A ROW
-- e.g. inspection_ids [130,130,130] + cycle_times [16,16,16] -> [130] + [16].
-- Dedupes the two parallel jsonb arrays TOGETHER by position, keeping the
-- first occurrence and original order. A repeated id with a DIFFERENT
-- cycle_time is kept (it's a distinct pair).
-- ---------------------------------------------------------------------
-- Preview which rows have repeated pairs (optional):
select id, inspection_ids, cycle_times
from "InspectionGuideDetails"
where jsonb_typeof(inspection_ids) = 'array'
  and (select count(*) from jsonb_array_elements(inspection_ids)) >
      (select count(distinct (i.elem #>> '{}') || '|' || (c.elem #>> '{}'))
       from jsonb_array_elements(inspection_ids) with ordinality i(elem, o)
       join jsonb_array_elements(cycle_times)    with ordinality c(elem, o2) on i.o = c.o2);

update "InspectionGuideDetails" d
set inspection_ids = r.ids,
    cycle_times    = r.times
from (
    with pairs as (
        select d2.id as row_id, e.ord,
               e.elem                 as id_elem,
               (e.elem #>> '{}')      as id_key,
               t.elem                 as time_elem,
               (t.elem #>> '{}')      as time_key
        from "InspectionGuideDetails" d2
        cross join lateral jsonb_array_elements(d2.inspection_ids) with ordinality as e(elem, ord)
        cross join lateral jsonb_array_elements(d2.cycle_times)    with ordinality as t(elem, ord)
        where e.ord = t.ord
          and jsonb_typeof(d2.inspection_ids) = 'array'
          and jsonb_typeof(d2.cycle_times) = 'array'
    ),
    dedup as (
        select distinct on (row_id, id_key, time_key)
               row_id, ord, id_elem, time_elem
        from pairs
        order by row_id, id_key, time_key, ord   -- keep first occurrence
    )
    select row_id as id,
           jsonb_agg(id_elem   order by ord) as ids,
           jsonb_agg(time_elem order by ord) as times
    from dedup
    group by row_id
) r
where d.id = r.id
  and (d.inspection_ids is distinct from r.ids or d.cycle_times is distinct from r.times);


-- ---------------------------------------------------------------------
-- STEP 5 — refresh PostgREST so the API sees the changes
-- ---------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
