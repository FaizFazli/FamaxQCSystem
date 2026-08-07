-- 2026-08-07  The market moves, so the rate is separated from the geometry - and open jobs are
--             frozen against the rate that applied when they started.
--
-- Third and last of today's costing files, and it restructures the second one. 2026-08-07_
-- part_material_cost.sql stored a single material cost per piece, which is rate x consumption
-- baked into one typed number. That is wrong the moment steel moves: 220 part numbers draw on
-- only 113 material/grade combinations, and FREE CUTTING STEEL ROUND BAR / 1215 alone feeds 15
-- of them. An 8% rise meant somebody recomputing fifteen per-piece figures by hand, redoing the
-- weight arithmetic each time and getting it slightly different each time.
--
-- SEPARATE WHAT MOVES FROM WHAT DOES NOT.
--   Consumption per piece is geometry. A part that takes 0.512 kg of bar takes 0.512 kg whatever
--   the market did this morning; it changes when the drawing changes and at no other time.
--   The rate is the market. It changes often, and it changes for one material at a time.
--
--   So they are two tables. material_rate holds RM per kg against a material and grade - 113 rows
--   at most, and a price move is one edit. part_material holds kg per piece against a part number
--   - 220 rows, entered once. The cost per piece is computed from the two and is never typed, so
--   there is no third number that can disagree with them.
--
--   The count is not the point. The point is that after this, "1215 is up 8%" is one row, and
--   every part made from it re-prices exactly rather than approximately.
--
-- THE OVERRIDE, AND WHY IT IS IN THE SAME TABLE.
--   Not every part's material cost is rate x weight. Free-issue material from a customer is
--   zero. A bought-in finished component has an invoice price and no bar behind it. Those need a
--   flat figure that bypasses the rate.
--
--   It sits in part_material next to kg_per_pcs rather than in a table of its own, because two
--   tables each claiming to answer "what does this part's material cost" is exactly how they end
--   up disagreeing - the same reasoning that retired tools_item.qty_on_hand. One row per part,
--   a check that at least one of the two is filled, and the override wins when both are.
--
-- FREEZING AN OPEN JOB.
--   Even split, editing a rate re-values every job already on the floor. A WIP total printed last
--   week stops reproducing, and nothing on the screen says why. So the rates in force get copied
--   onto the job order, and that job stays valued at them until it closes.
--
--   Copied, not joined - the same rule as tools_txn.txn_by and Data_IPQC.sa_by. A later change to
--   material_rate cannot reach backwards into a job that was already priced.
--
--   Freezing is a deliberate act on the costing screen, not a trigger on JobOrder insert. A
--   trigger would fire today against an empty cost master and freeze 210 job units at nothing,
--   which is worse than not freezing at all. Once the master is populated, an auto-freeze on
--   release is a small trigger away and this table is what it would write to.
--
-- Safe to re-run. Preserves every existing row.
--
-- Run as the table owner, AFTER the other two 2026-08-07 files:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-07_material_rate.sql

begin;

-- ---------------------------------------------------------------------
-- 0. Clear the views out of the way
-- ---------------------------------------------------------------------
--
-- Section 3 drops part_material_cost.cost_per_pcs, and both rollup views read it, so they have to
-- go first. Dropped here rather than with CASCADE at the point of the ALTER: cascade would take
-- whatever else happened to depend on them without saying so, and these are rebuilt by name in
-- sections 6 to 8 anyway.

drop view if exists v_joborder_wip_cost;
drop view if exists v_part_cost_summary;
drop view if exists v_part_material;

-- ---------------------------------------------------------------------
-- 1. One trail, now that there is more than one kind of thing to record
-- ---------------------------------------------------------------------
--
-- part_cost_history becomes cost_history, because a rate belongs to a material and not to any
-- part - it is the one change on this screen that moves fifteen parts at once, so it is the one
-- a reader most needs to see. Forcing it into a part-keyed table would have meant inventing a
-- part number for it.
--
-- The value columns lose "cost_per_pcs" from their names for the same reason: they now carry
-- RM/pc, RM/kg and kg/pc depending on what changed, and a column called old_cost_per_pcs holding
-- a weight is a lie waiting to be read. The unit is stated on every row instead.
--
-- All of this is free: the table has never held a row outside a test.

