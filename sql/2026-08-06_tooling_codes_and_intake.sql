-- 2026-08-06  Tool and item codes assign themselves, and a new item can arrive with stock.
--
-- Two things the masterlist could not do without this file.
--
-- 1. CODES WERE TYPED BY HAND.
--    tool_code and item_code are the factory's own running numbers - FTL-0001..FTL-0309 and
--    FTI-00001..FTI-00345, every one of the 654 conforming to its pattern exactly. Asking a person
--    to read the last one off the list and type the next is how you get FTL-0310 twice, or
--    FTL-310, or a silent gap. It is also a race: two people adding a tool at the same time both
--    read 309.
--
--    Sequences and a column DEFAULT move it into the database, where nextval is atomic and the
--    question "what is the next number" has exactly one answer. The page stops sending the column
--    at all. The UNIQUE constraint stays as the backstop for anything inserted by hand.
--
--    setval is recomputed from the data on every run rather than being a one-time seed, so this
--    file is safe to re-run and self-corrects if rows are ever loaded around it.
--
-- 2. A NEW ITEM COULD NOT ARRIVE WITH STOCK.
--    Adding a stock item and recording what is on the shelf were two screens. The item existed at
--    0 until somebody remembered to go and post an opening count, and an item that reads 0 when it
--    is not 0 is worse than one that does not exist - it is a number people trust.
--
--    tools_create_item() does both in one transaction. Either the item and its opening movement
--    both exist or neither does. This is the same reasoning that made a split return two rows in a
--    single insert: PostgREST gives a page no way to span two tables atomically, so the work that
--    must not half-happen goes in a function.
--
--    The movement is a real ledger row like any other - typed, dated, signed - so stock stays the
--    sum of tools_txn and nothing has to be taught about a special "initial quantity" column.
--
-- Safe to re-run. Independent of 2026-08-06_tooling_usage_unique.sql; both need
-- 2026-08-05_tooling_access.sql first.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-06_tooling_codes_and_intake.sql

begin;

-- ---------------------------------------------------------------------
-- 1. Running numbers
-- ---------------------------------------------------------------------
--
-- Width is pinned per column because the existing data pins it: FTL is 4 digits, FTI is 5. lpad
-- keeps that until the numbers outgrow it, at which point they get longer rather than wrapping -
-- FTL-10000 sorts after FTL-9999 as text, which is the only property that actually matters here.

create sequence if not exists tools_master_code_seq as bigint owned by tools_master.tool_code;
create sequence if not exists tools_item_code_seq   as bigint owned by tools_item.item_code;

-- Recomputed from the data, not seeded once. `true` means the next nextval returns max + 1.
-- greatest(..., 0) covers the empty-table case, where the first code must come out as 0001.
select setval('tools_master_code_seq',
    greatest((select coalesce(max(regexp_replace(tool_code, '\D', '', 'g')::bigint), 0)
                from tools_master where tool_code ~ '^FTL-[0-9]+$'), 0) + 1,
    false);

select setval('tools_item_code_seq',
    greatest((select coalesce(max(regexp_replace(item_code, '\D', '', 'g')::bigint), 0)
                from tools_item where item_code ~ '^FTI-[0-9]+$'), 0) + 1,
    false);

alter table tools_master
    alter column tool_code set default 'FTL-' || lpad(nextval('tools_master_code_seq')::text, 4, '0');

alter table tools_item
    alter column item_code set default 'FTI-' || lpad(nextval('tools_item_code_seq')::text, 5, '0');

comment on column tools_master.tool_code is
    'The factory''s running number for a tool type, FTL-nnnn. Assigned by tools_master_code_seq - '
    'omit the column on insert and let the default fill it. Still UNIQUE, which is what catches a '
    'code inserted by hand that collides with one the sequence will later reach.';
comment on column tools_item.item_code is
    'The factory''s running number for a stock item, FTI-nnnnn. Assigned by tools_item_code_seq; '
    'omit the column on insert. See tools_master.tool_code.';

-- ---------------------------------------------------------------------
-- 2. A new item, and the stock it arrived with, in one transaction
-- ---------------------------------------------------------------------
--
-- SECURITY INVOKER (the default) on purpose: every table it touches is already writable by anon
-- under the 2026-08-05 policies, so running as the definer would grant nothing the caller does not
-- already have, and would hide who did it from any future policy that cares.

