# Transaction Notifications for FamaxQCSystem — Implementation Plan

## Context

Goal: fire a notification on the PC whenever an admin creates a transaction in
the app — the example being **"when we generate a WI (Work Instruction), send a
notification on the PC."**

Today the app has **no** notification or realtime infrastructure — only per-page
Toastify toasts and a manual MS Teams webhook. This plan adds an automatic,
cross-machine notification feed.

**Chosen options:** Windows desktop popup (primary) · received on every open
admin page · eventually for every transaction · delivered via Supabase Realtime.

### Key constraints (built in, with graceful fallback)

- **Windows desktop popups require a secure context (HTTPS or localhost).** The
  app is served over plain `http://192.168.0.5`, which browsers treat as
  insecure, so the Web Notification API is blocked there. The feature therefore
  **always** runs an in-app alert (toast + bell badge + sound) as the guaranteed
  channel, and desktop popups switch on automatically on any PC served over
  HTTPS (or launched with the Chrome insecure-origin flag). See Phase 4.
- **Supabase Realtime must be enabled server-side** (realtime container up +
  table added to the `supabase_realtime` publication). If Realtime is
  unreachable, the receiver automatically falls back to ~15s polling.

## Architecture

Three parts — DB → emitter → receiver — all keyed off `window.APP_CONFIG`
(`/assets/app-config.js`):

1. **`notifications` table** (append-only feed) in the self-hosted Supabase.
2. **`/assets/notify.js`** — emitter. `window.Notify.log({...})` fire-and-forget
   POST to `/rest/v1/notifications`, capturing the actor from
   `sessionStorage.userId`. Called after each successful insert. Never blocks or
   breaks the underlying transaction.
3. **`/assets/notify-receiver.js`** — receiver, loaded in the always-open shell
   pages. Subscribes to Realtime INSERTs on `notifications`; on each event shows
   a desktop popup (when secure) + toast + sound + a sidebar bell badge/dropdown.
   Read state is tracked **per PC in localStorage** (`lastSeenId`) — there is no
   per-user login, so a DB `is_read` flag would be global and meaningless.

Emitters run inside iframe child pages; the receiver runs in the parent shell.
They communicate through the DB → Realtime round-trip (not postMessage) — which
is exactly what delivers the alert to *other* PCs.

## DB schema — `sql/2026-07-22_create_notifications.sql`

Idempotent migration (run once in the Supabase SQL editor), following the repo's
`sql/` convention. Columns: `id bigint identity PK`, `created_at timestamptz`,
`actor`, `actor_role`, `type`, `title`, `message`, `ref_table`, `ref_id text`,
`url`, `meta jsonb`, `dedupe_key`. Plus:

- Indexes on `created_at DESC`, `type`, partial index on `dedupe_key`.
- `GRANT SELECT, INSERT ON notifications TO anon` (append-only; **no**
  UPDATE/DELETE to anon — retention runs as service role). `GRANT USAGE, SELECT`
  on sequences.
- Permissive RLS policies for `anon` SELECT/INSERT (matches the app's current
  open-access model; harmless if RLS is globally off).
- `REPLICA IDENTITY FULL` + `ALTER PUBLICATION supabase_realtime ADD TABLE
  notifications` (guarded by a `pg_publication_tables` existence check).
- Retention (separate scheduled job, not in the create migration):
  `DELETE FROM notifications WHERE created_at < now() - interval '30 days'`.

## Emitter — `/assets/notify.js`

- Interface: `window.Notify.log({ type, title, message, ref_table, ref_id, url,
  actor?, actor_role?, meta?, dedupe_key? })` → void, fire-and-forget.
- Reads `APP_CONFIG.url`/`.key`; POSTs with its **own** axios (or `fetch`
  fallback) so it drops into both axios pages and supabase-js pages with no
  dependency on the page's client. Uses `Prefer: return=minimal`.
- Defaults `actor = sessionStorage.getItem('userId')`. Wrapped so it never
  throws; `.catch(()=>{})` on the POST — a notify failure can never affect the
  insert.
- In-memory debounce (skip same `type|ref_table|ref_id` within ~5s) to guard
  double-submits. Stamps `meta.client_id` (per-tab id in sessionStorage) for the
  receiver's self-suppression.