do $$
begin
    if exists (select 1 from information_schema.tables
                where table_schema = 'public' and table_name = 'part_cost_history')
       and not exists (select 1 from information_schema.tables
                        where table_schema = 'public' and table_name = 'cost_history')
    then
        execute 'alter table part_cost_history rename to cost_history';
    end if;
end $$;

do $$
begin
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='cost_history'
                  and column_name='old_cost_per_pcs') then
        execute 'alter table cost_history rename column old_cost_per_pcs to old_value';
    end if;
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='cost_history'
                  and column_name='new_cost_per_pcs') then
        execute 'alter table cost_history rename column new_cost_per_pcs to new_value';
    end if;
end $$;

alter table cost_history add column if not exists unit     text not null default 'RM/pc';
alter table cost_history add column if not exists material text;
alter table cost_history add column if not exists grade    text;
-- The job order a FREEZE or UNFREEZE row refers to. Null on everything else.
alter table cost_history add column if not exists ref      text;

-- A rate change names a material, not a part.
alter table cost_history alter column part_no drop not null;

alter table cost_history drop constraint if exists part_cost_history_kind_ck;
alter table cost_history drop constraint if exists cost_history_kind_ck;
alter table cost_history
    add constraint cost_history_kind_ck check (
        case cost_type
            when 'PROCESS'           then part_no is not null and process_name is not null
            when 'MATERIAL_USAGE'    then part_no is not null and process_name is null
            when 'MATERIAL_OVERRIDE' then part_no is not null and process_name is null
            when 'RATE'              then material is not null and process_name is null
            when 'FREEZE'            then ref is not null
            when 'UNFREEZE'          then ref is not null
            else false
        end
    );

comment on table cost_history is
    'Append-only trail of everything that changes a cost: a process rate, a part''s material '
    'consumption or override, a material''s rate per kg, and the freezing or unfreezing of a job '
    'order. One table because "what changed and when" is one question - a rate change and the '
    'part costs it moves are not two separate stories. Read unit before reading old_value and '
    'new_value: they are RM/pc, RM/kg or kg/pc depending on cost_type.';
comment on column cost_history.unit is
    'RM/pc for PROCESS, MATERIAL_OVERRIDE, FREEZE and UNFREEZE; RM/kg for RATE; kg/pc for '
    'MATERIAL_USAGE. Stated per row because the value columns carry all three.';
comment on column cost_history.ref is
    'The job order a FREEZE or UNFREEZE applies to, as "JO_Number | Part_Name" - the unit a '
    'freeze covers, because 34 of the 141 JO numbers carry more than one part.';

-- ---------------------------------------------------------------------
-- 2. The rate: RM per kg, per material and grade
-- ---------------------------------------------------------------------

create table if not exists material_rate (
    id                   bigint generated by default as identity primary key,
    material             text           not null,
    -- Nullable because one of the 235 part rows names a material with no grade. A rate for a
    -- material with no grade is a real statement, not a missing field.
    grade                text,
    rate_per_kg          numeric(12,4)  not null,
    -- Where the number came from: a supplier, a quote number, a date. Not validated, because the
    -- useful version of this is a sentence and the useless version is a dropdown.
    source               text,
    remarks              text,
    created_at           timestamptz    not null default now(),
    updated_at           timestamptz    not null default now(),
    updated_by           text,
    updated_by_position  text,

    constraint material_rate_material_ck check (btrim(material) <> ''),
    -- Zero is allowed: free-issue material stated as a rate rather than a per-part override.
    constraint material_rate_amount_ck   check (rate_per_kg >= 0)
);

