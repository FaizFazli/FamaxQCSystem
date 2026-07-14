# Register/Revise Part (Merged Add Part) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge add-part + add-part-image into one **Register/Revise Part** page with three required upload cards (+ optional references), full DMS + DB + revision status flow; delete document revision pages.

**Architecture:** Evolve `screen_page/add_part/addPart.html` in place. Reuse existing Excel parsers, DMS `/prepare` + `/upload-multi`, and Supabase IPQC/OQC/IQC patterns. New client-side state for process image slots, customer drawing, and optional refs. No backend API changes. Delete `revision/*` and rewire AdminLogin.

**Tech Stack:** jQuery, Select2, SheetJS, Supabase JS CDN, Toastify, `theme.css`, `APP_CONFIG`, existing Express `/FamaxDMS/*`

## Global Constraints

- Page title / H1 / AdminLogin card label: **Register/Revise Part**
- Part list from existing `Parts` table only
- Status suspend/activate only on **IPQC, OQC, IQC** (`Active` / `Suspended`)
- Customer drawing + other references → DMS subfolder **`Samples`**
- WI → **`Work Instruction (WI)`**; process files → **`Process Image`**
- New revision always calls `prepare` → `REV-{revision}` tree (idempotent mkdir)
- Process images: **one slot per WI process**; IQC/OQC require PDF
- Prefer keeping Excel range maps exactly as in current `handleIPQCFile` / `handleOQCFile` / `handleIQCFile`
- Commits only if user requested (do not commit by default in this repo)
- No new npm dependencies

## File map

| File | Action |
|------|--------|
| `screen_page/add_part/addPart.html` | Major UI + submit rewrite |
| `screen_page/add_part/addPartImage.html` | Replace with redirect to `addPart.html` |
| `screen_page/revision/revision.html` | **Delete** |
| `screen_page/revision/revisionImage.html` | **Delete** |
| `AdminLogin.html` | Merge revision card into Register/Revise Part; role enables |

---

### Task 1: Scaffold Register/Revise UI (cards + CSS)

**Files:**
- Modify: `screen_page/add_part/addPart.html` (body form region + styles; keep libraries head)

**Interfaces:**
- Produces: DOM ids used by later JS:
  - `#partSelect`, `#revInput`
  - `#cardWi`, `#wiFileInput`, `#wiFileList`
  - `#cardProcess`, `#processSlots`
  - `#cardDrawing`, `#drawingFileInput`, `#drawingFileList`
  - `#cardRefs`, `#refFileInput`, `#refFileList`
  - `#submitButton`, `#loading-overlay`
  - status badges: `#statusWi`, `#statusProcess`, `#statusDrawing`

- [ ] **Step 1: Widen layout and add card CSS**

In the `<style>` block of `addPart.html`, change main card max-width and add:

```css
.card { max-width: 960px; } /* was 600px */
.nav-top { max-width: 960px; }

.upload-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 14px;
  margin-top: 18px;
}
@media (min-width: 800px) {
  .upload-grid { grid-template-columns: 1fr 1fr; }
}
.upload-card {
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--surface-muted);
  padding: 14px 16px;
  min-height: 160px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.upload-card.required-ready { border-color: #10b981; box-shadow: 0 0 0 1px #10b98133; }
.upload-card.required-missing { border-color: #f59e0b; }
.upload-card .card-title-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
}
.upload-card h3 {
  margin: 0;
  font-size: 13px;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.badge {
  font-size: 10px;
  font-weight: 800;
  text-transform: uppercase;
  padding: 3px 8px;
  border-radius: 999px;
}
.badge-ok { background: #dcfce7; color: #15803d; }
.badge-need { background: #fef3c7; color: #b45309; }
.badge-opt { background: #e2e8f0; color: #475569; }
.file-chip-list { display: flex; flex-wrap: wrap; gap: 6px; }
.file-chip {
  font-size: 11px;
  font-weight: 600;
  background: #fff;
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 4px 8px;
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.process-slot {
  background: #fff;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 10px;
  display: grid;
  gap: 8px;
}
.process-slot .slot-head {
  font-size: 12px;
  font-weight: 800;
  display: flex;
  justify-content: space-between;
  gap: 8px;
}
.slot-cat {
  font-size: 10px;
  font-weight: 800;
  color: #1d4ed8;
  background: #dbeafe;
  padding: 2px 6px;
  border-radius: 999px;
}
.full-width-card { grid-column: 1 / -1; }
```

