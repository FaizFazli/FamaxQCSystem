# External Calibration — Setup Guide

How the external calibration masterlist works, and the two things still to do:
paste in the Teams webhook, and paste in the email flow. Written for someone
doing this for the first time.

Sections 1, 1b and 2 are already done — they are written up so you can redo them
on another machine, or check them. **Sections 3 to 7 are the work**, and section
1b has one finding that needs a decision from QA.

---

## 0. What you are building

```
  screen_page/calibration/
    external_calibration_masterlist.html   browse, filter, print, "Send alert now"
    external_calibration_form.html         key in one calibration certificate
         |
         v
  Supabase (Postgres)
    ext_cal_equipment        21 instruments, no dates
    ext_cal_event            one row per certificate  <- the dates live here
    v_ext_cal_masterlist     the two joined, plus OVERDUE / DUE_SOON / VALID
    storage/calibration_certificate   the uploaded certificate images
         |
         +-------------------------+
         |                         |
   "Send alert now"          Windows Task Scheduler
   (a person, any time)      (07:30 every morning)
         |                         |
         v                         v
   POST /FamaxQCSystem/     scripts/calibration-alert.js
     api/calibration-alert         |
         |                         |
         +----------+--------------+
                    v
        +-----------+-----------+
        |                       |
   Teams flow              Email flow          <- YOU BUILD THESE (sections 3, 4)
   (adaptive card)         (Send an email V2)
        |                       |
        v                       v
   Teams channel           QA inboxes
```

**Why two flows and not one.** So one can be switched off without the other. A
Teams card is right for "book this in", an email is right for the person who
reads mail and not Teams. Both are ticked on by default and either can be turned
off on the page.

**The message is only written once.** `assets/calibration-alert.js` builds the
card and the mail; the page and the scheduled task both call it. The 07:30 digest
and the one somebody triggers by hand at 14:00 cannot say different things.

---

## 1. The database  *(already applied on 25 Aug 2026)*

Six files, in this order:

```bash
docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
    < sql/2026-08-25_external_calibration.sql

docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
    < sql/data/2026-08-25_external_calibration_seed.sql

docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
    < sql/2026-08-25_external_calibration_form_settings.sql

docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
    < sql/data/2026-08-25_external_calibration_2024_2025.sql

docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
    < sql/2026-08-25_external_calibration_certificate_upload.sql

docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
    < sql/2026-08-25_external_calibration_certificate_pdf.sql
```

The order matters. The seed needs the schema; the 2024–2025 backfill needs both
the seed (it attaches prior certificates to instruments the seed created) and
the form-settings migration (which changes how `line_no` is numbered).

All six are safe to run again — the schema uses `create table if not exists`,
the seed matches on equipment code + serial number, and the backfill repairs its
own earlier rows rather than duplicating them.

Check it took:

```sql
select count(*) from ext_cal_equipment;                          -- 21  (18 + 3 retired)
select count(*) from ext_cal_event;                              -- 29
select count(line_no) from v_ext_cal_masterlist;                 -- 18  (the printed form)
select cal_status, count(*) from v_ext_cal_masterlist group by 1;
```

You should see **1 OVERDUE** — the WEIGHCOM counting scale, serial `A08326347`,
due 24 JUL 2026. It came in overdue from the spreadsheet. Before you chase it,
read section 1b: the older sheet says it was scrapped.

### What came across from the spreadsheet

All 18 rows of `MASTERLIST EXTERNAL CALIBRATION 2025 - 2026.xlsx`, transcribed as
they read — including the typos. `PITCH DIAMETR` on items 3 and 4 is still
spelled that way, `QA/QC` and `QA/QC LAB` are still two different locations, and
item 2's brand is still `SN-500`, which is a model number. A masterlist that
quietly disagrees with the signed record it replaced is worse than one that
repeats its typos. Fix them on the page whenever somebody decides what they
should say.