comment on table material_rate is
    'RM per kilogram for one raw material and grade. Matched to Parts.Raw_Material and '
    'Raw_Material_Grade on a trimmed, case-folded comparison. 220 part numbers draw on 113 of '
    'these, so one edit here re-prices every part that uses it - which is the whole reason this '
    'table exists rather than a cost per piece on each part.';
comment on column material_rate.rate_per_kg is
    'Per kilogram, always. Bar, tube, strip and coil all weigh, so kilograms are the one unit '
    'every material in Parts can be quoted in without a per-form conversion. Four decimals for '
    'the same reason process costs carry four - the error is multiplied by a weight and then by '
    'an order quantity.';

create unique index if not exists material_rate_uidx
    on material_rate (upper(btrim(material)), upper(btrim(coalesce(grade, ''))));

comment on index material_rate_uidx is
    'One rate per material and grade. Folds case and whitespace, because the part master spells '
    'the same material more than one way and a second rate row would silently shadow the first.';

-- ---------------------------------------------------------------------
-- 3. The part side: how much it consumes, or what it costs flat
-- ---------------------------------------------------------------------
--
-- part_material_cost becomes part_material. The name changes because the table no longer holds a
-- cost in the ordinary case - it holds consumption, and the cost is computed. Leaving "cost" in
-- the name would invite exactly the read this file is trying to prevent.

do $$
begin
    if exists (select 1 from information_schema.tables
                where table_schema = 'public' and table_name = 'part_material_cost')
       and not exists (select 1 from information_schema.tables
                        where table_schema = 'public' and table_name = 'part_material')
    then
        execute 'alter table part_material_cost rename to part_material';
    end if;
end $$;

alter table part_material drop constraint if exists part_material_cost_amount_ck;
alter table part_material drop column if exists cost_per_pcs;

alter table part_material add column if not exists kg_per_pcs            numeric(12,4);
alter table part_material add column if not exists cost_per_pcs_override numeric(12,4);
alter table part_material add column if not exists override_reason       text;

alter table part_material drop constraint if exists part_material_input_ck;
alter table part_material drop constraint if exists part_material_kg_ck;
alter table part_material drop constraint if exists part_material_override_ck;

-- A row that says neither how much the part consumes nor what it costs flat says nothing, and
-- would read on the screen as "costed" while contributing zero.
alter table part_material
    add constraint part_material_input_ck
    check (kg_per_pcs is not null or cost_per_pcs_override is not null);
alter table part_material
    add constraint part_material_kg_ck
    check (kg_per_pcs is null or kg_per_pcs > 0);
alter table part_material
    add constraint part_material_override_ck
    check (cost_per_pcs_override is null or cost_per_pcs_override >= 0);

comment on table part_material is
    'What one finished piece of a part takes out of raw material. kg_per_pcs is the ordinary '
    'case and is geometry - it changes when the drawing changes and at no other time. '
    'cost_per_pcs_override is the exception: free-issue material, or a bought-in component with '
    'an invoice and no bar behind it. When both are present the override wins, and '
    'override_reason is expected to say why. Was part_material_cost until this file.';
comment on column part_material.kg_per_pcs is
    'Kilograms of raw material per finished piece, including whatever cutting allowance, offcut '
    'and bar-end the person entering it decided to carry. Nothing derives it: '
    'RawMaterialStock.kg_per_pc is kilograms per BAR (0.93 kg for a 6-metre Ø5 SUS304), not per '
    'component, and no table in this schema records how many parts come off a bar.';
comment on column part_material.cost_per_pcs_override is
    'A flat RM per piece that bypasses the rate entirely. Null in the ordinary case. Zero is a '
    'real answer and means free-issue - which is not the same as null, meaning nobody has said.';
comment on column part_material.costed_material is
    'Parts.Raw_Material as it read when this row was last written. Compared against the live '
    'value to flag consumption recorded against a material the part is no longer made from - a '
    'change of material usually changes the weight too.';

