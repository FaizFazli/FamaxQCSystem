-- 2026-08-05  The tooling tables become reachable, and stock becomes three honest numbers.
--
-- Nine tools_* tables were loaded with real data - 309 tool types, 345 stockable items, 138
-- part/process assignments and 185 opening-stock movements - and not one row of it has ever been
-- readable by this application. Three things stand between that data and a screen. This file is
-- all three, and nothing else: no UI, no new entities, no cleanup of what the import left behind.
--
-- 1. RLS LOCKED THE APPLICATION OUT.
--    Every policy on these tables reads `for select ... to authenticated`, and there is no policy
--    at all for insert, update or delete. This application does not use Supabase Auth - it signs
--    in against AdminCredential / EmployeeTable and keeps the result in sessionStorage - so every
--    request arrives on the shared anon key and auth.jwt() is null. Every policy evaluated false:
--    reads returned [] and writes returned 401.
--
--    This is the same bug, from the same import, that 2026-07-30_gauge_categories_and_rls.sql
--    fixed for the gauge tables. The constraint names still say so: out_tool_*, out_part_*,
--    out_process_* - these tables and out_gauge_* were renamed from one `out_` schema. The fix is
--    the same fix, done the same way, for the same reason. See NOTE 3 for what it costs.
--
-- 2. STOCK WAS STATED TWICE AND THE TWO DISAGREED.
--    tools_item.qty_on_hand reads 0 on all 345 items. tools_txn holds 2,484 pieces of OPENING
--    stock across 185 of them. Nothing - no trigger, no function, no view - has ever kept the two
--    in step, so the column was not stale so much as never started.
--
--    The ledger wins. It is the thing with the audit trail: every piece in it arrived as a dated,
--    typed, attributable row, and a total derived from those rows cannot drift from them. A view
--    sums it. qty_on_hand is backfilled once so nothing reading it sees a lie, and is then inert -
--    not dropped, not synced, and commented to say so. Two columns claiming to hold the same
--    quantity is how they end up disagreeing; the same reasoning retired gauges.image_path.
--
-- 3. THE LEDGER HAD NO SIGN CONVENTION, AND NO WAY TO NAME A PERSON.
--    All 185 rows are OPENING and positive, so nothing in the data said whether issuing a tool
--    stores a negative quantity or a positive one whose type implies the direction. That question
--    gets settled here, in a CHECK constraint rather than in whichever page is written first,
--    because a convention enforced by the database cannot be re-litigated by the next screen.
--
--    Signed quantity, type as the reason: on_hand is then a sum of qty, with no CASE over the enum
--    repeated at every call site, and ADJUST corrects in either direction without a second path.
--    All 185 existing rows already satisfy it.
--
--    With one exception, and it is the whole reason section 1 below is as long as it is. A tool
--    issued to production comes back either reusable or worn out, and BOTH have to be recorded -
--    but only the reusable one returns to the shelf. The worn one left the shelf at ISSUE_PRD and
--    never comes back, so a scrap return has no shelf effect at all. It cannot be a negative
--    without subtracting the same tool twice, and it cannot be a zero, because qty <> 0. It is a
--    positive count that the shelf total excludes.
--
--    performed_by cannot record who did anything here. It is `uuid default uid()` referencing
--    tools_profile(id) -> auth.users(id), and with no Supabase Auth session uid() is always null.
--    txn_by / txn_by_position replace it, exactly as sa_by / sa_position do on Data_IPQC: the name
--    from EmployeeTable, identity proven by that person's PIN, the PIN itself never stored.
--
-- Safe to re-run. Preserves every existing row.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-05_tooling_access.sql

begin;

