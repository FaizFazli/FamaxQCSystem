-- =====================================================================
-- PRODUCTION MIGRATION - Store inventory item identity
-- Target: Supabase / PostgreSQL
-- Author decision record: 2026-07-23
--
-- WHAT THIS FIXES
--   storeRecords was linked to inventory only by part_name (the barcode
--   text). A barcode is not unique - the same barcode under a different
--   customer is a different item. Consequences in production today:
--     1. every item sharing a barcode shows the SAME transaction history
--     2. store_record.html applied each stock delta to EVERY row sharing
--        the barcode, so balances on those items are inflated
--
-- WHAT IT DOES
--   adds storeRecords.inventory_id, normalises the keys, merges true
--   duplicates, assigns every transaction to its owning item, repairs the
--   double-posted balances, then locks the rule in with a constraint.
--
-- BUSINESS RULES (confirmed with store team)
--   * an item is identified by barcode + customer
--   * same barcode + different customer  -> separate items, history split
--   * same barcode + same customer       -> merged into one item
--   * RESERVATION deducts stock, same as OUT
--
-- ============================ READ THIS ==============================
-- FREEZE STORE ENTRIES FOR THE DURATION.
-- Transactions saved while this runs will be missed by the assignment
-- passes and will skew the balance repair. Tell the store team to stop
-- entering, run the migration, deploy the app, then release.
--
-- Estimated hands-on time: 30-60 min, most of it STEP 5 (manual).
--
-- THERE ARE TWO MANDATORY STOP POINTS - 3.2 and STEP 5. Neither can be
-- automated; both need a human decision. Do not run past them blind.
--
-- HOW TO RUN: paste ONE numbered block at a time into the SQL editor.
-- Do NOT paste the whole file - the guards will fire and you will not be
-- able to tell which block failed.
-- =====================================================================


-- =====================================================================
-- STEP 0. BACKUP. Not optional.
-- =====================================================================

-- 0.1 Snapshots. These are your rollback (see STEP 9R).
drop table if exists inventory_backup_prod;
create table inventory_backup_prod as select * from public.inventory;

drop table if exists "storeRecords_backup_prod";
create table "storeRecords_backup_prod" as select * from public."storeRecords";

select (select count(*) from inventory_backup_prod)        as inventory_saved,
       (select count(*) from "storeRecords_backup_prod")   as store_saved;

-- 0.2 Scale of the job. Note these numbers - you will check them later.
select 'inventory rows'                          as metric, count(*)::text as value
  from public.inventory
union all
select 'storeRecords rows',      count(*)::text from public."storeRecords"
union all
select 'barcodes shared by >1 customer (SPLIT)',  count(*)::text from (
        select upper(trim(barcode)) from public.inventory
         group by upper(trim(barcode))
        having count(distinct upper(trim(coalesce(customer, '')))) > 1) a
union all
select 'barcode+customer duplicated (MERGE)',     count(*)::text from (
        select 1 from public.inventory
         group by upper(trim(barcode)), upper(trim(coalesce(customer, '')))
        having count(*) > 1) b
union all
select 'barcodes differing only by whitespace',   count(*)::text from (
        select 1 from public.inventory
         group by upper(trim(barcode)) having count(distinct barcode) > 1) c;


-- =====================================================================
-- STEP 1. SCHEMA. Idempotent.
-- =====================================================================

-- 1.1 Add inventory_id, matching whatever type inventory.id is
-- (uuid or bigint - derived, not assumed).
do $$
declare idtype text;
begin
    select format_type(a.atttypid, a.atttypmod) into idtype
      from pg_attribute a
     where a.attrelid = 'public.inventory'::regclass
       and a.attname = 'id' and a.attnum > 0;

    execute format(
        'alter table public."storeRecords"
           add column if not exists inventory_id %s references public.inventory(id)',
        idtype);
end $$;

create index if not exists "storeRecords_inventory_id_idx"
    on public."storeRecords" (inventory_id);

