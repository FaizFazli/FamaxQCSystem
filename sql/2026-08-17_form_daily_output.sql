-- 2026-08-17  Production daily output keyed in from a phone lands in the database.
--
-- Operators away from the shop-floor PCs record daily output through a Microsoft Form. Those
-- responses already land in the SharePoint list "PRODUCTION DAILY OUTPUT" on
-- famaxtechmy.sharepoint.com/sites/FamaxProduction, and stop there — invisible to this system,
-- unreportable next to Daily_Output, unjoinable to a job order.
--
-- A Power Automate flow now pushes each response through an on-premises data gateway into the
-- table below. This file is the database half; the flow and the gateway are configured in the
-- Microsoft admin UIs.
--
-- WHY THIS IS NOT Daily_Output.
--   daily_output.html:428 (updateJobOrderProgress) sums Daily_Output.output_count into
--   JobOrder.produced_qty and stamps production_completed_at once produced >= ordered — see
--   2026-07-28_joborder_production_progress.sql. A phone form has none of the autocomplete the
--   page has: it cannot check a JO number against JobOrder or a part against Parts as you type,
--   so every key it collects is unvalidated free text. Writing that straight into Daily_Output
--   means one mistyped JO number silently closes a live job order. Form responses therefore land
--   in their own table and are promoted, if ever, as a separate deliberate step. Nothing in this
--   file touches Daily_Output or JobOrder.
--
-- WHAT A JO NUMBER ACTUALLY RESOLVES TO — MEASURED, NOT ASSUMED.
--   The intent was that the operator types a JO number and everything else is derived. Against
--   the live JobOrder table (1072 rows, 167 distinct JO numbers) that is only partly possible:
--
--     JO alone        -> one part        130 of 167   (78%)
--     JO alone        -> one process      28 of 167   (17%)   <-- not derivable
--     JO + process    -> one part        794 of 889   (89%)
--     JO + part       -> one process      43 of 245   (18%)   <-- not derivable
--     part name       -> one part number 256 of 256  (100%)
--
--   A job order is a batch that covers several parts, each routed through the same list of
--   processes. JO/171125/01328 alone spans TURNING 1-4 and MILLING 2; JO/081225/01358 at
--   TURNING 1 covers three different parts. So:
--
--   THE FORM MUST ASK FOR THE PROCESS. It cannot be derived — 83% of JO numbers carry more than
--   one. Asking for the part name too raises part resolution from 78% to exact. What the trigger
--   genuinely buys is the part number (100% from the part name) and validation of the rest.
--
--   JobOrder is ALSO NOT UNIQUE on (JO_Number, Process): 109 such pairs are duplicated across
--   292 rows, and 95 of those disagree on Part_Name. So the resolver counts DISTINCT resolved
--   values, never rows. Counting rows would mark all 109 ambiguous and the match would fail on
--   exactly the busiest job orders.
--
-- A SECOND NORMALISER, DELIBERATELY.
--   norm_key() (2026-08-07_key_whitespace.sql) trims edge whitespace and nothing else — it does
--   not fold case and does not touch punctuation, and three unique indexes are built on it, so
--   its meaning cannot be changed here without silently corrupting them. Matching a JO number
--   typed on a phone needs more than a trim: 'jo/171125/01328', 'JO 171125 01328' and
--   'JO/171125/01328' are one job order. match_key() is that looser rule, added alongside rather
--   than in place of norm_key(). Both exist on purpose; NOTE 2 says which to reach for.
--
-- Idempotent: safe to re-run. Preserves existing rows.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-17_form_daily_output.sql

begin;

-- ---------------------------------------------------------------------
-- 1. The loose matcher
-- ---------------------------------------------------------------------
--
-- Strips every character that is not a letter or a digit, anywhere in the string, then folds
-- case. This is the rule daily_output.html:381 already applies to part names before comparing
-- them, so the database and the page agree on what counts as the same value. JO numbers are
-- slash-separated (JO/171125/01328, SO/280726/01700/4), which is exactly the punctuation a
-- phone keyboard gets wrong.
--
-- Immutable: same input, same output, no table access. upper() rather than lower() to match the
-- upper(norm_key(...)) idiom the costing indexes already use, and because handleJOInput
-- (daily_output.html:414) uppercases JO numbers as they are typed.