-- ---------------------------------------------------------------------
-- 1. The ledger's sign convention
-- ---------------------------------------------------------------------
--
-- A tool issued to production is in one of three places, and the ledger has to keep all three
-- straight:
--
--   ON THE SHELF   in the store, usable, ready to issue
--   ON THE FLOOR   issued, not yet returned
--   GONE           worn out in service and written off, or sold
--
-- Everything that leaves the shelf is negative and everything that arrives is positive, which is
-- what makes a sum of qty the shelf total.
--
--   OPENING       +   the count the store started from
--   RECEIPT_PO    +   bought in against a PO
--   RETURN_REUSE  +   came back from the floor with life left in it - back on the shelf
--   ISSUE_PRD     -   went out to production
--   ISSUE_SPARE   -   went out as a spare
--   SELL          -   sold on
--   ADJUST       +/-  a stock count correcting the ledger to the shelf, either way
--   RETURN_SCRAP  +   came back worn out. NO SHELF EFFECT - see below.
--
-- ADJUST is deliberately unconstrained. It is the only type that can go both ways, and that is
-- the whole of its job: without it, correcting an over-count would need a fake ISSUE.
--
-- RETURN_SCRAP is the one type whose quantity is not a shelf movement, and it is worth being
-- exact about why. Production returns a tool either reusable or worn - whether it is reusable is
-- a judgement against the tool's life - and both outcomes have to be recorded. Only the reusable
-- one goes back on the shelf. The worn one already left the shelf when it was issued and is never
-- coming back, so a scrap return changes the shelf by nothing:
--
--   ISSUE_PRD    -10    shelf 95 -> 85,  floor 0 -> 10
--   RETURN_REUSE  +3    shelf 85 -> 88,  floor 10 -> 7
--   RETURN_SCRAP   2    shelf unchanged, floor 7 -> 5,  scrapped 0 -> 2
--
-- Making it negative would subtract the same ten tools twice, once on issue and again on scrap.
-- Making it zero is impossible - qty <> 0 predates this file. So it carries a positive count of
-- tools written off, and the shelf total excludes it. That is one `filter` in one view, in
-- exchange for a scrap figure that is a straight sum and a floor figure that reconciles:
--
--   opening + receipts - sells = on_shelf + on_floor + scrapped
--
-- which is the check anyone counting the store will actually want to run.

alter table tools_txn drop constraint if exists tools_txn_direction_ck;
alter table tools_txn
  add constraint tools_txn_direction_ck check (
    case txn_type
      when 'OPENING'      then qty > 0
      when 'RECEIPT_PO'   then qty > 0
      when 'RETURN_REUSE' then qty > 0
      when 'RETURN_SCRAP' then qty > 0   -- a count written off, not a shelf movement
      when 'ISSUE_PRD'    then qty < 0
      when 'ISSUE_SPARE'  then qty < 0
      when 'SELL'         then qty < 0
      else true
    end
  );

comment on constraint tools_txn_direction_ck on tools_txn is
    'Direction lives in the sign of qty; txn_type says why. RETURN_SCRAP is positive and carries '
    'a count of tools worn out in service - it has no shelf effect, because the tools left the '
    'shelf when they were issued. ADJUST is exempt because a stock correction goes either way.';

comment on column tools_txn.qty is
    'Signed. Negative leaves the shelf, positive arrives, never 0 (out_tool_txn_qty_check). The '
    'exception is RETURN_SCRAP, where a positive qty counts tools worn out in service and moves '
    'nothing onto the shelf. Use v_tools_item_stock rather than summing this column by hand.';

-- ---------------------------------------------------------------------
-- 2. Who moved it
-- ---------------------------------------------------------------------

alter table tools_txn add column if not exists txn_by          text;
alter table tools_txn add column if not exists txn_by_position text;

comment on column tools_txn.txn_by is
    'Name from EmployeeTable of whoever recorded this movement. Identity was proven by '
    'EmployeeTable.pin - the PIN itself is never stored here. The same pattern as '
    'Data_IPQC.sa_by, and for the same reason: this application has no Supabase Auth session.';
comment on column tools_txn.txn_by_position is
    'That person''s position at the time, copied rather than joined, so a later change of role '
    'cannot rewrite who signed for a movement that has already happened.';
comment on column tools_txn.performed_by is
    'INERT. uuid default uid() referencing tools_profile -> auth.users, from the original import. '
    'This application has no Supabase Auth session, so uid() is always null and this column can '
    'never be filled by it. Kept, unread, because dropping it would break the FK to tools_profile '
    'for anything that later does use Auth. Read txn_by instead.';

-- ---------------------------------------------------------------------
-- 3. Stock, derived
-- ---------------------------------------------------------------------
--
-- security_invoker so the view is not a way around the policies below. Without it a view runs as
-- its owner, and this one would hand anon every row of tools_item regardless of what RLS on
-- tools_item says. Everything it reads is granted to anon anyway - the point is that it stays
-- that way by itself if any of those grants is ever tightened.

drop view if exists v_tools_item_stock;

create view v_tools_item_stock
  with (security_invoker = true) as
