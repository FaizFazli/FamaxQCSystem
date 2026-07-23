-- =====================================================================
-- RESTORE inventory + storeRecords from the PART 0.1 snapshots.
--
-- Puts both tables back exactly as they were when
--   inventory_backup_20260723 / storeRecords_backup_20260723
-- were taken, undoing the normalisation, the merge, the deletes, the
-- inventory_id backfill and the balance rebuild in one go.
--
-- Run SECTION 1 and read it before running SECTION 3.
-- SECTION 3 is a single transaction: it either fully succeeds or changes
-- nothing.
-- =====================================================================


-- =====================================================================
-- SECTION 0. EMERGENCY CHECK - run this first if SECTION 3 has already
-- failed on you.
--
-- SECTION 3 deletes both tables before re-inserting. It is wrapped in
-- begin/commit so a failure rolls the deletes back - but only if the
-- whole block ran in ONE execution. If you ran it line by line, or the
-- editor auto-committed each statement, the deletes may have stuck while
-- the insert failed.
--
-- If either count below is 0, the data is sitting only in the snapshot
-- tables. Do not run anything else that writes - go straight to 3.0 and
-- re-run SECTION 3 as a single execution.
-- =====================================================================
select (select count(*) from public.inventory)      as inventory_rows_now,
       (select count(*) from public."storeRecords") as store_rows_now,
       (select count(*) from inventory_backup_20260723)      as inventory_in_snapshot,
       (select count(*) from "storeRecords_backup_20260723") as store_in_snapshot;


-- =====================================================================
-- SECTION 1. PRE-FLIGHT. Read every result before continuing.
-- =====================================================================

-- 1.1 Do the snapshots exist, and how big are they?
select 'inventory (live)'          as tbl, count(*)::text as rows from public.inventory
union all
select 'inventory_backup_20260723',      count(*)::text from inventory_backup_20260723
union all
select 'storeRecords (live)',            count(*)::text from public."storeRecords"
union all
select 'storeRecords_backup_20260723',   count(*)::text from "storeRecords_backup_20260723";

-- If either backup table is missing, this script errors here. STOP - do
-- not proceed, and do not run anything else that writes. Tell me instead.

-- 1.2 Does anything OTHER than storeRecords point at inventory?
-- SECTION 3 empties inventory; any other child table would block the
-- delete or lose its parent. Expect only storeRecords_inventory_id_fkey.
select tc.constraint_name,
       tc.table_name   as child_table,
       kcu.column_name as child_column,
       rc.delete_rule
  from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu
    on kcu.constraint_name = tc.constraint_name
  join information_schema.constraint_column_usage ccu
    on ccu.constraint_name = tc.constraint_name
  join information_schema.referential_constraints rc
    on rc.constraint_name = tc.constraint_name
 where tc.constraint_type = 'FOREIGN KEY'
   and ccu.table_name = 'inventory'
   and tc.table_schema = 'public';

-- 1.3 Column drift between live and snapshot. Columns listed as
-- 'live only' are NOT restored (they get their default / null); columns
-- listed as 'snapshot only' are dropped on the floor.
-- inventory_id appearing as 'live only' is normal and harmless - it just
-- means every restored record comes back unassigned.
select tbl, column_name, presence from (
    select 'inventory' as tbl, c.column_name,
           case when b.column_name is null then 'live only' else 'both' end as presence
      from information_schema.columns c
      left join information_schema.columns b
        on b.table_schema = 'public'
       and b.table_name   = 'inventory_backup_20260723'
       and b.column_name  = c.column_name
     where c.table_schema = 'public' and c.table_name = 'inventory'
    union all
    select 'inventory', b.column_name, 'snapshot only'
      from information_schema.columns b
      left join information_schema.columns c
        on c.table_schema = 'public' and c.table_name = 'inventory'
       and c.column_name  = b.column_name
     where b.table_schema = 'public' and b.table_name = 'inventory_backup_20260723'
       and c.column_name is null
    union all
    select 'storeRecords', c.column_name,
           case when b.column_name is null then 'live only' else 'both' end
      from information_schema.columns c
      left join information_schema.columns b
        on b.table_schema = 'public'
       and b.table_name   = 'storeRecords_backup_20260723'
       and b.column_name  = c.column_name
     where c.table_schema = 'public' and c.table_name = 'storeRecords'
    union all
    select 'storeRecords', b.column_name, 'snapshot only'
      from information_schema.columns b
      left join information_schema.columns c
        on c.table_schema = 'public' and c.table_name = 'storeRecords'
       and c.column_name  = b.column_name
     where b.table_schema = 'public' and b.table_name = 'storeRecords_backup_20260723'
       and c.column_name is null
) x
 where presence <> 'both'
 order by tbl, presence, column_name;

