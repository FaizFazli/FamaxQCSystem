-- 2026-08-07  btrim() does not strip tabs, and the part master has tabs.
--
-- A bug in the three costing files above this one, found the first time a rate was matched to a
-- real part rather than a typed one. Part number 07150-03036 is stored as '07150-03036' followed
-- by four TAB characters. The pages key on JavaScript's String.trim(), which strips tabs; every
-- view and index keys on PostgreSQL's btrim(), which by default strips only spaces. The two
-- disagreed, so a cost entered against that part matched nothing and read on the screen as though
-- it had never been entered.
--
-- It is not one row:
--
--   Parts.Part_Number         5 rows with edge whitespace, 3 of them tabs btrim misses
--   Parts.Raw_Material        9 rows with edge whitespace, 7 of them tabs btrim misses
--   Parts.Raw_Material_Grade  3 rows with edge whitespace, 2 of them tabs btrim misses
--   JobOrder.Process          7 rows, all plain spaces - btrim was already handling these
--
-- Ten of the eleven tab-carrying rows are on the material side, which is exactly where the new
-- rate lookup joins, so this would have quietly cost ten parts nothing.
--
-- ONE NORMALISER, USED EVERYWHERE A KEY IS FORMED.
--   norm_key() replaces every btrim() that was acting as a key: in the three normalise triggers,
--   in the three uniqueness indexes, and in every join in the four views. It strips all
--   whitespace, so it agrees with the String.trim() the pages already use. The rule is now one
--   function in one place rather than a btrim() repeated in eleven, which is what let the
--   original mistake be made once and then copied.
--
-- THE MASTER IS NOT REWRITTEN.
--   Nothing here UPDATEs Parts. Normalising on read is what makes this robust against the next
--   pasted tab, which cleaning the existing rows would not - and whatever screen wrote a tab into
--   a part number is still writing them.
--
--   A tab on the end of a part number is unambiguous junk and would be safe to strip, unlike the
--   process-name variants the first file deliberately left alone. It is left to a person anyway,
--   because it is somebody else's table and v_cost_key_hygiene below lists exactly which rows to
--   look at. Nothing depends on it being done.
--
-- Safe to re-run. Preserves every existing row.
--
-- Run as the table owner, AFTER the other three 2026-08-07 files:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-07_key_whitespace.sql

begin;

-- ---------------------------------------------------------------------
-- 1. The normaliser
-- ---------------------------------------------------------------------
--
-- [[:space:]] covers space, tab, newline, carriage return, form feed and vertical tab, and in
-- this database's UTF-8 collation it also matches U+00A0. That is the same set String.trim()
-- strips, which is the whole requirement: the database and the page must agree on what the key
-- is. There are no U+00A0 in the master today - it is covered so that agreement does not depend
-- on that staying true.
--
-- Immutable because the uniqueness indexes below are built on it. It is: same input, same output,
-- no table access, no locale-dependent case folding.

create or replace function norm_key(t text) returns text
    language sql immutable as
$$ select nullif(regexp_replace(coalesce(t, ''), '^[[:space:]]+|[[:space:]]+$', '', 'g'), '') $$;

comment on function norm_key(text) is
    'Trim for keys: strips ALL leading and trailing whitespace, and returns null for what is left '
    'empty. Replaces btrim(), which strips only spaces and therefore disagreed with the '
    'String.trim() the pages key on - Parts.Part_Number 07150-03036 carries four tabs. Use this '
    'anywhere a text column is being used to match, never btrim().';

-- ---------------------------------------------------------------------
-- 2. Normalise triggers
-- ---------------------------------------------------------------------

create or replace function process_cost_normalise() returns trigger
    language plpgsql as $$
begin
    new.part_no      := norm_key(new.part_no);
    new.process_name := norm_key(new.process_name);
    new.remarks      := nullif(btrim(coalesce(new.remarks, '')), '');
    new.updated_at   := now();
    return new;
end $$;

create or replace function part_material_normalise() returns trigger
    language plpgsql as $$
begin
    new.part_no         := norm_key(new.part_no);
    new.costed_material := norm_key(new.costed_material);
    new.costed_grade    := norm_key(new.costed_grade);
    new.override_reason := nullif(btrim(coalesce(new.override_reason, '')), '');
    new.remarks         := nullif(btrim(coalesce(new.remarks, '')), '');
    new.updated_at      := now();
    return new;
