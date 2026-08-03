-- 2026-08-03  Subcontractor delivery: what went out, what came back, and under which DO.
--
-- Parts sent out for plating, heat treatment or outside machining leave on a Delivery
-- Order and come back — usually in more than one batch — under the subcontractor's own
-- return DO. None of that was recorded anywhere. There is no DeliveryOrder master table
-- in this system at all; the only trace a DO number left was the free-text, optional
-- "DO Number" box on the inspection form, which QC might fill in and might spell three
-- different ways. So "what is still at the subcon?" and "what was inspected against this
-- DO?" were questions you answered by asking around.
--
-- Three tables, deliberately flat, matching how the rest of this schema is built:
--
--   subcontractor        who we send to. A strict list, so the same vendor is spelled
--                        one way. The page's "Add Subcon" button inserts here.
--
--   subcon_delivery_out  ONE ROW = ONE PART LINE ON ONE OUTGOING DO. A DO carrying
--                        three parts is three rows sharing do_number. No separate DO
--                        header table — the same denormalized text-key convention as
--                        JobOrder (keyed by JO_Number) and TravelerSignoff.
--
--   subcon_delivery_in   ONE ROW = ONE RECEIPT AGAINST ONE OUTGOING LINE. Many rows per
--                        out line is the normal case: 500 sent, 200 back, 250 back,
--                        50 outstanding. Balance is out.quantity minus the sum of these.
--
-- subcon_delivery_in carries a REAL foreign key to subcon_delivery_out (unlike
-- TravelerSignoff, which links by text). That is on purpose: it lets PostgREST embed the
-- parent line in one request, which is how the inspection form loads the DO dropdown:
--
--   /subcon_delivery_in?select=return_do_number,subcon_delivery_out(part_name,part_no)
--
-- There is NO foreign key to Parts. Part_Name over there is not unique-constrained, the
-- whole codebase links parts by text, and a subcon job may involve a part that was never
-- registered — which is what from_masterlist records.
--
-- return_do_number is the number QC inspects against. It is stored uppercased by the
-- page, because InspectionRecord.DO_Number is uppercased on write by the inspection form
-- and the two are matched as plain text.
--
-- Run as the table owner (the "postgres" role is not it):
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-03_subcon_delivery.sql
-- Idempotent: safe to re-run. Preserves existing rows.

begin;

-- ---------------------------------------------------------------------
-- 1. The subcontractor list
-- ---------------------------------------------------------------------

create table if not exists subcontractor (
    id          bigint generated always as identity primary key,
    name        text not null unique,
    address     text,
    tel         text,
    created_at  timestamptz not null default now(),
    created_by  text
);

-- ---------------------------------------------------------------------
-- 2. Outgoing: one row per part line on a DO
-- ---------------------------------------------------------------------

create table if not exists subcon_delivery_out (
    id               bigint generated always as identity primary key,
    do_number        text not null,
    subcon_name      text not null,     -- denormalized, like JO_Number elsewhere
    part_name        text not null,     -- "DESCRIPTION (PART-NO)" when picked from Parts
    part_no          text,              -- extracted from the brackets, or typed
    from_masterlist  boolean not null default true,
    quantity         numeric not null check (quantity > 0),
    delivery_date    date not null,
    remark           text,
    -- Running total of what has come back, and whether anything is still out.
    -- Maintained by the trigger in part 4 — never write these from the app.
    -- They exist so "what is still at the subcon?" is a server-side filter
    -- (.eq('is_open', true)); computing the balance in the browser would mean
    -- paging over rows the page then hides, and page 1 showing 3 lines.
    received_qty     numeric not null default 0,
    is_open          boolean not null default true,
    created_at       timestamptz not null default now(),
    created_by       text,
    -- the same part twice on one DO is a data-entry slip, not two shipments
    unique (do_number, part_name)
);

-- Tables created before today's run predate the two columns above.
alter table subcon_delivery_out add column if not exists received_qty numeric not null default 0;
alter table subcon_delivery_out add column if not exists is_open      boolean not null default true;

-- ---------------------------------------------------------------------
-- 3. Incoming: one row per receipt against an outgoing line
-- ---------------------------------------------------------------------