-- 1.2 Helper for the location tie-break in 4.4.
-- inventory.item_location is jsonb (array of strings), not text[].
create or replace function public.loc_text_array(v jsonb)
returns text[] language sql immutable as $$
    select case jsonb_typeof(v)
        when 'array'  then coalesce((
                select array_agg(distinct upper(trim(e)))
                  from jsonb_array_elements_text(v) e
                 where nullif(trim(e), '') is not null), '{}'::text[])
        when 'string' then array[upper(trim(v #>> '{}'))]
        else '{}'::text[]
    end;
$$;

-- 1.3 Confirm item_location really is jsonb on inventory, and TEXT on
-- storeRecords. If storeRecords.item_location comes back as jsonb, SKIP
-- block 4.4 later - trim() on jsonb errors.
select table_name, column_name, data_type
  from information_schema.columns
 where table_schema = 'public'
   and table_name in ('inventory', 'storeRecords')
   and column_name = 'item_location';


-- =====================================================================
-- STEP 2. NORMALISE THE KEYS.
-- Untrimmed / mixed-case text silently defeats every count-based guard
-- below. Fix it at the source first.
-- =====================================================================

-- 2.1 Preview.
select 'inventory.barcode' as field, barcode as before, upper(trim(barcode)) as after
  from public.inventory where barcode is distinct from upper(trim(barcode))
union all
select 'inventory.customer', customer, upper(trim(customer))
  from public.inventory where customer is distinct from upper(trim(customer))
union all
select 'storeRecords.part_name', part_name, upper(trim(part_name))
  from public."storeRecords" where part_name is distinct from upper(trim(part_name))
union all
select 'storeRecords.customer_name', customer_name, upper(trim(customer_name))
  from public."storeRecords" where customer_name is distinct from upper(trim(customer_name));

-- 2.2 Apply.
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
-- STEP 3. MERGE - same barcode AND same customer.
-- =====================================================================

-- 3.1 Build the keep/drop map. Survivor = most complete row.
-- Ordered by id::text because uuid has no min() aggregate before PG 17.
drop table if exists dup_map;
create table dup_map as
with ranked as (
    select i.id, i.barcode, coalesce(i.customer, '') as cust,
           count(*) over (partition by i.barcode, coalesce(i.customer, '')) as grp_size,
           row_number() over (
               partition by i.barcode, coalesce(i.customer, '')
               order by (case when nullif(trim(i.product_name), '') is not null then 0 else 1 end),
                        (case when coalesce(i.units_per_carton, 0) > 0 then 0 else 1 end),
                        i.id::text) as rn
      from public.inventory i
)
select r.id, r.barcode, r.cust, r.rn, k.id as keep_id
  from ranked r
  join ranked k on k.barcode = r.barcode and k.cust = r.cust and k.rn = 1
 where r.grp_size > 1;

-- 3.2 *** STOP POINT 1 - READ THIS OUTPUT ***
-- Each group must describe the SAME physical product. If two rows in a
-- group are genuinely different products, barcode+customer is not a
-- sufficient key and this migration must not proceed - stop and redesign.
select d.barcode, nullif(d.cust, '') as customer,
       case when d.rn = 1 then 'KEEP' else 'MERGE + DELETE' end as action,
       i.id, i.product_name, i.uom, i.units_per_carton,
       i.available_pcs, i.item_location
  from dup_map d
  join public.inventory i on i.id = d.id
 order by d.barcode, d.cust, d.rn;

-- 3.3 Move any history already pointing at a loser.
update public."storeRecords" s
   set inventory_id = d.keep_id
  from dup_map d
 where s.inventory_id = d.id and d.id <> d.keep_id;

-- 3.4 Union the losers' locations onto the survivor (jsonb in, jsonb out).
update public.inventory i
   set item_location = coalesce((
        select jsonb_agg(distinct loc order by loc)
          from public.inventory i2
         cross join lateral unnest(public.loc_text_array(i2.item_location)) loc
         where i2.barcode = i.barcode
           and coalesce(i2.customer, '') = coalesce(i.customer, '')),
        i.item_location)
 where i.id in (select distinct keep_id from dup_map);

-- 3.5 Fill blanks on the survivor from a loser.
-- Correlated subqueries, not LATERAL - UPDATE ... FROM LATERAL cannot
-- reference the update target in PostgreSQL.
update public.inventory i
   set product_name = coalesce(nullif(trim(i.product_name), ''), (
            select nullif(trim(i2.product_name), '') from public.inventory i2
              join dup_map d2 on d2.id = i2.id
             where d2.keep_id = i.id and i2.id <> i.id
               and nullif(trim(i2.product_name), '') is not null
             order by i2.id::text limit 1)),
       uom = coalesce(nullif(trim(i.uom), ''), (
            select nullif(trim(i2.uom), '') from public.inventory i2
              join dup_map d2 on d2.id = i2.id
             where d2.keep_id = i.id and i2.id <> i.id
               and nullif(trim(i2.uom), '') is not null
             order by i2.id::text limit 1)),
       units_per_carton = case
            when coalesce(i.units_per_carton, 0) > 0 then i.units_per_carton
            else coalesce((select i2.units_per_carton from public.inventory i2
                             join dup_map d2 on d2.id = i2.id
                            where d2.keep_id = i.id and i2.id <> i.id
                              and coalesce(i2.units_per_carton, 0) > 0
                            order by i2.id::text limit 1), i.units_per_carton)
       end
 where i.id in (select distinct keep_id from dup_map);

-- 3.6 Refuse to delete anything still referenced, then delete.
do $$
declare n int;
begin
    select count(*) into n from public."storeRecords" s
      join dup_map d on d.id = s.inventory_id where d.id <> d.keep_id;
    if n > 0 then
        raise exception 'ABORT: % storeRecords still point at rows queued for deletion', n;
    end if;
end $$;

delete from public.inventory where id in (select id from dup_map where id <> keep_id);

-- 3.7 Confirm. Must be 0.
select count(*) as duplicate_pairs_remaining from (
    select 1 from public.inventory
     group by barcode, coalesce(customer, '') having count(*) > 1) x;


-- =====================================================================
-- STEP 4. SPLIT - assign every transaction to its owning item.
-- =====================================================================

-- 4.1 PASS A - barcode owned by exactly one item. No ambiguity.
-- Resolves the large majority.
update public."storeRecords" s
   set inventory_id = i.id
  from public.inventory i
 where i.barcode = s.part_name
   and s.inventory_id is null
   and (select count(*) from public.inventory i2 where i2.barcode = s.part_name) = 1;

-- 4.2 PASS B - shared barcode, record names its customer (OUT / RESERVATION).
update public."storeRecords" s
   set inventory_id = i.id
  from public.inventory i
 where i.barcode = s.part_name
   and i.customer = s.customer_name
   and s.inventory_id is null
   and s.customer_name is not null
   and s.customer_name <> 'RETURN TO QA';

-- 4.3 PASS C - shared barcode, inherit from a sibling on the same job order.
-- IN rows carry no customer, but an IN and an OUT on the same JO for the
-- same barcode are the same physical stock.
update public."storeRecords" s
   set inventory_id = (
        select distinct s2.inventory_id from public."storeRecords" s2
         where s2.jo_number = s.jo_number and s2.part_name = s.part_name
           and s2.inventory_id is not null)
 where s.inventory_id is null
   and s.jo_number is not null and trim(s.jo_number) <> ''
   and (select count(distinct s2.inventory_id) from public."storeRecords" s2
         where s2.jo_number = s.jo_number and s2.part_name = s.part_name
           and s2.inventory_id is not null) = 1;

-- 4.4 PASS D - shared barcode, tie-break on rack location. OPTIONAL.
-- SKIP if 1.3 showed storeRecords.item_location is jsonb, or if a
-- location can legitimately hold two customers' stock in your warehouse.
update public."storeRecords" s
   set inventory_id = (
        select i.id from public.inventory i
         where i.barcode = s.part_name
           and upper(trim(s.item_location)) = any (public.loc_text_array(i.item_location)))
 where s.inventory_id is null
   and s.item_location is not null and trim(s.item_location) <> ''
   and (select count(*) from public.inventory i
         where i.barcode = s.part_name
           and upper(trim(s.item_location)) = any (public.loc_text_array(i.item_location))) = 1;

-- 4.5 Coverage.
select count(*) filter (where inventory_id is not null) as assigned,
       count(*) filter (where inventory_id is null)     as unassigned,
       round(100.0 * count(*) filter (where inventory_id is not null)
             / nullif(count(*), 0), 1) as pct_assigned
  from public."storeRecords";


-- =====================================================================
-- STEP 5. *** STOP POINT 2 - MANUAL ASSIGNMENT ***
--
-- Whatever the passes could not resolve needs a human. Typically a
-- handful of rows. STEP 6 will refuse to run until this is empty.
-- =====================================================================

-- 5.1 Triage - why each row is stuck and what fixes it.
select s.id, s.part_name, s.entry_type, s.quantity,
       coalesce(s.customer_name, '(none)') as customer_on_record,
       coalesce(s.jo_number, '(none)')     as jo_number,
       coalesce(s.manu_date, s.out_date)   as txn_date,
       case
         when (select count(*) from public.inventory i where i.barcode = s.part_name) = 0
              then 'NO ITEM EXISTS for this barcode -> create it, then re-run 4.1'
         when s.customer_name is null
              then 'IN record, no customer -> pick owner by hand'
         when upper(trim(s.customer_name)) = 'RETURN TO QA'
              then 'RETURN TO QA -> pick owner by hand'
         when not exists (select 1 from public.inventory i
                           where i.barcode = s.part_name and i.customer = s.customer_name)
              then 'customer matches no item -> check spelling'
         else 'ambiguous -> pick owner by hand'
       end as why_stuck,
       (select string_agg(i.id::text || ' = ' || coalesce(i.customer, '(none)'), '   |   ')
          from public.inventory i where i.barcode = s.part_name) as candidates
  from public."storeRecords" s
 where s.inventory_id is null
 order by s.part_name, s.created_at;

-- ---------------------------------------------------------------------
-- 5.1a EVIDENCE. Run these before deciding. They turn most "pick by
-- hand" rows into a lookup instead of a guess.
-- ---------------------------------------------------------------------

-- (a) JO / SO -> customer. A jo_number of the form SO/ddmmyy/NNNNN is a
--     sales order; SalesOrders.customer_name names the buyer outright.
--     JO_Number carries a 4th segment, so match on prefix.
select s.id            as record_id,
       s.part_name,
       s.jo_number,
       so.so_number,
       so.customer_name as so_customer,
       so.status,
       jo."Part_Name"  as jo_part,
       jo."Quantity"   as jo_qty
  from public."storeRecords" s
  left join public."SalesOrders" so
         on so.so_number = split_part(s.jo_number, '/', 1) || '/'
                        || split_part(s.jo_number, '/', 2) || '/'
                        || split_part(s.jo_number, '/', 3)
  left join public."JobOrder" jo
         on jo."JO_Number" = s.jo_number
 where s.inventory_id is null
   and s.jo_number is not null and trim(s.jo_number) <> '';

-- (b) Full ledger for the affected barcodes, showing who each already
--     assigned row landed on. The customer mix on the OUT rows usually
--     tells you who the unassigned IN rows fed.
select s.id, s.part_name, s.entry_type, s.quantity,
       coalesce(s.customer_name, '(none)')  as customer_on_record,
       coalesce(s.jo_number, '(none)')      as jo_number,
       coalesce(s.manu_date, s.out_date)    as txn_date,
       coalesce(i.customer, '*** UNASSIGNED ***') as assigned_to
  from public."storeRecords" s
  left join public.inventory i on i.id = s.inventory_id
 where upper(trim(s.part_name)) in (
        select upper(trim(part_name)) from public."storeRecords"
         where inventory_id is null)
 order by s.part_name, coalesce(s.manu_date, s.out_date), s.id;

-- (c) The candidate items themselves - stock on hand, rack, when each
--     was last touched.
select i.id, i.barcode, i.customer, i.product_name, i.available_pcs,
       i.in_qa_pass_pcs, i.out_shipped_pcs, i.units_per_carton,
       i.item_location, i.created_at, i.updated_at
  from public.inventory i
 where upper(trim(i.barcode)) in (
        select upper(trim(part_name)) from public."storeRecords"
         where inventory_id is null)
 order by i.barcode, i.customer;

-- ---------------------------------------------------------------------
-- 5.1b WHAT-IF. Edit the uuids in `choice`, run, read balance_after.
-- An assignment that drives a row negative is the wrong assignment.
-- Changes nothing - it is a simulation.
-- ---------------------------------------------------------------------
with choice(rec_id, target) as (
     values (17,  '68fdc775-c9db-49bd-a940-222fa0f80278'::uuid),   -- USTI
            (25,  '68fdc775-c9db-49bd-a940-222fa0f80278'::uuid),   -- USTI
            (29,  '68fdc775-c9db-49bd-a940-222fa0f80278'::uuid),   -- USTI
            (57,  '68fdc775-c9db-49bd-a940-222fa0f80278'::uuid),   -- USTI
            (215, '137d931f-a97a-4604-b195-9f0798fb1a9b'::uuid)    -- SWK UTENSILERIE
),
sim as (
     select s.entry_type, s.quantity,
            coalesce(c.target, s.inventory_id) as inv_id
       from public."storeRecords" s
       left join choice c on c.rec_id = s.id
)
select i.barcode, coalesce(i.customer, '(none)') as customer,
       i.available_pcs                    as balance_now,
       bt.barcode_total, ot.own_total,
       i.available_pcs - bt.barcode_total as inferred_opening,
       i.available_pcs - bt.barcode_total + ot.own_total as balance_after
  from public.inventory i
  cross join lateral (
        select coalesce(sum(case when s.entry_type = 'IN'
                                 then s.quantity else -s.quantity end), 0) as barcode_total
          from public."storeRecords" s where s.part_name = i.barcode) bt
  cross join lateral (
        select coalesce(sum(case when x.entry_type = 'IN'
                                 then x.quantity else -x.quantity end), 0) as own_total
          from sim x where x.inv_id = i.id) ot
 where upper(trim(i.barcode)) in (
        select upper(trim(part_name)) from public."storeRecords"
         where inventory_id is null)
 order by i.barcode, i.customer;

-- 5.2 Assign, one statement per decision, using a uuid from `candidates`:
--   update public."storeRecords" set inventory_id = '<uuid>' where id = <record id>;
--
-- Bulk, when a whole barcode belongs to one customer:
--   update public."storeRecords"
--      set inventory_id = (select id from public.inventory
--                           where barcode = 'ABC123' and customer = 'BISON')
--    where inventory_id is null and part_name = 'ABC123';
--
-- If a barcode has NO item, create it first (balance 0 - STEP 6 computes it):
--   insert into public.inventory
--          (barcode, customer, product_name, uom, units_per_carton,
--           available_pcs, ready_to_ship_pcs, available_cartons, loose_remainder,
--           in_qa_pass_pcs, out_shipped_pcs)
--   values ('<BARCODE>', '<CUSTOMER>', '<PRODUCT>', 'PCS', <n>, 0,0,0,0,0,0);
--   -- then re-run 4.1

-- 5.3 THE GATE. Must return 0 before STEP 6.
select count(*) as must_be_zero from public."storeRecords" where inventory_id is null;


-- =====================================================================
-- STEP 6. REPAIR BALANCES - opening balance + own transactions.
--
-- DO NOT simply sum the ledger. storeRecords does not start from zero:
-- items carry opening stock predating the log (bulk import, or set by
-- hand via the dashboard, which writes available_pcs directly). Summing
-- the ledger would erase it - verified on real data where one item summed
-- to -6978 while physically holding 1244.
--
-- The old code applied every delta to EVERY row sharing a barcode, so:
--     current(i) = opening(i) + SUM(all txns on that BARCODE)
-- therefore:
--     opening(i) = current(i) - SUM(all txns on BARCODE)
--     correct(i) = opening(i) + SUM(txns assigned to THIS ITEM)
--
-- For a barcode with ONE owner both sums are equal and this is a NO-OP.
-- Only shared barcodes move. Surgical by construction.
-- =====================================================================

-- 6.1 PREVIEW. Most rows should say UNCHANGED.
select i.barcode, coalesce(i.customer, '(none)') as customer, i.product_name,
       i.available_pcs                                       as balance_now,
       calc.barcode_total, calc.own_total,
       i.available_pcs - calc.barcode_total                  as inferred_opening,
       i.available_pcs - calc.barcode_total + calc.own_total as balance_after,
       case
         when i.available_pcs - calc.barcode_total < 0                 then 'NEGATIVE OPENING - verify physically'
         when i.available_pcs - calc.barcode_total + calc.own_total < 0 then 'NEGATIVE RESULT - reassign transactions'
         when calc.barcode_total = calc.own_total                       then 'UNCHANGED'
         else 'REDISTRIBUTED'
       end as verdict
  from public.inventory i
  join lateral (
        select coalesce((select sum(case when s.entry_type = 'IN'
                                         then s.quantity else -s.quantity end)
                           from public."storeRecords" s where s.part_name = i.barcode), 0) as barcode_total,
               coalesce((select sum(case when s.entry_type = 'IN'
                                         then s.quantity else -s.quantity end)
                           from public."storeRecords" s where s.inventory_id = i.id), 0)   as own_total
       ) calc on true
 order by (case when calc.barcode_total = calc.own_total then 1 else 0 end), i.barcode;

-- 6.2 APPLY. Gated on a complete assignment.
do $$
declare unassigned int;
begin
    select count(*) into unassigned from public."storeRecords" where inventory_id is null;
    if unassigned > 0 then
        raise exception 'ABORT: % transactions still unassigned. Finish STEP 5.', unassigned;
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
                               from public."storeRecords" s where s.part_name = i2.barcode), 0)
                 + coalesce((select sum(case when s.entry_type = 'IN'
                                             then s.quantity else -s.quantity end)
                               from public."storeRecords" s where s.inventory_id = i2.id), 0) as new_bal,
               coalesce((select sum(s.quantity) from public."storeRecords" s
                          where s.inventory_id = i2.id and s.entry_type = 'IN'), 0)  as in_pcs,
               coalesce((select sum(s.quantity) from public."storeRecords" s
                          where s.inventory_id = i2.id and s.entry_type <> 'IN'), 0) as out_pcs
          from public.inventory i2
       ) calc
 where calc.id = i.id;