end $$;

create or replace function material_rate_normalise() returns trigger
    language plpgsql as $$
begin
    new.material   := norm_key(new.material);
    new.grade      := norm_key(new.grade);
    new.source     := nullif(btrim(coalesce(new.source, '')), '');
    new.remarks    := nullif(btrim(coalesce(new.remarks, '')), '');
    new.updated_at := now();
    return new;
end $$;

-- Remarks and source stay on btrim deliberately. They are prose, not keys - nothing matches on
-- them, so tidying their edges is cosmetic and a tab inside one is the author's business.

-- ---------------------------------------------------------------------
-- 3. Uniqueness, re-formed on the same rule
-- ---------------------------------------------------------------------

drop index if exists process_cost_part_proc_uidx;
create unique index process_cost_part_proc_uidx
    on process_cost (norm_key(part_no), upper(norm_key(process_name)));

comment on index process_cost_part_proc_uidx is
    'One cost per part number per process. norm_key rather than btrim, and upper() over it, so '
    'that a tab, a trailing space or a change of case cannot produce a second cost that shadows '
    'the first.';

-- Carried its name through the part_material_cost -> part_material rename.
drop index if exists part_material_cost_part_uidx;
drop index if exists part_material_part_uidx;
create unique index part_material_part_uidx
    on part_material (norm_key(part_no));

drop index if exists material_rate_uidx;
create unique index material_rate_uidx
    on material_rate (upper(norm_key(material)), upper(coalesce(norm_key(grade), '')));

-- ---------------------------------------------------------------------
-- 4. The views, rebuilt on norm_key
-- ---------------------------------------------------------------------

drop view if exists v_joborder_wip_cost;
drop view if exists v_part_cost_summary;
drop view if exists v_part_material;
drop view if exists v_part_process_cost;

create view v_part_process_cost
    with (security_invoker = true) as
select p.id                              as part_row_id,
       norm_key(p."Part_Number")         as part_no,
       p."Part_Name"                     as part_name,
       p."Revision"                      as revision,
       s.ord::int                        as step_no,
       norm_key(s.process_name)          as process_name,
       c.id                              as cost_id,
       c.cost_per_pcs,
       c.remarks                         as cost_remarks,
       c.updated_by                      as cost_updated_by,
       c.updated_at                      as cost_updated_at,
       (jsonb_or_null(p."Process") is not null) as routing_readable
  from "Parts" p
  left join lateral jsonb_array_elements_text(jsonb_or_null(p."Process"))
       with ordinality as s(process_name, ord) on true
  left join process_cost c
         on norm_key(c.part_no) = norm_key(p."Part_Number")
        and upper(norm_key(c.process_name)) = upper(norm_key(s.process_name));

comment on view v_part_process_cost is
    'Parts."Process" unpacked into one row per routing step, in order, with the cost for that '
    'step joined on. cost_per_pcs null means the step has not been costed - which is not zero. '
    'Costs join on the normalised part number, so all revisions of a part show the same figure '
    'for the same process name.';

grant select on v_part_process_cost to anon, authenticated;

create view v_part_material
    with (security_invoker = true) as
select p.id                                   as part_row_id,
       norm_key(p."Part_Number")              as part_no,
       norm_key(p."Raw_Material")             as raw_material,
       norm_key(p."Raw_Material_Grade")       as raw_material_grade,
       p."Raw_Material_Size"                  as raw_material_size,
       r.id                                   as rate_id,
       r.rate_per_kg,
       r.source                               as rate_source,
       r.updated_at                           as rate_updated_at,
       m.id                                   as part_material_id,
       m.kg_per_pcs,
       m.cost_per_pcs_override,
       m.override_reason,
       m.costed_material,
       case
           when m.cost_per_pcs_override is not null then m.cost_per_pcs_override
           when m.kg_per_pcs is not null and r.rate_per_kg is not null
               then (m.kg_per_pcs * r.rate_per_kg)::numeric(12,4)
       end                                    as cost_per_pcs,
       (m.cost_per_pcs_override is not null)  as is_override,
       case
           when m.id is null                        then 'NO_USAGE'
           when m.cost_per_pcs_override is not null then 'OK'
           when r.id is null                        then 'NO_RATE'
           else 'OK'
       end                                    as cost_state,
       (m.id is not null
        and norm_key(m.costed_material) is distinct from norm_key(p."Raw_Material"))
                                              as material_changed
  from "Parts" p
  left join part_material m
         on norm_key(m.part_no) = norm_key(p."Part_Number")
  left join material_rate r
         on upper(norm_key(r.material)) = upper(norm_key(p."Raw_Material"))
        and upper(coalesce(norm_key(r.grade), '')) = upper(coalesce(norm_key(p."Raw_Material_Grade"), ''));

