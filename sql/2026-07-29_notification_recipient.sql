-- 2026-07-29  Teams notifications: role -> person mapping as DATA, not code.
--
-- Every Teams notification recipient used to be a string literal in
-- screen_page/notification/teamsNotification.html, repeated in five places that had already
-- drifted apart (the ENG card displayed "Azim Bakar" while mentioning aiman.mazlan@fmefamax.com,
-- and the second ENG person named in the preview text was never actually mentioned).
-- Replacing someone who resigned meant editing code and pushing a release.
--
-- One row = one person who should be @mentioned for one role. A role may have many active
-- recipients; all of them get mentioned. Deactivate rather than delete to keep the history.
--
-- The roles themselves stay fixed (they are the three radio buttons on the send form);
-- only the people behind them are data.

create table if not exists "NotificationRecipient" (
    id            bigint generated always as identity primary key,
    role          text    not null check (role in ('QA', 'ENG', 'MANAGEMENT')),
    display_name  text    not null,
    email         text    not null,          -- Teams UPN -> msteams.entities[].mentioned.id
    active        boolean not null default true,
    sort_order    int     not null default 0,
    created_at    timestamptz not null default now()
);

create index if not exists idx_notificationrecipient_role
    on "NotificationRecipient" (role, active);

-- Seed the people who are hardcoded today. Guarded on email so re-running is safe.
insert into "NotificationRecipient" (role, display_name, email, sort_order)
select v.role, v.display_name, v.email, v.sort_order
from (values
        ('QA',         'Ayyub Sofi', 'ayyub.sofi@famax.com.my',   1),
        ('ENG',        'Nor Aiman',  'aiman.mazlan@fmefamax.com', 1),
        ('MANAGEMENT', 'Vicson Lee', 'vicson.lee@famax.com.my',   1)
     ) as v(role, display_name, email, sort_order)
where not exists (
        select 1 from "NotificationRecipient" r
        where lower(r.email) = lower(v.email) and r.role = v.role
);

-- NOTE: "Muhammad Zahid Bin A.Aziz" is named in the old ENG preview text but his email address
-- appears nowhere in the codebase, so he cannot be seeded here. Add him through the
-- "Manage Recipients" modal on the Teams Notification page once you have his address.

-- PostgREST exposes the table automatically once created; no server change required.