-- 6.3 Negatives = transactions still on the wrong item. Investigate.
select id, barcode, customer, product_name, available_pcs
  from public.inventory where available_pcs < 0 order by available_pcs;


-- =====================================================================
-- STEP 7. WRITE THE OPENING BALANCES INTO THE LEDGER.
--
-- After STEP 6 the opening portion exists only as a number in
-- available_pcs; nothing in storeRecords accounts for it. That is exactly
-- the condition that makes a naive future rebuild destructive.
--
-- This writes one visible OPENING BALANCE transaction per item so that
-- from here on: available_pcs == sum of its transactions.
-- RUN ONCE. 7.2 refuses a second run.
-- =====================================================================

-- 7.1 Preview.
select i.barcode, coalesce(i.customer, '(none)') as customer,
       i.available_pcs as balance_now,
       coalesce((select sum(case when s.entry_type = 'IN'
                                 then s.quantity else -s.quantity end)
                   from public."storeRecords" s where s.inventory_id = i.id), 0) as ledger_now,
       i.available_pcs - coalesce((select sum(case when s.entry_type = 'IN'
                                                   then s.quantity else -s.quantity end)
                                     from public."storeRecords" s
                                    where s.inventory_id = i.id), 0) as opening_to_write
  from public.inventory i
 where i.available_pcs is distinct from
       coalesce((select sum(case when s.entry_type = 'IN'
                                 then s.quantity else -s.quantity end)
                   from public."storeRecords" s where s.inventory_id = i.id), 0);

