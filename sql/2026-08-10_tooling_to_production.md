# Putting the tooling module on production — 2026-08-10

Production has the tooling **shape** and none of the tooling **data**. All nine `tools_*`
tables read zero rows on `192.168.0.5`, while the development copy holds 8 categories, 13
processes, 45 parts, 309 tool types, 345 stockable items, 138 assignments and 185 opening
movements. This is the order that closes that gap, and the checks that prove it closed.

## What is actually different

The two databases drifted in both directions, so neither is simply ahead. Read this before
assuming one should be made to match the other.

| | production `192.168.0.5` | development copy |
|---|---|---|
| 8 rows / 309 tools / 345 items / 185 movements | **none** | all of it |
| 5 × `tools_v_*` views | yes | **missing** |
| 7 functions, 3 triggers | yes | **missing** — has only `tools_create_item` |
| constraint + id sequence names | renamed (`tools_item_pkey`, `tools_master_id_seq`) | pre-rename (`out_tool_item_pkey`, `out_tool_id_seq`) |
| `tools_master_code_seq` / `tools_item_code_seq` + defaults | **missing** | yes |
| partial unique index on `tools_usage` | **missing** | yes |
| `v_tools_item_stock` | yes | yes |

So production is missing exactly two migrations that are already written and already in `sql/`,
plus the data. **Nothing here renames production's constraints back, and nothing drops its
views or triggers** — those are the newer, better half, and the development copy is the one
behind on them. Making production "match local" literally would throw them away.

## Order, and why it is this one

Run as a superuser, against production. Each step is idempotent or guarded.

```bash
PROD="-h 192.168.0.5 -p 5432 -U postgres.your-tenant-id -d postgres"

# 1. the data
psql $PROD -v ON_ERROR_STOP=1 -f sql/data/2026-08-10_tooling_dataset.sql

# 2. the partial unique index — after the data, so it fails loudly if the rows contradict it
psql $PROD -v ON_ERROR_STOP=1 -f sql/2026-08-06_tooling_usage_unique.sql

# 3. the running numbers — MUST be after the data; it computes setval FROM the rows
psql $PROD -v ON_ERROR_STOP=1 -f sql/2026-08-06_tooling_codes_and_intake.sql
```

Step 3 last is the part that matters. `2026-08-06_tooling_codes_and_intake.sql` seeds
`tools_master_code_seq` from `max(tool_code)` in the table. Run it against the empty tables and
both sequences start at 1, and the first tool anyone adds is handed `FTL-0001` — a code 309
existing rows already use, which the UNIQUE constraint then rejects.

## Checks that must pass afterwards

```sql
select (select count(*) from tools_master) as tools,      -- 309
       (select count(*) from tools_item)   as items,      -- 345
       (select count(*) from tools_txn)    as movements,  -- 185
       (select sum(qty_on_hand) from tools_item) as on_hand,  -- 2484
       (select sum(qty) from tools_txn)          as ledger;   -- 2484
```

`on_hand` and `ledger` must both read **2484**. If `on_hand` comes back **4968**, the load ran
with `tools_txn_apply_t` live: the development copy's `qty_on_hand` was already backfilled to
2484 by `2026-08-05_tooling_access.sql`, and the trigger added the same ledger on top. The data
file sets `session_replication_role = replica` to prevent exactly this. Re-run from an empty
set of tables rather than trying to subtract.

Then confirm the next codes continue rather than collide:

```sql
select 'FTL-'||lpad(nextval('tools_master_code_seq')::text,4,'0');  -- FTL-0310
select 'FTI-'||lpad(nextval('tools_item_code_seq')::text,5,'0');    -- FTI-00346
```

Those two calls consume a number each. That is harmless — the codes are a running number, not a
dense sequence — but it means the first real tool added lands on `FTL-0311`.

## Rehearsed, not assumed

This order was replayed on 2026-08-10 into an empty database built from
`sql/schema/tools.sql` (production's shape, captured the same day). All four steps ran with
zero errors, and the result equalled the development copy on every count above: 309/345/185,
`qty_on_hand` 2484 against a ledger of 2484, `max(tool_code)` `FTL-0309`, next code `FTL-0310`,
and `tools_v_stock` returning 345 rows totalling 2484.

## Still open after this

The development copy remains structurally behind production — no `tools_v_*` views, no
triggers, and one function against production's seven. Tooling screens developed there are
being written against a shape the server does not have: `tools_v_stock` resolves on production
and does not exist locally, and `qty_on_hand` is maintained by a trigger there and by nothing
here. `sql/schema/tools.sql` is the file to replay locally to close it, and the five views in
it are recorded in no migration at all — they came from the original import, not from `sql/`.