create table if not exists subcon_delivery_in (
    id                bigint generated always as identity primary key,
    out_line_id       bigint not null
                      references subcon_delivery_out (id) on delete cascade,
    out_do_number     text not null,    -- copied so History can search without a join
    return_do_number  text not null,    -- the subcon's DO — what QC inspects against
    receive_date      date not null,
    quantity          numeric not null check (quantity > 0),
    remark            text,
    created_at        timestamptz not null default now(),
    created_by        text
);

create index if not exists idx_subcon_out_do   on subcon_delivery_out (do_number);
create index if not exists idx_subcon_out_part on subcon_delivery_out (part_name);
create index if not exists idx_subcon_out_open on subcon_delivery_out (is_open);
create index if not exists idx_subcon_in_out   on subcon_delivery_in  (out_line_id);
create index if not exists idx_subcon_in_rdo   on subcon_delivery_in  (return_do_number);

-- ---------------------------------------------------------------------
-- 4. Keep received_qty / is_open true to the receipts
-- ---------------------------------------------------------------------
--
-- Recomputed from scratch rather than incremented, so an edited or deleted
-- receipt cannot leave the balance drifting. is_open stays true when more comes
-- back than went out (over-delivery is allowed and warned about on the page, not
-- blocked) only if the balance is still positive.

create or replace function subcon_refresh_out_line() returns trigger
language plpgsql as $$
declare line_id bigint;
begin
    line_id := coalesce(new.out_line_id, old.out_line_id);
    update subcon_delivery_out o
       set received_qty = coalesce((select sum(i.quantity)
                                      from subcon_delivery_in i
                                     where i.out_line_id = o.id), 0),
           is_open      = coalesce((select sum(i.quantity)
                                      from subcon_delivery_in i
                                     where i.out_line_id = o.id), 0) < o.quantity
     where o.id = line_id;
    return null;
end $$;

drop trigger if exists trg_subcon_in_refresh on subcon_delivery_in;
create trigger trg_subcon_in_refresh
    after insert or update or delete on subcon_delivery_in
    for each row execute function subcon_refresh_out_line();

-- Editing the sent quantity moves the balance too.
create or replace function subcon_refresh_on_qty() returns trigger
language plpgsql as $$
begin
    new.is_open := new.received_qty < new.quantity;
    return new;
end $$;

drop trigger if exists trg_subcon_out_qty on subcon_delivery_out;
create trigger trg_subcon_out_qty
    before update of quantity on subcon_delivery_out
    for each row execute function subcon_refresh_on_qty();

-- Backfill, so re-running this file after rows exist leaves them correct.
update subcon_delivery_out o
   set received_qty = coalesce((select sum(i.quantity) from subcon_delivery_in i
                                 where i.out_line_id = o.id), 0),
       is_open      = coalesce((select sum(i.quantity) from subcon_delivery_in i
                                 where i.out_line_id = o.id), 0) < o.quantity;

-- ---------------------------------------------------------------------
-- 5. RLS: grant the application's anon role
-- ---------------------------------------------------------------------
--
-- Every policy is `to anon, authenticated`, because this app has no Supabase Auth
-- session — it signs in against AdminCredential and keeps the result in sessionStorage,
-- so every request arrives on the shared anon key and auth.jwt() is null. Policies that
-- grant only `authenticated` evaluate false: reads return [] and writes return 401.
-- Authorisation stays where this app has always put it, in the page's access-level check
-- (WRITE_ROLES on subcon_delivery.html, mirroring AdminLogin's grant for the card).
-- Same trade as sql/2026-07-30_gauge_categories_and_rls.sql.

do $$
declare t text;
begin
  foreach t in array array['subcontractor','subcon_delivery_out','subcon_delivery_in']
  loop
    execute format('alter table %I enable row level security', t);
    -- Table privileges as well as policies: Supabase's default privileges only reach
    -- tables created by the role that set them, and this file may be run as another.
    execute format('grant select, insert, update, delete on %I to anon, authenticated', t);
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

-- The identity sequences need to be usable by the same roles as the tables.
grant usage, select on all sequences in schema public to anon, authenticated;

commit;

-- PostgREST exposes the tables automatically once created; no server change required.
-- If the dropdown on the inspection form stays empty after this runs, reload PostgREST's
-- schema cache:  docker exec supabase-db psql -U supabase_admin -d postgres \
--                    -c "notify pgrst, 'reload schema'"
