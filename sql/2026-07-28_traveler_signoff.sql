-- 2026-07-28  Job Traveler Card: per-step digital sign-off
-- One row = one operator/QC signature against a JO_Number + Process step.
-- No FK, matching the app's denormalized text-key convention (JobOrder is keyed by JO_Number text).

create table if not exists "TravelerSignoff" (
    id           bigint generated always as identity primary key,
    "JO_Number"  text not null,
    "Process"    text not null,
    stage        text not null check (stage in ('operator', 'qc')),
    signed_by    text not null,
    signed_at    timestamptz not null default now(),
    remark       text
);

create index if not exists idx_travelersignoff_jo on "TravelerSignoff" ("JO_Number");

-- PostgREST exposes the table automatically once created; no server change required.
-- The Job Traveler Card reads it in the same batch as the other QC tables and overlays
-- the latest signature per (Process, stage) onto the sign-off cells.