- [ ] **Step 2: Replace page title and form body**

Set `<title>` and header H1 to **Register/Revise Part**.

Replace the main form content (identity + single upload section) with this structure (keep Select2 on `#partSelect` and existing loading overlay/modals if still useful):

```html
<!-- Identity -->
<div class="form-group">
  <label>Part Name (from Parts)</label>
  <select id="partSelect" class="searchable-dropdown" style="width:100%">
    <option value=""></option>
  </select>
</div>
<div class="form-group">
  <label>Revision (e.g., 0, 1, A)</label>
  <input type="text" id="revInput" class="form-control" placeholder="0" />
</div>

<div class="upload-grid">
  <!-- Card 1 WI -->
  <div class="upload-card required-missing" id="cardWi">
    <div class="card-title-row">
      <h3>1. Work Instruction (WI)</h3>
      <span class="badge badge-need" id="statusWi">Required</span>
    </div>
    <p style="margin:0;font-size:12px;color:var(--text-muted);font-weight:600;">
      Upload one or more WI Excel files. Process names come from the filename before <code>_</code>.
    </p>
    <input type="file" id="wiFileInput" accept=".xlsx,.xls" multiple />
    <div class="file-chip-list" id="wiFileList"></div>
  </div>

  <!-- Card 2 Process Image -->
  <div class="upload-card required-missing" id="cardProcess">
    <div class="card-title-row">
      <h3>2. Process Image</h3>
      <span class="badge badge-need" id="statusProcess">Required</span>
    </div>
    <p style="margin:0;font-size:12px;color:var(--text-muted);font-weight:600;">
      One image per process. IQC/OQC also need a PDF guide.
    </p>
    <div id="processSlots">
      <div style="font-size:12px;color:var(--text-muted);">Upload WI files first…</div>
    </div>
  </div>

  <!-- Card 3 Customer Drawing -->
  <div class="upload-card required-missing" id="cardDrawing">
    <div class="card-title-row">
      <h3>3. Customer Drawing</h3>
      <span class="badge badge-need" id="statusDrawing">Required</span>
    </div>
    <p style="margin:0;font-size:12px;color:var(--text-muted);font-weight:600;">
      Saved to DMS <strong>Samples</strong> folder.
    </p>
    <input type="file" id="drawingFileInput" accept="image/*,.pdf" multiple />
    <div class="file-chip-list" id="drawingFileList"></div>
  </div>

  <!-- Card 4 Optional refs -->
  <div class="upload-card" id="cardRefs">
    <div class="card-title-row">
      <h3>4. Other References</h3>
      <span class="badge badge-opt" id="statusRefs">Optional</span>
    </div>
    <p style="margin:0;font-size:12px;color:var(--text-muted);font-weight:600;">
      Extra files also go to DMS <strong>Samples</strong>.
    </p>
    <input type="file" id="refFileInput" multiple />
    <div class="file-chip-list" id="refFileList"></div>
  </div>
</div>

<button type="button" id="submitButton" class="btn-main" disabled style="margin-top:18px;width:100%;">
  Submit Register/Revise
</button>
```

Remove the old “Continue to images” / single-step-only UI. Keep Active WI status modal only if already working; optional to leave.

- [ ] **Step 3: Visual check**

Open `addPart.html` in browser (static). Confirm four cards show, title is Register/Revise Part, Submit disabled.

---

### Task 2: Client state — process slots + validation

