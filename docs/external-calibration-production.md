# External Calibration on the Production Server — Runbook

How to get the daily calibration alert running on the production server
`192.168.0.5`. Written for someone doing this for the first time, at that
machine, with this page open beside them.

Work through the sections **in order**. Section 1 has to happen before section 2
or you will take the whole application down — that is not a figure of speech, and
the reason is explained there.

**Roughly how long:** 45 minutes, most of it section 5 (building the email flow
in Power Automate).

---

## 0. What you are setting up

```
  Windows Task Scheduler   "Famax — Calibration Alert", daily 07:30
           |
           v
  Run-CalibrationAlert.bat            appends to temp\calibration-alert.log
           |
           v
  node scripts\calibration-alert.js
           |
           |  reads config\config.js  -> Supabase URL + anon key, webhook URLs
           |  reads v_ext_cal_masterlist
           |
           +-- nothing due?  -> sends nothing, exits 0
           |
           +-- something due -> Teams card  +  email
                                 |             |
                                 v             v
                            Teams channel   QA inboxes
```

**It sends nothing when nothing is due.** There is no daily "all clear". An
alert that arrives every morning is one people stop reading, and then they stop
reading the one that matters.

**It sends at most once a day.** A digest that went out successfully blocks a
second one, so a Task Scheduler retry, or a server that wakes late and fires a
missed task, does not chase people twice. A *failed* send does not count, so a
retry after a failure is allowed.

### Before you start

- [ ] **Administrator access** to `192.168.0.5` (Remote Desktop or at the console).
- [ ] **The repo folder path** on that server. If you do not know it, right-click
      the shortcut that starts the QC server and read *Start in* / *Target*.
      Everything below is relative to that folder — this guide writes it as
      `C:\FamaxQCSystem\`, change it to whatever yours is.
- [ ] **Node is installed** — `node -v` in a Command Prompt should print a
      version. It must, because the same machine already runs `server.js`.
- [ ] **Production's Supabase anon key.** See section 3 — it is already on that
      machine, you just have to find it.
- [ ] A **Teams channel** for the alerts, and an **Office 365 account** that can
      send the email.

---

## 1. Back up `config/config.js` — BEFORE you pull

Open a Command Prompt on the server, in the repo folder, and copy the file
somewhere outside the repo:

```bat
cd /d C:\FamaxQCSystem
copy config\config.js %USERPROFILE%\Desktop\config.js.backup
```

### Why this is first, and why it matters

`config/config.js` used to be tracked by git and is not any more, because it
holds values that are **different on every machine** — folder paths, the Supabase
anon key, the webhook URLs, and `APP_URL`.

Sharing it through git meant every pull replaced production's settings with the
development machine's. `APP_URL` is the plain example: it currently reads
`http://FMX-L-022/…`, which is a developer's laptop and means nothing on the
plant network, so the "Open the masterlist" button on every alert would be dead.

The commit that stops tracking it also **removes it from the repository**. When
you pull, git will either delete your copy or refuse to merge, depending on
whether you had edited it.

If it gets deleted and you have no backup, the whole application stops — not just
the calibration alert. `server.js`, `controllers\qcController.js`,
`controllers\dmsController.js`, `routes\inspectionRoutes.js` and
`scripts\calibration-alert.js` all load it, and `server.js` is what serves every
page in the system.

**Take the backup. It is one line and it is the difference between a ten-minute
job and a very bad afternoon.**

---

## 2. Pull, and put the file back

```bat
cd /d C:\FamaxQCSystem
git pull
```

If git refuses with *"Your local changes to the following files would be
overwritten by merge: config/config.js"*, that is fine — you have the backup, so
discard the local copy and pull again:

```bat
git checkout -- config/config.js
git pull
```

Now make sure the file is there, restoring it if the pull removed it:

```bat
if not exist config\config.js copy %USERPROFILE%\Desktop\config.js.backup config\config.js
node -e "require('./config/config'); console.log('config loads OK')"
```

That must print `config loads OK`. If it does not, the file is missing or has a
syntax error — fix it before going on, because nothing else will work.

From here on `config\config.js` is ignored by git and will never be touched by a
pull again. There is a `config\config.example.js` in the repo showing the full
structure if you ever need to rebuild it from scratch.

---

## 3. Fill in production's values

Open `config\config.js` in Notepad. Five things to check.