select i.id                          as item_id,
       i.item_code,
       i.tool_id,
       m.tool_code,
       m.tool_name,
       m.category_id,
       c.code                        as category_code,
       c.name                        as category_name,
       i.mfr_code,
       i.brand,
       i.supplier,
       i.location,
       i.reorder_point,
       i.is_preferred,
       i.is_active,
       -- What is on the shelf. RETURN_SCRAP is excluded because a tool worn out in service left
       -- the shelf when it was issued; counting it again here would subtract it twice.
       coalesce(sum(t.qty) filter (where t.txn_type <> 'RETURN_SCRAP'), 0)::int as on_hand,

       -- What is out on the floor: issued, and not yet accounted for by a return of either kind.
       -- This is the number the return screen needs - you cannot return more than is out - and it
       -- is why a scrap return has to be a row even though it moves nothing onto the shelf.
       -- SELL is not here on purpose: a tool sold is gone, not lent out.
       (coalesce(sum(-t.qty) filter (where t.txn_type in ('ISSUE_PRD','ISSUE_SPARE')), 0)
        - coalesce(sum(t.qty)  filter (where t.txn_type in ('RETURN_REUSE','RETURN_SCRAP')), 0)
       )::int                        as on_floor,

       -- Worn out in service. A straight sum because RETURN_SCRAP is stored positive, and the
       -- figure tool life gets judged against.
       coalesce(sum(t.qty) filter (where t.txn_type = 'RETURN_SCRAP'), 0)::int as scrapped,

       count(t.id)::int              as movements,
       max(t.txn_at)                 as last_movement_at,
       -- Only a reorder point somebody set can be breached. Null means "nobody has decided what
       -- low is for this item", which is not the same as a threshold of zero, and an item sitting
       -- at 0 with no reorder point is not evidence that anyone wants more of it.
       (i.reorder_point is not null
          and coalesce(sum(t.qty) filter (where t.txn_type <> 'RETURN_SCRAP'), 0)
              <= i.reorder_point)    as below_reorder
from tools_item i
join tools_master   m on m.id = i.tool_id
join tools_category c on c.id = m.category_id
-- left, so the 160 items that have never moved read 0 rather than dropping out of the list. An
-- item with no stock is exactly what a store list has to be able to show.
left join tools_txn t on t.tool_item_id = i.id
group by i.id, i.item_code, i.tool_id, m.tool_code, m.tool_name, m.category_id,
         c.code, c.name, i.mfr_code, i.brand, i.supplier, i.location,
         i.reorder_point, i.is_preferred, i.is_active;

comment on view v_tools_item_stock is
    'One row per stockable item, stock derived from tools_txn. The only place that answers "how '
    'many are there" - tools_item.qty_on_hand is inert and must not be read. Three separate '
    'quantities: on_hand is the shelf, on_floor is issued and not yet returned, scrapped is worn '
    'out in service. opening + receipts - sells = on_hand + on_floor + scrapped.';

comment on column v_tools_item_stock.on_floor is
    'Issued and not yet returned. Can read negative if returns were recorded against issues that '
    'were never entered - that is a data-entry fault to investigate, not a state to design for, '
    'so it is deliberately not clamped to zero here.';

grant select on v_tools_item_stock to anon, authenticated;

-- The one-time reconciliation. Not a sync: nothing maintains this column afterwards, and no
-- reader should want it to. Re-running this file re-snapshots it, which is harmless and is not a
-- reason to start trusting it. RETURN_SCRAP is excluded for the same reason the view excludes it.
update tools_item i
   set qty_on_hand = l.s
  from (select tool_item_id, sum(qty)::int as s
          from tools_txn
         where txn_type <> 'RETURN_SCRAP'
         group by tool_item_id) l
 where l.tool_item_id = i.id
   and i.qty_on_hand is distinct from l.s;

comment on column tools_item.qty_on_hand is
    'INERT as of 2026-08-05. Backfilled once from tools_txn so it is not a lie, then left alone - '
    'nothing maintains it and nothing reads it. Stock comes from v_tools_item_stock. It is kept '
    'rather than dropped because dropping a column is the one change in this file that '
    're-running it could not undo.';

-- ---------------------------------------------------------------------
-- 4. Indexes for the reads the screens will actually make
-- ---------------------------------------------------------------------

-- The per-item movement history, newest first, and the per-item sum the view takes.
create index if not exists tools_txn_item_at_idx on tools_txn (tool_item_id, txn_at desc);

-- "What does this part need at this process", which is how the assignment screen is entered.
create index if not exists tools_usage_part_proc_idx on tools_usage (part_id, process_id);

-- ---------------------------------------------------------------------
-- 5. RLS: grant the application's anon role
-- ---------------------------------------------------------------------
--
-- Every policy below is `to anon, authenticated`, because the app has no Supabase Auth session and
-- arrives as anon. Read AND write are open at the database, exactly as they are for Parts,
-- JobOrder, TeamsLog and the gauge tables. Authorisation stays where this app has always put it:
-- the access-level check in the page. See NOTE 3.
--
-- tools_profile is deliberately NOT in this list. It keys off auth.users, this app creates no auth
-- users, and it has 0 rows. Leaving it with RLS on and no policy keeps it unreachable rather than
-- opening a table nothing can meaningfully fill. If Supabase Auth is ever adopted, that is the
-- table to start from.

do $$
declare t text;
begin
  foreach t in array array['tools_category','tools_master','tools_item','tools_part',
                           'tools_process','tools_usage','tools_txn','tools_part_demand']
  loop
    execute format('alter table %I enable row level security', t);
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