**Files:**
- Modify: `screen_page/add_part/addPart.html` (script section near file handling)

**Interfaces:**
- Produces state used by submit:
  - `wiFiles: File[]`
  - `fileDetails: { process, category, fileObject, partName }[]` (category from filename pattern)
  - `processSlots: { process, category, imageFile: File|null, pdfFile: File|null, needsPdf: boolean }[]`
  - `drawingFiles: File[]`
  - `refFiles: File[]`
- Produces: `rebuildProcessSlots()`, `updateCardUI()`, `canSubmit(): boolean`

- [ ] **Step 1: Replace old `fileArray`-only handlers with multi stores**

Near the top of the script (with other globals), use:

```javascript
let selectedPartName = "";
let wiFiles = [];       // File[]
let drawingFiles = [];  // File[]
let refFiles = [];      // File[]
/** @type {{process:string, category:string, imageFile:File|null, pdfFile:File|null, needsPdf:boolean}[]} */
let processSlots = [];
```

- [ ] **Step 2: Category-from-filename helper (keep existing toast warnings)**

```javascript
function categoryFromFileName(name) {
  const n = name.toUpperCase();
  if (n.includes("_OQC") || n.includes("OQC")) return "OQC";
  if (n.includes("_IQC") || n.includes("IQC")) return "IQC";
  return "IPQC";
}

function processFromFileName(name) {
  const stem = name.replace(/\.(xlsx|xls)$/i, "");
  return stem.split("_")[0];
}

function buildFileDetails() {
  return wiFiles.map((file) => ({
    partName: selectedPartName,
    fileName: file.name,
    process: processFromFileName(file.name),
    fileObject: file,
    category: categoryFromFileName(file.name),
  }));
}
```

- [ ] **Step 3: Rebuild process slots when WI files change**

```javascript
function rebuildProcessSlots() {
  const details = buildFileDetails();
  // first-seen category wins per process
  const map = new Map();
  details.forEach((d) => {
    if (!map.has(d.process)) {
      map.set(d.process, {
        process: d.process,
        category: d.category,
        imageFile: null,
        pdfFile: null,
        needsPdf: d.category === "IQC" || d.category === "OQC",
      });
    }
  });
  // preserve already-picked images if process still exists
  const prev = new Map(processSlots.map((s) => [s.process, s]));
  processSlots = [...map.values()].map((s) => {
    const old = prev.get(s.process);
    if (!old) return s;
    return {
      ...s,
      imageFile: old.imageFile,
      pdfFile: old.pdfFile,
    };
  });
  renderProcessSlots();
  updateCardUI();
}

function renderProcessSlots() {
  const root = $("#processSlots");
  if (!processSlots.length) {
    root.html('<div style="font-size:12px;color:var(--text-muted);">Upload WI files first…</div>');
    return;
  }
  root.empty();
  processSlots.forEach((slot, index) => {
    const imgName = slot.imageFile ? slot.imageFile.name : "No image";
    const pdfName = slot.pdfFile ? slot.pdfFile.name : "No PDF";
    root.append(`
      <div class="process-slot" data-index="${index}">
        <div class="slot-head">
          <span>${slot.process}</span>
          <span class="slot-cat">${slot.category}</span>
        </div>
        <div>
          <label style="font-size:11px;font-weight:700;">Image *</label>
          <input type="file" accept="image/*" data-role="img" data-index="${index}" />
          <div class="file-chip">${imgName}</div>
        </div>
        ${slot.needsPdf ? `
        <div>
          <label style="font-size:11px;font-weight:700;">PDF guide *</label>
          <input type="file" accept="application/pdf,.pdf" data-role="pdf" data-index="${index}" />
          <div class="file-chip">${pdfName}</div>
        </div>` : ""}
      </div>
    `);
  });
  root.find('input[type="file"]').on("change", function () {
    const i = Number(this.dataset.index);
    const role = this.dataset.role;
    const f = this.files && this.files[0];
    if (!f) return;
    if (role === "img") processSlots[i].imageFile = f;
    if (role === "pdf") processSlots[i].pdfFile = f;
    renderProcessSlots();
    updateCardUI();
  });
}
```