- **Drop-in pattern**, added immediately after a successful insert:

  ```js
  window.Notify?.log({
    type: 'wi.generate',
    title: 'New Work Instruction',
    message: `${sessionStorage.getItem('userId')||'Someone'} generated WI ${dbPayload.WI_Number}`,
    ref_table: 'Parts', ref_id: dbPayload.WI_Number,
    url: `screen_page/generate_file/FileGenerator.html?wi=${encodeURIComponent(dbPayload.WI_Number)}`
  });
  ```

- Inclusion: `<script src="/assets/notify.js"></script>` after app-config.js on
  each emitting page.

## Receiver — `/assets/notify-receiver.js`

Loaded in the persistent top-level shells only: `index.html`, `AdminLogin.html`
(optional `quality-hub.html`). **`index.html` must add the supabase-js v2 CDN
script** (`AdminLogin.html` already has it).

- `supabase.createClient(APP_CONFIG.url, APP_CONFIG.key)` then
  `.channel('notifications-feed').on('postgres_changes', {event:'INSERT',
  schema:'public', table:'notifications'}, onInsert).subscribe(onStatus)`.
- `onInsert(row)`:
  - **Desktop path:** if `window.isSecureContext && Notification.permission ===
    'granted'` → `new Notification(row.title, {body: row.message, tag, icon})`;
    click → focus window + open `row.url` (via `loadInView` in index.html, or
    `location.href` in AdminLogin).
  - **In-app path (always):** Toastify toast (reuse existing `showNotification`
    style) + sound + bell badge +1 + prepend to dropdown.
  - Optional self-suppression of the desktop popup when
    `row.meta.client_id === thisTab`.
- **Permission UX:** no auto-prompt on load. The bell has an "Enable desktop
  alerts" action that calls `Notification.requestPermission()` from a user
  gesture (meaningful only in a secure context; otherwise a tooltip explains
  in-app alerts are active and HTTPS is needed for desktop popups).
- **Reconnect:** on channel error/close → start ~15s polling
  (`GET notifications?id=gt.<lastKnownId>&order=id.asc`); on `SUBSCRIBED` → stop
  polling + run a catch-up fetch so nothing is missed. De-dupe by `id`.
- **Bell UI** is self-injected by the receiver into a known anchor (`.top-nav`
  in index.html:876; `.header` in AdminLogin.html:232), so the shells only add
  `<script>` tags — minimal HTML edits. Opening the dropdown sets `lastSeenId =
  lastKnownId` (clears badge); value persists in localStorage.

## Phase 4 — Enabling desktop popups (secure context)

Desktop popups stay dark until one of these is done (the feature still works
fully in-app meanwhile):

1. **Recommended:** front the `:80` static host and `:8000` Supabase with an
   HTTPS reverse proxy (Caddy/nginx) using an internal-CA/self-signed cert for
   the LAN host; trust the CA on client PCs (GPO-pushable). Then update
   `app-config.js` to `https://`/`wss://` and proxied paths. Realtime must be
   reachable over `wss://`.
2. **Stopgap per PC:** launch Chrome with
   `--unsafely-treat-insecure-origin-as-secure=http://192.168.0.5
   --user-data-dir=...`, or set the `OverrideSecurityRestrictionsOnInsecureOrigin`
   enterprise policy.

## Phase 5 — Realtime enablement (server-side)

- Realtime container running; gateway routes the `/realtime/v1` websocket.
- Publication includes the table (done by migration). Verify:
  `SELECT * FROM pg_publication_tables WHERE tablename='notifications';`
- `REPLICA IDENTITY FULL` (done by migration): `relreplident = 'f'`.
- `wal_level = logical` (Supabase default) + a live replication slot
  (`SELECT slot_name, active FROM pg_replication_slots;`).
- Anon SELECT grant/policy present (done by migration) or the channel yields
  nothing.

## Rollout (phased)

- **Phase 0 — Infra (no change to existing behavior):** run the migration;
  verify Realtime; add `notify.js` + `notify-receiver.js`; add supabase-js to
  `index.html` head; wire the receiver into `index.html` + `AdminLogin.html`;
  mount the bell. Test with a manual SQL insert → bell/toast on a second PC.
