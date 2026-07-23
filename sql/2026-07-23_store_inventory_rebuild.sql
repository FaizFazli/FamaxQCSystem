-- =====================================================================
-- STORE INVENTORY REBUILD - single authoritative script
-- Supersedes 2026-07-23_storeRecords_inventory_id.sql and
--            2026-07-23_merge_duplicate_inventory.sql
--
-- GOALS
--   1. same barcode + DIFFERENT customer -> separate items, history split
--   2. same barcode + SAME customer      -> merged into one item
--   3. balances rebuilt from the ledger, every row, no stale leftovers
--
-- BUSINESS RULES (confirmed 2026-07-23)
--   * an item is identified by barcode + customer
--   * RESERVATION deducts stock, same as OUT
--
-- SAFE TO RE-RUN. Assumes storeRecords.inventory_id (uuid) already exists;
-- creates it if not. Discards any earlier partial backfill and redoes it
-- properly on trimmed keys.
--
-- HOW TO RUN - one PART at a time, top to bottom. PART 4 is a STOP GATE:
-- do not run PART 5 until it returns zero rows. PART 5.0 now enforces
-- this and aborts rather than relying on you to check.
--
-- WHY THAT MATTERS: PART 5 sets each balance to the sum of its ASSIGNED
-- transactions. An item whose history is still unassigned therefore
-- rebuilds to 0 - not a recalculation, just an erasure. If that has
-- already happened, PART 5R restores the figures from the PART 0.1
-- snapshot.
-- =====================================================================


-- =====================================================================
-- PART 0. BACKUP + CURRENT STATE. Run this first, always.
-- =====================================================================

-- 0.1 Snapshot both tables. Re-running drops and recreates the snapshot,
-- so take it BEFORE you change anything today.
drop table if exists inventory_backup_20260723;
create table inventory_backup_20260723 as select * from public.inventory;

drop table if exists "storeRecords_backup_20260723";
create table "storeRecords_backup_20260723" as select * from public."storeRecords";

select (select count(*) from inventory_backup_20260723)          as inventory_rows_saved,
       (select count(*) from "storeRecords_backup_20260723")     as store_rows_saved;

-- To undo everything this script does:
--   delete from public."storeRecords";
--   insert into public."storeRecords" select * from "storeRecords_backup_20260723";
--   delete from public.inventory;
--   insert into public.inventory select * from inventory_backup_20260723;
-- (drop the FK first if it blocks the inventory delete)

-- 0.2 Make sure the column exists (no-op if you already added it).
alter table public."storeRecords"
    add column if not exists inventory_id uuid references public.inventory(id);
create index if not exists "storeRecords_inventory_id_idx"
    on public."storeRecords" (inventory_id);

-- 0.3 Column types, so the location handling below matches reality.
-- inventory.item_location is jsonb (an array of location strings), NOT
-- text[]. storeRecords.item_location is expected to be plain text - check
-- the output and tell me if it is not.
select table_name, column_name, data_type, udt_name
  from information_schema.columns
 where table_schema = 'public'
   and (table_name = 'inventory' or table_name = 'storeRecords')
   and column_name in ('item_location', 'barcode', 'customer',
                       'part_name', 'customer_name', 'id', 'inventory_id')
 order by table_name, column_name;

