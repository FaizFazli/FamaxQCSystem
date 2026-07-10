# Part Name Inspection Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a part-first page under `screen_page/inspection/` that loads part names from `Parts`, shows all `InspectionRecord` rows for the chosen part, and exports them to Excel.

**Architecture:** Single Vue 3 CDN page talks to Supabase PostgREST via axios (`APP_CONFIG`). No Node routes. Dashboard gets one sidebar button that navigates with existing `goTo()`.

**Tech Stack:** Vue 3, axios, SheetJS (`xlsx` CDN), `theme.css`, `assets/app-config.js`

## Global Constraints

- Use `window.APP_CONFIG.url` + `window.APP_CONFIG.key` only — never hardcode host/IP/key
- Data source is **`InspectionRecord`**, not Data_IPQC
- Part list from **`Parts.Part_Name`** (unique, non-empty, sorted)
- Export format: **Excel only** (SheetJS)
- No inline edit, PDF, print, date filter, or new server endpoints
- Match visual language of `inspectionDailyReport.html` (theme tokens + simple header)

## File map

| File | Responsibility |
|------|----------------|
| `screen_page/inspection/inspectionPartSummary.html` | New page: UI, fetch, table, export |
| `screen_page/inspection/inspectionDashboard.html` | Add sidebar nav button after Daily Report |

---

### Task 1: Create `inspectionPartSummary.html`

**Files:**
- Create: `screen_page/inspection/inspectionPartSummary.html`

**Interfaces:**
- Consumes: Supabase REST `Parts`, `InspectionRecord`; `window.APP_CONFIG`
- Produces: Standalone page at relative path `inspectionPartSummary.html` (same folder as dashboard)

- [ ] **Step 1: Create the page file with complete content**

Write `screen_page/inspection/inspectionPartSummary.html` exactly as follows (single self-contained page):