-- 7.2 Guard + insert.
do $$
declare existing int;
begin
    select count(*) into existing from public."storeRecords"
     where remark_in_out = 'OPENING BALANCE - MIGRATION 2026-07-23';
    if existing > 0 then
        raise exception 'ABORT: % opening records already exist. Re-running would double-count.', existing;
    end if;
end $$;

insert into public."storeRecords"
       (inventory_id, part_name, entry_type, quantity, customer_name,
        pic_name, manu_date, out_date, carton_info, remark_in_out)
select i.id, i.barcode,
       case when d.opening >= 0 then 'IN' else 'OUT' end,
       abs(d.opening), i.customer, 'MIGRATION',
       case when d.opening >= 0 then date '2026-07-23' end,
       case when d.opening <  0 then date '2026-07-23' end,
       abs(d.opening) || ' PCS (OPENING)',
       'OPENING BALANCE - MIGRATION 2026-07-23'
  from public.inventory i
  join lateral (
        select i.available_pcs
                 - coalesce((select sum(case when s.entry_type = 'IN'
                                             then s.quantity else -s.quantity end)
                               from public."storeRecords" s where s.inventory_id = i.id), 0) as opening
       ) d on true
 where d.opening <> 0;

-- 7.3 Verify. MUST return zero rows.
select i.id, i.barcode, i.customer, i.available_pcs,
       coalesce((select sum(case when s.entry_type = 'IN'
                                 then s.quantity else -s.quantity end)
                   from public."storeRecords" s where s.inventory_id = i.id), 0) as ledger
  from public.inventory i
 where i.available_pcs is distinct from
       coalesce((select sum(case when s.entry_type = 'IN'
                                 then s.quantity else -s.quantity end)
                   from public."storeRecords" s where s.inventory_id = i.id), 0);


