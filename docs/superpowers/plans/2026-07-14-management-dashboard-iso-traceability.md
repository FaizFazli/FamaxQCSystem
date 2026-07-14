# Management Dashboard + ISO Traceability Plan

> **For agentic workers:** Implement in phases. Prefer `index.html` for live ops KPIs; `quality-hub.html` for plant-wide management views. Real key-in stays in `screen_page/*`.

**Goal:** Give management clear visual cards/charts on **index.html** and **Famax Quality Hub**, using existing Supabase tables; and map how those tables become an **ISO audit / traceability packet**.

**Architecture:** Read-only dashboards query PostgREST (`APP_CONFIG`). No new write path until phase 3 glue table. Combine dimensional QC (`Data_*`) with lot QC (`InspectionRecord`) using soft keys first (JO + Part + date), then a proper `inspection_run_id` later.

**Tech Stack:** Vue 3 CDN / existing hub app, Chart.js (already on some pages), Supabase REST, existing files `index.html`, `quality-hub.html`, `quality-hub.app.js`.

**Global Constraints:**
- Do not invent columns that don’t exist; only propose FKs in later tasks.
- Management dashboards **must not write** results (read-only).
- Soft keys today: `Part_Name`, `JO_Number`, free-text `Person` — mark risk in UI footer.
- Prefer 7d/30d/90d filters already on index.

---

## 0. What you already have (grounds every chart)

### Dimensional results
| Table | Use |
|-------|-----|
| `Data_IPQC` | In-process readings (R1–R3), JO, Machine, Person, Remarks |
| `Data_BUYOFF` | Buy-off accepted (R1–R5), Attempt_Group, QC_Technician, Setting |
| `data_buyoff_logs` | Failed + OK item attempts (status OK/NG) → **OOS count** |
| `buyoff_approvals` | Supervisor/HOD sign-off (PENDING/APPROVED) |
| `Data_IQC` / `Data_OQC` | Incoming/outgoing (R1–R5 + visual checklists) |
| Masters `IPQC` / `IQC` / `OQC` | Specs / instruments / points |

### Lot / schedule
| Table | Use |
|-------|-----|
| `InspectionSchedule` | Planned tasks, AssignTo, remaining qty |
| `InspectionRecord` | Accept/Reject/Scrap, defects JSON, InspectBy |

### Supporting chain
| Table | Use |
|-------|-----|
| `JobOrder` / `Parts` | Job ↔ part identity |
| `EmployeeTable` | People + pin |
| `gauges` + `verification_*` | Gauge calibration evidence |
| `storeRecords` / `inventory` | FG movement (loose JO link) |
| PDF files via `/saveInspectionPdf` | Visual evidence (path not always in DB) |

---

## 1. Visualization plan — `index.html` (shop-floor analytics)

**Audience:** Supervisors, QC leads, daily ops.  
**Tone:** Live, short windows (7/30 days).

| # | Widget | Data source | Chart / layout | Business question |
|---|--------|-------------|----------------|-------------------|
| A | KPI strip (already exists) | `Data_IPQC` / `Data_BUYOFF` (+ IQC/OQC tabs) | Numbers: Total / OK / NG / Yield | Are we winning today? |
| B | Daily OK vs NG trend (exists) | same | Line/bar by day | Getting better or worse? |
| C | Part / Machine breakdown (exists) | same | Bar | Which part/machine hurts yield? |
| D | **NEW: Buy-off OOS attempts** | `data_buyoff_logs` where `status=NG` | KPI + sparkline | How many scrap loops before 5 OK? |
| E | **NEW: Pending buy-off approvals** | `buyoff_approvals` `status=PENDING` | Count + list link to `BUYOFF-approvals.html` | Who is blocking release? |
| F | **NEW: Open schedule overdue** | `InspectionSchedule` past `EstFinished` still open | Badge + top 5 list | Late inspections? |
| G | **NEW: Top NG remarks** | `Data_IPQC.Remarks` / `Data_BUYOFF.Remarks` (split `|`) | Horizontal bar categories | What story do remarks tell? |
| H | Enable IQC/OQC cards | already fetchable | Remove `opacity:0.5` + same KPI logic | Full gate visibility |

**index.html placement**
1. Keep existing KPI/charts for active tab.
2. Add second row: **Buy-off process health** (D+E).
3. Add third row: **Schedule pressure** (F).
4. Re-enable IQC/OQC quick cards when validators confirm forms.