comment on view v_part_material is
    'Material cost per piece for one Parts row: kg_per_pcs x rate_per_kg unless an override is '
    'set. cost_per_pcs null means it cannot be computed and cost_state says which half is '
    'missing - NO_USAGE is a part nobody has weighed, NO_RATE is a material nobody has priced. '
    'Different people fix those, which is why they are not one flag.';

grant select on v_part_material to anon, authenticated;

create view v_part_cost_summary
    with (security_invoker = true) as
select v.part_row_id,
       v.part_no,
       max(v.part_name)                              as part_name,
       max(v.revision)                               as revision,
       max(mm.raw_material)                          as raw_material,
       max(mm.raw_material_grade)                    as raw_material_grade,
       max(mm.raw_material_size)                     as raw_material_size,

       count(v.process_name)::int                    as steps,
       count(v.cost_id)::int                         as steps_costed,
       (count(v.process_name) - count(v.cost_id))::int as steps_uncosted,

       coalesce(sum(v.cost_per_pcs), 0)::numeric(12,4)   as cost_per_pcs_process,
       coalesce(max(mm.cost_per_pcs), 0)::numeric(12,4)  as cost_per_pcs_material,
       (coalesce(sum(v.cost_per_pcs), 0)
        + coalesce(max(mm.cost_per_pcs), 0))::numeric(12,4) as cost_per_pcs_total,

       max(mm.rate_per_kg)                           as rate_per_kg,
       max(mm.kg_per_pcs)                            as kg_per_pcs,
       bool_or(mm.is_override)                       as material_is_override,
       max(mm.cost_state)                            as material_state,
       bool_or(mm.cost_per_pcs is not null)          as material_costed,
       bool_or(mm.material_changed)                  as material_changed,

       (count(v.process_name) > 0
        and count(v.process_name) = count(v.cost_id)) as process_fully_costed,
       (count(v.process_name) > 0
        and count(v.process_name) = count(v.cost_id)
        and bool_or(mm.cost_per_pcs is not null))     as fully_costed,
       bool_and(v.routing_readable)                   as routing_readable
  from v_part_process_cost v
  join v_part_material mm on mm.part_row_id = v.part_row_id
 group by v.part_row_id, v.part_no;

comment on view v_part_cost_summary is
    'One row per Parts row: routing steps, how many are costed, the material cost computed for '
    'that row''s own material, and the three per-piece figures. cost_per_pcs_total is the whole '
    'cost of the part only when fully_costed is true.';

grant select on v_part_cost_summary to anon, authenticated;

create view v_joborder_wip_cost
    with (security_invoker = true) as
