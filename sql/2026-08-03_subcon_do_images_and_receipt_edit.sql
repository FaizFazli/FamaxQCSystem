-- 2026-08-03  Subcon delivery, part 2: photos of the outgoing DO, and editable return DOs.
--
-- Follows sql/2026-08-03_subcon_delivery.sql. Two things the first cut did not cover.
--
-- 1. PHOTOS OF THE DELIVERY ORDER
--
--    Store wants the scanned/photographed DO kept with the record — the paper is what the
--    subcontractor signs, and it is the only proof of what physically left. More than one
--    image per DO is normal: a two-page DO, a re-shot page, the signed copy that comes back.
--
--    Keyed by DO NUMBER, not by part line. A DO carrying three parts is three rows in
--    subcon_delivery_out but one piece of paper, so one set of photos. Deliberately NOT
--    attached to a receipt either: the images belong to what went OUT.
--
--    Same shape the gauge module uses (sql/2026-07-29_gauge_image.sql): the file goes to a
--    public Supabase Storage bucket and the row keeps the public URL. storage_path is kept
--    alongside so a delete can remove the object as well as the row.
--
-- 2. EDITING A RETURN DO NUMBER, AND CARRYING THE INSPECTIONS WITH IT
--
--    Goods often arrive before the subcontractor's paperwork does, so store books them in
--    under a temporary number and QC inspects against it the same day. When the real DO
--    turns up, renaming the receipt alone would strand every inspection filed under the
--    placeholder: InspectionRecord.DO_Number is plain text with no key back to the receipt,
--    so the history panel would simply go quiet and say "not inspected".
--
--    subcon_update_receipt() renames both in ONE transaction and returns how many
--    inspection rows moved. This is the first RPC in the codebase — everything else talks
--    to PostgREST tables directly — and it earns the exception: two separate PATCHes from
--    the browser can half-fail, and the half that fails silently detaches QC history from
--    its delivery, which is the exact thing this module exists to prevent.
--
--    The rename matches on DO_Number text, so it moves EVERY inspection filed under the old
--    number. That is the intent (there is no other link), but it means a placeholder should
--    be distinctive — "TEMP-1" typed twice in one week would merge two deliveries' history.
--    The page shows the affected row count before saving so this is never a surprise.
--
-- Run as the table owner:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/2026-08-03_subcon_do_images_and_receipt_edit.sql
-- Idempotent: safe to re-run.

begin;

-- ---------------------------------------------------------------------
-- 1. Images attached to an outgoing DO
-- ---------------------------------------------------------------------

create table if not exists subcon_do_image (
    id            bigint generated always as identity primary key,
    do_number     text not null,
    image_url     text not null,          -- public URL, as gauges.image_path does
    storage_path  text,                   -- object key inside the bucket, for deletes
    caption       text,
    uploaded_at   timestamptz not null default now(),
    uploaded_by   text
);

create index if not exists idx_subcon_do_image_do on subcon_do_image (do_number);

alter table subcon_do_image enable row level security;
grant select, insert, update, delete on subcon_do_image to anon, authenticated;

drop policy if exists subcon_do_image_read  on subcon_do_image;
drop policy if exists subcon_do_image_write on subcon_do_image;
create policy subcon_do_image_read  on subcon_do_image
    for select to anon, authenticated using (true);
create policy subcon_do_image_write on subcon_do_image
    for all to anon, authenticated using (true) with check (true);

-- ---------------------------------------------------------------------
-- 2. The storage bucket the images live in
-- ---------------------------------------------------------------------
--
-- Public, and scoped by bucket_id on all four verbs — the same arrangement the existing
-- iqc / ipqc / oqc / obsolete buckets already use on this install. The app arrives as anon
-- (it has no Supabase Auth session), which is why the role is `public` rather than
-- `authenticated`.

insert into storage.buckets (id, name, public)
values ('subcon', 'subcon', true)
on conflict (id) do nothing;

do $$
declare
    verb text;
    pol  text;
begin
    foreach verb in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE']
    loop
        pol := 'subcon_objects_' || lower(verb);
        execute format('drop policy if exists %I on storage.objects', pol);
        if verb = 'INSERT' then
            -- INSERT takes WITH CHECK; there is no USING clause on an insert policy.
            execute format(
                'create policy %I on storage.objects for insert to public '
                'with check (bucket_id = ''subcon'')', pol);
        else
            execute format(
                'create policy %I on storage.objects for %s to public '
                'using (bucket_id = ''subcon'')', pol, verb);
        end if;
    end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. Rename a return DO, taking its inspection records with it
-- ---------------------------------------------------------------------

create or replace function subcon_update_receipt(
    p_id           bigint,
    p_return_do    text,
    p_receive_date date,
    p_quantity     numeric,
    p_remark       text
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    old_do  text;
    renamed integer := 0;
begin
    select return_do_number into old_do from subcon_delivery_in where id = p_id;
    if old_do is null then
        raise exception 'Receipt % does not exist', p_id;
    end if;

    p_return_do := upper(btrim(p_return_do));
    if p_return_do = '' then
        raise exception 'A return DO number is required';
    end if;

    -- Inspections move first, inside the same transaction as the receipt update, so
    -- there is no window where one is renamed and the other is not.
    if old_do is distinct from p_return_do then
        update "InspectionRecord"
           set "DO_Number" = p_return_do
         where "DO_Number" = old_do;
        get diagnostics renamed = row_count;
    end if;

    update subcon_delivery_in
       set return_do_number = p_return_do,
           receive_date     = p_receive_date,
           quantity         = p_quantity,
           remark           = p_remark
     where id = p_id;

    -- The quantity may have moved, so the parent's balance has to be recomputed.
    -- trg_subcon_in_refresh fires on this UPDATE and does exactly that.

    return renamed;
end $$;

grant execute on function subcon_update_receipt(bigint, text, date, numeric, text)
    to anon, authenticated;

commit;

-- PostgREST exposes the table and the function automatically. If either 404s, reload the
-- schema cache:
--   docker exec supabase-db psql -U supabase_admin -d postgres \
--       -c "notify pgrst, 'reload schema'"