- **Phase 1 — WI hook (the example):** include `notify.js` in
  `FileGenerator.html`; add the `Notify.log` call after the successful
  `.from("Parts").insert(...)` (FileGenerator.html:~1206-1210). Generate a WI on
  PC A → notification on PC B.
- **Phase 2 — Batch the remaining ~30 insert sites** using the same one-liner.
  Per file: add the `notify.js` script tag, then one `Notify.log({...})` after
  each successful insert with a per-site `type`. Group multi-insert flows (sales
  order = SalesOrders + Items + JobOrder) into a single notification.

  | Type | File : line |
  | --- | --- |
  | `inspection.record` | inspectionCheckerForm.html:1355 |
  | `inspection.schedule` | inspectionSchedule.html:1242 |
  | `production.cycle_time` | production_cycle_time.html:1640 |
  | `sales.order` (once) | sales_order_entry.html:581 |
  | `production.daily_output` | daily_output.html:403 |
  | `job_order.update` | UpdateJO.html:808 |
  | `qc.buyoff` | BUYOFF-page2.html:869 |
  | `qc.ipqc` | IPQC-page.html:952, IPQC-page2.html:737 |
  | `qc.iqc` | IQC-page1.html:1499 |
  | `qc.oqc` | OQC-page1.html:1505 |
  | `gauge.verification` | gauge_verification_form.html:1162 |
  | `maintenance.log` | preventive_maintenance.html:510 |
  | `store.record` | store_record.html:1329 / 1412 |
  | `admin.user_create` | user.html:490 |

  Roll out in small, tested batches.

## Edge cases / risks (handled)

- **Echo / self-notify:** the actor's own tab receives its INSERT back →
  suppress its desktop popup via `meta.client_id`; keep an in-app confirmation.
- **Duplicates:** double-submit, or realtime + polling overlap → de-dupe by `id`
  (receiver) and debounce (emitter); multi-insert flows fire once.
- **Shared anon key ⇒ no server-side actor:** `actor` is client-supplied and not
  audit-grade — acceptable for an internal LAN tool; note it, don't rely on it
  for tamper-proof attribution.
- **Spam / rate:** only "interesting" types raise a popup; routine ones just
  bump the badge; emitter debounce; group multi-insert flows.
- **iframe vs top-level:** receiver lives in the parent shell (survives
  `loadInView`), never inside the iframe.
- **Retention:** append-only table → scheduled 30-day delete as service role.

## Critical files

| File | Change |
| --- | --- |
| `sql/2026-07-22_create_notifications.sql` | **NEW** migration (model on `sql/2026-07-21_add_and_backfill_schedule_id.sql`) |
| `assets/notify.js` | **NEW** emitter |
| `assets/notify-receiver.js` | **NEW** receiver + bell UI |
| `index.html` | add supabase-js CDN + receiver script; bell mounts in `.top-nav` |
| `AdminLogin.html` | add receiver script; bell mounts in `.header` |
| `assets/app-config.js` | later HTTPS/`wss` switch for desktop popups (Phase 4) |
| `screen_page/generate_file/FileGenerator.html` | Phase-1 WI hook after `.from("Parts").insert` (~:1206-1210); then the ~30 sites in Phase 2 |

## Verification

**In-app path (works today, no HTTPS):**

1. Run the migration. Open `index.html` on PC B.
2. On PC A generate a WI (or `INSERT` a test row in the SQL editor).
3. PC B within ~1s: toast, bell +1, dropdown entry, sound (after first gesture).
   Open dropdown → badge clears; reload → `lastSeenId` persists.
4. Stop the realtime container → ~15s polling still delivers; restart → catch-up
   fetch fills the gap with no duplicates.
5. Point notify at a dead port → WI still generates with no user-visible error
   (proves fire-and-forget).

**Desktop popup path (secure context):**

6. Serve one PC over HTTPS (trusted cert) or launch Chrome with the
   insecure-origin flag.
7. Click bell → "Enable desktop alerts" (grant). Trigger a transaction from
   another PC → Windows popup; clicking focuses the window and opens `row.url`.

**Server checks:** the `pg_publication_tables` / `relreplident` /
`pg_replication_slots` queries from Phase 5.
