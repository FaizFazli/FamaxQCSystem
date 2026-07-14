# Merged Add Part + DMS Upload Cards — Design

**Date:** 2026-07-10  
**Status:** Approved for planning  
**Primary file:** `screen_page/add_part/addPart.html`

## Goal

One registration page where the user picks an existing `Parts` row and a revision, fills **three required** upload cards (Work Instruction, Process Image, Customer Drawing) plus optional other references, then submits once. Submit creates the DMS revision tree, uploads files, suspends previous Active IPQC/OQC/IQC rows, inserts new Active rows, and updates process image paths. Supersedes the two-step add-part + add-part-image flow and the document **revision** pages.

## Decisions (locked)

| Topic | Choice |
|-------|--------|
| Architecture | Single page wizard in `addPart.html` (Approach A) |
| Part source | Existing `Parts` dropdown only (File Generator still creates Parts) |
| Status scope | IPQC / OQC / IQC only (`Active` → `Suspended`); new inserts `Active` |
| Process images | One required image per process derived from WI filenames; IQC/OQC also require PDF |
| Customer drawing | Required; save to DMS **`Samples`** |
| Other references | Optional multi-file; also **`Samples`** |
| revision pages | **Delete** `revision.html` + `revisionImage.html`; nav points to addPart |
| addPartImage | Keep as redirect stub to `addPart.html` |

## UI

**Header / nav:** Back to AdminLogin. Title: **“Register/Revise Part”**.

**Identity**
- Searchable select: unique `Part_Name` from `Parts`
- Revision text input (e.g. `0`, `1`, `A`) → DMS folder `REV-{revision}` via existing `prepareFolder`

**Cards (responsive grid; each shows ready / incomplete)**

1. **Work Instruction (WI)** — required multi `.xlsx` upload  
   - Same parse rules as today (`_IPQC` / `_OQC` / `_IQC`; process = name before first `_`)  
   - On change: rebuild Process Image slots from unique process names

2. **Process Image** — required per process slot  
   - Image required always  
   - PDF required when process category is IQC or OQC  
   - Preview file names per row

3. **Customer Drawing** — required ≥1 file any common image/PDF types → Screens label “Customer Drawing” → storage path `Samples`

4. **Other references** (optional) — multi file → also `Samples`

**Submit** button disabled until cards 1–3 valid. Progress toasts per step on submit.

## Submit sequence

Fail fast with user-visible error; on error do **not** continue remaining steps (DB may already be partially written—toast names the step that failed; no multi-step transaction API available).

1. Client validation (part, rev, files, process slots).  
2. `POST {APP_CONFIG.host}/FamaxDMS/prepare` body `{ productName: Part_Name, revision }`  
   - Creates (if missing):  
     `{DMS_FOLDER}\{cleanPart}\REV-{rev}\`  
     + `Process Image`, `Program FIle`, `Samples`, `Tooling List`, `Work Instruction (WI)`, `Drawing File`, `CMM Program`  
3. `POST /FamaxDMS/upload-multi`  
   - `subFolder: "Work Instruction (WI)"`, all WI files  
4. For each of `IPQC`, `OQC`, `IQC`:  
   - `.update({ Status: "Suspended" }).eq("Part_Name", part).eq("Status", "Active")`  
   - (Same pattern as current `revision.html`)  
5. Parse WI Excel and **insert** new rows with `Status: "Active"` (reuse existing field mapping from addPart).  
6. For each process slot:  
   - Upload image (+ PDF if needed) to DMS `Process Image` via `/upload-multi`  
   - Upload to Supabase Storage buckets `ipqc` / `iqc` / `oqc` at `{part}/{process}/...`  
   - Update matching table rows: `Path` / optional `Pdf_Path` where `Part_Name` + `Process` + `Status = "Active"`  
7. Upload customer drawing files to DMS `Samples` via `/upload-multi`.  
8. If any other references: upload same to `Samples`.  
9. Optional: `Parts.update({ Revision: rev }).eq("Part_Name", part)` so registry shows current rev.  
10. Success → redirect `AdminLogin.html` (or existing admin hub).

**No Node API changes required** if existing `/FamaxDMS/prepare` and `/upload-multi` remain sufficient.

## Navigation & delete list

| Action | Target |
|--------|--------|
| Modify | `addPart.html` — merged UI + submit |
| Replace body | `addPartImage.html` — immediate redirect to `addPart.html` |
| Delete | `screen_page/revision/revision.html` |
| Delete | `screen_page/revision/revisionImage.html` |
| Update links | `AdminLogin.html` (and grep for `revision/` / `addPartImage`) → `add_part/addPart.html`; label **“Register/Revise Part”** |

## Out of scope

- Creating `Parts` rows (stays File Generator)  
- Uploading customer drawings into `Drawing File` folder rather than Samples (user chose **Samples**)  
- Multi-step server transaction / rollback of DMS files on later DB failure  
- Changing DMS subfolder list (typo `Program FIle` kept)  
- Changing revision pages’ former “suspend without DMS Samples” lightweight path (deleted intentionally)

## Error handling

- Parts load fail → empty select + toast  
- prepare/upload fail → toast with server message; stop  
- Supabase suspend/insert/path update fail → toast; stop (operator may need ops cleanup if mid-sequence)  
- Submit guard: never POST with incomplete cards  

## Success criteria

1. User can complete register/revise on **one page** without visiting addPartImage or revision.  
2. New revision creates `REV-*` tree and does not wipe other revisions.  
3. Prior Active checklist data for that part becomes `Suspended`; new data `Active`.  
4. WI → `Work Instruction (WI)`; process images → `Process Image`; customer drawing + optional refs → `Samples`.  
5. No remaining live nav to deleted revision HTML.  
6. Process image count/slots match WI-derived process list; IQC/OQC require PDF gate.

## Risks / operator notes

- Mid-submit failure after DMS upload but before DB complete can leave files on share without matching rows — acceptable given no TX; show clear step name.  
- Suspend is by `Part_Name` Active all processes (not by revision column on checklist tables, which typically lack calc containers)—**same as current revision flow**.  