-- The original select-only names from the import, now superseded by the pair above.
drop policy if exists out_tool_category_read on tools_category;
drop policy if exists out_tool_read          on tools_master;
drop policy if exists out_tool_item_read     on tools_item;
drop policy if exists out_part_read          on tools_part;
drop policy if exists out_process_read       on tools_process;
drop policy if exists out_tool_usage_read    on tools_usage;
drop policy if exists out_tool_txn_read      on tools_txn;
drop policy if exists out_part_demand_read   on tools_part_demand;

commit;

-- PostgREST caches the schema; without this the new columns and the view 404 until the container
-- restarts.
notify pgrst, 'reload schema';

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - what this file does NOT do.
--   No screen reads any of it yet. Also left alone, deliberately:
--     * tools_part overlaps Parts on only 19 of its 45 rows. The assignment screen will pick from
--       the Parts master and upsert here, so new rows are spelled the way the rest of the system
--       spells them; the 26 that do not match are a reconciliation for a person, not a migration.
--     * tools_usage's UNIQUE (tool_id, part_id, process_id) does not constrain what it appears to,
--       because Postgres treats NULLs as distinct - the same tool and part can be added again and
--       again with no process. 6 rows already have a null process, though none is a duplicate
--       today. A partial unique index belongs with the screen that can create the duplicate.
--     * tools_master.needs_review is true on 49 rows. That is a queue for the masterlist page.
--     * tools_part_demand is empty and nothing plans against it yet.
--
-- NOTE 2 - returning a tool is two outcomes, and the screen has to offer both.
--   Production returns a tool either with life left in it or worn out, the judgement is against
--   the tool's life, and both have to be recorded. They are different rows:
--
--     RETURN_REUSE  +3   goes back on the shelf, available to issue again
--     RETURN_SCRAP   2   written off, never returns to the shelf
--
--   One return can be both. Ten issued, 3 reusable and 2 worn is two rows against the same issue,
--   and 5 still on the floor. The transaction screen should take one return and split it into the
--   two quantities, rather than making the storeman pick a single type for the whole lot.
--
--   Only RETURN_REUSE adds to the shelf. This is why the ledger must not be summed by hand - use
--   v_tools_item_stock, which keeps shelf, floor and scrapped apart.
--
--   What is NOT here: how much life a returned tool had used. tools_item is a quantity of
--   identical tools, not serialised individuals, so there is nowhere to hang a per-tool life
--   counter, and tools_usage.tool_life_pcs is a standard - expected pieces per tool - not a
--   running total. Judging actual against that standard needs pieces-produced captured on the
--   return row. That is a real feature and a small column, left out of this file because it was
--   not asked for and belongs with the transaction screen.
--
-- NOTE 3 - what the RLS change actually costs.
--   Anyone holding the anon key (it ships in assets/app-config.js, so: anyone who can load the
--   site) can read and write these tables directly, bypassing the page. That is already true of
--   Parts, JobOrder, SalesOrders, the gauge tables and the rest of this system - this migration
--   makes the tooling tables consistent with it, it does not introduce the exposure. If tooling
--   should be held to a higher standard than the rest of the app, the fix is a real Supabase Auth
--   session, and these policies revert to `to authenticated`.
--
-- NOTE 4 - verify:
--   select count(*) from v_tools_item_stock;                      -- 345
--   select sum(on_hand) from v_tools_item_stock;                  -- 2484
--   select count(*) from v_tools_item_stock where on_hand > 0;    -- 185
--   select count(*) from v_tools_item_stock where below_reorder;  -- 0 (no reorder point is set)
--   select sum(on_floor), sum(scrapped) from v_tools_item_stock;  -- 0, 0 (nothing issued yet)
--   -- the identity that should hold for every item, forever:
--   select count(*) from v_tools_item_stock s join (
--     select tool_item_id,
--            coalesce(sum(qty) filter (where txn_type in
--              ('OPENING','RECEIPT_PO')), 0)
--          + coalesce(sum(qty) filter (where txn_type = 'ADJUST'), 0)
--          + coalesce(sum(qty) filter (where txn_type = 'SELL'), 0) as inflow
--       from tools_txn group by tool_item_id) l on l.tool_item_id = s.item_id
--    where l.inflow <> s.on_hand + s.on_floor + s.scrapped;       -- 0
--   select count(*) from tools_item
--    where qty_on_hand is distinct from
--          (select coalesce(sum(qty),0) from tools_txn t where t.tool_item_id = tools_item.id);
--                                                                 -- 0, once, and never again
--   -- and as the app sees it, which is the part that was broken:
--   --   curl -s "$URL/rest/v1/v_tools_item_stock?select=item_code,on_hand&limit=3" \
--   --        -H "apikey: $ANON" -H "Authorization: Bearer $ANON"