-- ---------------------------------------------------------------------
-- 4. Triggers
-- ---------------------------------------------------------------------

create or replace function material_rate_normalise() returns trigger
    language plpgsql as $$
begin
    new.material   := btrim(new.material);
    new.grade      := nullif(btrim(coalesce(new.grade, '')), '');
    new.source     := nullif(btrim(coalesce(new.source, '')), '');
    new.remarks    := nullif(btrim(coalesce(new.remarks, '')), '');
    new.updated_at := now();
    return new;
end $$;

drop trigger if exists material_rate_normalise_trg on material_rate;
create trigger material_rate_normalise_trg
    before insert or update on material_rate
    for each row execute function material_rate_normalise();

create or replace function material_rate_log() returns trigger
    language plpgsql as $$
begin
    if tg_op = 'INSERT' then
        insert into cost_history (cost_id, part_no, process_name, cost_type, action, unit,
                                  material, grade, old_value, new_value,
                                  changed_by, changed_by_position)
        values (new.id, null, null, 'RATE', 'INSERT', 'RM/kg',
                new.material, new.grade, null, new.rate_per_kg,
                new.updated_by, new.updated_by_position);
        return new;

    elsif tg_op = 'UPDATE' then
        if new.rate_per_kg is distinct from old.rate_per_kg
           or new.source is distinct from old.source
           or new.remarks is distinct from old.remarks then
            insert into cost_history (cost_id, part_no, process_name, cost_type, action, unit,
                                      material, grade, old_value, new_value,
                                      changed_by, changed_by_position)
            values (new.id, null, null, 'RATE', 'UPDATE', 'RM/kg',
                    new.material, new.grade, old.rate_per_kg, new.rate_per_kg,
                    new.updated_by, new.updated_by_position);
        end if;
        return new;

    else
        insert into cost_history (cost_id, part_no, process_name, cost_type, action, unit,
                                  material, grade, old_value, new_value,
                                  changed_by, changed_by_position)
        values (null, null, null, 'RATE', 'DELETE', 'RM/kg',
                old.material, old.grade, old.rate_per_kg, null,
                old.updated_by, old.updated_by_position);
        return old;
    end if;
end $$;

drop trigger if exists material_rate_log_trg on material_rate;
create trigger material_rate_log_trg
    after insert or update or delete on material_rate
    for each row execute function material_rate_log();

-- part_material: two things can change on one row, and they are different units, so a single
-- edit can produce two trail rows. That is correct - "consumption went from 0.5 to 0.6 kg" and
-- "an override of RM 2 was added" are two facts.
create or replace function part_material_normalise() returns trigger
    language plpgsql as $$
begin
    new.part_no         := btrim(new.part_no);
    new.costed_material := nullif(btrim(coalesce(new.costed_material, '')), '');
    new.costed_grade    := nullif(btrim(coalesce(new.costed_grade, '')), '');
    new.override_reason := nullif(btrim(coalesce(new.override_reason, '')), '');
    new.remarks         := nullif(btrim(coalesce(new.remarks, '')), '');
    new.updated_at      := now();
    return new;
end $$;

drop trigger if exists part_material_cost_normalise_trg on part_material;
drop trigger if exists part_material_normalise_trg on part_material;
create trigger part_material_normalise_trg
    before insert or update on part_material
    for each row execute function part_material_normalise();

create or replace function part_material_log() returns trigger
    language plpgsql as $$
declare
    v_old_kg  numeric(12,4) := case when tg_op = 'INSERT' then null else old.kg_per_pcs end;
    v_new_kg  numeric(12,4) := case when tg_op = 'DELETE' then null else new.kg_per_pcs end;
    v_old_ov  numeric(12,4) := case when tg_op = 'INSERT' then null else old.cost_per_pcs_override end;
    v_new_ov  numeric(12,4) := case when tg_op = 'DELETE' then null else new.cost_per_pcs_override end;
    v_part    text          := case when tg_op = 'DELETE' then old.part_no else new.part_no end;
    v_id      bigint        := case when tg_op = 'DELETE' then null else new.id end;
    v_by      text          := case when tg_op = 'DELETE' then old.updated_by else new.updated_by end;
    v_pos     text          := case when tg_op = 'DELETE' then old.updated_by_position
                                    else new.updated_by_position end;
    v_action  text          := tg_op;