**Queries (postgrest patterns)**
```
GET /data_buyoff_logs?select=status,created_at,attempt_group&status=eq.NG&created_at=gte.<iso>
GET /buyoff_approvals?select=*&status=eq.PENDING&order=created_at.desc&limit=20
GET /InspectionSchedule?select=*&Status=neq.Done&order=EstFinished.asc&limit=50
```
(Use exact column casing as already used in frontends.)

---

## 2. Visualization plan — Famax Quality Hub (`quality-hub.html`)

**Audience:** Plant management, quality manager, ISO owner.  
**Tone:** Weekly/monthly, multi-module, low data entry.

| View | Priority widgets | Tables | Visualization |
|------|------------------|--------|---------------|
| **hub** (home) | Plant yield, open approvals, overdue schedule, gauge due, RM low stock | `InspectionRecord`, `buyoff_approvals`, `InspectionSchedule`, `verification_records`, `RawMaterialStock` | 4 KPI cards + traffic-light tiles |
| **quality** | Pass rate trend, NG by process, recent lot failures | `InspectionRecord` (live, not demo) | Line + stacked bar + table |
| **reports** | QC by part (live), OOS dimensional summary, JO completion | `InspectionRecord`, `Data_IPQC`, `Data_BUYOFF`, `JobOrder` | Tabs with filters Part / JO / date |
| **gauge** | Gauges overdue verification | `gauges`, `verification_records` | List + red/yellow/green |
| **store** | FG in/out by week, RM consumption | `storeRecords`, `RawMaterialMovement` | Bars |
| **maint** | PM compliance % | `MachinesM`, `MaintenanceLogs` | Donut |

**Must-fix in hub (before trusting numbers)**
1. Replace demo NG-by-process / openNG series with real aggregates.
2. Mobile: tables always in `overflow-x: auto` (shell CSS partially done).
3. Sidebar off-canvas under 768px (pair margin-left 0 already in CSS).

---

## 3. Recommended charts (copy-ready product line)

### Management (weekly slide)
1. **Yield rate** IPQC vs Buy-off vs lot Inspection (3 lines).
2. **Pareto of NG** by Part, then by Process.
3. **Buy-off first-pass yield** = accepted items / (accepted + OOS from logs).  
   Example: 5 OK + 5 OOS → FPY 50%; page shows only 5 OK.
4. **Approval latency** = mean hours `created` → `approved_at`.
5. **Schedule adherence** = on-time / planned.
6. **Customer risk view**: high RejectQty `InspectionRecord` + recent dimensional NG on same `Part_Name`.

### ISO evidence map (who asks what)
| ISO theme | Evidence packing using existing data |
|-----------|--------------------------------------|
| **Who** | `Person` / `InspectBy` / `approver_name` (+ later `empID`) |
| **What** | `Part_Name`, `Process`, master point rows |
| **When** | `created_at`, `actual_finished`, `approved_at` |
| **Where** | `Machine` / `Machine_No` |
| **With what instrument** | `Measuring_Instrument` text; ideally link `gauges` |
| **Against which criteria** | LSL/USL or Min/Max from row snapshot |
| **Result** | Readings + Accept/Reject/Scrap + Remarks |
| **Disposition** | `buyoff_approvals.status`, lot decision, ship PO from store |
| **Document** | PDF paths + revision notes (DMS / Parts.Revision) |

---

## 4. ISO traceability integration model

### Phase A — Virtual packet (no schema change)
Assemble by `JO_Number` + `Part_Name` + date window:
```
JobOrder
  ├─ Data_IPQC rows
  ├─ Data_BUYOFF rows (+ buyoff_approvals by Attempt_Group)
  ├─ data_buyoff_logs (attempt history + OOS count)
  ├─ InspectionRecord (lot counts/defects)
  ├─ InspectionSchedule tasks
  ├─ gauges verification for instruments used (text match, weak)
  └─ storeRecords where jo_number matches (ship ticket)
```
Expose as **Quality Hub → “Trace by JO”** search page:
- Header card (JO, part, process, status)
- Timeline of all inspections
- Buttons: open PDF folder / print packet