Two rows are not like the others:

| Row | What is different | Why |
|-----|-------------------|-----|
| 18 — CHENXI microscope lamp | Read `NA` in both date columns. Loaded with **calibration required = off** and no certificate. | It is a lamp. It reports "Not required" instead of ageing into overdue forever. |
| 3 — M23 x 1.25 6g thread ring | Condition `OUT OF SPEC` although it was calibrated 4 DEC 2025. | Condition now and condition at the last certificate are two different facts. The page keeps both. |

---

## 1b. The 2024–2025 sheet, loaded as history

`MASTERLIST EXTERNAL CALIBRATION 2024 - 2025.xlsx` — the previous revision,
signed by JESS LIM and dated 21/12/2024 — is loaded too. It adds **prior
certificates** to instruments that already exist, and registers the **three that
were retired** between the two revisions. It changes no current due date, no
current condition and no current criteria, and re-running it is a no-op.

| | |
|---|---|
| Certificates added | 12 |
| Instruments now carrying more than one certificate | 9 |
| Retired instruments registered (status `OBSOLETE`) | TPG M6 X 1-6H · TPG M14 X 2-6H · DTI dial test indicator |

The six MICRON block gauges appear on **both** sheets with the same 7 DEC 2021
certificate. That is one calibration written on two forms, so it loads once —
the unique index on (instrument, calibration date) makes that automatic.

Retired instruments do not print and are never chased by the alert. They show on
the masterlist under **Not required / retired**, which is where their history is
read.

### Two identity calls that were judgement, not arithmetic

Serial numbers were matched with leading zeros stripped, so `6014` and `06014`
are one gauge. Two rows needed more than that. Both decisions are written into
the loaded certificate's remarks, so you can find them under **History** on the
instrument and reverse them if they are wrong.

- **The push-pull gauge.** Serial `RefMA 4617` on the old sheet, `2809116082` on
  the new. Same description, same SN-500, same location, and only one push-pull
  gauge has ever been on the list — `RefMA` reads as a reference number, not a
  serial. Treated as one instrument.
- **The HALSTEN counting scale.** `231011032` against `23101132` — nine digits
  against eight, everything else identical. Treated as one instrument.
  Registering a second identical scale would be the worse error: it would sit on
  the form forever waiting for a calibration that belongs to the other one.

### ⚠ The overdue scale may be scrapped, not overdue

This one needs a person to settle. On the 2024–2025 sheet the WEIGHCOM scale
`A08326347` — the instrument the alert chases as overdue — has this in its
PERSON column:

> OBSOLETE (24/7/25) BROKEN

and the row immediately below it registers the HALSTEN scale as *NEW ISSUE
24/7/25*. Read together, those two rows say the WEIGHCOM broke and was replaced
that day. The 2025–2026 sheet nevertheless carries it forward as GOOD, due
24 JUL 2026 — which is what is now overdue.

Nothing was changed on the strength of that inference. The 2024–2025 certificate
is loaded with its condition recorded as `DAMAGED`, so the contradiction is
visible in the instrument's history. **If QA confirms it was scrapped**, retire
it on the page — Edit → Record status → `OBSOLETE` — and the alert stops chasing
it, the form renumbers, and the history stays.

---

## 2. Who can open it  *(already done)*

**Admin (`ALL`) and `QUALITY` only.** Everyone else gets a "Restricted page"
card and no data is loaded at all.

The check is in two places on purpose:

- `AdminLogin.html` — the **External Calibration** card in the Quality group is
  only enabled for those two roles.
- Both pages re-check for themselves, because a hidden card is still a URL that
  can be typed.

To change who has access you must edit **both**. `WRITE_ROLES` at the top of each
page's script, and the `btn-cal-external` entry in `AdminLogin.html`.

---

## 3. The Teams flow  ← **to do**

The easiest route is the **Workflows** app inside Teams. You do not need a Power
Automate licence beyond what is already in use.