### 3.1 The Supabase connection — the one that catches everybody

```js
SUPABASE: {
    URL: "http://localhost:8000",
    ANON_KEY: "eyJhbGciOi…",
},
```

**`URL` stays `localhost`.** The scheduled task runs on the same machine as the
database, so `localhost` is correct there and is not a mistake.

**`ANON_KEY` must be the key production's own Supabase accepts.** Do not assume —
**test it**, because a wrong key fails every morning with

```
Supabase 401 on /ext_cal_alert_config?select=*&id=eq.1
```

which looks like a permissions bug and is not. One line tells you:

```bat
node -e "const c=require('./config/config');fetch(c.SUPABASE.URL+'/rest/v1/ext_cal_equipment?select=id&limit=1',{headers:{apikey:c.SUPABASE.ANON_KEY,Authorization:'Bearer '+c.SUPABASE.ANON_KEY}}).then(r=>console.log('REST says',r.status,r.status===200?'- key is good':'- WRONG KEY'))"
```

`200` and you are done. `401` and the key is wrong: the right one is on that same
machine in `assets\app-config.js` — that file is per-machine and git leaves it
alone. Open it, find the line starting `key:`, and copy the long string between
the quotes into `ANON_KEY`.

> As of 25 Aug 2026 the key in the shared `config.js` happens to be the one
> production accepts, so this may already be correct. Check anyway — the two
> installs are free to diverge, and this file is no longer shared between them.

### 3.2 The alert settings

```js
CALIBRATION_ALERT: {
    TEAMS_WEBHOOK_URL: "https://…",
    EMAIL_WEBHOOK_URL: "https://…",
    APP_URL: "http://192.168.0.5/screen_page/calibration/external_calibration_masterlist.html",
},
```

- **`TEAMS_WEBHOOK_URL`** — the Power Automate flow that posts the card. Section
  3 of `docs\external-calibration-setup.md` builds one. You can reuse the same
  flow the development machine uses if the alerts should go to the same channel.
- **`EMAIL_WEBHOOK_URL`** — leave it empty for now; section 5 below fills it in.
- **`APP_URL`** — the "Open the masterlist" button on the alert. It must be the
  address people on the floor actually type. **Not `localhost`** — on somebody's
  phone, `localhost` means the phone.

### 3.3 Restart the server

`config.js` is read once when `server.js` starts, so nothing you just typed is
live until you restart it. Close the QC server window and start it again the
usual way.

The scheduled task does **not** need the restart — it starts a fresh Node process
each run and reads the file every time. The restart is for the "Send alert now"
button on the page, which goes through the server.

---

## 4. Load the data

Run all six, **in this order**. Every one is safe to run again, so running the
ones already applied costs nothing — and re-running is exactly how the problem
below gets fixed.

> **As of 25 Aug 2026 production is missing 9 certificates**, and re-running
> these files in order is the fix. Section 4.1 explains what happened and how to
> confirm you have repaired it. Run the six commands first.

```bat
cd /d C:\FamaxQCSystem

docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < sql\2026-08-25_external_calibration.sql
docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < sql\data\2026-08-25_external_calibration_seed.sql
docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < sql\2026-08-25_external_calibration_form_settings.sql
docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < sql\data\2026-08-25_external_calibration_2024_2025.sql
docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < sql\2026-08-25_external_calibration_certificate_upload.sql
docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < sql\2026-08-25_external_calibration_certificate_pdf.sql
```

The order matters: the seed needs the schema, and the 2024–2025 backfill attaches
prior certificates to instruments the seed creates.

### 4.1 Check it took — and the check that actually matters

```bat
docker exec -i supabase-db psql -U supabase_admin -d postgres -c "select count(*) equipment from ext_cal_equipment; select count(*) certificates from ext_cal_event; select count(*) with_history from (select equipment_id from ext_cal_event group by equipment_id having count(*) > 1) x;"
```

Expect **21** equipment, **29** certificates, and **9** instruments with more
than one certificate.

**That last number is the one worth reading.** Equipment count alone does not
tell you the load worked — production reached 21 equipment while holding only
20 certificates and **zero** instruments with any history at all.