- [ ] **Step 4: Wire file inputs + chip renderers + `updateCardUI`**

```javascript
function renderChips($el, files) {
  $el.empty();
  files.forEach((f) => $el.append(`<span class="file-chip">${f.name}</span>`));
}

function setBadge($badge, ready) {
  if (ready) {
    $badge.attr("class", "badge badge-ok").text("Ready");
  } else {
    $badge.attr("class", "badge badge-need").text("Required");
  }
}

function isProcessReady() {
  return (
    processSlots.length > 0 &&
    processSlots.every((s) => s.imageFile && (!s.needsPdf || s.pdfFile))
  );
}

function canSubmit() {
  return (
    !!selectedPartName &&
    !!($("#revInput").val() || "").trim() &&
    wiFiles.length > 0 &&
    isProcessReady() &&
    drawingFiles.length > 0
  );
}

function updateCardUI() {
  const wiOk = wiFiles.length > 0;
  const procOk = isProcessReady();
  const drawOk = drawingFiles.length > 0;

  $("#cardWi").toggleClass("required-ready", wiOk).toggleClass("required-missing", !wiOk);
  $("#cardProcess").toggleClass("required-ready", procOk).toggleClass("required-missing", !procOk);
  $("#cardDrawing").toggleClass("required-ready", drawOk).toggleClass("required-missing", !drawOk);

  setBadge($("#statusWi"), wiOk);
  setBadge($("#statusProcess"), procOk);
  setBadge($("#statusDrawing"), drawOk);

  $("#submitButton").prop("disabled", !canSubmit());
}

// bindings (on ready)
$("#wiFileInput").on("change", function () {
  wiFiles = Array.from(this.files || []);
  renderChips($("#wiFileList"), wiFiles);
  rebuildProcessSlots();
});
$("#drawingFileInput").on("change", function () {
  drawingFiles = Array.from(this.files || []);
  renderChips($("#drawingFileList"), drawingFiles);
  updateCardUI();
});
$("#refFileInput").on("change", function () {
  refFiles = Array.from(this.files || []);
  renderChips($("#refFileList"), refFiles);
});
$("#revInput").on("input", updateCardUI);
// part select change: set selectedPartName then updateCardUI (keep select2 init)
```

- [ ] **Step 5: Manual check**

In browser without submit: pick part + rev + WI → process slots appear; Submit stays disabled until drawing + images (and PDFs for OQC/IQC) filled.

---

### Task 3: Unified submit sequence

**Files:**
- Modify: `screen_page/add_part/addPart.html` — replace `submitFiles()`; keep `readExcel` + `handleIPQCFile` / `handleOQCFile` / `handleIQCFile` (insert maps unchanged)
- Merge process image upload logic from former `addPartImage.html` `submitAll`

**Interfaces:**
- Consumes: state from Task 2
- Produces: one async `submitRegisterRevise()` bound to `#submitButton`
- Helpers:
  - `uploadDms(productName, revision, subFolder, files: File[]): Promise<void>`
  - `suspendActiveChecklists(partName): Promise<void>`
  - `uploadProcessSlot(slot, partName, revision): Promise<void>`

- [ ] **Step 1: Add shared DMS upload helper**

```javascript
async function uploadDms(productName, revision, subFolder, files) {
  if (!files || !files.length) return;
  const fd = new FormData();
  fd.append("productName", productName);
  fd.append("revision", revision);
  fd.append("subFolder", subFolder);
  files.forEach((f) => fd.append("files", f));
  const res = await fetch(`${window.APP_CONFIG.host}/FamaxDMS/upload-multi`, {
    method: "POST",
    body: fd,
  });
  const data = await res.json().catch(() => ({ success: false }));
  if (!res.ok || !data.success) {
    throw new Error(data.error || data.message || `DMS upload failed (${subFolder})`);
  }
}
```