begin
    if v_old_kg is distinct from v_new_kg then
        insert into cost_history (cost_id, part_no, process_name, cost_type, action, unit,
                                  old_value, new_value, changed_by, changed_by_position)
        values (v_id, v_part, null, 'MATERIAL_USAGE', v_action, 'kg/pc',
                v_old_kg, v_new_kg, v_by, v_pos);
    end if;

    if v_old_ov is distinct from v_new_ov then
        insert into cost_history (cost_id, part_no, process_name, cost_type, action, unit,
                                  old_value, new_value, changed_by, changed_by_position)
        values (v_id, v_part, null, 'MATERIAL_OVERRIDE', v_action, 'RM/pc',
                v_old_ov, v_new_ov, v_by, v_pos);
    end if;

    return case when tg_op = 'DELETE' then old else new end;
end $$;

drop trigger if exists part_material_cost_log_trg on part_material;
drop trigger if exists part_material_log_trg on part_material;
create trigger part_material_log_trg
    after insert or update or delete on part_material
    for each row execute function part_material_log();

-- process_cost's trail, repointed at the renamed table and columns.
create or replace function process_cost_log() returns trigger
    language plpgsql as $$
begin
    if tg_op = 'INSERT' then
        insert into cost_history (cost_id, part_no, process_name, cost_type, action, unit,
                                  old_value, new_value, changed_by, changed_by_position)
        values (new.id, new.part_no, new.process_name, 'PROCESS', 'INSERT', 'RM/pc',
                null, new.cost_per_pcs, new.updated_by, new.updated_by_position);
        return new;

    elsif tg_op = 'UPDATE' then
        if new.cost_per_pcs is distinct from old.cost_per_pcs
           or new.remarks is distinct from old.remarks then
            insert into cost_history (cost_id, part_no, process_name, cost_type, action, unit,
                                      old_value, new_value, changed_by, changed_by_position)
            values (new.id, new.part_no, new.process_name, 'PROCESS', 'UPDATE', 'RM/pc',
                    old.cost_per_pcs, new.cost_per_pcs, new.updated_by, new.updated_by_position);
        end if;
        return new;

    else
        insert into cost_history (cost_id, part_no, process_name, cost_type, action, unit,
                                  old_value, new_value, changed_by, changed_by_position)
        values (null, old.part_no, old.process_name, 'PROCESS', 'DELETE', 'RM/pc',
                old.cost_per_pcs, null, old.updated_by, old.updated_by_position);
        return old;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. Frozen job orders
-- ---------------------------------------------------------------------

create table if not exists joborder_cost_frozen (
    id                    bigint generated by default as identity primary key,
    jo_number             text          not null,
    -- The unit is the job order AND the part: 34 of the 141 JO numbers carry more than one.
    part_name             text          not null,
    part_no               text,
    cost_type             text          not null check (cost_type in ('MATERIAL','PROCESS')),
    process_name          text,
    cost_per_pcs          numeric(12,4) not null check (cost_per_pcs >= 0),
    -- Kept on the material line so a frozen figure can be explained without going back to tables
    -- that have since moved on. This is the whole point of freezing.
    material_rate_per_kg  numeric(12,4),
    kg_per_pcs            numeric(12,4),
    frozen_at             timestamptz   not null default now(),
    frozen_by             text,
    frozen_by_position    text,

    constraint joborder_cost_frozen_kind_ck check (
        case cost_type
            when 'PROCESS'  then process_name is not null
            when 'MATERIAL' then process_name is null
        end
    )
);