Here is what had happened, because it is an easy mistake to repeat. The
2024–2025 backfill was run **before** the seed. At that moment there was no
equipment for it to attach prior certificates to, so it did the only part it
could: it created the three instruments that exist solely on the old sheet — the
two retired thread gauges and the dial test indicator — and gave them their
certificates. Three rows. The other nine attach to instruments the seed creates,
and the seed had not run yet, so they were silently skipped. Running the seed
afterwards brought the count to a plausible-looking 21 equipment and 20
certificates, and nothing anywhere said the history was missing.

Re-running the six files in the order above repairs it: the backfill is written
to be re-run, and this time it finds the equipment and inserts the nine.

If `with_history` still reads 0 after re-running, the files ran out of order
again — do the seed first, then the backfill.

### What the alert will report

```bat
docker exec -i supabase-db psql -U supabase_admin -d postgres -c "select cal_status, count(*) from v_ext_cal_masterlist group by 1 order by 2 desc;"
```

On a clean load this shows **1 OVERDUE** — the WEIGHCOM counting scale, serial
`A08326347`, due 24 JUL 2026 — and that is what the first scheduled run reports.

**On production today it shows none**, because that scale has already been
retired there. That is the right outcome and worth knowing about: the 2024–2025
sheet marks the same scale *"OBSOLETE (24/7/25) BROKEN"* and records its
replacement the same day, which the current sheet contradicts. Somebody acted on
it. See section 1b of `docs\external-calibration-setup.md`.

It does mean the first scheduled run will correctly send **nothing**, so use
`--force` in section 7 to prove the plumbing works.

---

## 5. Build the email flow

Full instructions with the JSON schema are in **section 4 of
`docs\external-calibration-setup.md`** — follow them there, they are the same on
any machine. In short:

1. Power Automate → **Create → Instant cloud flow → When an HTTP request is
   received**.
2. Paste the request-body JSON schema from that section (`to`, `subject`, `html`,
   `text`).
3. Add **Office 365 Outlook → Send an email (V2)**, with
   **To** = `join(triggerBody()?['to'], ';')`, **Subject** = the `subject` field,
   **Body** = the `html` field.
4. In the Body field click **`</>`** (code view). Without it Outlook sends the
   HTML as literal text and recipients get a page of markup instead of a table.
5. Save, copy the **HTTP POST URL**, paste it into `EMAIL_WEBHOOK_URL` in
   `config\config.js`.

Two production-specific notes:

- Build the flow under an account that will still exist next year. A flow owned
  by somebody who leaves stops working when their licence is removed.
- If Teams and email should go to the same people, you still need both — they are
  separate flows and either can be switched off independently on the page.

---

## 6. Add the recipients

On the production server, open the masterlist:

`http://192.168.0.5/screen_page/calibration/external_calibration_masterlist.html`

Sign in as an **ALL** or **QUALITY** account, then **Alerts**:

1. Under **Who gets told**, add each person: the name **exactly as it appears in
   Teams**, and their email address. One row supplies both the @mention and the
   inbox, so the name on the card and the person actually pinged are always the
   same person.
2. Check **When to warn** — 30 days first warning, 14 days urgent, by default.
3. Leave both channel tickboxes on.

**If nobody is listed, the email channel has nothing to send to** and the run
will say so. It is the most common reason a first scheduled run only posts to
Teams.

---

## 7. Test it by hand, before scheduling

Still in the repo folder on the server.

### Dry run — builds everything, sends nothing

```bat
node scripts\calibration-alert.js --dry-run
```

You should see an instrument count and a summary, then the card it would post
and the email it would send. Nothing is sent and nothing is logged.

**If this prints `Supabase 401`, go back to section 3.1** — the anon key is still
the development machine's. This is the single most likely thing to go wrong.

### Real send

```bat
Run-CalibrationAlert.bat --force
```

`--force` overrides the once-a-day rule so you can test whenever you like.

Then check all four:

| | |
|---|---|
| The Teams channel | the card is there |
| The recipients' inboxes | the mail arrived |
| `temp\calibration-alert.log` | the run, with an exit code at the end |
| `ext_cal_alert_log` | one row per channel |

```bat
docker exec -i supabase-db psql -U supabase_admin -d postgres -c "select sent_at, channel, ok, overdue_count, due_soon_count, sent_by from ext_cal_alert_log order by sent_at desc limit 5;"
```

**"Sent to Teams (queued)" is the normal answer.** Power Automate returns 202 the
moment it has *queued* the run — before any step of the flow has executed. The
card can still fail afterwards. Check the channel the first time; after that,
trust it.

