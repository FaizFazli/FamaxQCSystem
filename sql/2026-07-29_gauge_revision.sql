-- 2026-07-29  Gauge revisions: two independent-but-linked counters on every gauge.
--
-- A gauge master used to be a single mutable row. Two real events had nowhere to live:
--
--   1. The DRAWING is revised   -> the dimensions/tolerances the gauge is checked against change.
--   2. The GAUGE is replaced    -> same drawing, new physical part, because the old one wore out.
--
-- Both were handled by overwriting the master in place, which silently rewrote history:
-- re-printing a certificate from six months ago showed today's tolerances, not the ones the
-- operator actually measured against. For an ISO record that is the whole point of the document.
--
-- Numbering (agreed with QA):
--   drawing_rev  1, 2, 3 ...   bumped when the drawing is revised
--   gauge_rev    A, B, C ...   bumped when the physical gauge is replaced
--   A new drawing revision means a newly made gauge, so the LETTER RESETS TO 'A' on a drawing bump.
--
--     GA-001  Rev 1A   (every gauge in the system today)
--       gauge replaced   -> Rev 1B
--       drawing revised  -> Rev 2A     <- reset
--       gauge replaced   -> Rev 2B
--
-- Specifications are scoped by drawing_rev, so Rev 1 nominals stay readable forever.
-- Verification records are STAMPED with the revision in force when they were signed, so a
-- certificate always re-prints exactly as it was issued.
--
-- Run as the table owner (the "postgres" role is not it):
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-07-29_gauge_revision.sql
-- Re-running is safe.

-- ---------------------------------------------------------------------------
-- 1. The gauge master carries the CURRENT revision.
--
--    gauges.drawing_rev already exists in some installs as an unused TEXT column
--    (339 rows, every one NULL). Coerce it to int rather than adding a second column,
--    and refuse to run if anyone ever typed something non-numeric into it.
-- ---------------------------------------------------------------------------
do $$
declare
    col_type text;
    bad      int;
begin
    select format_type(a.atttypid, a.atttypmod)
      into col_type
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where c.relname = 'gauges' and n.nspname = 'public'
       and a.attname = 'drawing_rev' and a.attnum > 0 and not a.attisdropped;

    if col_type is null then
        alter table gauges add column drawing_rev int not null default 1;

    elsif col_type in ('integer', 'smallint', 'bigint') then
        -- already migrated (or already numeric) - just make sure the shape is right
        update gauges set drawing_rev = 1 where drawing_rev is null;
        alter table gauges alter column drawing_rev set default 1;
        alter table gauges alter column drawing_rev set not null;

    else
        execute 'select count(*) from gauges where drawing_rev is not null '
             || 'and btrim(drawing_rev::text) !~ ''^[0-9]+$''' into bad;
        if bad > 0 then
            raise exception
                'gauges.drawing_rev holds % non-numeric value(s); clean them up before migrating', bad;
        end if;

        alter table gauges alter column drawing_rev drop default;
        update gauges set drawing_rev = '1'
         where drawing_rev is null or btrim(drawing_rev::text) = '';
        alter table gauges
            alter column drawing_rev type int using btrim(drawing_rev::text)::int;
        alter table gauges alter column drawing_rev set default 1;
        alter table gauges alter column drawing_rev set not null;
    end if;
end $$;

alter table gauges add column if not exists gauge_rev text not null default 'A';

alter table gauges drop constraint if exists gauges_drawing_rev_positive;
alter table gauges add  constraint gauges_drawing_rev_positive check (drawing_rev >= 1);

alter table gauges drop constraint if exists gauges_gauge_rev_letters;
alter table gauges add  constraint gauges_gauge_rev_letters check (gauge_rev ~ '^[A-Z]+$');

-- ---------------------------------------------------------------------------
-- 2. Specifications belong to a drawing revision, not just to a gauge.
--    Existing rows are the Rev 1 spec set.
-- ---------------------------------------------------------------------------
alter table gauge_specifications add column if not exists drawing_rev int not null default 1;

-- Any uniqueness that spans (gauge_id, section_type, line_no) WITHOUT drawing_rev is what forced
-- Rev 2 to overwrite Rev 1. This install has two of them, under names that differ per environment:
--
--   gauge_spec_unique_key                                          (gauge_id, section_type, line_no)
--   gauge_specifications_gauge_id_part_no_section_type_line_no_key (gauge_id, part_no, section_type, line_no)
--
-- so match by column set instead of by name, and cover the bare-unique-index form too.
-- Both are superseded by uq_gauge_spec_rev below, which is strictly stricter (it ignores part_no),
-- so no uniqueness is lost by dropping them.
do $$
declare
    core text[] := array['gauge_id', 'section_type', 'line_no'];
    r record;