comment on table joborder_cost_frozen is
    'The cost lines in force when a job order was frozen, copied onto it. A frozen job is valued '
    'from these rows and not from process_cost, part_material or material_rate, so a later price '
    'change cannot re-value work that was already priced. Copied rather than joined, for the '
    'same reason tools_txn.txn_by copies a name rather than referencing an employee row.';
comment on column joborder_cost_frozen.material_rate_per_kg is
    'The rate the frozen material cost was computed from, alongside the kg per piece it was '
    'multiplied by. Neither is used in any calculation - they are here so that "why is this job '
    'at RM 2.15 when the part sheet says RM 2.32" has an answer on the screen.';

create unique index if not exists joborder_cost_frozen_uidx
    on joborder_cost_frozen (jo_number, part_name, cost_type, coalesce(process_name, ''));

create index if not exists joborder_cost_frozen_unit_idx
    on joborder_cost_frozen (jo_number, part_name);

-- ---------------------------------------------------------------------
-- 6. The live material cost, computed
-- ---------------------------------------------------------------------
--
-- Per part ROW, because the rate is looked up from that row's material and one part number
-- (120059) names different materials on different revisions. Keying the cost to the part number
-- while looking the rate up per revision is not a contradiction: consumption is a property of
-- the part, the rate is a property of the material, and a revision that changed the material
-- genuinely does cost something different.

drop view if exists v_joborder_wip_cost;
drop view if exists v_part_cost_summary;
drop view if exists v_part_material;

create view v_part_material
    with (security_invoker = true) as
select p.id                                   as part_row_id,
       btrim(p."Part_Number")                 as part_no,
       btrim(p."Raw_Material")                as raw_material,
       nullif(btrim(coalesce(p."Raw_Material_Grade", '')), '') as raw_material_grade,
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
       -- The override wins when both are present, and says so rather than being silently added.
       case
           when m.cost_per_pcs_override is not null then m.cost_per_pcs_override
           when m.kg_per_pcs is not null and r.rate_per_kg is not null
               then (m.kg_per_pcs * r.rate_per_kg)::numeric(12,4)
       end                                    as cost_per_pcs,
       (m.cost_per_pcs_override is not null)  as is_override,
       -- Why it is not costed, in one column, so a screen does not have to re-derive it.
       case
           when m.id is null                          then 'NO_USAGE'
           when m.cost_per_pcs_override is not null   then 'OK'
           when r.id is null                          then 'NO_RATE'
           else 'OK'
       end                                    as cost_state,
       (m.id is not null
        and m.costed_material is distinct from nullif(btrim(p."Raw_Material"), ''))
                                              as material_changed
  from "Parts" p
  left join part_material m
         on m.part_no = btrim(p."Part_Number")
  left join material_rate r
         on upper(btrim(r.material)) = upper(btrim(p."Raw_Material"))
        and upper(btrim(coalesce(r.grade, ''))) = upper(btrim(coalesce(p."Raw_Material_Grade", '')));

comment on view v_part_material is
    'Material cost per piece for one Parts row, computed as kg_per_pcs x rate_per_kg unless an '
    'override is set. cost_per_pcs is null when it cannot be computed, and cost_state says which '
    'half is missing: NO_USAGE means nobody has said how much the part consumes, NO_RATE means '
    'nobody has priced the material. The two need different people to fix, which is why they are '
    'not one flag.';

grant select on v_part_material to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Part rollup
-- ---------------------------------------------------------------------

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
    'that row''s material, and the three per-piece figures. cost_per_pcs_total is the whole cost '
    'of the part only when fully_costed is true. material_state distinguishes "no consumption '
    'entered" from "material not priced".';

grant select on v_part_cost_summary to anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. Work in progress, frozen or live
-- ---------------------------------------------------------------------
--
-- A unit is frozen if it has any row in joborder_cost_frozen. A frozen unit is valued ONLY from
-- those rows: a step with no frozen line reads as uncosted rather than falling back to the live
-- table, because the freeze is the record of what was priced and a silent fallback would defeat
-- the point of taking it.