-- =====================================================================
-- STEP 8. LOCK IT IN.
-- =====================================================================

-- 8.1 barcode + customer is the business key.
-- Extra parens required - COALESCE is a SQL construct, not a function call.
create unique index if not exists inventory_barcode_customer_uq
    on public.inventory (barcode, (coalesce(customer, '')));

-- 8.2 *** DEPLOY THE APPLICATION NOW ***
--   screen_page/store/store_record.html
--   screen_page/store/inventory_dashboard.html
-- Then smoke-test before 8.3:
--   a) save an IN on a barcode with ONE customer  -> only that item moves
--   b) save an OUT on a SHARED barcode            -> picker appears; only
--      the chosen customer's item moves
--   c) open a shared-barcode item in the dashboard -> its history shows
--      only its own transactions, plus the OPENING BALANCE row
--   d) confirm the amber "unassigned records" banner does NOT appear

-- 8.3 Only after 8.2 passes: make it structural. No future transaction
-- can exist without naming its item.
-- alter table public."storeRecords" alter column inventory_id set not null;


-- =====================================================================
-- STEP 9. FINAL VERIFICATION. All four must be 0.
-- =====================================================================
select (select count(*) from public."storeRecords" where inventory_id is null)
           as unassigned_transactions,
       (select count(*) from (select 1 from public.inventory
                               group by barcode, coalesce(customer, '')
                              having count(*) > 1) x)
           as duplicate_items,
       (select count(*) from public.inventory i
         where i.available_pcs is distinct from
               coalesce((select sum(case when s.entry_type = 'IN'
                                         then s.quantity else -s.quantity end)
                           from public."storeRecords" s where s.inventory_id = i.id), 0))
           as balances_out_of_sync,
       (select count(*) from public.inventory where available_pcs < 0)
           as negative_balances;