1. In Teams, go to the channel that should receive the alerts.
2. **⋯ → Workflows → "Post to a channel when a webhook request is received"**.
3. Give it a name — `Calibration Alert` — pick the team and channel, **Add
   workflow**.
4. Teams shows a URL. **Copy it.** This is the only time it is shown.

That trigger already expects the shape this system sends:

```json
{
  "type": "message",
  "attachments": [
    { "contentType": "application/vnd.microsoft.card.adaptive",
      "content": { "type": "AdaptiveCard", "version": "1.4", "body": [ ... ] } }
  ]
}
```

**If you would rather build it in Power Automate** (the way the existing
notification flow is built), use *When an HTTP request is received* → *Post card
in a chat or channel*, set the card content to
`triggerBody()?['attachments'][0]?['content']`, and copy the trigger URL.

### Reusing the existing channel

If calibration should go to the same channel as everything else, you can paste
the existing `TEAMS_WEBHOOK_URL` value into the calibration slot instead of
building a new flow. They are separate settings so calibration *can* be sent
somewhere quieter — not because it has to be.

---

## 4. The email flow  ← **to do**

1. Power Automate → **Create → Instant cloud flow → When an HTTP request is
   received**.
2. Paste this into **Request Body JSON Schema**:

```json
{
  "type": "object",
  "properties": {
    "to":      { "type": "array", "items": { "type": "string" } },
    "subject": { "type": "string" },
    "html":    { "type": "string" },
    "text":    { "type": "string" }
  }
}
```

3. Add **Office 365 Outlook → Send an email (V2)**:

   | Field | Value |
   |-------|-------|
   | **To** | `join(triggerBody()?['to'], ';')` |
   | **Subject** | the `subject` field from the trigger |
   | **Body** | the `html` field from the trigger |

4. In the Body field, click the **</>** (code view) button. Without it Outlook
   sends the HTML as literal text and the recipient gets a page of markup instead
   of a table.
5. **Save**, then copy the **HTTP POST URL** from the trigger card.

The `text` field is a plain-text copy of the same digest. You do not have to use
it; it is there if you want to set a plain-text alternative body.

---

## 5. Paste both URLs in

Open `config/config.js` and fill in the three empty strings:

```js
CALIBRATION_ALERT: {
    TEAMS_WEBHOOK_URL: "https://…",   // from section 3
    EMAIL_WEBHOOK_URL: "https://…",   // from section 4
    APP_URL: "http://192.168.0.5/screen_page/calibration/external_calibration_masterlist.html",
},
```

**`APP_URL`** is the "Open the masterlist" button on a *scheduled* alert. Use the
LAN address people actually type — not `localhost`, which on a phone means the
phone. Leave it empty and the alert simply omits the button rather than shipping
a dead link.

**Then restart the server** — `Start-FamaxQC.bat`. `config.js` is read once at
startup, and the `/api/calibration-alert` route does not exist until the server
has been restarted since this was installed.

### Why these live in config.js and not in the app

A webhook URL has a `sig=` in it. Anyone holding one can post to your channel or
send mail as the flow owner — it is a credential. Everything in the database is
readable with the anon key that ships in `assets/app-config.js`, so a webhook URL
stored there would be readable by anyone who can load the site. *How many days of
warning* is a setting and lives in the database, where QA can change it. *Where
to send it* is a credential and lives on the server.

### `config/config.js` is per-machine and is not in git

It is listed in `.gitignore`, so a `git pull` never touches it and never brings
another machine's settings over yours. `config/config.example.js` is the tracked
template showing the full structure.

Two consequences: a fresh clone has no `config/config.js` and will not start
until you copy the example and fill it in; and when a pull changes the *example*,
that new setting is not in your file — compare the two.

---

## 6. Add the recipients, and test

On the masterlist page → **Alerts**:

1. Under **Who gets told**, add each person: the name **exactly as it appears in
   Teams**, and their email address. One row supplies both the @mention and the
   inbox, so the name shown on the card and the person actually pinged are always
   the same person.