create view v_joborder_wip_cost
    with (security_invoker = true) as
with jo as (
    select j."JO_Number"                                           as jo_number,
           j."Part_Name"                                           as part_name,
           btrim(substring(j."Part_Name" from '\(([^()]+)\)\s*$')) as part_no,
           btrim(j."Process")                                      as process_name,
           case when btrim(coalesce(j."Quantity", '')) ~ '^[0-9]+(\.[0-9]+)?$'
                then btrim(j."Quantity")::numeric end              as qty,
           (j."Status" = 'Completed')                              as step_done,
           j.completed_at
      from "JobOrder" j
),
frozen_units as (
    select jo_number, part_name,
           min(frozen_at) as frozen_at,
           min(frozen_by) as frozen_by
      from joborder_cost_frozen
     group by jo_number, part_name
),
-- One canonical material per part number for the job-order side, because a job order names a
-- part but not a revision. The latest Parts row wins. It matters for exactly one part number
-- today (120059), and material_ambiguous says so rather than hiding it.
part_mat as (
    select distinct on (part_no)
           part_no, cost_per_pcs, rate_per_kg, kg_per_pcs, cost_state
      from v_part_material
     order by part_no, part_row_id desc
),
part_mat_amb as (
    select part_no,
           count(distinct coalesce(cost_per_pcs, -1)) > 1 as material_ambiguous
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
            and upper(fz.process_name) = upper(jo.process_name)
      left join process_cost lc
             on lc.part_no = jo.part_no
            and upper(lc.process_name) = upper(jo.process_name)
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
    'One row per job order and part. is_frozen says which side every figure came from: a frozen '
    'unit is valued only from joborder_cost_frozen, a live one from process_cost, part_material '
    'and material_rate as they read now. wip_value is processing only; material_value is '
    'reported beside it because nothing records when material is issued to the floor.';

comment on column v_joborder_wip_cost.is_frozen is
    'True when the rates in force were copied onto this job. A frozen job does not re-value when '
    'material_rate or process_cost changes - which is the point - so a WIP total printed last '
    'month still reproduces.';

grant select on v_joborder_wip_cost to anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. RLS
-- ---------------------------------------------------------------------

alter table material_rate         enable row level security;
alter table part_material         enable row level security;
alter table joborder_cost_frozen  enable row level security;

do $$
declare t text;
begin
    foreach t in array array['material_rate','part_material','joborder_cost_frozen']
    loop
        execute format('drop policy if exists %I on %I', t || '_read',  t);
        execute format('drop policy if exists %I on %I', t || '_write', t);
        execute format('create policy %I on %I for select to anon, authenticated using (true)',
                       t || '_read', t);
        execute format('create policy %I on %I for all to anon, authenticated using (true) with check (true)',
                       t || '_write', t);
        execute format('grant select, insert, update, delete on %I to anon, authenticated', t);
    end loop;
end $$;

-- The old names, from before the renames in sections 1 and 3.
drop policy if exists part_material_cost_read  on part_material;
drop policy if exists part_material_cost_write on part_material;
drop policy if exists part_cost_history_read   on cost_history;
drop policy if exists part_cost_history_insert on cost_history;
drop policy if exists cost_history_read        on cost_history;
drop policy if exists cost_history_insert      on cost_history;

alter table cost_history enable row level security;
create policy cost_history_read   on cost_history
    for select to anon, authenticated using (true);
create policy cost_history_insert on cost_history
    for insert to anon, authenticated with check (true);
grant select, insert on cost_history to anon, authenticated;

-- Sequences keep their original names through a table rename, so these are found by lookup
-- rather than named.
do $$
declare s text;
begin
    for s in
        select quote_ident(seq.relname)
          from pg_class seq
          join pg_depend d  on d.objid = seq.oid and d.classid = 'pg_class'::regclass
          join pg_class tbl on tbl.oid = d.refobjid
         where seq.relkind = 'S'
           and tbl.relname in ('material_rate','part_material','cost_history',
                               'joborder_cost_frozen','process_cost')
    loop
        execute format('grant usage, select on sequence %s to anon, authenticated', s);
    end loop;
end $$;

commit;

notify pgrst, 'reload schema';

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - what this does NOT solve.
--   The rate is still typed. Nothing in this schema records what raw material was bought for -
--   RawMaterialStock has kg_per_pc and supplier_po but no price, RawMaterialMovement has
--   qty_change and weight_change but no value, and there is no purchase order table. So
--   material_rate.rate_per_kg is somebody's figure, sourced by a sentence in material_rate.source
--   and nothing stronger.
--
--   The fix is a price captured at intake, and then a rate that is last-in or a weighted average
--   of recent receipts rather than a typed number. That is a column on RawMaterialStock, a field
--   on whichever screen books material in, and a habit from whoever books it - which is why it is
--   not in this file. material_rate is the table that would then be filled automatically instead
--   of by hand, so nothing here has to change shape when it happens.
--
-- NOTE 2 - freezing is manual, and only useful once there is something to freeze.
--   Nothing freezes automatically. A trigger on JobOrder insert would fire today against an empty
--   cost master and record 210 units frozen at nothing, which reads on a screen as "priced" and
--   is worse than unfrozen. Freeze from the costing screen once the master is populated; the
--   auto-freeze on release is then a trigger writing to joborder_cost_frozen and nothing else
--   changes.
--
--   Unfreezing deletes the frozen lines and writes an UNFREEZE row to cost_history naming who did
--   it, so a job cannot be quietly re-priced by removing its freeze.
--
-- NOTE 3 - one part number, two materials.
--   120059 names a different material on different revisions. v_part_cost_summary prices each
--   revision from its own material, which is right. v_joborder_wip_cost cannot - a job order
--   names a part, not a revision - so it takes the latest Parts row and sets material_ambiguous.
--   One row of 210 today.
--
-- NOTE 4 - verify:
--   select count(*) from v_part_material;                             -- 235
--   select cost_state, count(*) from v_part_material group by 1;      -- all NO_USAGE to start
--   select count(*) from v_part_cost_summary;                         -- 235
--   select count(*) from v_joborder_wip_cost;                         -- 210
--   select count(*) from v_joborder_wip_cost where is_frozen;         -- 0 to start
--   -- rate x usage, end to end:
--   insert into material_rate (material, grade, rate_per_kg, updated_by)
--        values ('HOT ROLLED ROUND BAR', 'AISI 4340', 6.85, 'tester');
--   insert into part_material (part_no, kg_per_pcs, costed_material, updated_by)
--        values ('07150-03036', 0.5120, 'HOT ROLLED ROUND BAR', 'tester');
--   select part_no, kg_per_pcs, rate_per_kg, cost_per_pcs, cost_state
--     from v_part_material where part_no = '07150-03036';   -- 0.5120 | 6.8500 | 3.5072 | OK
--   -- and the whole point: one edit moves every part on that rate
--   update material_rate set rate_per_kg = 7.40, updated_by = 'tester'
--    where upper(material) = 'HOT ROLLED ROUND BAR' and upper(grade) = 'AISI 4340';
--   select part_no, cost_per_pcs from v_part_material
--    where raw_material = 'HOT ROLLED ROUND BAR' and cost_per_pcs is not null;  -- all re-priced
--   select cost_type, action, unit, old_value, new_value, material
--     from cost_history order by id;
--        -- RATE           | INSERT | RM/kg | null   | 6.8500 | HOT ROLLED ROUND BAR
--        -- MATERIAL_USAGE | INSERT | kg/pc | null   | 0.5120 | null
--        -- RATE           | UPDATE | RM/kg | 6.8500 | 7.4000 | HOT ROLLED ROUND BAR