- [ ] **Step 2: Suspend old Active checklist rows**

```javascript
async function suspendActiveChecklists(partName) {
  for (const table of ["IPQC", "OQC", "IQC"]) {
    const { error } = await supabaseClient
      .from(table)
      .update({ Status: "Suspended" })
      .eq("Part_Name", partName)
      .eq("Status", "Active");
    if (error) throw new Error(`Suspend ${table}: ${error.message}`);
  }
}
```

- [ ] **Step 3: Process slot cloud + path update (from addPartImage)**

```javascript
async function uploadProcessSlot(slot, partName, revision) {
  await uploadDms(
    partName,
    revision,
    "Process Image",
    [slot.imageFile, slot.pdfFile].filter(Boolean)
  );

  const bucketMap = { IPQC: "ipqc", IQC: "iqc", OQC: "oqc" };
  const bucket = bucketMap[slot.category] || "general-images";
  const imgPath = `${partName}/${slot.process}/${slot.imageFile.name}`;
  const { error: upErr } = await supabaseClient.storage
    .from(bucket)
    .upload(imgPath, slot.imageFile, { upsert: true });
  if (upErr) throw upErr;

  const { data: imgData } = supabaseClient.storage.from(bucket).getPublicUrl(imgPath);
  const imgUrl = `${imgData.publicUrl}?t=${Date.now()}`;

  const updates = { Path: imgUrl };
  if (slot.pdfFile) {
    const pdfPath = `${partName}/${slot.process}/guide_${slot.pdfFile.name}`;
    const { error: pdfErr } = await supabaseClient.storage
      .from(bucket)
      .upload(pdfPath, slot.pdfFile, { upsert: true });
    if (pdfErr) throw pdfErr;
    const { data: pdfData } = supabaseClient.storage.from(bucket).getPublicUrl(pdfPath);
    updates.Pdf_Path = `${pdfData.publicUrl}?t=${Date.now()}`;
  }

  const { error: dbError } = await supabaseClient
    .from(slot.category)
    .update(updates)
    .eq("Part_Name", partName)
    .eq("Process", slot.process)
    .eq("Status", "Active");
  if (dbError) throw dbError;
}
```

- [ ] **Step 4: Replace `submitFiles` with full sequence**

```javascript
async function submitRegisterRevise() {
  if (!canSubmit()) {
    showToast("Complete required cards first", "error");
    return;
  }
  const revision = $("#revInput").val().trim();
  const partName = selectedPartName;

  $("#loading-overlay").show();
  $("#submitButton").prop("disabled", true);

  try {
    // 1) prepare REV tree
    const prepResponse = await fetch(`${window.APP_CONFIG.host}/FamaxDMS/prepare`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ productName: partName, revision }),
    });
    const prepData = await prepResponse.json().catch(() => ({ success: false }));
    if (!prepResponse.ok || !prepData.success) {
      throw new Error(prepData.error || "Prepare DMS folders failed");
    }

    // 2) WI to DMS
    await uploadDms(partName, revision, "Work Instruction (WI)", wiFiles);

    // 3) suspend previous Active
    await suspendActiveChecklists(partName);

    // 4) insert new Active from Excel (reuse existing handlers)
    const details = buildFileDetails().map((d) => ({ ...d, partName }));
    for (const detail of details) {
      if (detail.category === "IPQC") await handleIPQCFile(detail);
      else if (detail.category === "OQC") await handleOQCFile(detail);
      else if (detail.category === "IQC") await handleIQCFile(detail);
    }

    // 5) process images
    for (const slot of processSlots) {
      await uploadProcessSlot(slot, partName, revision);
    }

    // 6) customer drawing + optional refs → Samples
    await uploadDms(partName, revision, "Samples", drawingFiles);
    if (refFiles.length) {
      await uploadDms(partName, revision, "Samples", refFiles);
    }

    // 7) stamp Parts.Revision
    await supabaseClient.from("Parts").update({ Revision: revision }).eq("Part_Name", partName);

    showToast("Register/Revise completed", "success");
    setTimeout(() => {
      window.location.href = "../../AdminLogin.html";
    }, 1200);
  } catch (e) {
    console.error(e);
    showToast("Error: " + (e.message || e), "error");
    $("#loading-overlay").hide();
    $("#submitButton").prop("disabled", false);
    updateCardUI();
  }
}

$("#submitButton").off("click").on("click", submitRegisterRevise);
```

