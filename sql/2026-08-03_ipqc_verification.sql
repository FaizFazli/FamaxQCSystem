-- 2026-08-03  Sign-off trail for IPQC measurement batches.
--
-- Until now an IPQC submission was final the moment the inspector pressed Submit: the readings
-- landed in Data_IPQC and nobody countersigned them. Buy-off already has that second pair of
-- eyes (buyoff_approvals + BUYOFF-approvals.html); IPQC did not. These columns give IPQC the
-- same trail, without a second table.
--
-- WHY ON THE ROW, NOT A SEPARATE TABLE
--   Buy-off could use its own table because Data_BUYOFF carries Attempt_Group — a real batch key
--   to point at. Data_IPQC has no such column: a submission is only recognisable as "every row
--   sharing one created_at", because the whole batch goes in as a single multi-row INSERT and
--   now() is constant within a transaction. Keying a side table on a timestamp would be fragile,
--   so the verdict is stamped on each row of the batch instead. The verification page writes all
--   of a batch's rows by id in one update, so they move together.
--
-- STATE MODEL
--   verify_status NULL      -> pending, nobody has looked at it yet
--                 VERIFIED  -> countersigned; readings accepted as recorded
--                 REJECTED  -> countersigned as not acceptable; verify_remark says why
--   The other four columns are only meaningful once verify_status is set.
--
-- Note this is NOT the same question as special_accept, which already exists on this table.
-- special_accept is a concession on an out-of-spec reading — "ship it anyway". verify_status is
-- "a second person has reviewed this batch". A batch can be verified with a concession on it.
--
-- Nullable on purpose: ~12,800 rows already exist and none of them were ever countersigned.
-- Backfilling them as VERIFIED would invent a signature that nobody gave, so they stay pending
-- and the page's date filter keeps them out of the way.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-03_ipqc_verification.sql
-- Re-running is safe.

alter table "Data_IPQC" add column if not exists verify_status      text;
alter table "Data_IPQC" add column if not exists verified_by        text;
alter table "Data_IPQC" add column if not exists verifier_position  text;
alter table "Data_IPQC" add column if not exists verified_at        timestamptz;
alter table "Data_IPQC" add column if not exists verify_remark      text;

-- Only the two verdicts, or nothing. Guards against a typo in a future caller quietly creating
-- a third state that the pending filter would then never show.
alter table "Data_IPQC" drop constraint if exists data_ipqc_verify_status_chk;
alter table "Data_IPQC"
  add constraint data_ipqc_verify_status_chk
  check (verify_status is null or verify_status in ('VERIFIED', 'REJECTED'));

-- The page's default view is "pending, newest first". Partial, because the pending set stays
-- small while the verified set grows without bound — there is no reason to index the latter.
create index if not exists idx_data_ipqc_pending
  on "Data_IPQC" (created_at desc)
  where verify_status is null;

-- Reviewing what one person signed off, and the reverse lookup for an audit.
create index if not exists idx_data_ipqc_verified
  on "Data_IPQC" (verify_status, verified_at desc)
  where verify_status is not null;

comment on column "Data_IPQC".verify_status is
    'NULL = awaiting sign-off, VERIFIED / REJECTED = countersigned by a second person. '
    'Distinct from special_accept, which is a concession on an out-of-spec reading.';
comment on column "Data_IPQC".verified_by is
    'Name from EmployeeTable of whoever countersigned. Identity was proven by the PIN held in '
    'EmployeeTable.pin - the PIN itself is never stored here.';
comment on column "Data_IPQC".verify_remark is
    'Verifier note. Optional on VERIFIED, required on REJECTED.';


-- ---------------------------------------------------------------------------
-- 2. The batch view the verification page lists from.
--
-- WHY A VIEW AND NOT CLIENT-SIDE GROUPING
--   The page thinks in submissions; the table stores measurement points. Grouping in the
--   browser means downloading every point first, and a busy month is real: March 2026 alone
--   holds 14,416 points across 1,787 submissions. Pulling that to draw a 50-row list is absurd
--   and would silently truncate behind any row cap. Grouping here lets the page ask for one
--   page of submissions, filtered and ordered, and get back kilobytes.
-- ---------------------------------------------------------------------------

-- Torn down and rebuilt on every run, in dependency order, rather than patched in place.
--
-- The reason is the stored generated column below: Postgres computes it at write time and never
-- revisits it, so editing the function body leaves 75,000 rows holding verdicts from the OLD
-- rule with nothing to indicate they are stale. That is exactly how the capture-group bug would
-- have survived its own fix. Dropping the column forces a full recompute, which is the only
-- honest way to change the rule. Costs a table rewrite - a few seconds here - per run.
drop view if exists v_ipqc_batch;
alter table "Data_IPQC" drop column if exists is_ng;

