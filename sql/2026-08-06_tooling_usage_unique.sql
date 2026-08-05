-- 2026-08-06  Close the duplicate hole in tools_usage, before a screen can dig it.
--
-- tools_usage carries UNIQUE (tool_id, part_id, process_id), which does not constrain what it
-- looks like it constrains. Postgres treats NULLs as distinct in a unique constraint, so the same
-- tool on the same part with NO process can be inserted again and again - each row is "different"
-- because null <> null. 6 of the 138 rows have a null process today and none is a duplicate, so
-- the hole has never been dug. It has also never been reachable: until 2026-08-05_tooling_access
-- these tables could not be written by this application at all.
--
-- Tooling Assignment is the screen that can dig it, so the index lands with that screen. A partial
-- unique index is the whole fix: it applies exactly where the constraint stops applying.
--
-- WHY NOT MAKE process_id NOT NULL INSTEAD
--   Because "this tool is used on this part, and it is not tied to one process" is a real and
--   useful statement - a deburring tool, a holder that serves every operation. Six rows already
--   say it. Forcing a process would make those rows lie, and inventing an 'ANY' process row to
--   point them at would put the same meaning in a place where nothing else can see it.
--
-- Safe to re-run. Fails loudly rather than silently if duplicates are ever introduced by another
-- route, which is the point of it.
--
-- Run as the table owner, AFTER 2026-08-05_tooling_access.sql:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-06_tooling_usage_unique.sql

begin;

create unique index if not exists tools_usage_tool_part_noproc_uq
    on tools_usage (tool_id, part_id)
 where process_id is null;

comment on index tools_usage_tool_part_noproc_uq is
    'Completes out_tool_usage_tool_id_part_id_process_id_key, which cannot cover the rows it '
    'most needs to: Postgres treats NULLs as distinct, so a unique constraint including a '
    'nullable process_id permits unlimited (tool, part, no process) duplicates. This index '
    'forbids them. Together the two mean one row per tool per part per process, with or without '
    'a process named.';

commit;

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - the other half of this is in the page, and has to be.
--   An index rejects a duplicate; it does not explain one. Tooling Assignment checks for the
--   existing row first and offers to edit it, so the normal case never reaches the constraint.
--   The index is there for the abnormal one - two people adding the same assignment at once, or a
--   write that bypasses the page - which is exactly the case a UI check cannot cover.
--
-- NOTE 2 - verify:
--   select count(*) from tools_usage where process_id is null;              -- 6
--   -- and that it actually bites:
--   --   insert into tools_usage (tool_id, part_id) values (1, 1);          -- ok first time
--   --   insert into tools_usage (tool_id, part_id) values (1, 1);          -- 23505
