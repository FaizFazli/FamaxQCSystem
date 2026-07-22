# Power BI Guide — Inspection Dashboard Data

A step-by-step guide for building the Inspection Dashboard in Power BI from the
FamaxQCSystem database. Written for someone new to the project.

---

## 1. What the data is

The dashboard is built almost entirely from **one table, `InspectionRecord`**,
with two supporting tables. The backend is a **self-hosted Supabase**, which is
**PostgreSQL** underneath, running on the server at **`192.168.0.5`**.

### `InspectionRecord` — the core table (all the KPI numbers)
| Column | Meaning |
|---|---|
| `created_at` | When the record was entered |
| `actual_finished` | **When the inspection was finished** (primary date) |
| `TotalCheck` | Total pieces checked |
| `AcceptQty` | Accepted / passed |
| `RejectQty` | Rejected |
| `ScrapQty` | Scrapped |
| `ReworkQty` | Reworked |
| `InspectBy` | Inspector name |
| `part_no`, `Part_Name` | Part identity |
| `JO_Number` | Job order |
| `Parameter`, `Inspection_Type` | What was inspected |
| `remark_finished` | Remark on overdue closes |
| `schedule_id` | Link to `InspectionSchedule.id` |

### `InspectionSchedule` — for on-time / overdue analysis
`id`, `StartDate`, `EstFinished`, `Status`, `AssignTo`, `Replacement`,
`JO_Number`, `Part_Name`, `Parameter`, `actual_finished_time`, `remaining_qty`.
Linked to a record by `InspectionRecord.schedule_id = InspectionSchedule.id`.

### `EmployeeTable` — QA/QC roster
`name`, `department` (filter `department = 'QA/QC'`).

> **⚠️ Month/day rule (important):** attribute a check to a month/day by
> `actual_finished`, and fall back to `created_at` when it's empty. If you bucket
> by `created_at` instead, your totals won't match the app.

---

## 2. Easiest path: use the ready-made view

Instead of joining tables yourself, the project ships a view that does it for
you: **`vw_inspection_dashboard`** (see `sql/2026-07-22_vw_inspection_dashboard.sql`).

Have the DB admin run that SQL file once. It produces **one flat row per
inspection record** already containing:
- `eff_date`, `eff_month` (the correct attribution date, computed for you)
- `total_check`, `accept_qty`, `reject_qty`, `scrap_qty`, `rework_qty`
- `pass_rate`, `reject_rate`, `rework_rate`
- schedule fields + `is_overdue`, `overdue_minutes`

In Power BI you then just import the single table `vw_inspection_dashboard` — no
joins needed.

---

## 3. Connecting Power BI to the database

### Option A — PostgreSQL connector (recommended)

1. Power BI Desktop → **Get Data → PostgreSQL database**.
2. **Server:** `192.168.0.5` — **Port:** `5432` (or `6543` if using the Supabase
   pooler). Enter as `192.168.0.5:5432` if prompted for one box.
3. **Database:** `postgres`
4. **Data Connectivity mode:** Import
5. **Credentials:** a **read-only** Postgres login (see §4 to get one).
6. In the Navigator, tick either `vw_inspection_dashboard` (easiest) **or** the
   three raw tables `InspectionRecord`, `InspectionSchedule`, `EmployeeTable`.
7. Load. If you imported raw tables, create the relationship
   `InspectionRecord[schedule_id] → InspectionSchedule[id]`.

### Option B — REST API (only if the DB port can't be opened)

The same data is at `http://192.168.0.5:8000/rest/v1/<table>`. Use the anon key
from `assets/app-config.js`. Power BI → **Get Data → Blank query → Advanced
Editor**, paste and adapt this (handles the 1000-row page limit):