-- The spec rule, in SQL. This is the twin of validateReading() in IPQC-page2.html: a reading
-- must not count as out-of-spec in one place and in-spec in another. If the rule ever changes,
-- both change together.
--
-- It had a third copy, readingState() in ipqc_verification.html, which went with that page when
-- sign-off moved into the Data Editor. validateSpec() in table_editor.html agrees with this
-- function on every reading, including the STOP/DOWNTIME exemption, and differs only in that it
-- leaves a special-accepted row unmarked - it colours cells for someone deciding what still
-- needs accepting, not deciding whether a part passed.
--
-- The leading-number substring mimics JavaScript's parseFloat, which stops at the first
-- character it cannot use - so "5.28mm" reads as 5.28 here exactly as it does there, rather
-- than failing a strict numeric cast and being reported as a false rejection.
--
-- The (?: ) is load-bearing, not tidiness. substring(text from pattern) returns the first
-- CAPTURE GROUP when the pattern has one, and only the whole match when it does not. Written
-- with a capturing '(\.\d+)?' the function reads "31.04" as ".04", decides 0.04 is below a
-- 30.5 lower limit, and reports a good part as out of spec. That is not hypothetical: it
-- disagreed with the JavaScript rule on 19,162 of the 75,418 rows in this table before the
-- group was made non-capturing.
create or replace function ipqc_reading_ng(reading text, lsl text, usl text)
returns boolean
language sql
immutable
as $$
    select case
        -- No reading is not a failed reading; the point was simply left blank.
        when reading is null or btrim(reading) = '' then false
        -- A machine-stop record writes the stop type into the reading slots. Not a measurement.
        when upper(btrim(reading)) in ('STOP', 'DOWNTIME') then false
        -- Attribute specs: pass is OK/GO, anything else fails.
        when lower(coalesce(lsl, '')) in ('ok', 'go')
            then lower(btrim(reading)) not in ('ok', 'go')
        when lower(coalesce(usl, '')) in ('ng', 'nogo')
            then lower(btrim(reading)) in ('ng', 'nogo')
        -- Variable specs: only judgeable when both limits are numbers.
        when substring(btrim(lsl) from '^-?(?:\d+(?:\.\d+)?|\.\d+)') is not null
         and substring(btrim(usl) from '^-?(?:\d+(?:\.\d+)?|\.\d+)') is not null
            then substring(btrim(reading) from '^-?(?:\d+(?:\.\d+)?|\.\d+)') is null
              or substring(btrim(reading) from '^-?(?:\d+(?:\.\d+)?|\.\d+)')::numeric
                     < substring(btrim(lsl) from '^-?(?:\d+(?:\.\d+)?|\.\d+)')::numeric
              or substring(btrim(reading) from '^-?(?:\d+(?:\.\d+)?|\.\d+)')::numeric
                     > substring(btrim(usl) from '^-?(?:\d+(?:\.\d+)?|\.\d+)')::numeric
        -- Limits that are neither numeric nor the attribute words cannot be judged. Saying
        -- "in spec" beats raising an alarm nobody can act on.
        else false
    end;
$$;

comment on function ipqc_reading_ng(text, text, text) is
    'True when one reading is outside its spec. Mirrors validateReading() in IPQC-page2.html '
    'and validateSpec() in table_editor.html - keep the three in step. validateSpec '
    'additionally leaves a special-accepted row unmarked.';

-- Answered once per row at write time, not three times per row on every list query.
--
-- The measurement is that per-query evaluation dominated everything else: aggregating the batch
-- list cost 2.9s, of which ~2.85s was 226,000 calls to the function above on rows the user was
-- never going to see. Stored here it costs a byte a row and the list query stops caring.
--
-- Safe as a generated column because ipqc_reading_ng is immutable: the verdict depends only on
-- the three readings and the two limits, all of which live on the row.
alter table "Data_IPQC" add column is_ng boolean
    generated always as (
        ipqc_reading_ng("Reading_1", "LSL_OK", "USL_NG")
     or ipqc_reading_ng("Reading_2", "LSL_OK", "USL_NG")
     or ipqc_reading_ng("Reading_3", "LSL_OK", "USL_NG")
    ) stored;

comment on column "Data_IPQC".is_ng is
    'True when any of the three readings is outside spec. Maintained by the database - never '
    'write to it. Derived from ipqc_reading_ng(), so it cannot drift from the readings.';

