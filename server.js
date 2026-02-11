// ------------------- Dependencies -------------------
const express = require("express");
const bodyParser = require("body-parser");
const multer = require("multer");
const cors = require("cors");
const fs = require("fs");
const path = require("path");
const ExcelJS = require("exceljs");
const favicon = require("serve-favicon");
const axios = require("axios");


const app = express();

// ------------------- Middleware -------------------
app.use(cors());
app.use(bodyParser.json({ limit: '50mb' }));
app.use(bodyParser.urlencoded({ limit: '50mb', extended: true }));
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ limit: '50mb', extended: true }));

app.use(favicon(path.join(__dirname, "img", "icon3.svg"), { maxAge: 0 }));


// Serve static files (HTML, CSS, JS) from current folder
// app.use(express.static(__dirname));
app.use("/FamaxQCSystem", express.static(path.join(__dirname)));


// Default route to load index.html
app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "index.html"));
});

const BASE_FOLDER = "C:\\Users\\FamaxQC_Doc"; // New base folder

// ------------------- Helper Functions -------------------
function findMasterDocument(documentType) {
  const masterFolder = path.join(__dirname, "Master_Document");
  console.log("📂 Master_Document full path:", masterFolder);
  const files = fs.existsSync(masterFolder) ? fs.readdirSync(masterFolder) : [];
  return files.find((f) => f.toUpperCase().includes(documentType.toUpperCase()))
    ? path.join(
      masterFolder,
      files.find((f) => f.toUpperCase().includes(documentType.toUpperCase()))
    )
    : null;
}