```html
<!DOCTYPE html>
<html lang="en">

<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Part Name Inspection Summary | Famax Quality Hub</title>
    <link rel="icon" type="png" href="/FamaxQCSystem/assets/LogoRound.png?v=2">
    <script src="https://unpkg.com/vue@3/dist/vue.global.prod.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/axios/dist/axios.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js"></script>
    <script src="/assets/app-config.js"></script>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="/assets/theme.css">
    <style>
        body {
            font-family: var(--font-sans);
            background: var(--bg-body);
            color: var(--text-main);
            margin: 0;
            padding: var(--space-4);
        }
        .page { max-width: 1500px; margin: 0 auto; }
        .card {
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: var(--radius-lg);
            box-shadow: var(--shadow);
            padding: var(--space-5);
            margin-bottom: var(--space-5);
        }
        .header-row {
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: var(--space-4);
            flex-wrap: wrap;
            margin-bottom: var(--space-5);
        }
        .title {
            margin: 0;
            font-size: var(--fs-xl);
            font-weight: 800;
            text-transform: uppercase;
            letter-spacing: -0.3px;
        }
        .title span { color: var(--primary); }
        .toolbar {
            display: flex;
            flex-wrap: wrap;
            gap: var(--space-4);
            align-items: flex-end;
        }
        .field { display: flex; flex-direction: column; gap: var(--space-1); min-width: 260px; flex: 1; }
        .field label {
            font-size: var(--fs-xs);
            font-weight: 700;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.04em;
        }
        select, .btn {
            height: 42px;
            border-radius: var(--radius-sm);
            font-family: inherit;
        }
        select {
            border: 1px solid var(--border);
            padding: 0 12px;
            background: #fff;
            color: var(--text-main);
        }
        .btn {
            border: none;
            padding: 0 18px;
            font-weight: 700;
            cursor: pointer;
            background: var(--primary);
            color: #fff;
            display: inline-flex;
            align-items: center;
            gap: 8px;
        }
        .btn:hover:not(:disabled) { background: var(--primary-hover); }
        .btn:disabled { opacity: 0.45; cursor: not-allowed; }
        .btn-success { background: var(--success); }
        .btn-success:hover:not(:disabled) { background: #059669; }
        .btn-home {
            width: 40px; height: 40px; border-radius: 999px;
            border: none; background: var(--surface-muted); cursor: pointer;
        }
        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
            gap: var(--space-3);
            margin-bottom: var(--space-5);
        }
        .stat {
            background: var(--surface-muted);
            border: 1px solid var(--border);
            border-radius: var(--radius-sm);
            padding: var(--space-3) var(--space-4);
        }
        .stat .label {
            font-size: var(--fs-xs);
            font-weight: 700;
            color: var(--text-muted);
            text-transform: uppercase;
        }
        .stat .value { font-size: var(--fs-lg); font-weight: 800; margin-top: 4px; }
        .table-wrap { width: 100%; overflow-x: auto; }
        table.rec {
            width: 100%;
            min-width: 1200px;
            border-collapse: collapse;
            border: 1px solid var(--border);
        }
        table.rec th {
            background: var(--surface-muted);
            color: var(--text-muted);
            font-size: var(--fs-xs);
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.04em;
            padding: 10px 8px;
            text-align: left;
            border-bottom: 1px solid var(--border);
            white-space: nowrap;
        }
        table.rec td {
            padding: 10px 8px;
            border-bottom: 1px solid var(--border);
            font-size: var(--fs-sm);
            vertical-align: top;
        }
        .empty {
            text-align: center;
            color: var(--text-muted);
            padding: var(--space-10);
            font-weight: 600;
        }
        .err { color: #b91c1c; font-weight: 600; margin-top: var(--space-3); }
        .ok { color: #059669; font-weight: 700; }
        .bad { color: #dc2626; font-weight: 700; }
    </style>
</head>

<body>
    <div id="app" class="page">
        <div class="card">
            <div class="header-row">
                <h1 class="title">Part Name <span>Inspection Summary</span></h1>
                <button class="btn-home" type="button" title="Dashboard" @click="goHome">
                    <i class="fa fa-home"></i>
                </button>
            </div>

            <div class="toolbar">
                <div class="field">
                    <label for="partSelect">Part Name (from Parts)</label>
                    <select id="partSelect" v-model="selectedPart" @change="loadRecords">
                        <option value="">— Select part name —</option>
                        <option v-for="p in partNames" :key="p" :value="p">{{ p }}</option>
                    </select>
                </div>
                <button class="btn" type="button" @click="loadRecords" :disabled="!selectedPart || loading">
                    <i class="fa fa-sync"></i> Refresh
                </button>
                <button class="btn btn-success" type="button" @click="exportExcel" :disabled="!rows.length">
                    <i class="fa fa-file-excel"></i> Export Excel
                </button>
            </div>
            <p v-if="error" class="err">{{ error }}</p>
            <p v-if="loading" style="margin-top:12px;font-weight:600;color:var(--text-muted)">Loading…</p>
        </div>

        <div class="card" v-if="selectedPart">
            <div class="stats">
                <div class="stat"><div class="label">Records</div><div class="value">{{ stats.count }}</div></div>
                <div class="stat"><div class="label">Total Check</div><div class="value">{{ stats.total }}</div></div>
                <div class="stat"><div class="label">Accept</div><div class="value ok">{{ stats.accept }}</div></div>
                <div class="stat"><div class="label">Reject</div><div class="value bad">{{ stats.reject }}</div></div>
                <div class="stat"><div class="label">Rework</div><div class="value">{{ stats.rework }}</div></div>
                <div class="stat"><div class="label">Scrap</div><div class="value">{{ stats.scrap }}</div></div>
            </div>

            <div v-if="!loading && !rows.length" class="empty">No inspection records for this part.</div>

            <div v-else class="table-wrap">
                <table class="rec">
                    <thead>
                        <tr>
                            <th>Date / Time</th>
                            <th>Part Name</th>
                            <th>Part No</th>
                            <th>Process</th>
                            <th>JO</th>
                            <th>DO</th>
                            <th>Type</th>
                            <th>Category</th>
                            <th>Parameter</th>
                            <th>Inspect By</th>
                            <th>Finalize By</th>
                            <th>Total</th>
                            <th>Reject</th>
                            <th>Rework</th>
                            <th>Accept</th>
                            <th>Scrap</th>
                            <th>Remark</th>
                            <th>Remark Finished</th>
                        </tr>
                    </thead>
                    <tbody>
                        <tr v-for="r in rows" :key="r.id || (r.created_at + r.JO_Number + r.Parameter)">
                            <td>{{ formatDateTime(r.actual_finished || r.created_at) }}</td>
                            <td>{{ r.Part_Name || '-' }}</td>
                            <td>{{ r.part_no || '-' }}</td>
                            <td>{{ r.process || '-' }}</td>
                            <td>{{ r.JO_Number || '-' }}</td>
                            <td>{{ r.DO_Number || '-' }}</td>
                            <td>{{ r.Inspection_Type || '-' }}</td>
                            <td>{{ r.Category || '-' }}</td>
                            <td>{{ r.Parameter || '-' }}</td>
                            <td>{{ r.InspectBy || '-' }}</td>
                            <td>{{ r.FinalizeBy || '-' }}</td>
                            <td><strong>{{ num(r.TotalCheck) }}</strong></td>
                            <td class="bad">{{ num(r.RejectQty) }}</td>
                            <td>{{ num(r.ReworkQty) }}</td>
                            <td class="ok">{{ num(r.AcceptQty) }}</td>
                            <td>{{ num(r.ScrapQty) }}</td>
                            <td>{{ formatRemark(r.Remark) }}</td>
                            <td>{{ r.remark_finished || '-' }}</td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>

        <div class="card" v-else>
            <div class="empty">Select a part name to load full inspection history.</div>
        </div>
    </div>

    <script>
        const { createApp, ref, computed, onMounted } = Vue;

        function formatRemark(remark) {
            if (remark == null || remark === '') return '-';
            if (typeof remark === 'string') {
                try { remark = JSON.parse(remark); } catch (_) { return remark || '-'; }
            }
            if (!Array.isArray(remark)) return String(remark);
            if (!remark.length) return '-';
            return remark.map((d) => {
                const desc = (d && (d.description || d.Description)) || '';
                const qty = d && (d.quantity != null ? d.quantity : d.Quantity);
                return desc ? `${String(desc).toUpperCase()}:${Number(qty) || 0}` : '';
            }).filter(Boolean).join('; ') || '-';
        }

        function formatDateTime(iso) {
            if (!iso) return '-';
            const d = new Date(iso);
            if (isNaN(d.getTime())) return String(iso);
            return d.toLocaleDateString('en-GB') + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        }

        function num(v) { return Number(v) || 0; }

        function safeFilePart(name) {
            return String(name || 'part').replace(/[\\/:*?"<>|]+/g, '_').slice(0, 80);
        }

        createApp({
            setup() {
                const api = axios.create({
                    baseURL: `${window.APP_CONFIG.url}/rest/v1`,
                    headers: {
                        apikey: window.APP_CONFIG.key,
                        Authorization: `Bearer ${window.APP_CONFIG.key}`
                    }
                });

                const partNames = ref([]);
                const selectedPart = ref('');
                const rows = ref([]);
                const loading = ref(false);
                const error = ref('');

                const stats = computed(() => {
                    return rows.value.reduce((acc, r) => {
                        acc.count += 1;
                        acc.total += num(r.TotalCheck);
                        acc.accept += num(r.AcceptQty);
                        acc.reject += num(r.RejectQty);
                        acc.rework += num(r.ReworkQty);
                        acc.scrap += num(r.ScrapQty);
                        return acc;
                    }, { count: 0, total: 0, accept: 0, reject: 0, rework: 0, scrap: 0 });
                });

                const loadParts = async () => {
                    error.value = '';
                    try {
                        const res = await api.get('/Parts?select=Part_Name');
                        const list = (res.data || [])
                            .map((r) => r.Part_Name)
                            .filter(Boolean);
                        partNames.value = [...new Set(list)].sort((a, b) => a.localeCompare(b));
                    } catch (e) {
                        console.error(e);
                        error.value = 'Failed to load part names from Parts.';
                        partNames.value = [];
                    }
                };

                const fetchRecordsForPart = async (name) => {
                    const q = encodeURIComponent(name);
                    const res = await api.get(
                        `/InspectionRecord?Part_Name=eq.${q}&order=created_at.desc`
                    );
                    return res.data || [];
                };

                const loadRecords = async () => {
                    if (!selectedPart.value) {
                        rows.value = [];
                        return;
                    }
                    loading.value = true;
                    error.value = '';
                    try {
                        let data = await fetchRecordsForPart(selectedPart.value);
                        if (!data.length) {
                            const upper = selectedPart.value.toUpperCase();
                            if (upper !== selectedPart.value) {
                                data = await fetchRecordsForPart(upper);
                            }
                        }
                        rows.value = data;
                    } catch (e) {
                        console.error(e);
                        rows.value = [];
                        error.value = 'Failed to load inspection records.';
                    } finally {
                        loading.value = false;
                    }
                };

                const exportExcel = () => {
                    if (!rows.value.length) return;
                    const sheetRows = rows.value.map((r) => ({
                        'Date/Time': formatDateTime(r.actual_finished || r.created_at),
                        'Part Name': r.Part_Name || '',
                        'Part No': r.part_no || '',
                        Process: r.process || '',
                        JO: r.JO_Number || '',
                        DO: r.DO_Number || '',
                        'Inspection Type': r.Inspection_Type || '',
                        Category: r.Category || '',
                        Parameter: r.Parameter || '',
                        'Inspect By': r.InspectBy || '',
                        'Finalize By': r.FinalizeBy || '',
                        'Total Check': num(r.TotalCheck),
                        Reject: num(r.RejectQty),
                        Rework: num(r.ReworkQty),
                        Accept: num(r.AcceptQty),
                        Scrap: num(r.ScrapQty),
                        Remark: formatRemark(r.Remark),
                        'Remark Finished': r.remark_finished || ''
                    }));
                    const ws = XLSX.utils.json_to_sheet(sheetRows);
                    const wb = XLSX.utils.book_new();
                    XLSX.utils.book_append_sheet(wb, ws, 'Inspection');
                    const day = new Date().toISOString().slice(0, 10);
                    XLSX.writeFile(wb, `Inspection_${safeFilePart(selectedPart.value)}_${day}.xlsx`);
                };

                const goHome = () => {
                    window.location.href = 'inspectionDashboard.html';
                };

                onMounted(loadParts);

                return {
                    partNames, selectedPart, rows, loading, error, stats,
                    loadRecords, exportExcel, goHome, formatDateTime, formatRemark, num
                };
            }
        }).mount('#app');
    </script>
</body>

</html>
```