-- One row per IPQC review.
--
-- The batch key is (day, JO, part, process, machine) — deliberately the calendar DAY and not the
-- insert timestamp. An inspector measures the same job on the same machine several times through
-- a shift, so keying on created_at produced a separate review for every round: five sign-offs
-- for what QA regards as one day's work on one job. Same date, same JO, same part, same process,
-- same machine is one review.
--
-- The day is the MALAYSIAN one. created_at is timestamptz, so ::date alone would cut the day at
-- 08:00 local and file a morning shift's first hour under the previous date. Malaysia has had no
-- DST since 1982, so the +08 offset is safe to rely on both here and in the page's JavaScript.
--
-- The inspector is NOT in the key: two people can measure the same job on the same day, and that
-- is still one review.
--
-- Only one name and a "there were others" flag are carried here, not the full list. Collecting
-- every name with array_agg costs more than everything else in this view put together: it pushes
-- Postgres off HashAggregate onto a GroupAggregate fed by a full sort of all 75,419 rows, spilling
-- 6-9MB to disk. Measured, that is 688ms against 128ms for the identical query without it. The
-- list does not need the names anyway - opening a review loads that review's rows, so the page
-- derives the exact set of inspectors from the data already in front of it, which is also what it
-- checks against when refusing to let someone sign off their own readings.
create or replace view v_ipqc_batch as
select
    (d.created_at at time zone 'Asia/Kuala_Lumpur')::date     as batch_day,
    d."JO_Number" as jo_number,
    d."Part_Name" as part_name,
    d."Process"   as process,
    d."Machine"   as machine,
    min(d."Person")                                          as person,
    min(d."Person") <> max(d."Person")                       as multi_person,
    -- The span of the day's rounds, for the list to show and for nothing else.
    min(d.created_at)                                        as first_at,
    max(d.created_at)                                        as last_at,
    min(d."Remarks")                                         as remarks,
    count(*)::int                                            as points,
    count(*) filter (where d.is_ng)::int                     as ng_points,
    count(*) filter (where coalesce(d.special_accept, 0) <> 0)::int as concessions,
    -- Every point a stop record = the batch is a machine stop, not a measurement run.
    bool_and(upper(btrim(coalesce(d."Reading_1", ''))) in ('STOP', 'DOWNTIME')) as is_stop,
    -- A review is signed off in one update, so a split status means either the table was
    -- hand-edited or a later round landed after the day was signed. Either way the page shows it
    -- as inconsistent and refuses to sign, rather than guessing which verdict was meant.
    -- coalesce inside the aggregates makes an all-null batch read as PENDING.
    case
        when min(coalesce(d.verify_status, 'PENDING')) <> max(coalesce(d.verify_status, 'PENDING'))
            then 'MIXED'
        else min(coalesce(d.verify_status, 'PENDING'))
    end                                                      as status,
    min(d.verified_by)       as verified_by,
    min(d.verifier_position) as verifier_position,
    min(d.verified_at)       as verified_at,
    min(d.verify_remark)     as verify_remark
from "Data_IPQC" d
group by (d.created_at at time zone 'Asia/Kuala_Lumpur')::date,
         d."JO_Number", d."Part_Name", d."Process", d."Machine";

comment on view v_ipqc_batch is
    'One row per IPQC review: a day''s measuring of one job, on one machine, for one process. '
    'Rounds taken at different times of the same day collapse into a single row. Readings are '
    'fetched from Data_IPQC only for the review actually being opened.';

-- The page reads this with the anon key, same as it reads Data_IPQC (which has RLS disabled).
grant select on v_ipqc_batch to anon, authenticated;

-- Supports the day-bounded fetch the page makes when a review is opened, and the month filter.
--
-- It deliberately does NOT try to match the view's GROUP BY. It cannot: the leading key is now an
-- expression over created_at, so no plain index on the column can present the groups pre-sorted,
-- and Postgres hash-aggregates the table for the list either way. That costs ~200ms here and is
-- only affordable because is_ng is stored rather than computed per query - without it the same
-- plan took 2.9s. If this table grows several times over, the next step is a materialised view
-- refreshed on write, not another index.
drop index if exists idx_data_ipqc_batch_key;    -- superseded
create index if not exists idx_data_ipqc_batch_order
  on "Data_IPQC" (created_at, "JO_Number", "Part_Name", "Process", "Machine");

-- Teaches the planner how many reviews the GROUP BY actually produces, and it is the difference
-- between a 128ms page and a 910ms one.
--
-- Without it Postgres estimates the group count by multiplying the distinct counts of the five
-- key columns independently. They are anything but independent - a machine runs one job, a job is
-- one part - so it predicted 9,396 groups against a real 3,404, decided the hash table would not
-- fit in work_mem, and fell back to a GroupAggregate that sorted all 75,419 rows and spilled 9MB
-- to disk. The hash it was avoiding actually needs 2.2MB.
--
-- Raising work_mem globally would also have "fixed" it, by giving every sort in the application
-- more memory to paper over one bad estimate. Correcting the estimate is the smaller change.
create statistics if not exists data_ipqc_batch_ndistinct (ndistinct) on
    ((created_at at time zone 'Asia/Kuala_Lumpur')::date),
    "JO_Number", "Part_Name", "Process", "Machine"
    from "Data_IPQC";

-- Extended statistics are only populated by ANALYZE, so the object alone changes nothing.
analyze "Data_IPQC";

-- PostgREST caches the schema; without this the new view 404s until the container restarts.
notify pgrst, 'reload schema';