async function copyFileWithRetry(src, dest, retries = 3) {
  for (let i = 0; i < retries; i++) {
    try {
      fs.copyFileSync(src, dest);
      return true;
    } catch (err) {
      if (i === retries - 1) throw err;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
}

function moveObsoleteFiles(partName, process, documentType) {
  try {
    // const partFolder = `\\\\192.168.0.5\\FamaxQC_Doc\\${partName}`;
    const partFolder = path.join(BASE_FOLDER, partName);
    const obsoleteFolder = path.join(partFolder, "obsolete");
    if (!fs.existsSync(obsoleteFolder))
      fs.mkdirSync(obsoleteFolder, { recursive: true });

    const filePattern = `${process}_${documentType}`;
    const files = fs
      .readdirSync(partFolder)
      .filter((f) => f.includes(filePattern));

    files.forEach((file) => {
      const oldPath = path.join(partFolder, file);
      const newPath = path.join(obsoleteFolder, file);
      fs.renameSync(oldPath, newPath);
    });
    return true;
  } catch (err) {
    console.error(err);
    return false;
  }
}

// ------------------- API Endpoints -------------------

// Utility function to sanitize folder/file names
function sanitizeName(name) {
  // Replace spaces with _
  // Replace / \ ? % * : | " < > ( ) with _
  return name
    .trim()
    .replace(/[\/\\?%*:|"<>]/g, "_")
    .replace(/[]/g, "_");
}

// Create folder and copy master document
app.post("/FamaxQCSystem/createFolder", async (req, res) => {
  const {
    folderPath,
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
    const safePartDescription = sanitizeName(partDescription);
    // const safeFolderPath = path.join(folderPath, safePartDescription);

    // Ensure folder exists
    if (!fs.existsSync(folderPath)) {
      fs.mkdirSync(folderPath, { recursive: true });
    }

    for (let i = 0; i < processes.length; i++) {
      const proc = processes[i];

      // Pick correct template for this process
      const masterDocumentPath = findMasterDocument(proc.documentType);
      if (!masterDocumentPath) {
        console.warn(`⚠️ Master template not found for ${proc.documentType}`);
        continue;
      }

      // Destination file name
      const safeProcessName = sanitizeName(proc.name);
      const documentName = `${safeProcessName}_${proc.documentType}.xlsx`;
      const destinationPath = path.join(folderPath, documentName);

      // Copy template
      await copyFileWithRetry(masterDocumentPath, destinationPath);

      // Load workbook
      const workbook = new ExcelJS.Workbook();
      await workbook.xlsx.readFile(destinationPath);
      const sheet = workbook.worksheets[0];

      // Fill headers
      sheet.getCell("C4").value = partDescription;
      sheet.getCell("C5").value = partNo;
      sheet.getCell("C6").value = rawMaterial;
      sheet.getCell("C7").value = rawMaterialGrade;
      sheet.getCell("C8").value = rawMaterialSize;
      sheet.getCell("S4").value = docNumber1;
      sheet.getCell("S5").value = docNumber2;
      sheet.getCell("S6").value = revNumber;

      // Fill ALL processes in each file
      let startRow = 14;
      processes.forEach((p, idx) => {
        sheet.getCell(`R${startRow + idx}`).value = idx + 1; // Process No
        sheet.getCell(`S${startRow + idx}`).value = p.name; // Process Name
      });
      // Insert images
      insertImageIntoSheet(workbook, sheet);

      // 🖼️ Insert process-specific image (Base64)
      if (proc.imageBase64) {
        const base64Data = proc.imageBase64.replace(/^data:image\/\w+;base64,/, "");
        const buffer = Buffer.from(base64Data, "base64");

        const imageId = workbook.addImage({
          buffer: buffer,
          extension: "png", // or "jpeg" depending on input
        });

        // Insert image inside range A10:Q47
        sheet.addImage(imageId, {
          tl: { col: 0, row: 9 }, // top-left corner
          br: { col: 17, row: 47 }, // bottom-right corner
          editAs: "absolute"
        });
      }

      // 1. Force Page Break Preview (Blue Lines Mode)
      sheet.views = [
        {
          state: "pageBreakPreview",
          activeCell: "A1",
          showRuler: true,
          showGridLines: false,
          zoomScale: 60,
        },
      ];

      // 2. Set the Print Area for the WHOLE 40-page block
      // 21 columns * 4 pages = 84 columns (Column CF)
      // 48 rows * 10 pages = 480 rows
      sheet.pageSetup.printArea = "A1:CF480";

      // 3. ROW BREAKS (Horizontal Lines) - THIS WORKS
      // Add a blue line every 48 rows
      for (let r = 48; r < 480; r += 48) {
        // exceljs supports adding breaks to rows
        sheet.getRow(r).addPageBreak();
      }

      // 4. COLUMN BREAKS (Vertical Lines) - REMOVED
      // We removed the column loop because .addPageBreak() does not exist for columns.
      // Instead, we use the settings below to force the vertical breaks.

      // 5. Fit Settings
      sheet.pageSetup.fitToPage = true;
      sheet.pageSetup.fitToWidth = 4;   // Forces the width to be exactly 4 pages
      sheet.pageSetup.fitToHeight = 10;

      // Save file
      await workbook.xlsx.writeFile(destinationPath);
      console.log(`✅ Created file for process: ${proc.name}`);
    }

    res.json({
      success: true,
      message: "All Excel files created & filled successfully.",
    });
  } catch (err) {
    console.error("❌ Error in /createFolder:", err);
    res.json({ success: false, message: err.message });
  }
});

// Save PDF using multer
const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    const tempFolder = `${BASE_FOLDER}\\Temp`;
    if (!fs.existsSync(tempFolder))
      fs.mkdirSync(tempFolder, { recursive: true });
    cb(null, tempFolder);
  },
  filename: (req, file, cb) => cb(null, "Process_Flow_Report.pdf"),
});
const upload = multer({ storage });

app.post("/FamaxQCSystem/savePdf", upload.single("pdf"), (req, res) => {
  try {
    if (!req.file)
      return res.json({ success: false, message: "No file uploaded" });

    // Recalculate the same folder as in /createFolder
    const { folderPath, processName, documentType, partDescription } = req.body;

    const cleanDescription = partDescription.replace(/[\\/:\*\?"<>\|]/g, "_");

    // If you are joining paths, ensure the result doesn't have the quote
    const targetDir = path.join('C:', 'Users', 'FamaxQC_Doc', cleanDescription);

    if (!fs.existsSync(targetDir)) {
      fs.mkdirSync(targetDir, { recursive: true });
    }

    // PDF goes into same folder as folderPath
    const finalPath = path.join(targetDir, "Process_Flow_Report.pdf");
    fs.renameSync(req.file.path, finalPath);

    res.json({
      success: true,
      message: "PDF saved successfully!",
      path: finalPath,
    });
  } catch (err) {
    res.json({ success: false, message: `Error saving PDF: ${err.message}` });
  }
});

// Move obsolete files
app.post("/FamaxQCSystem/moveObsoleteFiles", (req, res) => {
  const { partName, process, documentType } = req.body;
  if (!partName || !process || !documentType)
    return res.json({ success: false, message: "Missing parameters" });

  const result = moveObsoleteFiles(partName, process, documentType);
  if (result)
    res.json({ success: true, message: "Obsolete files moved successfully." });
  else res.json({ success: false, message: "Failed to move obsolete files" });
});

// Save Excel file
const excelUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 50 * 1024 * 1024 },
});