- [ ] **Step 2: Sanity-check file exists and has key strings**

Run (PowerShell from repo root):

```powershell
Select-String -Path "screen_page\inspection\inspectionPartSummary.html" -Pattern "InspectionRecord|exportExcel|Parts\?select"
```

Expected: matches for `Parts?select`, `InspectionRecord`, `exportExcel`.

- [ ] **Step 3: Commit (only if user asked to commit; otherwise skip)**

```bash
git add screen_page/inspection/inspectionPartSummary.html
git commit -m "feat(inspection): add part name inspection summary page"
```

---

### Task 2: Link from `inspectionDashboard.html`

**Files:**
- Modify: `screen_page/inspection/inspectionDashboard.html` (sidebar nav, after Daily Report button ~line 483)

**Interfaces:**
- Consumes: existing `goTo(file)` helper on dashboard
- Produces: sidebar entry “Part Summary” → `inspectionPartSummary.html`

- [ ] **Step 1: Insert sidebar button after the Daily Report block**

Find this block (ends with Daily Report close `</button>`):

```html
                <!-- 8. INSPECTION DAILY REPORT -->
                <button @click="goTo('inspectionDailyReport.html')" title="Inspection Daily Report"
                    :class="isSidebarOpen ? 'w-full justify-start px-4' : 'w-12 h-12 justify-center mx-auto'"
                    class="nav-item flex items-center hover:bg-gray-100/50 rounded-2xl transition-all" style="color: var(--primary);">
                    <i class="fa-regular fa-calendar-check text-xl flex-shrink-0"></i>
                    <span v-if="isSidebarOpen"
                        class="ml-4 text-[10px] font-black uppercase tracking-widest whitespace-nowrap">
                        Daily Report
                    </span>
                </button>
```