with jo as (
    select j."JO_Number"                                              as jo_number,
           j."Part_Name"                                              as part_name,
           norm_key(substring(j."Part_Name" from '\(([^()]+)\)\s*$')) as part_no,
           norm_key(j."Process")                                      as process_name,
           case when norm_key(j."Quantity") ~ '^[0-9]+(\.[0-9]+)?$'
                then norm_key(j."Quantity")::numeric end              as qty,
           (j."Status" = 'Completed')                                 as step_done,
           j.completed_at
      from "JobOrder" j
),
frozen_units as (
    select jo_number, part_name, min(frozen_at) as frozen_at, min(frozen_by) as frozen_by
      from joborder_cost_frozen
     group by jo_number, part_name
),
part_mat as (
    select distinct on (part_no)
           part_no, cost_per_pcs, rate_per_kg, kg_per_pcs, cost_state
      from v_part_material
     order by part_no, part_row_id desc
),
part_mat_amb as (
    select part_no, count(distinct coalesce(cost_per_pcs, -1)) > 1 as material_ambiguous
      from v_part_material
     group by part_no
),
steps as (
    select jo.*,
           fu.frozen_at,
           fu.frozen_by,
           (fu.jo_number is not null)                      as unit_frozen,
           case when fu.jo_number is not null
                then fz.cost_per_pcs
                else lc.cost_per_pcs
           end                                             as step_cost
      from jo
      left join frozen_units fu
             on fu.jo_number = jo.jo_number and fu.part_name = jo.part_name
      left join joborder_cost_frozen fz
             on fz.jo_number = jo.jo_number and fz.part_name = jo.part_name
            and fz.cost_type = 'PROCESS'
            and upper(norm_key(fz.process_name)) = upper(jo.process_name)
      left join process_cost lc
             on norm_key(lc.part_no) = jo.part_no
            and upper(norm_key(lc.process_name)) = upper(jo.process_name)
),
rolled as (
    select jo_number, part_name, part_no,
           max(qty)                                        as qty,
           (min(qty) is distinct from max(qty))            as qty_inconsistent,
           bool_or(unit_frozen)                            as is_frozen,
           max(frozen_at)                                  as frozen_at,
           min(frozen_by)                                  as frozen_by,
           count(*)::int                                   as steps,
           count(*) filter (where step_done)::int          as steps_done,
           count(step_cost)::int                           as steps_costed,
           count(*) filter (where step_done and step_cost is null)::int as steps_done_uncosted,
           coalesce(sum(step_cost) filter (where step_done), 0)::numeric(12,4) as cost_per_pcs_done,
           coalesce(sum(step_cost), 0)::numeric(12,4)      as cost_per_pcs_all,
           (count(*) = count(*) filter (where step_done))  as all_done,
           (count(*) = count(step_cost))                   as process_fully_costed,
           max(completed_at)                               as last_completed_at
      from steps
     group by jo_number, part_name, part_no
)
select r.jo_number,
       r.part_name,
       r.part_no,
       r.qty,
       r.qty_inconsistent,
       r.is_frozen,
       r.frozen_at,
       r.frozen_by,
       r.steps,
       r.steps_done,
       r.steps_costed,
       r.steps_done_uncosted,
       r.cost_per_pcs_done,
       r.cost_per_pcs_all,

       coalesce(case when r.is_frozen then fm.cost_per_pcs else pm.cost_per_pcs end, 0)::numeric(12,4)
                                                           as material_cost_per_pcs,
       (case when r.is_frozen then fm.cost_per_pcs else pm.cost_per_pcs end is not null)
                                                           as material_costed,
       case when r.is_frozen then fm.material_rate_per_kg else pm.rate_per_kg end
                                                           as material_rate_per_kg,
       case when r.is_frozen then fm.kg_per_pcs else pm.kg_per_pcs end
                                                           as kg_per_pcs,
       coalesce(pm.cost_state, 'NO_USAGE')                 as material_state,
       coalesce(amb.material_ambiguous, false)             as material_ambiguous,

       (r.qty * r.cost_per_pcs_done)::numeric(14,2)        as wip_value,
       (r.qty * r.cost_per_pcs_all)::numeric(14,2)         as full_value,
       (r.qty * coalesce(case when r.is_frozen then fm.cost_per_pcs else pm.cost_per_pcs end, 0))::numeric(14,2)
                                                           as material_value,
       (r.qty * (r.cost_per_pcs_done
                 + coalesce(case when r.is_frozen then fm.cost_per_pcs else pm.cost_per_pcs end, 0)))::numeric(14,2)
                                                           as wip_value_with_material,
       (r.qty * (r.cost_per_pcs_all
                 + coalesce(case when r.is_frozen then fm.cost_per_pcs else pm.cost_per_pcs end, 0)))::numeric(14,2)
                                                           as full_value_with_material,

       r.all_done,
       r.process_fully_costed,
       (r.process_fully_costed
        and (case when r.is_frozen then fm.cost_per_pcs else pm.cost_per_pcs end) is not null)
                                                           as fully_costed,
       r.last_completed_at
  from rolled r
  left join part_mat     pm  on pm.part_no  = r.part_no
  left join part_mat_amb amb on amb.part_no = r.part_no
  left join joborder_cost_frozen fm
         on fm.jo_number = r.jo_number and fm.part_name = r.part_name
        and fm.cost_type = 'MATERIAL';