2. Check **When to warn** — 30 days first warning, 7 days urgent, by default.
3. **Send alert now.**

You should see the WEIGHCOM scale in the card and the mail.

**"Sent to Teams (queued)"** is the normal answer from Power Automate. It means
the flow accepted the request — not that the card reached the channel. Check the
flow's run history the first time; after that, trust it.

### Recipients are shared with the other notification screen

They live in `NotificationRecipient` under the role `CALIBRATION`. The Teams
Notification page edits the same table, so somebody who leaves is removed in one
place. One person can hold two roles by having two rows.

---

## 7. The daily task  ← **to do**

The button covers the days somebody opens the page. This covers the rest.

> **Setting this up on the production server?** Follow
> **`docs/external-calibration-production.md`** instead of this section. It has
> the same task settings plus the things that only bite on a server: backing up
> `config/config.js` before pulling, checking the Supabase key, loading the data,
> and choosing which account the task runs as.

**Task Scheduler → Create Task** (not *Create Basic Task* — you need the
security options):

| Tab | Setting |
|-----|---------|
| General | Name: `Famax — Calibration Alert`. **Run whether user is logged on or not**. |
| Triggers | Daily, `07:30`. |
| Actions | Start a program → `<repo folder>\Run-CalibrationAlert.bat` <br> **Start in:** `<repo folder>` |
| Conditions | Untick *Start the task only if the computer is on AC power*. |
| Settings | Tick *Run task as soon as possible after a scheduled start is missed*. |

**"Start in" is not optional.** Without it the task runs from `system32`, the
script cannot find `config/config.js`, and it fails every morning with a
path error. Type the path with no quotation marks — Task Scheduler treats them
as part of it.

### Try it first

```bash
node scripts/calibration-alert.js --dry-run
```

Builds everything, prints it, sends nothing, logs nothing. Then run the `.bat`
by hand once and check `temp/calibration-alert.log`.

### What it does on its own

- **Nothing due → nothing sent.** No daily "all clear". An alert that arrives
  every morning is one people stop reading, and then they stop reading the one
  that matters.
- **Sends once a day.** If a digest already went out successfully this morning it
  will not go again — Task Scheduler retries, and a machine that wakes late fires
  missed tasks the moment it comes up. A *failed* send does not count, so a retry
  after a failure is allowed. `--force` overrides.
- **Exit code 0** = sent, or correctly nothing to send. **1** = something failed.
  That is what Task Scheduler shows as *Last Run Result*, so a red number means
  somebody should look.
- **Everything is logged** to `ext_cal_alert_log`, failures included. A failed
  send that left no row would be indistinguishable from a quiet day.

---

## 8. How the record works day to day

### Recording a calibration

Masterlist → **Record calibration** on the row (or the entry form direct). The
instrument arrives already chosen, so nobody files a certificate against the
wrong counting scale — there are two, both reading `DIGITAL COUNTING SCALE
(6000g x 0.2g)`, and only one of them is overdue.

Fill in the certificate, sign with **your own account password**, save. The due
date rolls forward, the badge changes, and the previous certificate is still
there under **History**.

### Things the form will not let you do

| It stops you | Because |
|--------------|---------|
| A due date before the calibration date | It is a typo, every time. |
| A calibration date in the future | It parks the instrument in a bucket nothing chases until that date arrives. |
| Two certificates for one instrument on one day | It is how a double-submit gets recorded twice. |
| `FAIL` with condition `GOOD` and no remarks | An instrument that came back out of tolerance, left on the floor marked good, is the exact failure this record exists to prevent. |

### The due date is typed, not calculated

It is pre-filled at the instrument's interval, and you can type over it. The
certificates are why: the MAGODA floor scale went 15 DEC 2025 → 14 DEC 2026 and
both counting scales 23 JUL 2026 → 22 JUL 2027 — a day short of a year, because
the lab dates the certificate, not us. The six MICRON block gauges run five
years. A calculated due date would have silently corrected six real certificates
into being wrong.