- [ ] **Step 5: Remove redirect to `addPartImage.html` and any localStorage handoff** (`selectedPartName` / `currentRev` / `processNames` for that path). Keep submit working offline of image page.

- [ ] **Step 6: Smoke test (needs Supabase + DMS share)**

1. Pick part that already has Active IPQC rows; set new revision.  
2. Upload WI(s) + images + customer drawing.  
3. Confirm: new `REV-*` folder, WI / Process Image / Samples files, old rows `Suspended`, new `Active` with Path, Parts.Revision updated.

---

### Task 4: Nav cleanup + delete revision pages

**Files:**
- Modify: `AdminLogin.html`
- Replace: `screen_page/add_part/addPartImage.html` (redirect stub)
- Delete: `screen_page/revision/revision.html`
- Delete: `screen_page/revision/revisionImage.html`
- Grep repo (exclude `node_modules`) for `revision/revision` / `addPartImage` leftover **app** links

- [ ] **Step 1: AdminLogin card + roles**

Find the Add Part and Revision cards. Convert to **one** card (or retitle both to same destination):

```html
<div id="addPartBtn" class="dashboard-card"
     onclick="navigateTo('screen_page/add_part/addPart.html')">
  <!-- icon keep -->
  <span class="card-title">Register/Revise Part</span>
  <span class="card-desc">Upload WI, process images, and customer drawing for a part revision.</span>
</div>
```

Remove the separate `revisionBtn` card (or hide + stop enabling). In role matrices, remove `'revisionBtn'` from enable arrays; keep `'addPartBtn'` wherever revision was previously enabled for ENGINEER/ALL.

- [ ] **Step 2: Replace addPartImage with redirect**

Write `screen_page/add_part/addPartImage.html` as:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Redirecting…</title>
  <meta http-equiv="refresh" content="0; url=addPart.html" />
  <script>location.replace("addPart.html");</script>
</head>
<body>
  <p>This step is merged into <a href="addPart.html">Register/Revise Part</a>.</p>
</body>
</html>
```

- [ ] **Step 3: Delete revision pages**

```powershell
Remove-Item -LiteralPath "screen_page\revision\revision.html"
Remove-Item -LiteralPath "screen_page\revision\revisionImage.html"
```

Confirm directory empty (leave folder or remove if empty).

- [ ] **Step 4: Grep leftover links**

```powershell
rg -n "revision/revision|addPartImage|revisionBtn" --glob "!node_modules/**" .
```

Expected: only redirect text / historical docs, no live AdminLogin path to deleted files.

---

## Spec coverage

| Spec item | Task |
|-----------|------|
| Title Register/Revise Part | 1, 4 |
| 3 required cards + optional refs | 1, 2 |
| Process slots from WI | 2 |
| prepare + WI + Process Image + Samples | 3 |
| Suspend Active IPQC/OQC/IQC | 3 |
| Insert new Active + path update | 3 |
| Parts.Revision | 3 |
| Delete revision pages | 4 |
| addPartImage redirect | 4 |
| AdminLogin nav | 4 |

## Self-review notes

- No TBD. Excel cell maps intentionally deferred to existing functions (do not rewrite).  
- Path update now filters `Status=Active` (stricter than old addPartImage; correct for revise).  
- Mid-submit failure is non-transactional per spec; error toast after failed step.