---

## 8. Register the scheduled task

**Task Scheduler → Create Task…** — *Create Task*, not *Create Basic Task*. You
need the security options and Basic does not offer them.

| Tab | Setting |
|-----|---------|
| **General** | Name: `Famax — Calibration Alert`. See the note below about *Run whether user is logged on or not*. |
| **Triggers** | New → Daily, start `07:30:00`, recur every 1 day. |
| **Actions** | New → *Start a program*. <br> **Program/script:** `C:\FamaxQCSystem\Run-CalibrationAlert.bat` <br> **Start in (optional):** `C:\FamaxQCSystem` |
| **Conditions** | Untick *Start the task only if the computer is on AC power*. |
| **Settings** | Tick *Run task as soon as possible after a scheduled start is missed*. |

### "Start in" is not optional, whatever Windows calls it

Windows labels that field *(optional)*. It is not. Without it the task runs from
`C:\Windows\System32`, the script cannot find `config\config.js`, and it fails
every morning with:

```
Error: Cannot find module '../config/config'
```

Type the repo folder path into it. **No quotation marks** — Task Scheduler treats
them as part of the path.

### Which account to run as

This is a real choice with a real trade-off, so decide rather than accepting the
default.

**Run whether user is logged on or not** — the task runs even with nobody signed
in, which is what you want on a server. Windows stores the account's password to
do it, and **when that password is next changed the task stops running and says
nothing.** If your organisation expires passwords, put a reminder somewhere, or
use an account whose password does not expire.

**Run only when user is logged on** — no stored password, nothing to expire, but
nothing runs while the server sits at the login screen. Only sensible if that
machine is always signed in.

Whichever you pick, the account needs: read access to the repo folder, write
access to `temp\` for the log, and outbound HTTPS to Power Automate.

---

## 9. Confirm it fires

Right-click the task → **Run**. Then look at the task list:

- **Last Run Result `0x0`** — it worked. Either it sent, or there was correctly
  nothing to send.
- **`0x1`** — something failed. Open `temp\calibration-alert.log`; the last lines
  say which channel and why.

The exit codes mean something on purpose. A task that always reports success is a
task nobody ever checks.

Then check `temp\calibration-alert.log` for the run you just triggered, and
confirm once more the next morning that it fired on its own at 07:30.

---

## 10. If something is wrong

| What you see | What it is |
|---|---|
| `Supabase 401 on /ext_cal_alert_config` | The anon key is the wrong one. Section 3.1. |
| `Error: Cannot find module '../config/config'` | Either **Start in** is empty (section 8), or `config\config.js` is missing (section 2). |
| `config.SUPABASE is not set` | `config\config.js` was rebuilt from an old copy that predates the calibration work. Compare it against `config\config.example.js`. |
| History modal shows only one certificate for everything | The 2024–2025 backfill ran before the seed. Re-run the six files in the order in section 4, then re-check `with_history` — it must be 9. |
| Last Run Result `0x1` | A channel failed. The log names it. |
| Last Run Result `0x2` | Windows could not find the `.bat`. Check the path in **Actions**, and that it has no quotation marks. |
| Task shows Ready but never runs | Password changed on the account, or the trigger is disabled. Section 8. |
| Ran fine, nothing sent | Correct behaviour if nothing is due. If something *is* due, a digest already went out today — `--force` overrides. |
| `EMAIL is enabled but no active CALIBRATION recipients exist` | Section 6. |
| `Teams webhook is not configured` | `TEAMS_WEBHOOK_URL` is empty in `config\config.js`. |
| Teams says sent, no card in the channel | Power Automate returned 202 and the flow failed afterwards. Its run history says why. |
| "Send alert now" on the page says not configured, but the task works | The server was not restarted after editing `config.js`. Section 3.3. |

---

## 11. After a future `git pull`

`config\config.js` is ignored by git now, so a pull leaves it alone and none of
section 3 needs doing again.

What a pull **can** bring is a new `.sql` file. If one arrives, run it the same
way as section 4 — they are all written to be safe to re-run.

If a pull ever adds a new *setting*, it will appear in `config\config.example.js`
but not in your `config\config.js`, because yours is no longer shared. Comparing
the two after a pull that touches the example file is the one habit worth
keeping.