-- 1.4 Anything created through the app SINCE the snapshot will be LOST by
-- the restore. Check this is empty, or copy the rows out first.
select 'inventory' as tbl, i.id::text, i.barcode, i.customer, i.product_name
  from public.inventory i
 where not exists (select 1 from inventory_backup_20260723 b where b.id = i.id);

select 'storeRecords' as tbl, s.id::text, s.part_name, s.entry_type,
       s.quantity::text, s.created_at::text
  from public."storeRecords" s
 where not exists (select 1 from "storeRecords_backup_20260723" b where b.id = s.id)
 order by s.created_at desc;


-- =====================================================================
-- SECTION 2. SAFETY NET - snapshot the CURRENT state first.
--
-- Makes the restore itself reversible. Cheap; do not skip it.
-- =====================================================================
drop table if exists inventory_prerestore_20260723;
create table inventory_prerestore_20260723 as select * from public.inventory;

drop table if exists "storeRecords_prerestore_20260723";
create table "storeRecords_prerestore_20260723" as select * from public."storeRecords";

select (select count(*) from inventory_prerestore_20260723)        as inventory_saved,
       (select count(*) from "storeRecords_prerestore_20260723")   as store_saved;


-- =====================================================================
-- SECTION 3. THE RESTORE. Run this whole block in one execution.
--
-- Order is forced by the foreign key:
--   storeRecords must be emptied BEFORE inventory, and repopulated AFTER.
--
-- Columns are matched by NAME, not position, so it still works if the
-- live table gained or lost a column since the snapshot.
-- =====================================================================

begin;

-- 3.0 Drop the unique index before restoring.
--
-- inventory_barcode_customer_uq enforces "one row per barcode+customer".
-- The snapshot predates the merge, so it still CONTAINS those duplicates
-- - e.g. ('HVT 50 V', 'Swk Utensilerie') twice. Restoring with the index
-- in place fails with 23505.
--
-- This is correct: the constraint describes the state you are migrating
-- TOWARDS, not the state you are rolling back TO. Recreate it at the end
-- of the rebuild (PART 6.1), once the merge has genuinely removed the
-- duplicates.
drop index if exists public.inventory_barcode_customer_uq;

-- 3.1 Empty the child first, then the parent.
delete from public."storeRecords";
delete from public.inventory;

-- 3.2 Parent back first so the FK can resolve.
do $$
declare cols text;
begin
    select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
      into cols
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name   = 'inventory'
       and exists (select 1 from information_schema.columns b
                    where b.table_schema = 'public'
                      and b.table_name   = 'inventory_backup_20260723'
                      and b.column_name  = c.column_name);

    if cols is null then
        raise exception 'No matching columns between inventory and its snapshot';
    end if;

    execute format(
        'insert into public.inventory (%s) select %s from public.inventory_backup_20260723',
        cols, cols);
end $$;

-- 3.3 Then the child.
do $$
declare cols text;
begin
    select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
      into cols
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name   = 'storeRecords'
       and exists (select 1 from information_schema.columns b
                    where b.table_schema = 'public'
                      and b.table_name   = 'storeRecords_backup_20260723'
                      and b.column_name  = c.column_name);

    if cols is null then
        raise exception 'No matching columns between storeRecords and its snapshot';
    end if;

    execute format(
        'insert into public."storeRecords" (%s) select %s from public."storeRecords_backup_20260723"',
        cols, cols);
end $$;