### Phase B — Soft ancestor id (minimal DB)
Add nullable columns (or small table):
```
inspection_headers (
  id uuid PK,
  jo_number text,
  part_name text,
  process text,
  machine text,
  inspector_empid text,
  type text,           -- IPQC | BUYOFF | IQC | OQC | LOT
  started_at, finished_at,
  pdf_path text
)
```
Write `header_id` on save from page2 finish paths.

### Phase C — Hard ISO controls
- Inspector always `empID` (not free name alone)
- Instrument must be verified-not-due (`gauges` + due_date)
- Ship gate: block `storeRecords` OUT if racist open PENDING buyoff for JO
- CAPA table for NCR: link defects to corrective action id

---

## 5. Data integrate map (what can be wired now)

```
index KPI/trend  ←── Data_IPQC / Data_BUYOFF / Data_IQC / Data_OQC
index OOS badge  ←── data_buyoff_logs (NG)
index approvals  ←── buyoff_approvals
hub quality view ←── InspectionRecord (+ schedules)
hub stores view  ←── inventory / storeRecords / RawMaterial*
hub gauge view   ←── gauges / verification_records
trace JO packet  ←── join all of the above on JO+Part
```

**Cannot fully close today without phase B/C:**
- Unique person identity of every historical row
- Gauge ↔ reading FKs
- Document revision freeze at measurement time
- Single closed CAPA loop

---

## 6. Mobile friendliness status (2026-07-14 audit + fixes)

### Already good
IPQC/BUYOFF page1–2, index shell, DMS dashboard, IQC/OQC entry pages (form-sized).

### Fixed this session
- `inspectionRejectReport.html` — horizontal scroll for wide table
- `IQC-page1/2.html`, `OQC-page1/2.html` — mobile paddings, overflow tables, sticky full-width buttons, 16px inputs
- `inspectionDashboard.html` — mobile off-canvas sidebar; `w-full` not `100vw`
- `quality-hub.html` — starting `@media 768` table overflow / margin-left 0

### Still ok / later polish
- `quality-hub` large tables + desktop-first UI (needs continuous QA on real phone)
- Daily report `min-width: 1000px` checker grid (scroll exists, still pan-heavy)
-Print-first layouts that stay pan-to-read (OK for paper)

---

## Implementation tasks (when building web widgets)

### Task 1: Index — Buy-off OOS + approvals strip
**Files:** `index.html`  
**Steps:**
1. Add two KPI cards next to existing strip.
2. Fetch `data_buyoff_logs` NG count + `buyoff_approvals` PENDING for selected range.
3. Link “Approvals” → `screen_page/buy_off/BUYOFF-approvals.html`.
4. Manual test: create pending approval, refresh ... count +1.

### Task 2: Hub — kill demo series on quality view
**Files:** `quality-hub.app.js`  
**Steps:**
1. Aggregate NG from `InspectionRecord.RejectQty` grouped by `process`.
2. Pass-rate series from daily `AcceptQty/(TotalCheck)`.
3. Show empty state if API fails (no silent seed).

### Task 3: Hub — Trace by JO
**Files:** `quality-hub.html`, `quality-hub.app.js`  
**Steps:**
1. Search box: JO.
2. Parallel fetch all tables filtered by JO.
3. Render timeline + counts (IPQC rows, Buy-off, OOS log count, lot records).
4. Export simpler HTML/PDF packet.

### Task 4: optional inspection_headers
**Files:** SQL + page2 finish handlers (`IPQC-page2`, `BUYOFF-page2`, lot form)  
**Steps:** create table, set id in localStorage at start of run, write on finish.

---

## Success criteria

| Metric | Target |
|--------|--------|
| Manager can answer weekly yield without Excel | Yes from index alone |
| OOS loops for buy-off visible | OOS count KPI matches page1 counter philosophy |
| JO audit in <2 minutes | Trace view lists all linked rows |
| Mobile shop use | No page wider than viewport without scroll container on key ops pages |
| ISO story board | Document uses tables above with Who/What/When/Where/Result |

---

## Out of scope (YAGNI until asked)
- Real-time MTConnect machine dashboard
- New full CAPA product
- Replacing Quality Hub with a SPA framework
- Offline PWA

---

## Notes from current code reality
- Page2 Buy-off remarks store `OUT of spec count: N` from page1 localStorage counters.
- Index already groups dimensional OK/NG by reading vs LSL/USL.
- Quality Hub is **read-only** and still mixes seed data — treat as management shell, not system of record until Task 2 done.