app.post("/FamaxQCSystem/saveExcelFile", excelUpload.single("file"), (req, res) => {
  // const { documentType, process, partName } = req.body;
  try {
    if (!req.file)
      return res.json({ success: false, message: "No file uploaded" });

    const { partName } = req.body;
    if (!partName)
      return res.json({ success: false, message: "Missing partName" });

    // const safePartProcess = sanitizeName(process);
    // const safeFolderPath = path.join(BASE_FOLDER, partName);

    const partFolder = path.join(BASE_FOLDER, partName);
    if (!fs.existsSync(partFolder))
      fs.mkdirSync(partFolder, { recursive: true });

    const destinationPath = path.join(partFolder, req.file.originalname);
    fs.writeFileSync(destinationPath, req.file.buffer);

    res.json({
      success: true,
      message: "File saved",
      filePath: destinationPath,
    });
  } catch (err) {
    res.json({
      success: false,
      message: `Error saving Excel file: ${err.message}`,
    });
  }
});

// ------------------- Save Inspection PDF -------------------

//---------IPQC save pdf-----------
app.post("/FamaxQCSystem/saveInspectionPdf", upload.single("pdf"), (req, res) => {
  try {
    if (!req.file) {
      return res.json({ success: false, message: "No file uploaded" });
    }

    const { partDescription, personName, joNumber, processName, inspectionType } = req.body;

    if (!partDescription) {
      return res.json({ success: false, message: "Missing partDescription" });
    }

    // 1. Setup Folders
    const cleanDescription = partDescription.replace(/[\\/:*?"<>|]/g, "_").trim();
    const now = new Date();
    const dateFolder = `${String(now.getDate()).padStart(2, '0')}-${String(now.getMonth() + 1).padStart(2, '0')}-${now.getFullYear()}`;
    const timeFolder = `${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}`;
    let summaryInspectionPath="C:\\Users\\IPQC_Part_Summary";
    // Use the specific IPQC path you defined
    if (inspectionType === "IPQC") {
      summaryInspectionPath = "C:\\Users\\IPQC_Part_Summary";
    }else if(inspectionType === "BuyOff"){
      summaryInspectionPath = "C:\\Users\\BuyOff_Part_Summary";
    }else if(inspectionType === "IQC"){
      summaryInspectionPath = "C:\\Users\\IQC_Part_Summary";
    }else if(inspectionType === "OQC"){
      summaryInspectionPath = "C:\\Users\\OQC_Part_Summary";
    }

    const targetDir = path.join(summaryInspectionPath, cleanDescription, dateFolder);

    // 2. Ensure the directory exists
    if (!fs.existsSync(targetDir)) {
      fs.mkdirSync(targetDir, { recursive: true });
    }

    // 3. Determine Filename
    // Use originalname if it exists (the one from options.filename in frontend)
    const fileName = `${personName || 'Unknown'}_${processName}_${sanitizeName(joNumber)}_${timeFolder}.pdf`;
    const finalPath = path.join(targetDir, fileName);

    // 4. Move the file SAFELY (Copy then Delete)
    // renameSync fails across different drives/partitions
    fs.copyFileSync(req.file.path, finalPath);
    fs.unlinkSync(req.file.path);

    console.log(`✅ PDF Report successfully saved to: ${finalPath}`);

    res.json({
      success: true,
      message: "PDF saved successfully to server!",
      path: finalPath,
    });
  } catch (err) {
    console.error("❌ Error saving PDF:", err);
    res.status(500).json({ success: false, message: `Error: ${err.message}` });
  }
});




// ------------------- Save QC HUB Summary PDF -------------------
app.post("/FamaxQCSystem/QCHUBInspectionSummary", upload.single("pdf"), (req, res) => {
  try {
    if (!req.file) {
      return res.json({ success: false, message: "No file uploaded" });
    }

    // Extract data from frontend
    const { supervisorName, joNumber, personName } = req.body;

    // 1. Sanitize Names (Remove characters that Windows doesn't allow in folder names)
    const cleanSupervisor = (supervisorName || "Unassigned_Supervisor").replace(/[\\/:*?"<>|]/g, "_").trim();
    // const cleanJO = (joNumber || "NoJO").replace(/[\\/:*?"<>|]/g, "_").trim();

    // 2. Setup Date and Time
    const now = new Date();
    const dateFolder = `${String(now.getDate()).padStart(2, '0')}-${String(now.getMonth() + 1).padStart(2, '0')}-${now.getFullYear()}`;
    const timeStamp = `${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}`;

    // 3. Define Path: Base > Supervisor Name > Date Folder
    const summaryHubBase = "C:\\Users\\QCHUBInspectionSummary";
    const targetDir = path.join(summaryHubBase, cleanSupervisor, dateFolder);

    // 4. Create directory if it doesn't exist (recursive: true creates parent folders too)
    if (!fs.existsSync(targetDir)) {
      fs.mkdirSync(targetDir, { recursive: true });
    }

    // 5. Determine Filename
    const fileName = `HUB_${timeStamp}.pdf`;
    const finalPath = path.join(targetDir, fileName);

    // 6. Move the file
    fs.copyFileSync(req.file.path, finalPath);
    fs.unlinkSync(req.file.path);

    console.log(`✅ QC HUB Report saved: ${finalPath}`);

    res.json({
      success: true,
      message: "Saved to QC HUB successfully",
      path: finalPath,
    });
  } catch (err) {
    console.error("❌ Error saving QC HUB PDF:", err);
    res.status(500).json({ success: false, message: err.message });
  }
});

app.post("/api/teams", async (req, res) => {
  try {
    // YOUR TEAMS WEBHOOK URL HERE
    const TEAMS_URL = "https://fmefamax3.webhook.office.com/webhookb2/f45f5cc6-1616-40b2-a58a-9b68ad1a4357@e0eb2e96-7e5f-4ebc-9891-a07922257dce/IncomingWebhook/d6acc3987e41441187168e334b0c7f42/7dbace1f-849f-4069-b37e-3d8852f42c31/V2wDgPw2MmdzmrgOh8B0rs5uu91wK_WbEb6sIhn5mvX1Y1"
    console.log("Relaying message to Teams...");

    // Forward the request body to Teams
    const response = await axios.post(TEAMS_URL, req.body, {
      headers: { "Content-Type": "application/json" },
    });

    res
      .status(200)
      .json({ message: "Successfully sent to Teams", status: response.status });
  } catch (error) {
    console.error("Error relaying to Teams:", error.message);
    res
      .status(500)
      .json({ error: "Failed to send message", details: error.message });
  }
});

// // Delete folder
// app.post('/deleteFolder', (req, res) => {
//     const { partName } = req.body;
//     if (!partName) return res.json({ success: false, message: 'Missing partName' });

//     const partFolder = `\\\\192.168.0.5\\FamaxQC_Doc\\${partName}`;
//     if (!fs.existsSync(partFolder)) return res.json({ success: false, message: 'Folder does not exist' });

//     const deleteFolderRecursive = (p) => {
//         if (fs.existsSync(p)) {
//             fs.readdirSync(p).forEach(file => {
//                 const curPath = path.join(p, file);
//                 if (fs.lstatSync(curPath).isDirectory()) deleteFolderRecursive(curPath);
//                 else fs.unlinkSync(curPath);
//             });
//             fs.rmdirSync(p);
//         }
//     };
//     deleteFolderRecursive(partFolder);
//     res.json({ success: true, message: `Folder ${partName} deleted successfully` });
// });

// ------------------- Default Route -------------------
// Always return index.html for root
app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

// ------------------- Start Server -------------------
app.listen(80, () => {
  console.log("✅ Server is running at http://192.168.0.5/FamaxQCSystem");
});

function insertImageIntoSheet(workbook, sheet, documentType) {
  // 1. Add Images to Workbook (Using your specific paths)
  const logoFamax = workbook.addImage({
    filename: "C:\\Users\\Acer\\IPQC_Project\\FamaxQCSystem\\img\\Famax.png",
    extension: "png",
  });

  const logoConfidential = workbook.addImage({
    filename: "C:\\Users\\Acer\\IPQC_Project\\FamaxQCSystem\\img\\Confidential.png",
    extension: "png",
  });

  // Original Pixel Sizes
  const sizeFamax = { width: 125, height: 51 };
  const sizeConfidential = { width: 189, height: 56 };

  /**
   * Helper: Places an image into a specific range of cells.
   * Calculates 'br' (Bottom Right) based on colSpan/rowSpan to ensure correct sizing.
   */
  const placeImage = (imageId, col, row, colSpan, rowSpan, pixelSize) => {
    sheet.addImage(imageId, {
      tl: { col: col, row: row },                    // Top-Left
      br: { col: col + colSpan, row: row + rowSpan }, // Bottom-Right (Calculated)
      editAs: "absolute",
      ext: pixelSize,
    });
  };

  // =========================================================
  // LOGIC FOR IPQC / IQC (Grid Layout)
  // =========================================================
  // Note: Based on your snippet, this applies to the grid layout documents

  // --- 1. Header Images (Page 1 Only) ---
  // Col A to C (0 to 2 = Span 2), Row 0 to 3 (Span 3)
  placeImage(logoFamax, 0, 0, 2, 3, sizeFamax);

  // Col S to V (18 to 21 = Span 3), Row 0 to 3 (Span 3)
  placeImage(logoConfidential, 18, 0, 3, 3, sizeConfidential);

  // --- 2. Recurring Images (Every 48 rows, 10 Pages) ---
  for (let i = 0; i < 10; i++) {
    const row = i * 48; // 0, 48, 96, 144...

    // A. Famax Logo Placement (Spans 2 cols, 3 rows)
    // Columns from your code: V(21), AQ(42), BL(63)
    const famaxCols = [21, 42, 63];
    famaxCols.forEach(col => {
      // Input: tl:21, br:23 -> colSpan = 2
      placeImage(logoFamax, col, row, 2, 3, sizeFamax);
    });

    // B. Confidential Logo Placement (Spans 3 cols, 3 rows)
    // Columns from your code: AN(39), BI(60), CD(81)
    const confCols = [39, 60, 81];
    confCols.forEach(col => {
      // Input: tl:39, br:42 -> colSpan = 3
      placeImage(logoConfidential, col, row, 3, 3, sizeConfidential);
    });
  }
}