### Attaching the certificate

The **Certificate** field takes a **PDF**, or an image — JPG, PNG, WEBP or HEIC —
up to 10 MB. It is stored in the `calibration_certificate` bucket inside the
system, so the record does not depend on a network path staying where somebody
left it. The lab's PDF, or a phone photo of the printout: either works.

The old free-text field is still there underneath for a link, and anything
already recorded that way keeps working. Choosing a file disables it — an
uploaded image *is* the certificate link, and two different answers must not end
up in one column.

Nothing is uploaded when you pick the file. It goes up when you press **Save**,
because abandoning a half-filled form is ordinary and would otherwise leave an
image in the bucket belonging to a certificate that was never recorded. If the
upload fails, nothing is saved and you can retry with the form still in front of
you. If the *save* fails after the image went up — a duplicate date, usually —
the image is taken back out again.

After saving you get the image back as a thumbnail. That is deliberate: a
thumbnail that renders is the only thing that proves the file both reached the
bucket and can be read out of it again.

**Seeing a certificate.** Every row with one has a **View certificate** button,
and the certificate numbers in the History modal open the same viewer. Images
show inline, PDFs embed, and either way there is an **Open in a new tab** button
— an embedded PDF is at the mercy of the browser's built-in viewer and some
builds refuse to embed one at all.

**One file per certificate.** A multi-page certificate needs either the best
page photographed or the pages combined first. If that turns out to be a real
nuisance, multiple files per certificate is an additive change — a small table
alongside `ext_cal_event`, the way `subcon_do_image` already works.

### Criteria are copied onto each certificate

Edit the criteria on the form and it asks whether the change is permanent. Tick
it and the masterlist is updated too; leave it and it applies to that certificate
only. Either way the certificate keeps what applied on the day it was issued.

### Retiring an instrument

Set **Record status** to `OBSOLETE`. Do not delete — deleting removes every
certificate with it, which is the audit trail. The page says how many it is about
to take before it lets you.

### Printing

**Print** gives you REC-QAS010-05 as the workbook draws it, not the screen table
with its buttons hidden:

- **A4 landscape**, columns A–J at the widths the sheet sets (`NO` 5, `EQUIPMENT`
  15.71, `DESCRIPTION` 33.71 … converted to percentages so it still lines up if
  somebody prints Letter).
- **Times New Roman**, every cell ruled and centred.
- **Ten instruments per page**, which is what the source does — page 1 of the
  workbook is rows 6–25 and page 2 restarts at row 39, twenty rows at two per
  instrument. Change it in `ext_cal_form_settings.rows_per_page`.
- **Masthead on every page**: the Famax mark in A:B, the company line in C:E, the
  title and `(Page: n/m)` in F:J.
- **Signature block and retention footer on every page**, in the same columns.
- **Empty slots stay ruled.** A page with eight instruments still draws ten
  boxes, as page 2 of the workbook does — an unruled gap reads as the form having
  been cut.

Three things are deliberately *not* copied from the workbook:

| | |
|---|---|
| Page numbers are computed | Both sheets of the 2025–2026 file are headed `(Page: 1/1)`. That is a clerical slip, not a structure to reproduce — you get `1/2` and `2/2`. |
| Margins are 6 mm, not 0 | The workbook sets every margin to 0 and centres the print area. No browser prints reliably to the sheet edge, so this takes the smallest margin drivers generally honour. |
| Names come from settings | `NAME: FARIANA` / `NAME: AYYUB` are typed into the sheet. They live in `ext_cal_form_settings` now, so replacing somebody who left is not an edit to an HTML file. Leave either blank and the form prints a rule to sign by hand, as the 2024–2025 sheet did. |

