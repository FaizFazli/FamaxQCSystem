const axios = require("axios");
const fs = require("fs");
const path = require("path");
const ExcelJS = require("exceljs");
const config = require("../config/config");

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
            if (err.code === 'EBUSY' && i < retries - 1) {
                console.warn(`⚠️ File ${path.basename(dest)} is busy/locked. Retrying (${i + 1}/${retries})...`);
                // Wait 1 second before retrying
                await new Promise(resolve => setTimeout(resolve, 1000));
            } else {
                throw err;
            }
        }
    }
};

exports.createFolder = async (req, res) => {
    const { folderPath, partDescription, partNo, rawMaterial, rawMaterialGrade, rawMaterialSize, processes, docNumber1, docNumber2, revNumber } = req.body;

    try {
        if (!fs.existsSync(folderPath)) {
            fs.mkdirSync(folderPath, { recursive: true });
        }

        let filesCreatedCount = 0;

        for (const proc of processes) {
            const masterPath = excelUtil.findMasterDocument(proc.documentType);

            if (!masterPath) {
                console.error(`❌ Template not found for: ${proc.documentType}`);
                continue;
            }

            const fileName = `${sanitizeName(proc.name)}_${proc.documentType}.xlsx`;
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
                const buffer = Buffer.from(proc.imageBase64.replace(/^data:image\/\w+;base64,/, ""), "base64");
                const imageId = workbook.addImage({ buffer, extension: "png" });
                sheet.addImage(imageId, { tl: { col: 0, row: 9 }, br: { col: 17, row: 47 }, editAs: "absolute" });
            }

            // Insert Recurring Logos & Page Breaks
            excelUtil.insertImageIntoSheet(workbook, sheet);

            // 1. Set A4 Paper and Zero Margins
            // This gives row 48 enough room to stay on Page 1
            sheet.pageSetup.paperSize = 9; // 9 = A4
            sheet.pageSetup.margins = {
                left: 0, right: 0,
                top: 0, bottom: 0,
                header: 0, footer: 0
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
            sheet.pageSetup.fitToWidth = 4;   // 84 columns / 4 = 21 columns (Ends at U)
            sheet.pageSetup.fitToHeight = 10; // 480 rows / 10 = 48 rows per page

            // 5. Center content to look clean
            sheet.pageSetup.horizontalCentered = true;
            sheet.pageSetup.verticalCentered = true;

            // 6. Preview Mode
            sheet.views = [
                {
                    state: 'pageLayout', // This opens the "intended" view immediately
                    activeCell: 'A1',
                    zoomScale: 100,      // Normal size
                    showRuler: true,
                    showGridLines: false
                }
            ];

            // Save the File (This will also fail if locked, so we use a try/catch)
            try {
                await workbook.xlsx.writeFile(destinationPath);
            } catch (saveErr) {
                if (saveErr.code === 'EBUSY') {
                    throw new Error(`Cannot save "${fileName}". Please close the file in Excel and try again.`);
                }
                throw saveErr;
            }

            filesCreatedCount++;
            console.log(`✅ Created/Replaced: ${fileName}`);
        }

        res.json({ success: true, message: `${filesCreatedCount} Excel files processed successfully.` });

    } catch (err) {
        console.error("Error creating folder/files:", err);
        res.status(500).json({ success: false, message: err.message });
    }
};

// 2. Move Obsolete Files
exports.moveObsoleteFiles = (req, res) => {
    const { partName, process, documentType } = req.body;
    try {
        const partFolder = path.join(config.BASE_FOLDER, partName);
        const obsoleteFolder = path.join(partFolder, "obsolete");
        if (!fs.existsSync(obsoleteFolder)) fs.mkdirSync(obsoleteFolder, { recursive: true });

        const files = fs.readdirSync(partFolder).filter(f => f.includes(`${process}_${documentType}`));
        files.forEach(file => {
            fs.renameSync(path.join(partFolder, file), path.join(obsoleteFolder, file));
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
        const dateFolder = new Date().toLocaleDateString('en-GB').replace(/\//g, '-');

        const targetDir = path.join(config.INSPECTION_PATHS.HUB, cleanSupervisor, dateFolder);
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
        const { partName } = req.body;
        const partFolder = path.join(config.BASE_FOLDER, partName);
        if (!fs.existsSync(partFolder)) fs.mkdirSync(partFolder, { recursive: true });

        const destinationPath = path.join(partFolder, req.file.originalname);
        fs.writeFileSync(destinationPath, req.file.buffer);
        res.json({ success: true, filePath: destinationPath });
    } catch (err) {
        res.json({ success: false, message: err.message });
    }
};

// 5. Teams Relay
exports.relayToTeams = async (req, res) => {
    try {
        const response = await axios.post(config.TEAMS_WEBHOOK_URL, req.body);
        res.status(200).json({ message: "Sent to Teams", status: response.status });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
};

// 6. Save Inspection PDF
exports.saveInspectionPdf = (req, res) => {
    try {
        if (!req.file) return res.status(400).json({ success: false, message: "No file received" });

        const { partDescription, personName, joNumber, inspectionType, processName } = req.body;
        const baseDir = config.INSPECTION_PATHS[inspectionType] || config.INSPECTION_PATHS.IPQC;

        const now = new Date();
        const dateFolder = `${String(now.getDate()).padStart(2, '0')}-${String(now.getMonth() + 1).padStart(2, '0')}-${now.getFullYear()}`;

        const cleanPartName = sanitizeName(partDescription);
        const targetDir = path.join(baseDir, cleanPartName, dateFolder);

        if (!fs.existsSync(targetDir)) fs.mkdirSync(targetDir, { recursive: true });

        const timeStamp = `${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}`;
        const fileName = `${sanitizeName(personName)}_${sanitizeName(processName)}_${sanitizeName(joNumber)}_${timeStamp}.pdf`;
        const finalPath = path.join(targetDir, fileName);

        fs.copyFileSync(req.file.path, finalPath);
        fs.unlinkSync(req.file.path);

        res.json({ success: true, message: "PDF saved to server successfully", path: finalPath });
    } catch (err) {
        res.status(500).json({ success: false, message: err.message });
    }
};

// 7. Save Process Flow Report PDF
exports.saveProcessFlowPdf = (req, res) => {
    try {
        if (!req.file) return res.json({ success: false, message: "No file uploaded" });

        const { partDescription } = req.body;
        const cleanDescription = sanitizeName(partDescription);
        const targetDir = path.join(config.BASE_FOLDER, cleanDescription);

        if (!fs.existsSync(targetDir)) fs.mkdirSync(targetDir, { recursive: true });

        const finalPath = path.join(targetDir, "Process_Flow_Report.pdf");

        fs.copyFileSync(req.file.path, finalPath);
        fs.unlinkSync(req.file.path);

        res.json({ success: true, message: "PDF saved successfully!", path: finalPath });
    } catch (err) {
        res.json({ success: false, message: `Error saving PDF: ${err.message}` });
    }
};