comment on view v_joborder_wip_cost is
    'One row per job order and part. is_frozen says where every figure came from: a frozen unit '
    'is valued only from joborder_cost_frozen, a live one from process_cost, part_material and '
    'material_rate as they read now. wip_value is processing only; material_value sits beside it '
    'because nothing records when material is issued to the floor.';

grant select on v_joborder_wip_cost to anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. What to clean, if anyone wants to
-- ---------------------------------------------------------------------
--
-- Nothing depends on this being acted on - norm_key handles every row it lists. It exists so the
-- rows are nameable rather than being a fact buried in a migration comment, and so the same
-- question can be asked again after the next import.

create or replace view v_cost_key_hygiene
    with (security_invoker = true) as
select 'Parts'         as table_name, p.id::text as row_id,
       'Part_Number'   as column_name, p."Part_Number" as value
  from "Parts" p where p."Part_Number" is distinct from norm_key(p."Part_Number")
union all
select 'Parts', p.id::text, 'Raw_Material', p."Raw_Material"
  from "Parts" p where p."Raw_Material" is distinct from norm_key(p."Raw_Material")
union all
select 'Parts', p.id::text, 'Raw_Material_Grade', p."Raw_Material_Grade"
  from "Parts" p where p."Raw_Material_Grade" is distinct from norm_key(p."Raw_Material_Grade")
union all
select 'JobOrder', j.id::text, 'Process', j."Process"
  from "JobOrder" j where j."Process" is distinct from norm_key(j."Process")
union all
select 'JobOrder', j.id::text, 'Part_Name', j."Part_Name"
  from "JobOrder" j where j."Part_Name" is distinct from norm_key(j."Part_Name");

comment on view v_cost_key_hygiene is
    'Master rows whose key column carries leading or trailing whitespace. Costing reads through '
    'norm_key() and is unaffected; this is here so somebody can tidy the master if they want to, '
    'and so the same question can be asked after the next import. Nothing in the costing screens '
    'depends on it being empty.';

grant select on v_cost_key_hygiene to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - how this was found, and what it says about the other two files.
--   It surfaced on the first attempt to price a real part against a real rate: 07150-03036 had
--   consumption entered and a rate that matched its material, and v_part_material still returned
--   nothing. Both figures were correct and the key was not.
--
--   The lesson is in the repetition. btrim() appeared in eleven places across three files because
--   it was written once and copied, so one wrong assumption about what "trim" means became
--   eleven. norm_key() is one function; the next time the rule changes it changes once.
--
-- NOTE 2 - what norm_key deliberately does not do.
--   It does not fold case - the uniqueness indexes apply upper() over it where case-folding is
--   wanted, and the stored spelling is left as it was typed. It does not collapse whitespace in
--   the middle of a string, so 'TURNING  1' with two spaces is still a different process name
--   from 'TURNING 1'. Neither appears in the master today, and inventing a rule for them would be
--   guessing at what somebody meant.
--
-- NOTE 3 - verify:
--   select count(*) from v_cost_key_hygiene;                            -- 25
--   select column_name, count(*) from v_cost_key_hygiene group by 1;
--        -- Part_Number 5, Process 7, Raw_Material 9, Raw_Material_Grade 4
--   -- 4 grades, not the 3 counted in the header: the fourth is whitespace-only, which btrim
--   -- leaves as '' and norm_key returns as null. An empty grade and a grade of one space are
--   -- the same absence, and only norm_key treats them that way.
--   -- the row that started it, now matching:
--   insert into material_rate (material, grade, rate_per_kg, updated_by)
--        values ('HOT ROLLED ROUND BAR','AISI 4340', 6.85, 'tester');
--   insert into part_material (part_no, kg_per_pcs, costed_material, updated_by)
--        values ('07150-03036', 0.5120, 'HOT ROLLED ROUND BAR', 'tester');
--   select part_no, kg_per_pcs, rate_per_kg, cost_per_pcs, cost_state
--     from v_part_material where part_no = '07150-03036';   -- 0.5120 | 6.8500 | 3.5072 | OK
