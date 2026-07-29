# Job Traveler Card — User Guide

A step-by-step guide to using the **Job Traveler Card** in the Famax QC System.

> The Job Traveler Card is at `screen_page/job_order/jobTravelerCard.html`.
> One-time setup: an admin must run the three SQL migrations in `sql/` dated `2026-07-28` so the
> sign-off, shift and production-progress columns exist.

---

## 1. Opening the card

You can open it two ways:

- **Home dashboard** → *Production Planning* group → **Job Traveler Card** tile.
- **Job Order page** (`Update JO`) → search a part → click **Traveler Card** on any JO row
  (opens the card with that JO already loaded).

_[Screenshot to capture: home dashboard tile + Update JO row button]_

---

## 2. Loading a Job Order

1. Click the **Job Order Number** box. A dropdown of recent JOs appears.
2. Type to filter by JO number or part name, or scroll and click one.
3. The card loads instantly (or press **Load** / Enter after typing).

If you arrived via the Traveler Card button on a JO row, the card is already loaded.

_[Screenshot to capture: JO search dropdown]_

---

## 3. Reading the card

### Header
Shows JO Number, Part Name / No, Revision, Ordered Qty, Customer PO, Created & Printed dates, and a
**QR code** of the JO number for shop-floor scanning.

### Production progress (top bar)
A green bar shows **Produced / Ordered (Remaining)**. A badge shows:
- 🟢 **PRODUCTION DONE** — every process has produced its full quantity.
- 🟡 **IN PRODUCTION** — still producing.

### Section A — Process Routing & QC Status
One row per process (from the part master flow). Columns: Process, **QC Status** badge, Accept,
Reject, Inspector, Last Activity, and the Operator / QC **sign-off** cells.

Status badge meaning:

| Badge | Meaning |
|-------|---------|
| 🟢 **PASSED** | Inspection accepted / Buy-off OK, no failures. |
| 🔴 **FAILED** | An out-of-spec IPQC reading, a Buy-off NG, or rejects with no accept. |
| 🟡 **IN-PROGRESS** | Checking started but not fully accepted yet. |
| ⚪ **PENDING** | No QC records yet. |

The **Incoming (IQC)** and **Outgoing (OQC)** bookend rows sit above the first and below the last step.

### Section B — Production Output
Per process: Machine, Produced, Reject, Remaining and a progress bar. Click the **[n logs]** link next
to a process to expand the **Date / Shift / Machine / Counter / Output / Reject / Operator** breakdown.

_[Screenshot to capture: Section A badges + Section B expanded breakdown]_

---

## 4. Logging production output (operators)

Output is entered on the **Daily Production Entry** screen
(`screen_page/production_planning/daily_output.html`), once per machine per shift:

1. **Production Date** — defaults to today.
   - ⚠️ **Night shift after midnight:** keep the date the shift *started*. A 19:00–05:00 shift logged
     at 02:00 should stay on the previous calendar date.
2. **Shift** — choose **Day** (08:00–18:00, OT to 19:00) or **Night** (19:00–05:00).
3. **Operator (PIC)** — your name / ID.
4. **Job Order / Part / Process / Machine** — search and select.
5. **Machine Counter Start / End** and **Reject Qty** — the **Net OK output** is calculated
   automatically (`end − start − reject`).
6. Click **Submit Entry**.

The system adds your output to the JO's running total and, once the total reaches the ordered
quantity, flags the JO as **PRODUCTION DONE** automatically. Date, shift and operator stay filled so
you can log several machines/processes quickly.

_[Screenshot to capture: daily output form with Shift + Operator]_

---

## 5. Signing off a step

On the traveler card, in **Section A**:

1. Click **Sign** in the **Operator Sign** or **QC Sign** cell of a completed process.
2. Enter your name (pre-filled if you are logged in) and an optional remark.
3. Click **Sign**. Your name + timestamp are saved and shown in the cell.

Signatures are stored in `TravelerSignoff` and persist across reloads.

_[Screenshot to capture: sign-off modal]_

---

## 6. Printing / exporting

- **Print** — opens the browser print dialog; use it to print on paper or *Save as PDF*. The layout
  is A4 portrait; badge and progress colours are preserved.
- **Save PDF** — downloads `Traveler_<JO>.pdf` directly.

Print at the start (blank sign-off boxes for wet-ink signatures on the shop floor) and again at close
(with digital sign-offs + final production totals) as the ISO record.

---

## Quick reference

| I want to… | Where |
|------------|-------|
| See a JO's full status | Job Traveler Card |
| Record parts produced this shift | Daily Production Entry (`daily_output.html`) |
| Sign a completed process | Job Traveler Card → Sign |
| Print the card | Job Traveler Card → Print / Save PDF |
| Mark the JO QC-complete | Update JO (`UpdateJO.html`) |

## Troubleshooting

- **"Could not save signature"** — the `TravelerSignoff` table migration hasn't been run yet. Ask an admin to run `sql/2026-07-28_traveler_signoff.sql`.
- **Shift/Operator not saving on output** — run `sql/2026-07-28_shift_output.sql`.
- **Progress bar stays at 0** — confirm the output was logged against the same `JO_Number` **and** `Process` spelling as the Job Order, and that `sql/2026-07-28_joborder_production_progress.sql` has been applied.