begin
    -- unique CONSTRAINTS covering the core columns but not scoped by revision
    for r in
        select con.conname as name
        from pg_constraint con
        join pg_class rel on rel.oid = con.conrelid
        join pg_namespace ns on ns.oid = rel.relnamespace
        where rel.relname = 'gauge_specifications'
          and ns.nspname  = 'public'
          and con.contype = 'u'
          and (
                select array_agg(att.attname::text)
                from unnest(con.conkey) k
                join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k
              ) @> core
          and not (
                select array_agg(att.attname::text)
                from unnest(con.conkey) k
                join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k
              ) @> array['drawing_rev']
    loop
        execute format('alter table public.gauge_specifications drop constraint %I', r.name);
        raise notice 'dropped constraint %', r.name;
    end loop;

    -- bare unique INDEXES (not backed by a constraint) with the same problem
    for r in
        select cls.relname as name
        from pg_index idx
        join pg_class cls on cls.oid = idx.indexrelid
        join pg_class rel on rel.oid = idx.indrelid
        join pg_namespace ns on ns.oid = rel.relnamespace
        where rel.relname = 'gauge_specifications'
          and ns.nspname  = 'public'
          and idx.indisunique
          and not exists (select 1 from pg_constraint c where c.conindid = idx.indexrelid)
          and (
                select array_agg(att.attname::text)
                from unnest(string_to_array(idx.indkey::text, ' ')::int2[]) k
                join pg_attribute att on att.attrelid = idx.indrelid and att.attnum = k
              ) @> core
          and not (
                select array_agg(att.attname::text)
                from unnest(string_to_array(idx.indkey::text, ' ')::int2[]) k
                join pg_attribute att on att.attrelid = idx.indrelid and att.attnum = k
              ) @> array['drawing_rev']
    loop
        execute format('drop index public.%I', r.name);
        raise notice 'dropped index %', r.name;
    end loop;
end $$;

-- One spec line per (gauge, drawing revision, section, line). This is the conflict target the
-- verification form upserts on, so Rev 2 writes new rows instead of trampling Rev 1.
create unique index if not exists uq_gauge_spec_rev
    on gauge_specifications (gauge_id, drawing_rev, section_type, line_no);

-- ---------------------------------------------------------------------------
-- 3. Stamp each verification with the revision it was performed against.
--    Everything already recorded was performed against Rev 1A by definition.
-- ---------------------------------------------------------------------------
alter table verification_records add column if not exists drawing_rev int;
alter table verification_records add column if not exists gauge_rev   text;

update verification_records set drawing_rev = 1   where drawing_rev is null;
update verification_records set gauge_rev   = 'A' where gauge_rev   is null;

-- ---------------------------------------------------------------------------
-- 4. Why each revision happened, and who authorised it.
--    gauges.id type is discovered rather than assumed (bigint vs uuid differs per install).
-- ---------------------------------------------------------------------------
do $$
declare
    gid_type text;
begin
    select format_type(a.atttypid, a.atttypmod)
      into gid_type
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where c.relname = 'gauges' and n.nspname = 'public'
       and a.attname = 'id' and a.attnum > 0 and not a.attisdropped;

    if gid_type is null then
        raise exception 'table public.gauges has no id column - run this against the gauge schema';
    end if;

    execute format($f$
        create table if not exists gauge_revision_history (
            id               bigint generated always as identity primary key,
            gauge_id         %s   not null references gauges(id) on delete cascade,

            -- 'DRAWING' bumps the number and resets the letter; 'GAUGE' bumps the letter only.
            rev_type         text not null check (rev_type in ('DRAWING', 'GAUGE')),

            from_drawing_rev int,
            from_gauge_rev   text,
            to_drawing_rev   int  not null,
            to_gauge_rev     text not null,

            drawing_no       text,          -- snapshot: the drawing no this revision was issued against
            drawing_path     text,          -- snapshot: the PDF in force from this revision onward

            reason           text not null, -- "WEAR AND TEAR", "CUSTOMER DRAWING REV C", ...
            changed_by       text not null,
            effective_date   date not null default current_date,
            created_at       timestamptz not null default now()
        )$f$, gid_type);
end $$;

create index if not exists idx_gauge_rev_hist_gauge
    on gauge_revision_history (gauge_id, created_at desc);

-- Seed the starting point so every gauge has a traceable origin row rather than appearing
-- out of nowhere at its first revision. Guarded so re-running adds nothing.
insert into gauge_revision_history
    (gauge_id, rev_type, from_drawing_rev, from_gauge_rev, to_drawing_rev, to_gauge_rev,
     drawing_no, drawing_path, reason, changed_by)
select g.id, 'DRAWING', null, null, 1, 'A',
       g.drawing_no, g.drawing_path, 'INITIAL REGISTRATION', 'SYSTEM'
  from gauges g
 where not exists (select 1 from gauge_revision_history h where h.gauge_id = g.id);

-- PostgREST roles (self-hosted Supabase): the app reads and appends revision history.
grant select, insert on gauge_revision_history to anon, authenticated;
