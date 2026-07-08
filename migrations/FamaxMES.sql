-- =====================================================================
-- FAMAX MES — schema migration
-- Run once in your (self-hosted) Supabase SQL editor / Studio.
-- All tables are PostgREST-exposed and use the same anon key as the app.
-- =====================================================================

-- ---- Alter existing tables --------------------------------------------
alter table "SalesOrders" add column if not exists status text default 'PENDING_SCM';
-- lifecycle: PENDING_SCM -> APPROVED -> IN_PRODUCTION -> DONE (or REJECTED)

alter table "JobOrder" add column if not exists machine_id text;   -- FK MachinesM.machine_id
alter table "JobOrder" add column if not exists sequence int;      -- order within a machine queue

-- unique SO number so the daily counter can't double-issue (see sales_order_entry retry)
do $$ begin
  alter table "SalesOrders" add constraint so_number_unique unique (so_number);
exception when duplicate_table then null; when duplicate_object then null;
end $$;

-- ---- New: Tooling (entry-form target) ---------------------------------
create table if not exists "Tooling" (
  id bigint generated always as identity primary key,
  part_number text,
  part_name   text,
  tooling_name text,
  tooling_type text,
  cavity int,
  location text,
  revision text,
  status text default 'AVAILABLE',        -- AVAILABLE / IN_USE / MISSING
  remarks text,
  created_by text,
  created_at timestamptz default now()
);

-- ---- New: scm_validations (mirrors buyoff_approvals) ------------------
create table if not exists "scm_validations" (
  id bigint generated always as identity primary key,
  so_id bigint,
  so_number text,
  part_number text,
  part_name text,
  raw_material_status text,                -- OK / SHORT
  raw_material_detail jsonb,               -- {required, available, material spec}
  tooling_status text,                     -- READY / MISSING
  status text default 'PENDING',           -- PENDING / APPROVED / REJECTED
  approver_name text,
  approver_position text,
  approved_at timestamptz,
  remarks text,
  created_at timestamptz default now()
);

-- ---- New: raw_material_requests ---------------------------------------
create table if not exists "raw_material_requests" (
  id bigint generated always as identity primary key,
  request_no text,
  so_id bigint,
  so_number text,
  part_number text,
  material_type text,
  grade text,
  size_dimensions text,
  qty_required numeric,
  uom text default 'PCS',
  status text default 'REQUESTED',         -- REQUESTED / ISSUED / REJECTED
  requested_by text,
  issued_by text,
  created_at timestamptz default now()
);
