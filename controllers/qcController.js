const axios = require("axios");
const fs = require("fs");
const path = require("path");
const ExcelJS = require("exceljs");
const config = require("../config/config");
const { partFolder } = require("../utils/paths");

// IMPORTANT: This must match your actual file name and folder!
// If your file is in 'utils' and named 'excelUtil.js', use this:
const excelUtil = require("../utils/excelUtils");

// Destructure sanitizeName so it can be used easily in other functions
const { sanitizeName } = excelUtil;

const copyFileWithRetry = async (src, dest, retries = 3) => {
  for (let i = 0; i < retries; i++) {
    try {
      // copyFileSync automatically REPLACES the file if it exists
      fs.copyFileSync(src, dest);
      return;
    } catch (err) {
      if (err.code === "EBUSY" && i < retries - 1) {
        console.warn(
          `⚠️ File ${path.basename(dest)} is busy/locked. Retrying (${i + 1}/${retries})...`,
        );
        // Wait 1 second before retrying
        await new Promise((resolve) => setTimeout(resolve, 1000));
      } else {
        throw err;
      }
    }
  }
};


exports.createFolder = async (req, res) => {
  const {
    partDescription,
    partNo,
    rawMaterial,
    rawMaterialGrade,
    rawMaterialSize,
    processes,
    docNumber1,
    docNumber2,
    revNumber,
  } = req.body;

  try {
    const folderPath = partFolder(partDescription, partNo);
    if (!fs.existsSync(folderPath)) {
      fs.mkdirSync(folderPath, { recursive: true });
    }

    let filesCreatedCount = 0;

    for (const [idx, proc] of processes.entries()) {
      const masterPath = excelUtil.findMasterDocument(proc.documentType);

      if (!masterPath) {
        console.error(`❌ Template not found for: ${proc.documentType}`);
        continue;
      }

      // Prefix the process sequence number (the "#" from the generator) so
      // the files sort in process order on disk. The register step strips
      // this leading "NN_" back off - see processFromFileName in addPart.
      const seqNo = String(idx + 1).padStart(2, "0");
      const fileName = `${seqNo}_${sanitizeName(proc.name)}_${proc.documentType}.xlsx`;
      const destinationPath = path.join(folderPath, fileName);

      // --- REPLACEMENT LOGIC ---
      // This will attempt to overwrite the existing file.
      // If the file is open in Excel, it will retry 3 times.
      await copyFileWithRetry(masterPath, destinationPath);

      const workbook = new ExcelJS.Workbook();
      await workbook.xlsx.readFile(destinationPath);
      const sheet = workbook.worksheets[0];

      // Fill Headers
      sheet.getCell("C4").value = partDescription;
      sheet.getCell("C5").value = partNo;
      sheet.getCell("C6").value = rawMaterial;
      sheet.getCell("C7").value = rawMaterialGrade;
      sheet.getCell("C8").value = rawMaterialSize;
      sheet.getCell("S4").value = docNumber1;
      sheet.getCell("S5").value = docNumber2;
      sheet.getCell("S6").value = revNumber;

      // Fill Process Table
      processes.forEach((p, idx) => {
        sheet.getCell(`R${14 + idx}`).value = idx + 1;
        sheet.getCell(`S${14 + idx}`).value = p.name;
      });

      // Insert Process Specific Image
      if (proc.imageBase64) {
        const buffer = Buffer.from(
          proc.imageBase64.replace(/^data:image\/\w+;base64,/, ""),
          "base64",
        );
        const imageId = workbook.addImage({ buffer, extension: "png" });
        sheet.addImage(imageId, {
          tl: { col: 0, row: 9 },
          br: { col: 17, row: 47 },
          editAs: "absolute",
        });
      }

      // Drop the #VALUE! the template's in-cell logos leave behind once ExcelJS has read
      // them, then draw both logos back as floating images. Order matters only in that the
      // clear has to happen while the sheet still belongs to us - see clearInCellImageErrors.
      excelUtil.clearInCellImageErrors(sheet);

      // Insert Recurring Logos & Page Breaks
      excelUtil.insertImageIntoSheet(workbook, sheet);

      // 1. Set A4 Paper and Zero Margins
      // This gives row 48 enough room to stay on Page 1
      sheet.pageSetup.paperSize = 9; // 9 = A4
      sheet.pageSetup.margins = {
        left: 0,
        right: 0,
        top: 0,
        bottom: 0,
        header: 0,
        footer: 0,
      };

      // 2. Set Row Breaks
      // Note: getRow(48).addPageBreak() makes row 48 the LAST row of the page.
      for (let r = 48; r <= 480; r += 48) {
        const row = sheet.getRow(r);
        row.addPageBreak();
      }

      // 3. Set Print Area (A1 to CF480)
      sheet.pageSetup.printArea = "A1:CF480";

      // 4. THE FIX FOR THE DASHED LINE:
      // Instead of fitToHeight: 0, use 10.
      // This forces Excel to shrink the rows slightly to fit exactly 48 rows per page.
      sheet.pageSetup.fitToPage = true;
      sheet.pageSetup.fitToWidth = 4; // 84 columns / 4 = 21 columns (Ends at U)
      sheet.pageSetup.fitToHeight = 10; // 480 rows / 10 = 48 rows per page

      // 5. Center content to look clean
      sheet.pageSetup.horizontalCentered = true;
      sheet.pageSetup.verticalCentered = true;

      // 6. Preview Mode
      sheet.views = [
        {
          state: "pageLayout", // This opens the "intended" view immediately
          activeCell: "A1",
          zoomScale: 100, // Normal size
          showRuler: true,
          showGridLines: false,
        },
      ];

      // Save the File (This will also fail if locked, so we use a try/catch)
      try {
        await workbook.xlsx.writeFile(destinationPath);
      } catch (saveErr) {
        if (saveErr.code === "EBUSY") {
          throw new Error(
            `Cannot save "${fileName}". Please close the file in Excel and try again.`,
          );
        }
        throw saveErr;
      }

      filesCreatedCount++;
      console.log(`✅ Created/Replaced: ${fileName}`);
    }

    res.json({
      success: true,
      message: `${filesCreatedCount} Excel files processed successfully.`,
    });
  } catch (err) {
    console.error("Error creating folder/files:", err);
    res.status(500).json({ success: false, message: err.message });
  }
};

