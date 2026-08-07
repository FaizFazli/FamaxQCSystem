-- 2026-08-07  affected_qty becomes text, so "ALL" is sayable.
--
-- 2026-08-04_ipqc_reject_record.sql added affected_qty as an integer: how many parts a single
-- out-of-spec point put at risk. The integer was the wrong shape for the answer people actually
-- give. When a dimension drifted and nobody segregated the run, the honest entry is ALL - the
-- whole lot is suspect - and an integer forces that to be guessed at as a number, or left blank.
-- Blank already means "nobody has said yet", so writing ALL as blank destroys the distinction the
-- original migration was careful to keep.
--
-- Nothing is lost by the change. All 75,419 rows have affected_qty null, so there is no number to
-- convert and no history to reinterpret.
--
-- WHAT IS AND IS NOT CONSTRAINED.
--   The column is free text, trimmed and non-empty. No vocabulary is imposed beyond that: this
--   is a box on a controlled form (REC-QAS020-04) that a quality person fills in, and the useful
--   answer is sometimes a count, sometimes ALL, and sometimes a sentence about which cavity. A
--   check constraint listing the words allowed today would be a rule invented here rather than
--   one the form has.
--
--   What IS kept is the ability to add these up. affected_qty_num is a generated column holding
--   the integer when the entry is purely a number and null otherwise, so anything counting parts
--   at risk reads it and gets a real number or an honest null - never 0 standing in for ALL.
--   Generated rather than a second editable column, for the reason tools_item.qty_on_hand was
--   retired: two columns claiming to hold the same quantity is how they come to disagree. It is
--   the same device is_ng already uses on this table.
--
-- WHY NO NORMALISING TRIGGER.
--   Data_IPQC takes writes from the IPQC entry pages on every shift, and a BEFORE trigger on it
--   is a change to that path for the sake of one field edited on a different screen. The reject
--   report trims and upper-cases ALL before it writes; the check below is what stops an
--   all-whitespace entry from any other path.
--
-- Safe to re-run. Preserves every existing row.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-07_ipqc_affected_qty_text.sql

begin;

-- The integer-era check has to go before the type changes, or the cast fails against it.
alter table "Data_IPQC" drop constraint if exists data_ipqc_affected_qty_chk;

-- Dropped and re-added rather than altered: affected_qty_num is generated FROM affected_qty, and
-- a generated column blocks a type change on the column it reads. It is re-created below from the
-- new text column. No data is lost - it never held any of its own.
alter table "Data_IPQC" drop column if exists affected_qty_num;

do $$
begin
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'Data_IPQC'
                  and column_name = 'affected_qty' and data_type = 'integer')
    then
        execute 'alter table "Data_IPQC" alter column affected_qty type text using affected_qty::text';
    end if;
end $$;

alter table "Data_IPQC" drop constraint if exists data_ipqc_affected_qty_text_chk;
alter table "Data_IPQC"
    add constraint data_ipqc_affected_qty_text_chk
    check (affected_qty is null or btrim(affected_qty) <> '');

comment on column "Data_IPQC".affected_qty is
    'How many parts this one out-of-spec point put at risk, as the person completing '
    'REC-QAS020-04 wrote it. Free text on purpose: the true answer is often ALL - the run was not '
    'segregated and the whole lot is suspect - which an integer cannot say. Null still means '
    '"nobody has answered yet", which is not the same as 0 and not the same as ALL. To count '
    'parts, read affected_qty_num.';

-- The countable half. Null whenever the entry is not purely a number, which includes ALL - and
-- that null is the honest answer to "how many", because ALL is a quantity nobody has counted.
alter table "Data_IPQC"
    add column affected_qty_num integer
    generated always as (
        case when affected_qty ~ '^[[:space:]]*[0-9]+[[:space:]]*$'
             then btrim(affected_qty)::integer end
    ) stored;

comment on column "Data_IPQC".affected_qty_num is
    'affected_qty as an integer when it is purely a number, null otherwise - including for ALL. '
    'Generated and unwritable, so it cannot drift from the text it is derived from. Sum this '
    'rather than affected_qty, and count the rows where it is null but affected_qty is not: those '
    'are the ones a total silently leaves out.';

commit;

notify pgrst, 'reload schema';

-- =====================================================================
--  NOTES
-- =====================================================================
--
-- NOTE 1 - a total over this column is never the whole story.
--   sum(affected_qty_num) skips every ALL, and an ALL is by definition the largest answer on the
--   form. Any report adding these up has to say how many rows it could not add:
--
--     select sum(affected_qty_num)                                            as counted,
--            count(*) filter (where affected_qty is not null
--                               and affected_qty_num is null)                 as not_countable
--       from "Data_IPQC" where affected_qty is not null;
--
--   That is the same rule the costing screens follow for uncosted steps: a figure travels with
--   the count of what it excludes, or it will be read as complete.
--
-- NOTE 2 - verify:
--   select count(*) from "Data_IPQC" where affected_qty is not null;   -- 0 before anything is keyed
--   update "Data_IPQC" set affected_qty = 'ALL' where id = (select min(id) from "Data_IPQC");
--   update "Data_IPQC" set affected_qty = ' 250 ' where id = (select min(id)+1 from "Data_IPQC");
--   select id, affected_qty, affected_qty_num from "Data_IPQC" where affected_qty is not null;
--        -- ALL   | null
--        -- ' 250 ' | 250
--   update "Data_IPQC" set affected_qty = '   ' where id = (select min(id) from "Data_IPQC");
--        -- ERROR: data_ipqc_affected_qty_text_chk
--   update "Data_IPQC" set affected_qty = null where affected_qty is not null;   -- clean up