Immediately after it, insert:

```html
                <!-- 8b. PART NAME INSPECTION SUMMARY -->
                <button @click="goTo('inspectionPartSummary.html')" title="Part Name Inspection Summary"
                    :class="isSidebarOpen ? 'w-full justify-start px-4' : 'w-12 h-12 justify-center mx-auto'"
                    class="nav-item flex items-center hover:bg-gray-100/50 rounded-2xl transition-all" style="color: var(--primary);">
                    <i class="fa-solid fa-cubes text-xl flex-shrink-0"></i>
                    <span v-if="isSidebarOpen"
                        class="ml-4 text-[10px] font-black uppercase tracking-widest whitespace-nowrap">
                        Part Summary
                    </span>
                </button>
```

Do not reorder other items.

- [ ] **Step 2: Verify link string present**

```powershell
Select-String -Path "screen_page\inspection\inspectionDashboard.html" -Pattern "inspectionPartSummary"
```

Expected: one match with `goTo('inspectionPartSummary.html')`.

- [ ] **Step 3: Commit (only if user asked)**

```bash
git add screen_page/inspection/inspectionDashboard.html
git commit -m "feat(inspection): link part name inspection summary on dashboard"
```

---

### Task 3: Manual verification (browser)

**Files:** none (runtime check)