create or replace function match_key(t text) returns text
    language sql immutable as
$$ select nullif(upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g')), '') $$;

comment on function match_key(text) is
    'Loose key for matching operator-typed text against master data: removes all non-alphanumeric '
    'characters anywhere in the string and folds case, so JO/171125/01328, jo 171125 01328 and '
    'JO17112501328 are one key. Deliberately more aggressive than norm_key(), which only trims the '
    'edges and never folds case. Use norm_key() when storing or enforcing uniqueness; use '
    'match_key() only to find a master row from something a person typed. Never store its result.';

-- ---------------------------------------------------------------------
-- 2. The mirror table
-- ---------------------------------------------------------------------
--
-- The primary key is the SharePoint item id, supplied by the flow — NOT an identity column.
-- Two reasons, both load-bearing: the Power Automate PostgreSQL connector has a known bug
-- inserting into tables whose primary key is auto-increment, and a natural key from the source
-- makes the insert idempotent, so a retried flow run or a re-run of the backfill cannot
-- duplicate a response.

create table if not exists form_daily_output (
    sp_item_id       text primary key,
    sp_created_at    timestamptz,
    sp_created_by    text,

    production_date  date,
    shift            text,
    operator         text,

    jo_number        text,
    part_name        text,
    part_number      text,
    process          text,
    machine_no       text,

    counter_start    numeric,
    counter_end      numeric,
    output_count     numeric,
    reject_qty       numeric,
    remark           text,

    match_status     text not null default 'no_jo'
                     check (match_status in ('matched','ambiguous','conflict','no_jo')),
    matched_at       timestamptz,

    review_status    text not null default 'pending'
                     check (review_status in ('pending','accepted','rejected')),

    raw              jsonb,
    ingested_at      timestamptz not null default now()
);

comment on table form_daily_output is
    'One row per Microsoft Form response mirrored from the SharePoint list PRODUCTION DAILY '
    'OUTPUT. A parallel record to Daily_Output, never a substitute: nothing here feeds '
    'JobOrder.produced_qty, because these keys are unvalidated free text typed on a phone.';

comment on column form_daily_output.sp_item_id is
    'SharePoint list item ID, supplied by the flow. Deliberately not an identity column — the '
    'PostgreSQL connector cannot insert into auto-increment keys, and this makes re-runs idempotent.';
comment on column form_daily_output.sp_created_at is
    'SharePoint Created, in UTC as SharePoint returns it. The rest of this repo writes '
    'browser-local +08:00 — do not join the two naively.';
comment on column form_daily_output.production_date is
    'The date the operator picked, stored as picked. For a night shift this is the date the shift '
    'STARTED (2026-07-28_shift_output.sql). Never derive it from sp_created_at: a night entry '
    'submitted after 20:00 MYT converts to the previous day in UTC.';
comment on column form_daily_output.jo_number is
    'As typed, edges trimmed only. Matching happens through match_key(); the typed spelling is '
    'kept so a bad entry stays diagnosable.';
comment on column form_daily_output.process is
    'The Form must collect this — only 28 of 167 job orders have a single process, so it cannot '
    'be derived. Filled from the job order only in that minority.';
comment on column form_daily_output.part_name is
    'Resolved from the job order when the response left it blank and the JO plus process name a '
    'single part; kept as typed when it disagrees, with match_status = conflict.';
comment on column form_daily_output.part_number is
    'Resolved from Parts by part name, as selectJO does at daily_output.html:402-403. 256 of 256 '
    'part names in the master resolve to exactly one part number, so this one is reliable.';
comment on column form_daily_output.output_count is
    'Net OK pieces. Computed as counter_end - counter_start - reject_qty, floored at zero, when '
    'the response did not supply it — the same rule as calculatedOutput, daily_output.html:325.';
comment on column form_daily_output.match_status is
    'matched: job order found and both part and process are known. ambiguous: job order found, '
    'but what was supplied does not narrow it to a single part or process — nothing is invented. '
    'conflict: job order found, but the operator typed a part or process it does not carry, and '
    'their value was kept. no_jo: no job order matches, often a response that arrived before the '
    'job order was created — see rematch_form_daily_output().';
comment on column form_daily_output.review_status is
    'Hook for a future promote-into-Daily_Output step. Nothing reads it yet — it exists so that '
    'step is a data change rather than a migration.';
comment on column form_daily_output.raw is
    'The whole SharePoint item as the flow sent it, so a question added to the Form is never lost '
    'just because no typed column exists for it yet.';

create index if not exists idx_form_daily_output_date
    on form_daily_output (production_date desc, shift);
create index if not exists idx_form_daily_output_jo
    on form_daily_output (jo_number);
create index if not exists idx_form_daily_output_unresolved
    on form_daily_output (match_status) where match_status <> 'matched';

-- ---------------------------------------------------------------------
-- 3. Resolving the job order
-- ---------------------------------------------------------------------
--
-- Three rules, each forced by the shape of the real data:
--
--   1. Count DISTINCT resolved values, not rows. 109 (JO, process) pairs are duplicated in
--      JobOrder. Rows that agree on part and process are one answer, not an ambiguity.
--   2. A typed value that appears nowhere under this JO is a CONFLICT, not a filter. Narrowing
--      by it would return nothing and read as 'no job order', hiding the disagreement.
--   3. Fill blanks only. A value the operator typed is never overwritten — that would destroy
--      the only evidence the disagreement exists, which is the thing that makes it fixable.

create or replace function form_daily_output_resolve() returns trigger
    language plpgsql as $$
declare
    v_total      int;
    v_proc_hits  int;
    v_part_hits  int;
    v_proc_given boolean;
    v_part_given boolean;
    v_conflict   boolean := false;
    v_parts      int;
    v_procs      int;
    v_part_pick  text;
    v_proc_pick  text;
    v_distinct   int;
    v_partno     text;
begin
    -- Trim the edges of everything a person typed. The spelling is otherwise untouched.
    new.jo_number   := norm_key(new.jo_number);
    new.part_name   := norm_key(new.part_name);
    new.part_number := norm_key(new.part_number);
    new.process     := norm_key(new.process);
    new.machine_no  := norm_key(new.machine_no);
    new.operator    := norm_key(new.operator);
    new.shift       := norm_key(new.shift);

    -- Net output, when the Form did not ask for it. Same rule as calculatedOutput.
    if new.output_count is null
       and new.counter_start is not null and new.counter_end is not null then
        new.output_count := greatest(
            new.counter_end - new.counter_start - coalesce(new.reject_qty, 0), 0);
    end if;

    new.matched_at := now();

    v_proc_given := match_key(new.process)   is not null;
    v_part_given := match_key(new.part_name) is not null;

    if match_key(new.jo_number) is null then
        new.match_status := 'no_jo';
        return new;
    end if;

    -- What exists under this JO, and whether what the operator typed appears under it at all.
    select count(*),
           count(*) filter (where match_key(j."Process")   = match_key(new.process)),
           count(*) filter (where match_key(j."Part_Name") = match_key(new.part_name))
      into v_total, v_proc_hits, v_part_hits
      from "JobOrder" j
     where match_key(j."JO_Number") = match_key(new.jo_number);

    if v_total = 0 then
        new.match_status := 'no_jo';
        return new;
    end if;

    v_conflict := (v_proc_given and v_proc_hits = 0)
               or (v_part_given and v_part_hits = 0);

    -- Narrow by whichever typed values DID appear, then see what the survivors agree on.
    select count(distinct match_key(j."Part_Name")), min(norm_key(j."Part_Name")),
           count(distinct match_key(j."Process")),   min(norm_key(j."Process"))
      into v_parts, v_part_pick, v_procs, v_proc_pick
      from "JobOrder" j
     where match_key(j."JO_Number") = match_key(new.jo_number)
       and (not (v_proc_given and v_proc_hits > 0)
            or match_key(j."Process")   = match_key(new.process))
       and (not (v_part_given and v_part_hits > 0)
            or match_key(j."Part_Name") = match_key(new.part_name));

    if not v_part_given and v_parts = 1 then new.part_name := v_part_pick; end if;
    if not v_proc_given and v_procs = 1 then new.process   := v_proc_pick; end if;

    -- Part number from Parts by part name — the one derivation that is essentially total.
    if new.part_name is not null then
        select count(distinct norm_key(p."Part_Number")), min(norm_key(p."Part_Number"))
          into v_distinct, v_partno
          from "Parts" p
         where match_key(p."Part_Name") = match_key(new.part_name);

        if new.part_number is null then
            if v_distinct = 1 then
                new.part_number := v_partno;
            end if;
        elsif v_distinct = 1
              and match_key(new.part_number) is distinct from match_key(v_partno) then
            v_conflict := true;
        end if;
    end if;

    new.match_status := case
        when v_conflict                                   then 'conflict'
        when new.part_name is null or new.process is null  then 'ambiguous'
        else 'matched'
    end;

    return new;
end $$;

comment on function form_daily_output_resolve() is
    'Resolves part name, part number and process against JobOrder and Parts from what the '
    'operator typed, and computes net output when the Form did not collect it. Fills blanks only; '
    'a typed value the job order does not carry is kept and flagged as conflict. Counts distinct '
    'resolved values rather than rows, because JobOrder holds duplicate (JO, process) pairs.';

drop trigger if exists form_daily_output_resolve_t on form_daily_output;
create trigger form_daily_output_resolve_t
    before insert or update on form_daily_output
    for each row execute function form_daily_output_resolve();

-- Responses routinely arrive before the job order exists — the operator is quicker than the
-- office. Those sit at no_jo forever otherwise. This re-fires the trigger over everything still
-- unresolved and returns how many rows changed status. Safe to run any time.

create or replace function rematch_form_daily_output() returns int
    language plpgsql as $$
declare
    v_changed int;
begin
    with before as (
        select sp_item_id, match_status
          from form_daily_output
         where match_status in ('no_jo','ambiguous')
    ), bumped as (
        update form_daily_output f
           set jo_number = f.jo_number     -- no-op assignment; fires the resolve trigger
          from before b
         where f.sp_item_id = b.sp_item_id
        returning f.sp_item_id, f.match_status, b.match_status as was
    )
    select count(*)::int into v_changed
      from bumped where match_status is distinct from was;

    return v_changed;
end $$;

comment on function rematch_form_daily_output() is
    'Re-resolves every response still at no_jo or ambiguous against current master data, and '
    'returns how many changed status. Run after creating job orders — a phone response often '
    'arrives before the JO it belongs to exists.';

-- ---------------------------------------------------------------------
-- 4. RLS
-- ---------------------------------------------------------------------
--
-- Permissive to anon, matching Parts, JobOrder, TeamsLog and the gauge tables
-- (2026-07-30_gauge_categories_and_rls.sql). The app has no Supabase Auth session — it signs in
-- against AdminCredential and every request arrives on the shared anon key — so a policy written
-- `to authenticated` would evaluate false and the table would be invisible. See NOTE 3.

alter table form_daily_output enable row level security;

drop policy if exists form_daily_output_read  on form_daily_output;
drop policy if exists form_daily_output_write on form_daily_output;

create policy form_daily_output_read on form_daily_output
    for select to anon, authenticated using (true);
create policy form_daily_output_write on form_daily_output
    for all to anon, authenticated using (true) with check (true);

grant select, insert, update, delete on form_daily_output to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - what the Form must collect, and what the flow must send.
--   The Form has to ask for JO NUMBER and PROCESS. Process is not derivable (28 of 167 job
--   orders have only one). Ask for PART NAME too if you want the match exact rather than 89%.
--   Counter start and end are enough for the output figure — the trigger computes it.
--
--   Flow sends: sp_item_id (the SharePoint ID), sp_created_at, sp_created_by, production_date,
--   shift, operator, jo_number, process, part_name, machine_no, counter_start, counter_end,
--   reject_qty, remark, raw.
--   Flow leaves unmapped: part_number, output_count, match_status, matched_at.
--
--   Numbers arrive from SharePoint as text. Guard the empty string in the flow — int('') throws
--   and fails the whole run. Use if(empty(x), null, int(x)).
--
-- NOTE 2 - norm_key or match_key?
--   norm_key()  storing a value, and any unique index. Trims edges, keeps case and punctuation.
--   match_key() finding a master row from something a person typed. Strips all punctuation
--               everywhere and folds case. Never store a match_key() result — it is a lookup key,
--               not the value.
--
-- NOTE 3 - what the permissive policy costs.
--   Anyone holding the anon key (it ships in assets/app-config.js, so: anyone who can load the
--   site) can read and write this table directly. That is already true of Parts, JobOrder and
--   SalesOrders; this table is consistent with them rather than introducing anything new. It also
--   matters less than it looks: the anon key is signed with Supabase's published default
--   self-hosting secret, so anyone who can reach :8000 can already mint a service_role token.
--   Rotating JWT_SECRET is the fix, and it is a separate, larger job.
--
-- NOTE 4 - verify. JO/171125/01328 spans TURNING 1-4 and MILLING 2 on one part; JO/081225/01358
--   at TURNING 1 covers three different parts. Both are live rows, so both make good tests.
--
--   -- exact: JO + process + the part named -> matched, part number filled, output 145
--   insert into form_daily_output (sp_item_id, jo_number, process, counter_start, counter_end,
--                                  reject_qty)
--        values ('t1', 'JO/171125/01328', 'TURNING 1', 100, 250, 5);
--   select part_name, part_number, process, output_count, match_status
--     from form_daily_output where sp_item_id = 't1';
--
--   -- punctuation and case must not be a barrier: also matched, same resolution
--   insert into form_daily_output (sp_item_id, jo_number, process)
--        values ('t2', 'jo 171125 01328', 'turning 1');
--   select part_name, match_status from form_daily_output where sp_item_id = 't2';
--
--   -- no process given, JO has five -> ambiguous, nothing invented
--   insert into form_daily_output (sp_item_id, jo_number) values ('t3', 'JO/171125/01328');
--   select part_name, process, match_status from form_daily_output where sp_item_id = 't3';
--
--   -- a JO+process covering three parts -> ambiguous until the part is named
--   insert into form_daily_output (sp_item_id, jo_number, process)
--        values ('t4', 'JO/081225/01358', 'TURNING 1');
--   select part_name, match_status from form_daily_output where sp_item_id = 't4';   -- ambiguous
--   insert into form_daily_output (sp_item_id, jo_number, process, part_name)
--        values ('t5', 'JO/081225/01358', 'TURNING 1', 'DISQUE (K315D.08)');
--   select part_number, match_status from form_daily_output where sp_item_id = 't5'; -- matched
--
--   -- a process this JO does not carry -> conflict, and the typed value survives
--   insert into form_daily_output (sp_item_id, jo_number, process)
--        values ('t6', 'JO/171125/01328', 'ANODISING');
--   select process, match_status from form_daily_output where sp_item_id = 't6';
--                                                              -- 'ANODISING' | conflict
--
--   insert into form_daily_output (sp_item_id, jo_number) values ('t7', 'NOSUCHJO');
--   select match_status from form_daily_output where sp_item_id = 't7';              -- no_jo
--
--   select rematch_form_daily_output();
--   delete from form_daily_output where sp_item_id in ('t1','t2','t3','t4','t5','t6','t7');
--
--   -- and the thing this migration must never do:
--   select count(*) from "Daily_Output";     -- unchanged by everything above