**Print always gives the whole active list**, never the current filter. The form
is a controlled record of every externally calibrated instrument; a copy showing
only what happened to be in the search box would be indistinguishable from the
real thing, and wrong. Retired instruments are absent for the same reason — they
are not on the form, which is why they have no line number.

Check it once in your browser's **Print Preview** and set the printer to A4
landscape. If the page breaks in the wrong place, `rows_per_page` is the dial.

---

## 9. If something is wrong

| What you see | What it is |
|--------------|------------|
| "Restricted page" | The account is not `ALL` or `QUALITY`. Check it in Users. |
| "The masterlist could not load … relation does not exist" | Section 1 has not been run on this database. |
| "no webhook configured — paste the URL into config/config.js" | Section 5, and restart the server. |
| Alert says sent, nothing in Teams | Power Automate returned 202 (queued) and the flow failed afterwards. Its run history says why. |
| "Email is switched on but nobody is listed under CALIBRATION" | Section 6, step 1. |
| `Cannot POST /FamaxQCSystem/api/calibration-alert` | The server has not been restarted since this was installed. |
| Scheduled task fails, log shows a path error | The **Start in** field is empty. Section 7. |
| CSV opens in Excel with `Â±` and `Âµm` | Excel was told to import it rather than opening it. The file is UTF-8 with a BOM; double-click it instead. |
| Printed form breaks in the wrong place | `ext_cal_form_settings.rows_per_page` — it is 10, matching the workbook. |
| Printed form is portrait, or cut off at the right | The browser's print dialog is not on A4 landscape. The page asks for it via `@page`, but a printer setting overrides that. |
| An instrument is missing from the print | It is not `ACTIVE`. Retired instruments are not on the form by design — check its Record status. |
| "mime type application/pdf is not supported" | The PDF migration has not been run on that database. See section 1. |
| "The object exceeded the maximum allowed size" | Over 10 MB. Photograph it again at a lower resolution, or raise `file_size_limit` on the bucket. |
| Certificate thumbnail is a broken image | The bucket is not public, or its SELECT policy is missing. Re-run the certificate-upload migration. |

---

## 10. Files

| File | What it is |
|------|-----------|
| `sql/2026-08-25_external_calibration.sql` | Schema, view, RLS. |
| `sql/data/2026-08-25_external_calibration_seed.sql` | The 18 rows from the 2025–2026 sheet. |
| `sql/2026-08-25_external_calibration_form_settings.sql` | The printed form's masthead/signatures/footer, and `line_no` numbering only active rows. |
| `sql/data/2026-08-25_external_calibration_2024_2025.sql` | The 2024–2025 sheet, loaded as history. Every identity decision is stated in its header. |
| `sql/2026-08-25_external_calibration_certificate_upload.sql` | The `calibration_certificate` storage bucket, its policies, and `cert_storage_path`. |
| `sql/2026-08-25_external_calibration_certificate_pdf.sql` | Widens that bucket's allow-list to accept PDF. |
| `assets/calibration-certificate.js` | The allow-list, size limit and upload, shared by both screens. |
| `config/config.example.js` | Template for the per-machine `config/config.js`, which is not in git. |
| `docs/external-calibration-production.md` | Runbook for deploying and scheduling this on the production server. |
| `screen_page/calibration/external_calibration_masterlist.html` | The list, filters, print, alerts. |
| `screen_page/calibration/external_calibration_form.html` | Entering one certificate. |
| `assets/calibration-alert.js` | The card and the email. Shared by the page and the task. |
| `utils/webhookRelay.js` | Posting, and deciding honestly whether it arrived. |
| `controllers/qcController.js` | `relayCalibrationAlert` — the endpoint the page calls. |
| `scripts/calibration-alert.js` | The daily run. |
| `Run-CalibrationAlert.bat` | What Task Scheduler runs. Logs to `temp/`. |
| `config/config.js` | `CALIBRATION_ALERT` — the two webhook URLs and `APP_URL`. |