**Prerequisites:** Express on :80, Supabase on :8000, at least one `Parts` row and ideally `InspectionRecord` rows for a part.

- [ ] **Step 1: Open dashboard**

Navigate to: `http://localhost/FamaxQCSystem/screen_page/inspection/inspectionDashboard.html`  
(or your LAN host + `/FamaxQCSystem/...`)

- [ ] **Step 2: Open Part Summary**

Click **Part Summary** in the sidebar.  
Expected: new page loads; dropdown populates with part names; empty state text visible until selection.

- [ ] **Step 3: Select a part that has records**

Expected: table fills; stats chips update; Export enabled.

- [ ] **Step 4: Select a part with no records**

Expected: “No inspection records for this part.” Export disabled.

- [ ] **Step 5: Export**

Click **Export Excel**.  
Expected: download `Inspection_<part>_<YYYY-MM-DD>.xlsx` with flat columns matching the table.

- [ ] **Step 6: Home**

Click home button → returns to `inspectionDashboard.html`.

---

## Spec coverage checklist

| Spec requirement | Task |
|------------------|------|
| Page at `inspectionPartSummary.html` | Task 1 |
| Part dropdown from `Parts` | Task 1 `loadParts` |
| Full `InspectionRecord` history for part | Task 1 `loadRecords` |
| Uppercase retry if 0 rows | Task 1 `loadRecords` |
| Summary chips | Task 1 `stats` |
| Excel export only | Task 1 `exportExcel` |
| Dashboard link | Task 2 |
| APP_CONFIG only | Task 1 axios setup |
| No edit/PDF/date filter | omitted by design |

## Placeholder / consistency self-review

- No TBD left.
- Field names match checker form: `Part_Name`, `part_no`, `JO_Number`, `DO_Number`, `Inspection_Type`, `Category`, `Parameter`, `InspectBy`, `FinalizeBy`, `TotalCheck`, `RejectQty`, `ReworkQty`, `AcceptQty`, `ScrapQty`, `Remark`, `remark_finished`, `actual_finished`, `created_at`.
- `goTo('inspectionPartSummary.html')` matches same-folder relative navigation used by Daily Report.