create or replace function tools_create_item(
    p_tool_id           bigint,
    p_mfr_code          text    default null,
    p_brand             text    default null,
    p_supplier          text    default null,
    p_location          text    default null,
    p_reorder_point     integer default null,
    p_is_preferred      boolean default false,
    p_is_active         boolean default true,
    p_remarks           text    default null,
    -- Everything below is the opening movement, and all of it is optional. No quantity means no
    -- ledger row: an item somebody is registering now and will count later is a real case.
    p_qty               integer default null,
    p_txn_type          text    default 'OPENING',
    p_po_no             text    default null,
    p_txn_by            text    default null,
    p_txn_by_position   text    default null,
    p_item_code         text    default null   -- null = let the sequence assign it
) returns tools_item
language plpgsql
as $$
declare
    v_item tools_item;
begin
    if p_qty is not null then
        if p_qty <= 0 then
            raise exception 'Opening quantity must be more than 0, or left blank (got %).', p_qty;
        end if;
        -- Only the inbound types can bring stock into being. An ISSUE against an item that did not
        -- exist a moment ago is not a thing that can have happened.
        if p_txn_type not in ('OPENING', 'RECEIPT_PO') then
            raise exception 'A new item can only arrive as OPENING or RECEIPT_PO (got %).', p_txn_type;
        end if;
        if coalesce(btrim(p_txn_by), '') = '' then
            raise exception 'Opening stock must be signed for - p_txn_by is required when p_qty is given.';
        end if;
    end if;

    insert into tools_item (
        tool_id, item_code, mfr_code, brand, supplier, location,
        reorder_point, is_preferred, is_active, remarks
    ) values (
        p_tool_id,
        -- coalesce onto the column default: passing null here means "assign one".
        coalesce(p_item_code, 'FTI-' || lpad(nextval('tools_item_code_seq')::text, 5, '0')),
        p_mfr_code, p_brand, p_supplier, p_location,
        p_reorder_point, p_is_preferred, p_is_active, p_remarks
    )
    returning * into v_item;

    if p_qty is not null then
        insert into tools_txn (
            tool_item_id, txn_type, qty, po_no, txn_by, txn_by_position, remarks
        ) values (
            v_item.id, p_txn_type::tools_txn_type, p_qty, p_po_no, p_txn_by, p_txn_by_position,
            case when p_txn_type = 'OPENING' then 'Opening count recorded when the item was added'
                 else 'Received when the item was added' end
        );
    end if;

    return v_item;
end $$;

comment on function tools_create_item is
    'Creates a stock item and, if a quantity is given, its opening ledger row - both or neither. '
    'PostgREST cannot span two tables in one transaction, and an item that reads 0 when it is not '
    '0 is worse than one that does not exist, so the pair lives here. Pass p_item_code null to '
    'have the sequence assign it. The movement is an ordinary tools_txn row: stock stays the sum '
    'of the ledger and nothing needs to know about an "initial quantity".';

grant execute on function tools_create_item to anon, authenticated;

commit;

-- PostgREST caches the schema; without this the new function 404s until the container restarts.
notify pgrst, 'reload schema';

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - the default does not fire if the caller sends the column.
--   Sending item_code explicitly still works and is how a hand-corrected code gets in. It does NOT
--   advance the sequence, so a code typed ahead of the counter will collide with the sequence
--   later and be refused by the UNIQUE constraint. That is the correct outcome - it is a person
--   having claimed a number the system was going to issue - but it is worth knowing why it looks
--   like a duplicate out of nowhere. Re-running this file re-syncs the counter past it.
--
-- NOTE 2 - why not a trigger instead of a DEFAULT.
--   A DEFAULT is skipped when a value is supplied, which is exactly the behaviour wanted here. A
--   BEFORE INSERT trigger would have to decide whether to overwrite what the caller sent, and
--   either answer is surprising.
--
-- NOTE 3 - verify:
--   select nextval('tools_master_code_seq');            -- 310 on first run against this data
--   select currval('tools_item_code_seq');
--   -- and end to end, rolled back:
--   --   begin;
--   --     select item_code, id from tools_create_item(1, p_brand => 'TEST', p_qty => 7,
--   --            p_txn_by => 'TESTER');
--   --     select * from v_tools_item_stock where item_code like 'FTI-%' order by item_id desc limit 1;
--   --   rollback;