// 2. Move Obsolete Files
exports.moveObsoleteFiles = (req, res) => {
  const { partName, partNo, process, documentType } = req.body;

  try {
    const folder = partFolder(partName, partNo);
    const obsoleteFolder = path.join(folder, "obsolete");
    if (!fs.existsSync(obsoleteFolder))
      fs.mkdirSync(obsoleteFolder, { recursive: true });

    const files = fs
      .readdirSync(folder)
      .filter((f) => f.includes(`${process}_${documentType}`));
    files.forEach((file) => {
      fs.renameSync(
        path.join(folder, file),
        path.join(obsoleteFolder, file),
      );
    });
    res.json({ success: true, message: "Obsolete files moved" });
  } catch (err) {
    res.json({ success: false, message: err.message });
  }
};

// 3. Save QC HUB Summary
exports.saveHubSummary = (req, res) => {
  try {
    const { supervisorName } = req.body;
    const cleanSupervisor = sanitizeName(supervisorName || "Unassigned");
    const dateFolder = new Date()
      .toLocaleDateString("en-GB")
      .replace(/\//g, "-");

    const targetDir = path.join(
      config.INSPECTION_PATHS.HUB,
      cleanSupervisor,
      dateFolder,
    );
    if (!fs.existsSync(targetDir)) fs.mkdirSync(targetDir, { recursive: true });

    const finalPath = path.join(targetDir, `HUB_${Date.now()}.pdf`);
    fs.copyFileSync(req.file.path, finalPath);
    fs.unlinkSync(req.file.path);

    res.json({ success: true, message: "Saved to QC HUB", path: finalPath });
  } catch (err) {
    res.status(500).json({ success: false, message: err.message });
  }
};

// 4. Save Excel File (Manual Upload)
exports.saveExcelFile = (req, res) => {
  try {
    const { partName, partNo } = req.body;
    const folder = partFolder(partName, partNo);
    if (!fs.existsSync(folder)) fs.mkdirSync(folder, { recursive: true });

    const destinationPath = path.join(folder, req.file.originalname);
    fs.writeFileSync(destinationPath, req.file.buffer);
    res.json({ success: true, filePath: destinationPath });
  } catch (err) {
    res.json({ success: false, message: err.message });
  }
};

// 5. Teams Relay
// Relays an Adaptive Card payload to the configured Teams endpoint.
//
// Do NOT treat "no exception" as delivered. Two ways this silently lies:
//   - Classic O365 connectors returned HTTP 200 with an error STRING in the body.
//   - Power Automate returns 202 Accepted immediately, before the flow runs; the
//     "Post card" step can fail afterwards and nothing reaches the channel.
// So we pass the upstream status/body straight back to the caller and only report
// ok when the status is 2xx AND the body doesn't look like an error.
exports.relayToTeams = async (req, res) => {
  try {
    const response = await axios.post(config.TEAMS_WEBHOOK_URL, req.body, {
      validateStatus: () => true, // never throw on 4xx/5xx — we want to see it
      timeout: 15000,
    });

    const raw =
      typeof response.data === "string"
        ? response.data
        : JSON.stringify(response.data ?? "");
    const looksLikeError = /error|failed|invalid|unauthorized/i.test(raw || "");
    const ok =
      response.status >= 200 && response.status < 300 && !looksLikeError;

    console.log(
      `[teams-relay] upstream ${response.status} ok=${ok} body=${(raw || "").slice(0, 300)}`,
    );

    res.status(ok ? 200 : 502).json({
      ok,
      message: ok
        ? "Sent to Teams"
        : "Teams endpoint did not accept the message",
      upstreamStatus: response.status,
      upstreamBody: (raw || "").slice(0, 500),
      // 202 means Power Automate QUEUED it — the flow can still fail afterwards.
      queuedOnly: response.status === 202,
    });
  } catch (error) {
    console.error("[teams-relay] request failed:", error.message);
    res.status(500).json({ ok: false, error: error.message });
  }
};

// 6. Save Inspection PDF
exports.saveInspectionPdf = (req, res) => {
  try {
    if (!req.file)
      return res
        .status(400)
        .json({ success: false, message: "No file received" });

    const {
      partDescription,
      personName,
      joNumber,
      inspectionType,
      processName,
    } = req.body;
    const baseDir =
      config.INSPECTION_PATHS[inspectionType] || config.INSPECTION_PATHS.IPQC;

    const now = new Date();
    const dateFolder = `${String(now.getDate()).padStart(2, "0")}-${String(now.getMonth() + 1).padStart(2, "0")}-${now.getFullYear()}`;

    const cleanPartName = sanitizeName(partDescription);
    const targetDir = path.join(baseDir, cleanPartName, dateFolder);

    if (!fs.existsSync(targetDir)) fs.mkdirSync(targetDir, { recursive: true });

    const timeStamp = `${String(now.getHours()).padStart(2, "0")}${String(now.getMinutes()).padStart(2, "0")}`;
    const fileName = `${sanitizeName(personName)}_${sanitizeName(processName)}_${sanitizeName(joNumber)}_${timeStamp}.pdf`;
    const finalPath = path.join(targetDir, fileName);

    fs.copyFileSync(req.file.path, finalPath);
    fs.unlinkSync(req.file.path);

    res.json({
      success: true,
      message: "PDF saved to server successfully",
      path: finalPath,
    });
  } catch (err) {
    res.status(500).json({ success: false, message: err.message });
  }
};

// 7. Save Process Flow Report PDF
exports.saveProcessFlowPdf = (req, res) => {
  try {
    if (!req.file)
      return res.json({ success: false, message: "No file uploaded" });

    const { partDescription, partNo } = req.body;
    const targetDir = partFolder(partDescription, partNo);

    if (!fs.existsSync(targetDir)) fs.mkdirSync(targetDir, { recursive: true });

    const finalPath = path.join(targetDir, "Process_Flow_Report.pdf");

    fs.copyFileSync(req.file.path, finalPath);
    fs.unlinkSync(req.file.path);

    res.json({
      success: true,
      message: "PDF saved successfully!",
      path: finalPath,
    });
  } catch (err) {
    res.json({ success: false, message: `Error saving PDF: ${err.message}` });
  }
};

// 8. External calibration alert
//
// One request, two independent channels. They are relayed separately and reported separately,
// because "the alert went out" is not one fact: the Teams flow can accept while the mail flow is
// switched off, and a QA lead who sees the card has no way to know the plant manager never got
// the mail. Each channel returns its own ok, and the caller writes one ext_cal_alert_log row per
// channel from what comes back.
//
// The delivery test is the one relayToTeams already uses, and for the same two reasons: a classic
// O365 connector answers 200 with an error STRING in the body, and Power Automate answers 202 as
// soon as it has queued the run - before any step of the flow has executed. So a 2xx alone is not
// delivery, and 202 is flagged queuedOnly so the page can say "queued" instead of "sent".

// The relay itself lives in utils/webhookRelay.js, because scripts/calibration-alert.js needs
// exactly the same delivery test and runs with no server in the picture. See that file for why a
// 2xx is not proof of delivery.
const { relayOneChannel } = require("../utils/webhookRelay");

exports.relayCalibrationAlert = async (req, res) => {
  const { teams, email } = req.body || {};

  // Nothing to send is a caller mistake, not a quiet success. Returning ok here would have the
  // page log an alert that never had a payload.
  if (!teams && !email) {
    return res.status(400).json({
      ok: false,
      error:
        "Nothing to send - the request carried neither a teams nor an email payload",
    });
  }

  // Guard the mail flow rather than the mail server: a Send an email (V2) step with an empty To
  // fails inside Power Automate, where nobody is watching, and the run history is the only
  // place it shows up.
  if (email && !(Array.isArray(email.to) && email.to.length)) {
    return res.status(400).json({
      ok: false,
      error:
        "The email payload has no recipients - add someone under the CALIBRATION role",
    });
  }

  const cfg = config.CALIBRATION_ALERT || {};

  // Both at once. They do not depend on each other, and a Teams flow that takes 15 seconds to
  // answer should not delay the mail by 15 seconds.
  const [teamsResult, emailResult] = await Promise.all([
    teams ? relayOneChannel("Teams", cfg.TEAMS_WEBHOOK_URL, teams) : null,
    email ? relayOneChannel("Email", cfg.EMAIL_WEBHOOK_URL, email) : null,
  ]);

  // ok means every channel that was ASKED for got through. A caller that sent only a card is
  // not marked down for the mail flow being unconfigured.
  const attempted = [teamsResult, emailResult].filter(Boolean);
  const ok = attempted.length > 0 && attempted.every((r) => r.ok);

  res.status(ok ? 200 : 502).json({
    ok,
    teams: teamsResult,
    email: emailResult,
  });
};