-- Release the store team here.


-- =====================================================================
-- STEP 9R. ROLLBACK - full restore from the STEP 0.1 snapshots.
-- Run the whole block in ONE execution so it is atomic.
-- =====================================================================
-- begin;
-- drop index if exists public.inventory_barcode_customer_uq;
-- alter table public."storeRecords" alter column inventory_id drop not null;
-- delete from public."storeRecords";
-- delete from public.inventory;
-- do $$
-- declare cols text;
-- begin
--     select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) into cols
--       from information_schema.columns c
--      where c.table_schema='public' and c.table_name='inventory'
--        and exists (select 1 from information_schema.columns b
--                     where b.table_schema='public' and b.table_name='inventory_backup_prod'
--                       and b.column_name=c.column_name);
--     execute format('insert into public.inventory (%s) select %s from public.inventory_backup_prod', cols, cols);
--
--     select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) into cols
--       from information_schema.columns c
--      where c.table_schema='public' and c.table_name='storeRecords'
--        and exists (select 1 from information_schema.columns b
--                     where b.table_schema='public' and b.table_name='storeRecords_backup_prod'
--                       and b.column_name=c.column_name);
--     execute format('insert into public."storeRecords" (%s) select %s from public."storeRecords_backup_prod"', cols, cols);
-- end $$;
-- -- Re-sync the id sequence or the next app insert fails on duplicate key.
-- do $$
-- declare seq text;
-- begin
--     seq := pg_get_serial_sequence('public."storeRecords"', 'id');
--     if seq is not null then
--         perform setval(seq, coalesce((select max(id) from public."storeRecords"), 1));
--     end if;
-- end $$;
-- commit;


-- =====================================================================
-- STEP 10. CLEANUP - only after the store team has checked real balances
-- against physical stock. Keep the snapshots until then.
-- =====================================================================
-- drop table if exists dup_map;
-- drop table if exists inventory_backup_prod;
-- drop table if exists "storeRecords_backup_prod";
-- drop function if exists public.loc_text_array(jsonb);