-- 3.4 CRITICAL - re-sync the id sequence.
-- Rows were re-inserted with their original ids, but the sequence still
-- sits where it was. Without this the next insert from the app collides
-- with an existing id and fails on a duplicate key.
do $$
declare seq text;
begin
    seq := pg_get_serial_sequence('public."storeRecords"', 'id');
    if seq is not null then
        perform setval(seq, coalesce((select max(id) from public."storeRecords"), 1));
        raise notice 'storeRecords id sequence reset to %',
                     coalesce((select max(id) from public."storeRecords"), 1);
    end if;

    seq := pg_get_serial_sequence('public.inventory', 'id');
    if seq is not null then
        perform setval(seq, coalesce((select max(id::text)::bigint
                                        from public.inventory), 1));
    end if;
exception when others then
    -- inventory.id is uuid, which has no sequence. Not an error.
    raise notice 'Sequence reset skipped for inventory (uuid id)';
end $$;

commit;


-- =====================================================================
-- SECTION 4. VERIFY.
-- =====================================================================

-- 4.1 Counts must match the snapshots exactly.
select (select count(*) from public.inventory)                 as inventory_now,
       (select count(*) from inventory_backup_20260723)         as inventory_expected,
       (select count(*) from public."storeRecords")             as store_now,
       (select count(*) from "storeRecords_backup_20260723")    as store_expected;

-- 4.2 No row should differ from its snapshot. Expect zero rows back.
select b.id, b.barcode, b.customer,
       b.available_pcs as snapshot_balance,
       i.available_pcs as restored_balance
  from inventory_backup_20260723 b
  join public.inventory i on i.id = b.id
 where i.available_pcs   is distinct from b.available_pcs
    or i.barcode         is distinct from b.barcode
    or i.customer        is distinct from b.customer
    or i.product_name    is distinct from b.product_name;

-- 4.3 Clean up the working table from the rebuild script - it describes a
-- state that no longer exists and would mislead a later run.
drop table if exists dup_map;

-- 4.4 Sanity check the sequence. next_value_will_be must be GREATER than
-- max_existing_id, otherwise the next insert from the app fails on a
-- duplicate key. (This consumes one id - a harmless gap.)
select (select max(id) from public."storeRecords") as max_existing_id,
       nextval(pg_get_serial_sequence('public."storeRecords"', 'id')) as next_value_will_be;

-- 4.5 IMPORTANT - did the snapshot predate the row that went missing?
--
-- The 0.1 snapshot only captures what existed AT THAT MOMENT. If a row
-- was deleted by SECTION C7 of the superseded merge script BEFORE the
-- snapshot was taken, it is not in the backup and this restore cannot
-- bring it back.
--
-- Any barcode listed here has history but no inventory row even after the
-- restore - meaning it was already gone when the snapshot was taken.
-- Recovering those needs Supabase point-in-time restore, or recreating
-- the item by hand.
select s.part_name,
       count(*) as txns,
       string_agg(distinct coalesce(s.customer_name, '(none)'), ', ') as customers_seen,
       sum(case when s.entry_type = 'IN' then s.quantity else -s.quantity end) as implied_balance
  from public."storeRecords" s
 where not exists (select 1 from public.inventory i
                    where upper(trim(i.barcode)) = upper(trim(s.part_name)))
 group by s.part_name
 order by txns desc;


-- 4.6 Confirm the constraint is gone (it must be, to hold the pre-merge
-- data) and see the duplicates that are now back in the table. These are
-- exactly what PART 2 of the rebuild script merges.
select i.barcode,
       coalesce(i.customer, '<null>') as customer,
       count(*)                       as row_count,
       string_agg(i.id::text, ', ')   as ids,
       string_agg(distinct coalesce(i.product_name, '(blank)'), '  ||  ') as products,
       sum(i.available_pcs)           as combined_balance
  from public.inventory i
 group by i.barcode, i.customer
having count(*) > 1
 order by row_count desc, i.barcode;

select count(*) as unique_index_present_should_be_0
  from pg_indexes
 where schemaname = 'public' and indexname = 'inventory_barcode_customer_uq';


-- =====================================================================
-- SECTION 5. If the restore itself went wrong, undo it.
-- =====================================================================
-- begin;
-- delete from public."storeRecords";
-- delete from public.inventory;
-- insert into public.inventory select * from inventory_prerestore_20260723;
-- insert into public."storeRecords" select * from "storeRecords_prerestore_20260723";
-- commit;
