# Part Name Inspection Summary — Design

**Date:** 2026-07-10  
**Status:** Approved for planning  
**Location:** `screen_page/inspection/inspectionPartSummary.html`

## Goal

Let a user pick a part name from `Parts` and see the full `InspectionRecord` history for that part, with Excel export. Part-first view (opposite of date-first `inspectionDailyReport.html`).

## Scope

**In**
- Load distinct `Part_Name` from `Parts` into a selector
- After selection, load all matching `InspectionRecord` rows (newest first)
- On-screen table + qty summary chips
- Excel (XLSX) export of the loaded rows
- Link from `inspectionDashboard.html`

**Out**
- Inline edit, PDF/print, date filter, server/Node routes, Data_IPQC / self-hosted file templates

## Stack

Match inspection module: Vue 3 (CDN), axios, SheetJS (`xlsx`), `theme.css`, `assets/app-config.js` (`APP_CONFIG.url` / `key`). No hardcoded host/IP.

## UI

1. Header: title “Part Name Inspection Summary” + home back to dashboard  
2. Toolbar: part `<select>` (or searchable if already common CDN patterns nearby; native select is enough), Refresh, Export Excel (disabled until rows exist)  
3. Summary chips: record count, TotalCheck, Accept, Reject, Scrap, Rework sums  
4. Scrollable table columns:  
   Date/Time · Part Name · Part No · Process · JO · DO · Type · Category · Parameter · InspectBy · FinalizeBy · Total · Reject · Rework · Accept · Scrap · Remark · remark_finished  
5. Empty state: “Select a part” / “No records for this part”

## Data flow

```
onMounted
  → GET /rest/v1/Parts?select=Part_Name
  → unique, non-empty, sort → dropdown options

on part change / Refresh
  → GET /rest/v1/InspectionRecord?Part_Name=eq.<encodeURIComponent(name)>&order=created_at.desc
  → Query selected name as-is; if 0 rows retry once with name.toUpperCase() (checker stores UPPERCASE)

Export
  → only when rows.length > 0
  → map flat fields; Remark array → "DESC:qty; ..."
  → download Inspection_<safePartName>_<YYYY-MM-DD>.xlsx via XLSX.utils
```

## Error handling

- Parts load fail → show message, empty dropdown  
- Record load fail → clear table, alert message  

- Export with no data → no-op / button disabled  

## Files touched

| File | Change |
|------|--------|
| `screen_page/inspection/inspectionPartSummary.html` | **New** page |
| `screen_page/inspection/inspectionDashboard.html` | Add nav button/link to new page |

No DB migration, no `server.js` / routes changes.

## Success criteria

1. Dropdown shows unique part names from `Parts`  
2. Selecting a part lists all its `InspectionRecord` rows  
3. Export downloads one Excel file with those rows  
4. Dashboard can open the page in one click  
5. Works via `APP_CONFIG` on any host that serves Supabase :8000  