```m
let
    BaseUrl  = "http://192.168.0.5:8000/rest/v1/InspectionRecord",
    ApiKey   = "PUT-ANON-KEY-HERE",   // from assets/app-config.js
    PageSize = 1000,

    GetPage = (offset as number) as list =>
        Json.Document(
            Web.Contents(BaseUrl, [
                Query   = [ select = "*",
                            limit  = Text.From(PageSize),
                            offset = Text.From(offset) ],
                Headers = [ apikey = ApiKey,
                            Authorization = "Bearer " & ApiKey ]
            ])
        ),

    Pages = List.Generate(
        () => [p = GetPage(0), off = 0],
        each List.Count([p]) > 0,
        each [p = GetPage([off] + PageSize), off = [off] + PageSize],
        each [p]
    ),

    AllRows  = List.Combine(Pages),
    AsTable  = Table.FromList(AllRows, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
    Expanded = Table.ExpandRecordColumn(AsTable, "Column1",
        {"id","created_at","actual_finished","TotalCheck","AcceptQty",
         "RejectQty","ScrapQty","ReworkQty","InspectBy","part_no",
         "Part_Name","JO_Number","schedule_id","remark_finished"})
in
    Expanded
```

Repeat for `InspectionSchedule` and `EmployeeTable` (or just query the view:
`.../rest/v1/vw_inspection_dashboard`).

> The REST route is fiddlier (manual paging + typing). Prefer Option A whenever
> the DB port is reachable.

---

## 4. Getting a database login (for Option A)

The Postgres username/password lives on the **server** (`192.168.0.5`), not in
this app. On that machine (PowerShell):

```powershell
docker ps                                       # find the DB container, e.g. supabase-db
docker exec supabase-db env | Select-String POSTGRES
```

That prints `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`.

**Do not give the intern the master `postgres` password.** Have the admin create
a read-only role once:

```sql
CREATE ROLE bi_readonly LOGIN PASSWORD 'pick-a-strong-password';
GRANT CONNECT ON DATABASE postgres TO bi_readonly;
GRANT USAGE ON SCHEMA public TO bi_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO bi_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO bi_readonly;
```

The admin must also make sure port **5432** (or **6543**) is published to the LAN
in the Supabase `docker-compose.yml` and allowed through the firewall.

---

## 5. DAX measures

Build these on the `vw_inspection_dashboard` table (rename it `Inspections` in
the model if you like):

```dax
Total Checks = SUM(vw_inspection_dashboard[total_check])
Passed       = SUM(vw_inspection_dashboard[accept_qty])
Rejected     = SUM(vw_inspection_dashboard[reject_qty])
Scrap        = SUM(vw_inspection_dashboard[scrap_qty])
Rework       = SUM(vw_inspection_dashboard[rework_qty])
Records      = COUNTROWS(vw_inspection_dashboard)

Pass Rate    = DIVIDE([Passed],   [Total Checks])
Reject Rate  = DIVIDE([Rejected], [Total Checks])
Rework Rate  = DIVIDE([Rework],   [Total Checks])

Overdue Count    = CALCULATE([Records], vw_inspection_dashboard[is_overdue] = TRUE())
Avg Overdue Mins = AVERAGE(vw_inspection_dashboard[overdue_minutes])
```

If you imported the raw `InspectionRecord` table instead of the view, point the
measures at `InspectionRecord[TotalCheck]`, `[AcceptQty]`, etc.

### Date axis / time intelligence
Create a Date table and relate it to **`eff_date`** (not `created_at`):

```dax
DateTable = CALENDAR(DATE(2025,1,1), DATE(2027,12,31))
```

Relate `DateTable[Date]` → `vw_inspection_dashboard[eff_date]`, then slice all
measures by `DateTable` for month/day trends that match the app.

---

## 6. Suggested visuals (to mirror the app)
- KPI cards: **Total Checks, Passed, Rejected, Scrap, Rework Rate**
- Line chart: **Total Checks by `eff_date`** (daily trend)
- Bar chart: **Total Checks / Reject Rate by `inspector`** (`InspectBy`)
- Table: **per-part** `Part_Name` with checks, pass rate, reject rate
- Card: **Overdue Count** and **Avg Overdue Mins**
