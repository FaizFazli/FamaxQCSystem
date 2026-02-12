const axios = require("axios");
const fs = require("fs");
const path = require("path");
const ExcelJS = require("exceljs");
const config = require("../config/config");
const { sanitizeName, findMasterDocument, insertImageIntoSheet } = require("../utils/excelUtils");


// 1. Create Folder and Generate Excel Files
exports.createFolder = async (req, res) => {
    const { folderPath, partDescription, partNo, rawMaterial, rawMaterialGrade, rawMaterialSize, processes, docNumber1, docNumber2, revNumber } = req.body;
    try {
        if (!fs.existsSync(folderPath)) fs.mkdirSync(folderPath, { recursive: true });

        for (const proc of processes) {
            const masterPath = findMasterDocument(proc.documentType);
            if (!masterPath) continue;

            const destinationPath = path.join(folderPath, `${sanitizeName(proc.name)}_${proc.documentType}.xlsx`);
            fs.copyFileSync(masterPath, destinationPath);

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

            // Insert Process Image
            if (proc.imageBase64) {
                const buffer = Buffer.from(proc.imageBase64.replace(/^data:image\/\w+;base64,/, ""), "base64");
                const imageId = workbook.addImage({ buffer, extension: "png" });
                sheet.addImage(imageId, { tl: { col: 0, row: 9 }, br: { col: 17, row: 47 }, editAs: "absolute" });
            }

            insertImageIntoSheet(workbook, sheet);
            await workbook.xlsx.writeFile(destinationPath);
        }
        res.json({ success: true, message: "Excel files created" });
    } catch (err) {
        res.json({ success: false, message: err.message });
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
// 4. Save Excel File
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
// 5. Save Excel File
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
        // 1. Check if Multer actually saved the file to Temp
        if (!req.file) {
            return res.status(400).json({ success: false, message: "No file received" });
        }

        const { partDescription, personName, joNumber, inspectionType, processName } = req.body;

        // 2. Determine Base Path from Config
        // (e.g., C:\Users\IPQC_Part_Summary)
        const baseDir = config.INSPECTION_PATHS[inspectionType] || config.INSPECTION_PATHS.IPQC;
        
        // 3. Create Date Folder (DD-MM-YYYY)
        const now = new Date();
        const dateFolder = `${String(now.getDate()).padStart(2, '0')}-${String(now.getMonth() + 1).padStart(2, '0')}-${now.getFullYear()}`;
        
        // 4. Construct Target Directory: BaseDir \ PartDescription \ Date
        const cleanPartName = sanitizeName(partDescription);
        const targetDir = path.join(baseDir, cleanPartName, dateFolder);

        // 5. Create the full folder path (Recursive creates all missing folders)
        if (!fs.existsSync(targetDir)) {
            fs.mkdirSync(targetDir, { recursive: true });
        }

        // 6. Construct Final Filename
        const timeStamp = `${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}`;
        const fileName = `${sanitizeName(personName)}_${sanitizeName(processName)}_${sanitizeName(joNumber)}_${timeStamp}.pdf`;
        const finalPath = path.join(targetDir, fileName);

        // 7. MOVE the file from Temp to Final Location
        // Using copy + unlink because renameSync often fails on Windows for permission/drive reasons
        fs.copyFileSync(req.file.path, finalPath);
        fs.unlinkSync(req.file.path); 

        console.log(`✅ File moved from Temp to: ${finalPath}`);

        res.json({ 
            success: true, 
            message: "PDF saved to server successfully", 
            path: finalPath 
        });

    } catch (err) {
        console.error("❌ Error in saveInspectionPdf:", err);
        res.status(500).json({ success: false, message: err.message });
    }
};
// 7.Save Process Flow Report PDF
exports.saveProcessFlowPdf = (req, res) => {
    try {
        if (!req.file) return res.json({ success: false, message: "No file uploaded" });

        const { partDescription } = req.body;
        if (!partDescription) return res.json({ success: false, message: "Missing partDescription" });

        const cleanDescription = sanitizeName(partDescription);
        
        // Use the base folder from config
        const targetDir = path.join(config.BASE_FOLDER, cleanDescription);

        if (!fs.existsSync(targetDir)) {
            fs.mkdirSync(targetDir, { recursive: true });
        }

        const finalPath = path.join(targetDir, "Process_Flow_Report.pdf");

        // Safely move the file
        fs.copyFileSync(req.file.path, finalPath);
        fs.unlinkSync(req.file.path);

        console.log(`✅ Process Flow PDF saved for: ${cleanDescription}`);
        
        res.json({
            success: true,
            message: "PDF saved successfully!",
            path: finalPath,
        });
    } catch (err) {
        console.error("❌ Error saving Process Flow PDF:", err);
        res.json({ success: false, message: `Error saving PDF: ${err.message}` });
    }
};