-- 0.4 Helper: turn whatever inventory.item_location holds into a clean
-- uppercase text[]. Tolerates an array, a bare string, or null.
-- Dropped again in 6.4.
create or replace function public.loc_text_array(v jsonb)
returns text[]
language sql
immutable
as $$
    select case jsonb_typeof(v)
        when 'array'  then coalesce((
                select array_agg(distinct upper(trim(e)))
                  from jsonb_array_elements_text(v) e
                 where nullif(trim(e), '') is not null), '{}'::text[])
        when 'string' then array[upper(trim(v #>> '{}'))]
        else '{}'::text[]
    end;
$$;

-- 0.5 What are we dealing with?
select 'inventory rows'                as metric, count(*)::text as value from public.inventory
union all
select 'storeRecords rows',            count(*)::text from public."storeRecords"
union all
select 'barcodes shared by >1 customer (will be SPLIT)',
       count(*)::text from (
           select upper(trim(barcode)) b
             from public.inventory
            group by 1
           having count(distinct upper(trim(coalesce(customer, '')))) > 1) x
union all
select 'barcode+customer duplicated (will be MERGED)',
       count(*)::text from (
           select upper(trim(barcode)) b, upper(trim(coalesce(customer, ''))) c
             from public.inventory
            group by 1, 2 having count(*) > 1) y
union all
select 'barcodes differing only by whitespace/case',
       count(*)::text from (
           select upper(trim(barcode)) b
             from public.inventory
            group by 1 having count(distinct barcode) > 1) z;


-- =====================================================================
-- PART 1. NORMALISE THE KEYS.
--
-- Every problem so far traces back to untrimmed / mixed-case text. Fix it
-- once, at the source, so every later comparison is trivially correct.
-- =====================================================================

-- 1.1 Preview what will change.
select 'inventory.barcode'  as field, barcode  as before, upper(trim(barcode))  as after
  from public.inventory where barcode  is distinct from upper(trim(barcode))
union all
select 'inventory.customer', customer, upper(trim(customer))
  from public.inventory where customer is distinct from upper(trim(customer))
union all
select 'storeRecords.part_name', part_name, upper(trim(part_name))
  from public."storeRecords" where part_name is distinct from upper(trim(part_name))
union all
select 'storeRecords.customer_name', customer_name, upper(trim(customer_name))
  from public."storeRecords" where customer_name is distinct from upper(trim(customer_name));

-- 1.2 Apply.
update public.inventory
   set barcode  = upper(trim(barcode)),
       customer = upper(trim(customer))
 where barcode  is distinct from upper(trim(barcode))
    or customer is distinct from upper(trim(customer));

update public."storeRecords"
   set part_name     = upper(trim(part_name)),
       customer_name = upper(trim(customer_name))
 where part_name     is distinct from upper(trim(part_name))
    or customer_name is distinct from upper(trim(customer_name));


-- =====================================================================
-- PART 2. MERGE - same barcode AND same customer.
--
-- These are true duplicates of one item. Survivor keeps the lowest id;
-- losers hand over their history, locations and any field the survivor
-- left blank, then are deleted.
-- =====================================================================

-- 2.1 Build the keep/drop map.
--
-- Survivor = the most complete row (has a product name, has a pack size),
-- tie-broken deterministically by id. Ordering by id::text rather than id
-- because uuid has no min()/max() aggregate before PG 17.
drop table if exists dup_map;
create table dup_map as
with ranked as (
    select i.id,
           i.barcode,
           coalesce(i.customer, '') as cust,
           count(*) over (partition by i.barcode, coalesce(i.customer, '')) as grp_size,
           row_number() over (
               partition by i.barcode, coalesce(i.customer, '')
               order by (case when nullif(trim(i.product_name), '') is not null
                              then 0 else 1 end),
                        (case when coalesce(i.units_per_carton, 0) > 0
                              then 0 else 1 end),
                        i.id::text
           ) as rn
      from public.inventory i
)
select r.id, r.barcode, r.cust, r.rn, k.id as keep_id
  from ranked r
  join ranked k
    on k.barcode = r.barcode and k.cust = r.cust and k.rn = 1
 where r.grp_size > 1;

-- 2.2 REVIEW BEFORE GOING FURTHER. If two rows in a group describe
-- genuinely different products, do NOT merge them - tell me, because the
-- key would then need a third column.
select d.barcode,
       nullif(d.cust, '') as customer,
       case when d.rn = 1 then 'KEEP' else 'MERGE + DELETE' end as action,
       i.id,
       i.product_name,
       i.uom,
       i.units_per_carton,
       i.available_pcs,
       i.item_location
  from dup_map d
  join public.inventory i on i.id = d.id
 order by d.barcode, d.cust, d.rn;

-- 2.3 Move any history already pointing at a loser.
update public."storeRecords" s
   set inventory_id = d.keep_id
  from dup_map d
 where s.inventory_id = d.id
   and d.id <> d.keep_id;

-- 2.4 Union the losers' locations onto the survivor.
-- item_location is jsonb, so the result is rebuilt as a jsonb array.
update public.inventory i
   set item_location = coalesce((
        select jsonb_agg(distinct loc order by loc)
          from public.inventory i2
         cross join lateral unnest(public.loc_text_array(i2.item_location)) loc
         where i2.barcode = i.barcode
           and coalesce(i2.customer, '') = coalesce(i.customer, '')),
        i.item_location)
 where i.id in (select distinct keep_id from dup_map);

-- 2.5 Fill blanks on the survivor from a loser.
-- Correlated scalar subqueries, not a LATERAL join - UPDATE ... FROM
-- LATERAL cannot reference the update target in PostgreSQL.
update public.inventory i
   set product_name = coalesce(nullif(trim(i.product_name), ''), (
            select nullif(trim(i2.product_name), '')
              from public.inventory i2
              join dup_map d2 on d2.id = i2.id
             where d2.keep_id = i.id and i2.id <> i.id
               and nullif(trim(i2.product_name), '') is not null
             order by i2.id::text limit 1)),
       uom = coalesce(nullif(trim(i.uom), ''), (
            select nullif(trim(i2.uom), '')
              from public.inventory i2
              join dup_map d2 on d2.id = i2.id
             where d2.keep_id = i.id and i2.id <> i.id
               and nullif(trim(i2.uom), '') is not null
             order by i2.id::text limit 1)),
       units_per_carton = case
            when coalesce(i.units_per_carton, 0) > 0 then i.units_per_carton
            else coalesce((
                select i2.units_per_carton
                  from public.inventory i2
                  join dup_map d2 on d2.id = i2.id
                 where d2.keep_id = i.id and i2.id <> i.id
                   and coalesce(i2.units_per_carton, 0) > 0
                 order by i2.id::text limit 1), i.units_per_carton)
       end
 where i.id in (select distinct keep_id from dup_map);

-- 2.6 Refuse to delete anything still referenced.
do $$
declare n int;
begin
    select count(*) into n
      from public."storeRecords" s
      join dup_map d on d.id = s.inventory_id
     where d.id <> d.keep_id;
    if n > 0 then
        raise exception 'Aborting: % storeRecords still point at rows queued for deletion', n;
    end if;
end $$;

-- 2.7 Delete the losers.
delete from public.inventory
 where id in (select id from dup_map where id <> keep_id);

-- 2.8 Confirm none remain.
select count(*) as duplicate_pairs_remaining
  from (select barcode, coalesce(customer, '')
          from public.inventory group by 1, 2 having count(*) > 1) x;


-- =====================================================================
-- PART 2R. RECONCILE ROW COUNTS against the snapshot.
--
-- The counts SHOULD differ: 2.7 deleted the merge losers. What matters is
-- that every missing row is explained by a merge and nothing else.
--
-- Deliberately does NOT rely on dup_map - if you re-ran 2.1 after the
-- merge, dup_map was rebuilt from the already-clean data and is now empty,
-- so it can no longer explain anything.
-- =====================================================================

-- 2R.1 The arithmetic.
select (select count(*) from inventory_backup_20260723) as rows_in_snapshot,
       (select count(*) from public.inventory)          as rows_now,
       (select count(*) from inventory_backup_20260723)
     - (select count(*) from public.inventory)          as rows_removed,
       (select count(*) from inventory_backup_20260723 b
         where not exists (select 1 from public.inventory i where i.id = b.id))
                                                        as ids_missing_now,
       (select count(*) from public.inventory i
         where not exists (select 1 from inventory_backup_20260723 b where b.id = i.id))
                                                        as ids_added_since;

-- 2R.2 Every row present in the snapshot but not in inventory now, with
-- the reason. Read the `status` column:
--
--   MERGED         - expected. A survivor with the same barcode+customer
--                    still exists; this row's history moved to it (2.3).
--   OTHER CUSTOMER - the barcode survives but only under a different
--                    customer. NOT a merge - this row was lost, likely to
--                    SECTION C7 of the superseded merge script.
--   FULLY GONE     - no item with this barcode remains at all. Definitely
--                    needs restoring.
select b.id,
       b.barcode,
       coalesce(b.customer, '<null>') as customer,
       b.product_name,
       b.available_pcs as balance_in_snapshot,
       (select count(*) from public."storeRecords" s
         where upper(trim(s.part_name)) = upper(trim(b.barcode))) as txns_on_barcode,
       case
         when exists (select 1 from public.inventory i
                       where upper(trim(i.barcode)) = upper(trim(b.barcode))
                         and coalesce(upper(trim(i.customer)), '')
                           = coalesce(upper(trim(b.customer)), ''))
              then 'MERGED'
         when exists (select 1 from public.inventory i
                       where upper(trim(i.barcode)) = upper(trim(b.barcode)))
              then 'OTHER CUSTOMER - investigate'
         else 'FULLY GONE - investigate'
       end as status
  from inventory_backup_20260723 b
 where not exists (select 1 from public.inventory i where i.id = b.id)
 order by status desc, b.barcode;

-- 2R.3 Summary of the above.
select status, count(*) as rows, sum(balance_in_snapshot) as pcs_affected
  from (
    select b.available_pcs as balance_in_snapshot,
           case
             when exists (select 1 from public.inventory i
                           where upper(trim(i.barcode)) = upper(trim(b.barcode))
                             and coalesce(upper(trim(i.customer)), '')
                               = coalesce(upper(trim(b.customer)), ''))
                  then 'MERGED'
             when exists (select 1 from public.inventory i
                           where upper(trim(i.barcode)) = upper(trim(b.barcode)))
                  then 'OTHER CUSTOMER - investigate'
             else 'FULLY GONE - investigate'
           end as status
      from inventory_backup_20260723 b
     where not exists (select 1 from public.inventory i where i.id = b.id)
  ) x
 group by status order by rows desc;

-- 2R.4 RESTORE a row that should not have been deleted.
-- Only for rows 2R.2 flags as OTHER CUSTOMER or FULLY GONE. Restoring a
-- MERGED row would recreate the duplicate you just resolved.
--
-- This copies every column from the snapshot, including the balance it
-- held at PART 0.1. PART 5 recomputes that from the ledger anyway once
-- its history is assigned in PART 4.
--
-- insert into public.inventory
-- select * from inventory_backup_20260723 b
--  where b.id = '<uuid from 2R.2>'
--    and not exists (select 1 from public.inventory i where i.id = b.id);
--
-- Bulk version - restores everything NOT explained by a merge:
-- insert into public.inventory
-- select b.* from inventory_backup_20260723 b
--  where not exists (select 1 from public.inventory i where i.id = b.id)
--    and not exists (select 1 from public.inventory i
--                     where upper(trim(i.barcode)) = upper(trim(b.barcode))
--                       and coalesce(upper(trim(i.customer)), '')
--                         = coalesce(upper(trim(b.customer)), ''));


-- =====================================================================
-- PART 3. SPLIT - assign every transaction to its owning item.
--
-- After PART 2, (barcode, customer) is unique. A barcode shared by
-- several customers now maps to several distinct items, and each
-- transaction must be attached to exactly one of them.
-- =====================================================================

-- 3.0 Discard the earlier partial backfill - it was computed on untrimmed
-- keys and cannot be trusted.
-- SKIP THIS STATEMENT if you have already hand-assigned any records.
update public."storeRecords" set inventory_id = null;

-- 3.1 PASS A - barcode belongs to exactly one item. No ambiguity possible.
-- This resolves the large majority of history.
update public."storeRecords" s
   set inventory_id = i.id
  from public.inventory i
 where i.barcode = s.part_name
   and s.inventory_id is null
   and (select count(*) from public.inventory i2 where i2.barcode = s.part_name) = 1;

-- 3.2 PASS B - shared barcode, record names its customer.
-- Covers OUT and RESERVATION rows, which carry customer_name.
update public."storeRecords" s
   set inventory_id = i.id
  from public.inventory i
 where i.barcode = s.part_name
   and i.customer = s.customer_name
   and s.inventory_id is null
   and s.customer_name is not null
   and s.customer_name <> 'RETURN TO QA';

-- 3.3 PASS C - shared barcode, inherit from the same job order.
-- IN rows carry no customer, but an IN and an OUT on the same JO for the
-- same barcode are the same physical stock. Only fires when every already-
-- resolved sibling on that JO agrees on one item.
update public."storeRecords" s
   set inventory_id = (
        select distinct s2.inventory_id
          from public."storeRecords" s2
         where s2.jo_number = s.jo_number
           and s2.part_name = s.part_name
           and s2.inventory_id is not null)
 where s.inventory_id is null
   and s.jo_number is not null
   and trim(s.jo_number) <> ''
   and (select count(distinct s2.inventory_id)
          from public."storeRecords" s2
         where s2.jo_number = s.jo_number
           and s2.part_name = s.part_name
           and s2.inventory_id is not null) = 1;

-- 3.4 PASS D - shared barcode, tie-break on rack location.
-- inventory.item_location accumulates every location an item has used, so
-- a location can appear on more than one item; the = 1 guard means this
-- only fires when the location points at a single candidate.
--
-- OPTIONAL. Comment out 3.4 if location does not imply ownership in your
-- warehouse, and resolve those rows by hand in PART 4 instead.
--
-- This assumes storeRecords.item_location is plain TEXT (the app inserts a
-- bare string). Check 0.3's output - if it reports jsonb, skip 3.4 and tell
-- me, because trim() on jsonb will error.
update public."storeRecords" s
   set inventory_id = (
        select i.id from public.inventory i
         where i.barcode = s.part_name
           and upper(trim(s.item_location)) = any (public.loc_text_array(i.item_location)))
 where s.inventory_id is null
   and s.item_location is not null
   and trim(s.item_location) <> ''
   and (select count(*) from public.inventory i
         where i.barcode = s.part_name
           and upper(trim(s.item_location)) = any (public.loc_text_array(i.item_location))) = 1;

-- 3.5 Coverage so far.
select count(*) filter (where inventory_id is not null) as assigned,
       count(*) filter (where inventory_id is null)     as unassigned,
       round(100.0 * count(*) filter (where inventory_id is not null)
             / nullif(count(*), 0), 1)                  as pct_assigned
  from public."storeRecords";


-- =====================================================================
-- PART 4. STOP GATE - resolve these by hand.
--
-- PART 5 computes each balance as the SUM OF ITS ASSIGNED TRANSACTIONS.
-- Anything left unassigned here is silently dropped from that sum, which
-- is exactly how balances went wrong last time. Do not skip this.
-- =====================================================================

-- 4.0 TRIAGE - why is each remaining record stuck, and what fixes it.
-- Run this first; it tells you which of 4.3 / 4.4 applies to each row.
select s.id,
       s.part_name,
       s.entry_type,
       s.quantity,
       coalesce(s.customer_name, '(none)') as customer_on_record,
       coalesce(s.jo_number, '(none)')     as jo_number,
       coalesce(s.manu_date, s.out_date)   as txn_date,
       (select count(*) from public.inventory i where i.barcode = s.part_name) as candidate_items,
       case
         when (select count(*) from public.inventory i
                where i.barcode = s.part_name) = 0
              then 'NO ITEM EXISTS for this barcode -> create it (4.4), then re-run 3.1'
         when s.customer_name is null
              then 'IN record, no customer -> pick the owner by hand (4.3)'
         when upper(trim(s.customer_name)) = 'RETURN TO QA'
              then 'RETURN TO QA -> pick the owner by hand (4.3)'
         when not exists (select 1 from public.inventory i
                           where i.barcode  = s.part_name
                             and i.customer = s.customer_name)
              then 'customer on record does not match any item -> check spelling, then 4.3'
         else 'ambiguous -> pick the owner by hand (4.3)'
       end as why_stuck,
       (select string_agg(i.id::text || ' = ' || coalesce(i.customer, '(none)'), '   |   ')
          from public.inventory i where i.barcode = s.part_name) as candidates
  from public."storeRecords" s
 where s.inventory_id is null
 order by s.part_name, s.created_at;

-- 4.1 What is left, with the items each row could belong to.
select s.id,
       s.part_name,
       s.entry_type,
       s.quantity,
       s.customer_name,
       s.item_location,
       s.jo_number,
       s.pic_name,
       coalesce(s.manu_date, s.out_date) as txn_date,
       (select string_agg(i.id::text || ' = ' || coalesce(i.customer, '(none)')
                          || ' / ' || coalesce(i.product_name, ''), '   |   '
                          order by i.customer)
          from public.inventory i where i.barcode = s.part_name) as candidates
  from public."storeRecords" s
 where s.inventory_id is null
 order by s.part_name, s.created_at;

-- 4.2 Same thing grouped, to see how big the job really is.
select s.part_name,
       count(*) as unassigned_txns,
       string_agg(distinct coalesce(s.customer_name, '(none)'), ', ') as customers_seen,
       (select count(*) from public.inventory i where i.barcode = s.part_name) as candidate_items
  from public."storeRecords" s
 where s.inventory_id is null
 group by s.part_name
 order by unassigned_txns desc;

-- 4.3 Assign them. One statement per decision:
--   update public."storeRecords" set inventory_id = '<uuid from candidates>'
--    where id = <record id>;
--
-- Or in bulk, when a whole barcode+customer set belongs to one item:
--   update public."storeRecords"
--      set inventory_id = (select id from public.inventory
--                           where barcode = 'ABC123' and customer = 'BISON')
--    where inventory_id is null and part_name = 'ABC123';

-- 4.4 Records whose barcode has NO inventory row at all. These cannot be
-- assigned until you create the item - they are likely the rows deleted
-- earlier. Create the item, then re-run PASS A (3.1).
select s.part_name,
       count(*) as orphan_txns,
       string_agg(distinct coalesce(s.customer_name, '(none)'), ', ') as customers_seen,
       string_agg(distinct coalesce(s.item_location::text, '(none)'), ', ') as locations_seen,
       sum(case when s.entry_type = 'IN' then s.quantity else -s.quantity end) as implied_balance
  from public."storeRecords" s
 where not exists (select 1 from public.inventory i where i.barcode = s.part_name)
 group by s.part_name
 order by orphan_txns desc;

-- 4.5 THE GATE. Must return 0 before PART 5.
select count(*) as must_be_zero_before_part_5
  from public."storeRecords" where inventory_id is null;


-- =====================================================================
-- PART 5. REBUILD BALANCES - every row, from the ledger.
--
-- *** SUPERSEDED BY PART 5A for this database. ***
-- 5.2 assumes storeRecords is a complete ledger from zero. It is not -
-- items here carry opening stock that predates the log, so summing the
-- ledger erases it. Use PART 5A. Kept only for reference.
--
-- Each balance becomes the SUM OF ITS ASSIGNED TRANSACTIONS.
--
-- Therefore an item whose history is still unassigned rebuilds to ZERO -
-- not because its stock is zero, but because the ledger cannot see it.
-- That is data loss dressed up as a calculation, so 5.0 now REFUSES to
-- run rather than trusting anyone to have read 4.5.
--
-- RESERVATION deducts, same as OUT.
-- =====================================================================

-- 5.0 HARD GUARD. Aborts the whole rebuild unless every transaction has
-- an owner. Run it in the same execution as 5.2, or just run 5.0 first
-- and confirm it succeeds silently.
do $$
declare
    unassigned  int;
    would_zero  int;
begin
    select count(*) into unassigned
      from public."storeRecords" where inventory_id is null;

    if unassigned > 0 then
        raise exception
            'ABORT: % transactions have no inventory_id. Rebuilding now would '
            'reset their items to 0. Finish PART 4 first.', unassigned;
    end if;

    -- Belt and braces: an item about to become 0 while transactions exist
    -- on its barcode means those rows landed on the wrong item.
    select count(*) into would_zero
      from public.inventory i
     where not exists (select 1 from public."storeRecords" s
                        where s.inventory_id = i.id)
       and exists (select 1 from public."storeRecords" s
                    where s.part_name = i.barcode);

    if would_zero > 0 then
        raise exception
            'ABORT: % items would be zeroed while their barcode still has '
            'transactions assigned elsewhere. Check PART 4.2.', would_zero;
    end if;
end $$;

-- 5.0a INSPECT the items the second guard is complaining about.
--
-- These have NO transactions of their own, but their barcode has
-- transactions assigned to a sibling item (another customer). Two very
-- different situations, and only you can tell them apart:
--
--   A) The item genuinely never received stock. Its current balance is an
--      artefact of the OLD double-posting bug, which applied every delta
--      to every row sharing the barcode. Zeroing it is the correct fix.
--      Tell-tale: balance_now equals or tracks a sibling's balance.
--
--   B) The item really did receive stock, but its receipts were assigned
--      to the sibling by mistake (IN rows carry no customer, so PASS C/D
--      or a manual call may have guessed wrong). Zeroing it would be
--      WRONG - go back and re-assign those records first.
--      Tell-tale: the sibling's transaction count looks too high for one
--      customer, or its history names locations belonging to this item.
select i.id,
       i.barcode,
       coalesce(i.customer, '(none)') as customer,
       i.product_name,
       i.available_pcs as balance_now,
       0               as balance_after,
       (select count(*) from public."storeRecords" s
         where s.part_name = i.barcode)                  as txns_on_barcode,
       (select string_agg(x.customer || ': ' || x.txns || ' txns, bal ' || x.bal,
                          '   |   ' order by x.customer)
          from (select coalesce(i2.customer, '(none)') as customer,
                       (select count(*) from public."storeRecords" s
                         where s.inventory_id = i2.id) as txns,
                       (select coalesce(sum(case when s.entry_type = 'IN'
                                                 then s.quantity else -s.quantity end), 0)
                          from public."storeRecords" s
                         where s.inventory_id = i2.id) as bal
                  from public.inventory i2
                 where i2.barcode = i.barcode and i2.id <> i.id) x)
                                                          as siblings,
       case when exists (select 1 from public.inventory i2
                          where i2.barcode = i.barcode
                            and i2.id <> i.id
                            and i2.available_pcs = i.available_pcs)
            then 'LIKELY (A) - balance mirrors a sibling, classic double-post artefact'
            else 'CHECK (B) - balance differs from siblings, verify before zeroing'
       end as assessment
  from public.inventory i
 where not exists (select 1 from public."storeRecords" s where s.inventory_id = i.id)
   and exists (select 1 from public."storeRecords" s where s.part_name = i.barcode)
 order by i.barcode, i.customer;

-- 5.0b If 5.0a confirms all three are case (A), run THIS instead of 5.0.
-- It keeps the unassigned-transaction check - the one that actually
-- protects you - and drops only the would-be-zeroed warning.
do $$
declare unassigned int;
begin
    select count(*) into unassigned
      from public."storeRecords" where inventory_id is null;

    if unassigned > 0 then
        raise exception
            'ABORT: % transactions have no inventory_id. Rebuilding now would '
            'reset their items to 0. Finish PART 4 first.', unassigned;
    end if;

    raise notice 'Gate passed: every transaction has an owner. Zeroing of '
                 'transaction-less items was reviewed and accepted via 5.0a.';
end $$;

-- =====================================================================
-- PART 5A. THE CORRECT REBUILD - opening balance + own transactions.
--
-- *** USE THIS INSTEAD OF 5.1/5.2 IF 5A.0 SHOWS OPENING BALANCES. ***
--
-- WHY 5.2 IS WRONG FOR THIS DATA
-- 5.2 assumes storeRecords is a complete ledger starting from zero, so a
-- balance is just the sum of its transactions. That is false here:
--   * ESL N367664 / REYNOSA sums to -6978 while holding 1244
--   * AVT 3 PB has ONE transaction on the barcode but balances of 270/245
-- Items carry opening stock that predates the log (bulk import, or set by
-- hand through the dashboard's Save Changes, which writes available_pcs
-- directly). Summing the ledger would erase it.
--
-- THE FIX
-- The old code applied every delta to EVERY row sharing a barcode, so:
--     current_balance(i) = opening(i) + SUM(all txns on that BARCODE)
-- therefore:
--     opening(i)         = current_balance(i) - SUM(all txns on BARCODE)
--     correct_balance(i) = opening(i) + SUM(txns assigned to THIS ITEM)
--
-- KEY PROPERTY: for a barcode owned by a single item, the two sums are
-- identical and the formula is a NO-OP - that item's balance is left
-- exactly as it is. Only barcodes shared by several customers change.
-- This is surgical: it repairs the double-posting and nothing else.
--
-- ASSUMPTION, STATE IT TO YOUR STORE TEAM: that both rows existed for the
-- whole period, so both received every delta. If one was created midway,
-- its inferred opening will be off - 5A.0 flags negative openings, which
-- is the usual symptom.
-- =====================================================================

-- 5A.0 PREVIEW. Read this before applying anything.
--
-- verdict column:
--   UNCHANGED        - single-owner barcode, nothing to fix
--   REDISTRIBUTED    - shared barcode, double-posting unwound
--   NEGATIVE OPENING - inferred opening is below zero. The assumption
--                      does not hold for this item; do not trust the new
--                      figure, check it physically.
--   NEGATIVE RESULT  - new balance below zero; transactions are still on
--                      the wrong item.
select i.barcode,
       coalesce(i.customer, '(none)') as customer,
       i.product_name,
       i.available_pcs                                        as balance_now,
       calc.barcode_total,
       calc.own_total,
       i.available_pcs - calc.barcode_total                   as inferred_opening,
       i.available_pcs - calc.barcode_total + calc.own_total  as balance_after,
       case
         when i.available_pcs - calc.barcode_total < 0            then 'NEGATIVE OPENING - verify physically'
         when i.available_pcs - calc.barcode_total
              + calc.own_total < 0                                then 'NEGATIVE RESULT - reassign transactions'
         when calc.barcode_total = calc.own_total                 then 'UNCHANGED'
         else 'REDISTRIBUTED'
       end as verdict
  from public.inventory i
  join lateral (
        select coalesce((select sum(case when s.entry_type = 'IN'
                                         then s.quantity else -s.quantity end)
                           from public."storeRecords" s
                          where s.part_name = i.barcode), 0) as barcode_total,
               coalesce((select sum(case when s.entry_type = 'IN'
                                         then s.quantity else -s.quantity end)
                           from public."storeRecords" s
                          where s.inventory_id = i.id), 0)   as own_total
       ) calc on true
 order by (case when calc.barcode_total = calc.own_total then 1 else 0 end),
          i.barcode, i.customer;

-- 5A.1 Summary of the above - how much actually changes.
select verdict, count(*) as items from (
    select case
             when i.available_pcs - calc.barcode_total < 0 then 'NEGATIVE OPENING - verify physically'
             when i.available_pcs - calc.barcode_total + calc.own_total < 0 then 'NEGATIVE RESULT - reassign transactions'
             when calc.barcode_total = calc.own_total then 'UNCHANGED'
             else 'REDISTRIBUTED'
           end as verdict
      from public.inventory i
      join lateral (
            select coalesce((select sum(case when s.entry_type = 'IN'
                                             then s.quantity else -s.quantity end)
                               from public."storeRecords" s
                              where s.part_name = i.barcode), 0) as barcode_total,
                   coalesce((select sum(case when s.entry_type = 'IN'
                                             then s.quantity else -s.quantity end)
                               from public."storeRecords" s
                              where s.inventory_id = i.id), 0)   as own_total
           ) calc on true
) x group by verdict order by items desc;

-- 5A.2 APPLY. Only after 5A.0 looks right.
-- Gated on every transaction having an owner - without that the
-- redistribution is meaningless.
do $$
declare unassigned int;
begin
    select count(*) into unassigned
      from public."storeRecords" where inventory_id is null;
    if unassigned > 0 then
        raise exception 'ABORT: % transactions still have no inventory_id.', unassigned;
    end if;
end $$;

update public.inventory i
   set available_pcs     = calc.new_bal,
       ready_to_ship_pcs = calc.new_bal,
       available_cartons = floor(calc.new_bal::numeric
                                 / greatest(coalesce(i.units_per_carton, 1), 1)),
       loose_remainder   = calc.new_bal % greatest(coalesce(i.units_per_carton, 1), 1),
       in_qa_pass_pcs    = calc.in_pcs,
       out_shipped_pcs   = calc.out_pcs,
       updated_at        = now()
  from (
        select i2.id,
               i2.available_pcs
                 - coalesce((select sum(case when s.entry_type = 'IN'
                                             then s.quantity else -s.quantity end)
                               from public."storeRecords" s
                              where s.part_name = i2.barcode), 0)
                 + coalesce((select sum(case when s.entry_type = 'IN'
                                             then s.quantity else -s.quantity end)
                               from public."storeRecords" s
                              where s.inventory_id = i2.id), 0) as new_bal,
               coalesce((select sum(s.quantity) from public."storeRecords" s
                          where s.inventory_id = i2.id and s.entry_type = 'IN'), 0)  as in_pcs,
               coalesce((select sum(s.quantity) from public."storeRecords" s
                          where s.inventory_id = i2.id and s.entry_type <> 'IN'), 0) as out_pcs
          from public.inventory i2
       ) calc
 where calc.id = i.id;

-- 5A.3 Verify: totals should be preserved per barcode, only redistributed.
select i.barcode,
       string_agg(coalesce(i.customer, '(none)') || ': ' || i.available_pcs,
                  '   |   ' order by i.customer) as balances_now,
       sum(i.available_pcs)                      as barcode_total_now
  from public.inventory i
 where i.barcode in (select barcode from public.inventory
                      group by barcode having count(*) > 1)
 group by i.barcode
 order by i.barcode;


-- 5.1 Preview: what changes, and by how much.
-- Check this BEFORE 5.2. Any row where txns = 0 but balance_now > 0 is a
-- red flag - that item is about to lose its stock figure.
select i.barcode, i.customer, i.product_name,
       i.available_pcs as balance_now,
       led.bal         as balance_after,
       led.bal - i.available_pcs as delta,
       led.txns
  from public.inventory i
  join lateral (
        select coalesce(sum(case when s.entry_type = 'IN'
                                 then s.quantity else -s.quantity end), 0) as bal,
               count(*) as txns
          from public."storeRecords" s where s.inventory_id = i.id) led on true
 where led.bal is distinct from i.available_pcs
 order by abs(led.bal - i.available_pcs) desc;

-- 5.2 Apply.
update public.inventory i
   set available_pcs     = led.bal,
       ready_to_ship_pcs = led.bal,
       available_cartons = floor(led.bal::numeric
                                 / greatest(coalesce(i.units_per_carton, 1), 1)),
       loose_remainder   = led.bal % greatest(coalesce(i.units_per_carton, 1), 1),
       in_qa_pass_pcs    = led.in_pcs,
       out_shipped_pcs   = led.out_pcs,
       updated_at        = now()
  from (
        select i2.id,
               coalesce((select sum(case when s.entry_type = 'IN'
                                         then s.quantity else -s.quantity end)
                           from public."storeRecords" s
                          where s.inventory_id = i2.id), 0) as bal,
               coalesce((select sum(s.quantity) from public."storeRecords" s
                          where s.inventory_id = i2.id and s.entry_type = 'IN'), 0)  as in_pcs,
               coalesce((select sum(s.quantity) from public."storeRecords" s
                          where s.inventory_id = i2.id and s.entry_type <> 'IN'), 0) as out_pcs
          from public.inventory i2
       ) led
 where led.id = i.id;

-- 5.3 Negative balances = a transaction is still on the wrong item.
-- Investigate each one; do not just zero it.
select id, barcode, customer, product_name, available_pcs
  from public.inventory where available_pcs < 0 order by available_pcs;


-- =====================================================================
-- PART 5R. RECOVERY - undo a premature rebuild.
--
-- Use this if PART 5.2 already ran while records were unassigned and
-- zeroed items that actually hold stock. Requires the PART 0.1 snapshot.
-- =====================================================================

-- 5R.1 What did the rebuild change? Compare live against the snapshot.
select i.barcode, i.customer, i.product_name,
       b.available_pcs as balance_in_backup,
       i.available_pcs as balance_now,
       (select count(*) from public."storeRecords" s where s.inventory_id = i.id) as assigned_txns,
       (select count(*) from public."storeRecords" s where s.part_name = i.barcode) as txns_on_barcode
  from public.inventory i
  join inventory_backup_20260723 b on b.id = i.id
 where i.available_pcs is distinct from b.available_pcs
 order by abs(coalesce(b.available_pcs, 0) - coalesce(i.available_pcs, 0)) desc;

-- 5R.2 Restore the stock columns from the snapshot. Leaves inventory_id
-- assignments and the PART 1/2 normalisation+merge work intact - this
-- rolls back ONLY the balance figures.
update public.inventory i
   set available_pcs     = b.available_pcs,
       ready_to_ship_pcs = b.ready_to_ship_pcs,
       available_cartons = b.available_cartons,
       loose_remainder   = b.loose_remainder,
       in_qa_pass_pcs    = b.in_qa_pass_pcs,
       out_shipped_pcs   = b.out_shipped_pcs,
       updated_at        = now()
  from inventory_backup_20260723 b
 where b.id = i.id
   and i.available_pcs is distinct from b.available_pcs;

-- 5R.3 If the snapshot is gone, reconstruct from history instead. This
-- sums by BARCODE + CUSTOMER rather than inventory_id, so it works even
-- while inventory_id is still null. IN rows carry no customer, so their
-- quantity is credited to the barcode's only item when there is one -
-- review the output before trusting it for shared barcodes.
select i.id, i.barcode, i.customer, i.available_pcs as balance_now,
       coalesce(sum(case when s.entry_type = 'IN'
                         then s.quantity else -s.quantity end), 0) as balance_from_history,
       count(s.id) as txns_matched
  from public.inventory i
  left join public."storeRecords" s
    on s.part_name = i.barcode
   and (s.customer_name = i.customer
        or (s.customer_name is null
            and (select count(*) from public.inventory i2
                  where i2.barcode = i.barcode) = 1))
 group by i.id, i.barcode, i.customer, i.available_pcs
 order by i.barcode, i.customer;


-- =====================================================================
-- PART 6. LOCK IT IN.
-- =====================================================================

-- 6.0 RECOMMENDED - write the opening balances into the ledger.
--
-- After 5A.2 each balance is: inferred_opening + its own transactions.
-- The opening part exists only as a number in inventory.available_pcs;
-- nothing in storeRecords accounts for it. That is the exact condition
-- that made 5.2 destructive - a future rebuild would erase it again.
--
-- This inserts one visible OPENING BALANCE transaction per item so that
-- from now on:
--     available_pcs == sum of its transactions
-- The ledger becomes complete and self-checking, and the dashboard shows
-- operators where the stock originally came from.
--
-- RUN ONCE, AFTER 5A.2. Running it twice double-counts every opening.
-- 6.0c below refuses to let that happen.

-- 6.0a PREVIEW - what will be written.
select i.barcode,
       coalesce(i.customer, '(none)') as customer,
       i.available_pcs as balance_now,
       coalesce((select sum(case when s.entry_type = 'IN'
                                 then s.quantity else -s.quantity end)
                   from public."storeRecords" s
                  where s.inventory_id = i.id), 0) as ledger_now,
       i.available_pcs
         - coalesce((select sum(case when s.entry_type = 'IN'
                                     then s.quantity else -s.quantity end)
                       from public."storeRecords" s
                      where s.inventory_id = i.id), 0) as opening_to_write
  from public.inventory i
 where i.available_pcs
       is distinct from coalesce((select sum(case when s.entry_type = 'IN'
                                                  then s.quantity else -s.quantity end)
                                    from public."storeRecords" s
                                   where s.inventory_id = i.id), 0)
 order by abs(i.available_pcs
              - coalesce((select sum(case when s.entry_type = 'IN'
                                          then s.quantity else -s.quantity end)
                            from public."storeRecords" s
                           where s.inventory_id = i.id), 0)) desc;

-- 6.0b GUARD - refuses if opening records already exist.
do $$
declare existing int;
begin
    select count(*) into existing
      from public."storeRecords"
     where remark_in_out = 'OPENING BALANCE - MIGRATION 2026-07-23';
    if existing > 0 then
        raise exception
            'ABORT: % opening-balance records already exist. Running again '
            'would double-count every opening.', existing;
    end if;
end $$;

-- 6.0c INSERT. A negative opening is written as an OUT so the sign works
-- out; those should be rare and are worth investigating separately.
insert into public."storeRecords"
       (inventory_id, part_name, entry_type, quantity, customer_name,
        pic_name, manu_date, out_date, carton_info, remark_in_out, item_location)
select i.id,
       i.barcode,
       case when d.opening >= 0 then 'IN' else 'OUT' end,
       abs(d.opening),
       i.customer,
       'MIGRATION',
       case when d.opening >= 0 then date '2026-07-23' end,
       case when d.opening <  0 then date '2026-07-23' end,
       abs(d.opening) || ' PCS (OPENING)',
       'OPENING BALANCE - MIGRATION 2026-07-23',
       null
  from public.inventory i
  join lateral (
        select i.available_pcs
                 - coalesce((select sum(case when s.entry_type = 'IN'
                                             then s.quantity else -s.quantity end)
                               from public."storeRecords" s
                              where s.inventory_id = i.id), 0) as opening
       ) d on true
 where d.opening <> 0;

-- 6.0d VERIFY - must return zero rows. Every balance now equals its ledger.
select i.id, i.barcode, i.customer, i.available_pcs,
       coalesce((select sum(case when s.entry_type = 'IN'
                                 then s.quantity else -s.quantity end)
                   from public."storeRecords" s
                  where s.inventory_id = i.id), 0) as ledger
  from public.inventory i
 where i.available_pcs
       is distinct from coalesce((select sum(case when s.entry_type = 'IN'
                                                  then s.quantity else -s.quantity end)
                                    from public."storeRecords" s
                                   where s.inventory_id = i.id), 0);


-- 6.1 barcode + customer is now the business key.
-- Extra parens around the expression are required - COALESCE is a SQL
-- construct, not a plain function call.
create unique index if not exists inventory_barcode_customer_uq
    on public.inventory (barcode, (coalesce(customer, '')));

-- 6.2 Every future transaction must name its item. Run this only after
-- the app changes are deployed - the pages now always send inventory_id.
-- alter table public."storeRecords" alter column inventory_id set not null;

-- 6.3 Final verification - all three should be zero.
select (select count(*) from public."storeRecords" where inventory_id is null) as unassigned_txns,
       (select count(*) from (select barcode, coalesce(customer, '')
                                from public.inventory group by 1, 2 having count(*) > 1) x)
                                                                                as duplicate_items,
       (select count(*) from public.inventory i
         where i.available_pcs is distinct from
               coalesce((select sum(case when s.entry_type = 'IN'
                                         then s.quantity else -s.quantity end)
                           from public."storeRecords" s where s.inventory_id = i.id), 0))
                                                                                as balances_out_of_sync;

-- =====================================================================
-- UTILITY. Check one barcode before/while migrating.
-- Replace '150102' in all three queries with the barcode you are looking
-- at. Answers: will PASS A handle this automatically, or is manual work
-- needed?
-- =====================================================================

-- U.1 How many items share this barcode?
--   1 row  -> PASS A (3.1) assigns everything automatically. No work.
--  >1 rows -> ambiguous; PASS B/C/D try, remainder is manual.
select id, barcode, customer, product_name, units_per_carton, available_pcs
  from public.inventory
 where upper(trim(barcode)) = upper(trim('150102'))
 order by customer;

-- U.2 Its transactions, and which pass will claim each one.
select s.id,
       s.entry_type,
       s.quantity,
       s.customer_name,
       s.jo_number,
       s.item_location,
       coalesce(s.manu_date, s.out_date) as txn_date,
       case
         when s.inventory_id is not null then 'already assigned'
         when (select count(*) from public.inventory i
                where upper(trim(i.barcode)) = upper(trim(s.part_name))) = 1
              then 'PASS A - automatic'
         when s.customer_name is not null
          and upper(trim(s.customer_name)) <> 'RETURN TO QA'
          and exists (select 1 from public.inventory i
                       where upper(trim(i.barcode))  = upper(trim(s.part_name))
                         and upper(trim(i.customer)) = upper(trim(s.customer_name)))
              then 'PASS B - matched on customer'
         when s.jo_number is not null and trim(s.jo_number) <> ''
              then 'PASS C - maybe, if a sibling on this JO resolves'
         else 'MANUAL - no customer, no JO'
       end as resolved_by
  from public."storeRecords" s
 where upper(trim(s.part_name)) = upper(trim('150102'))
 order by s.created_at;

-- U.3 Assign this barcode's remaining records to one item, when the store
-- team confirms they all belong to the same customer.
-- update public."storeRecords"
--    set inventory_id = (select id from public.inventory
--                         where upper(trim(barcode))  = upper(trim('150102'))
--                           and upper(trim(customer)) = upper(trim('BISON')))
--  where inventory_id is null
--    and upper(trim(part_name)) = upper(trim('150102'));


-- 6.4 Once you are satisfied, drop the scaffolding:
-- drop table if exists inventory_backup_20260723;
-- drop table if exists "storeRecords_backup_20260723";
-- drop table if exists dup_map;
-- drop function if exists public.loc_text_array(jsonb);
