const fs = require("fs");
const path = require("path");
const XLSX = require("xlsx");
const config = require("../config/config");

exports.getPartData = async (req, res) => {
    try {
        const { productName, revision } = req.params;
        const rootPath = path.join(config.DMS_FOLDER, productName, revision);

        if (!fs.existsSync(rootPath)) {
            return res.status(404).json({ message: "Folder not found" });
        }

        const data = {
            instructionModules: [],
            wiPdf: null,
            programModules: [],
            tooling: [],
            samples: [],
            processImages: []
        };

        const getFiles = (sub) => {
            const p = path.join(rootPath, sub);
            return fs.existsSync(p) ? fs.readdirSync(p) : [];
        };

        // --- 1. WORK INSTRUCTIONS (WI) LOGIC ---
        // (Keep your existing WI logic here - unchanged)
        const wiFiles = getFiles("Work Instruction (WI)");
        data.wiPdf = wiFiles.find(f => f.toLowerCase().endsWith('.pdf'));
        const excelFiles = wiFiles.filter(f => /\.(xlsx|xls|xlsm|ods)$/i.test(f));
        excelFiles.forEach(file => {
            try {
                const filePath = path.join(rootPath, "Work Instruction (WI)", file);
                const wb = XLSX.readFile(filePath);
                const sheet = wb.Sheets[wb.SheetNames[0]];
                const rows = XLSX.utils.sheet_to_json(sheet, { header: 1 });
                if (rows.length < 2) return;
                let headerRowIndex = 0;
                let insColIdx = -1;
                let imgColIdx = -1;
                for (let i = 0; i < Math.min(5, rows.length); i++) {
                    const row = rows[i];
                    insColIdx = row.findIndex(cell => cell && ['instruction', 'step', 'process', 'action', 'description', 'task', 'work'].some(t => String(cell).toLowerCase().includes(t)));
                    imgColIdx = row.findIndex(cell => cell && ['image', 'img', 'photo', 'picture'].some(t => String(cell).toLowerCase().includes(t)));
                    if (insColIdx !== -1) { headerRowIndex = i; break; }
                }
                if (insColIdx === -1) insColIdx = 0;
                if (imgColIdx === -1) imgColIdx = 1;
                const steps = [];
                for (let i = headerRowIndex + 1; i < rows.length; i++) {
                    const text = rows[i][insColIdx];
                    if (text && String(text).trim() !== "") { steps.push({ Instruction: text, Image: rows[i][imgColIdx] || null }); }
                }
                if (steps.length > 0) {
                    data.instructionModules.push({
                        moduleName: file.replace(/\.(xlsx|xls|xlsm|ods)$/i, '').replace(/_/g, ' '),
                        fileName: file,
                        steps: steps
                    });
                }
            } catch (err) { console.error(`❌ Error parsing ${file}:`, err.message); }
        });
        data.instructionModules.sort((a, b) => a.moduleName.localeCompare(b.moduleName));


        // --- 2. UPDATED MULTI-FILE PROGRAM SCANNING LOGIC (Process > Machine > Files) ---
        const programFolderNames = ["Program FIle", "Program File", "Program", "PROGRAM"];
        let actualProgramFolder = programFolderNames.find(f => fs.existsSync(path.join(rootPath, f)));

        if (actualProgramFolder) {
            const programRoot = path.join(rootPath, actualProgramFolder);
            const processFolders = fs.readdirSync(programRoot);

            processFolders.forEach(procName => {
                const procPath = path.join(programRoot, procName);

                if (fs.statSync(procPath).isDirectory()) {
                    const machineFolders = fs.readdirSync(procPath);
                    const machineGroups = [];

                    machineFolders.forEach(machName => {
                        const machPath = path.join(procPath, machName);

                        if (fs.statSync(machPath).isDirectory()) {
                            const files = fs.readdirSync(machPath).filter(f => {
                                return !fs.statSync(path.join(machPath, f)).isDirectory();
                            });

                            if (files.length > 0) {
                                machineGroups.push({
                                    machineName: machName,
                                    files: files
                                });
                            }
                        }
                    });

                    if (machineGroups.length > 0) {
                        data.programModules.push({
                            processName: procName,
                            machines: machineGroups
                        });
                    }
                }
            });
        }

        // --- 3. IMAGES & TOOLING ---
        const imgRegex = /\.(jpg|jpeg|png|gif)$/i;
        data.tooling = getFiles("Tooling List").filter(f => imgRegex.test(f));
        data.samples = getFiles("Samples");
        data.drawingFiles = getFiles("Drawing File"); // <--- ADD THIS LINE
        data.cmmPrograms = getFiles("CMM Program");
        data.processImages = getFiles("Process Image").filter(f => imgRegex.test(f));

        res.json(data);
    } catch (err) {
        console.error("❌ Critical getPartData Error:", err);
        res.status(500).json({ error: err.message });
    }
};

// --- 2. SAVE UPLOADED FILE (For Future Use) ---
exports.saveDmsFile = (req, res) => {
    try {
        if (!req.file) return res.status(400).json({ success: false, message: "No file uploaded" });

        const { productName, revision, category } = req.body;
        const targetDir = path.join(config.DMS_FOLDER, productName, revision, category);

        if (!fs.existsSync(targetDir)) fs.mkdirSync(targetDir, { recursive: true });

        const finalPath = path.join(targetDir, req.file.originalname);
        fs.renameSync(req.file.path, finalPath);

        res.json({ success: true, message: `Successfully saved to ${category}` });
    } catch (err) {
        res.status(500).json({ success: false, message: err.message });
    }
}; 33
// Add/Replace in dmsController.js
exports.downloadFile = (req, res) => {
    try {
        const { productName, revision, subfolder, fileName } = req.query; // Changed to query params

        if (!productName || !revision || !subfolder || !fileName) {
            return res.status(400).send("Missing parameters");
        }

        const filePath = path.join(config.DMS_FOLDER, productName, revision, subfolder, fileName);

        console.log("-----------------------------------------");
        console.log("DOWNLOAD REQUESTED");
        console.log("Path:", filePath);

        if (fs.existsSync(filePath)) {
            console.log("✅ File found. Starting download...");
            res.download(filePath, fileName);
        } else {
            console.error("❌ File NOT found at path:", filePath);
            res.status(404).send("File not found on server.");
        }
    } catch (err) {
        console.error("❌ Download Error:", err);
        res.status(500).send("Server Error: " + err.message);
    }
};
// Folder list 
exports.listFolders = async (req, res) => {
    try {
        const rootPath = config.DMS_FOLDER;
        console.log("--- DASHBOARD SCAN START ---");
        console.log("Scanning root:", rootPath);

        if (!fs.existsSync(rootPath)) {
            console.error("❌ Root folder does not exist or is inaccessible.");
            return res.status(404).json({ message: "Root DMS folder not found" });
        }

        const items = fs.readdirSync(rootPath, { withFileTypes: true });
        const folders = [];

        for (const item of items) {
            // Only process folders, skip files like "Thumbs.db" or "desktop.ini"
            if (item.isDirectory()) {
                try {
                    const productPath = path.join(rootPath, item.name);

                    // Try to read the revisions (subfolders) inside
                    const revisionItems = fs.readdirSync(productPath, { withFileTypes: true });
                    const revisions = revisionItems
                        .filter(rev => rev.isDirectory())
                        .map(rev => rev.name);

                    // Only add to dashboard if it has folders inside (revisions)
                    if (revisions.length > 0) {
                        folders.push({
                            name: item.name,
                            revisions: revisions
                        });
                    }
                } catch (subErr) {
                    // If we can't open a specific folder, skip it and move to the next one
                    console.warn(`⚠️ Skipping folder "${item.name}": Access Denied or Busy.`);
                }
            }
        }

        console.log(`✅ Scan complete. Found ${folders.length} valid product folders.`);
        res.json(folders);
    } catch (err) {
        console.error("❌ Critical Dashboard Error:", err.message);
        res.status(500).json({ error: err.message });
    }
};

exports.getToolingStatus = async (req, res) => {
    try {
        const { productName, revision } = req.params;
        const { toolName, fileName } = req.query;

        // Change this line to your actual path if config isn't working
        const baseFolder = config.DMS_FOLDER || "\\\\FAMAX\\Famax DMS";
        const targetPath = path.join(baseFolder, productName, revision, 'Tooling List');

        console.log("Checking path:", targetPath);

        if (!fs.existsSync(targetPath)) {
            return res.status(404).json({ message: "Tooling List folder not found." });
        }

        const stats = fs.lstatSync(targetPath);

        // --- CASE A: "Tooling List" is an old single Excel file ---
        if (stats.isFile()) {
            console.log("Found single file, processing...");
            const workbook = XLSX.readFile(targetPath);
            return res.json(workbook.SheetNames.map(sn => ({
                fileName: 'Tooling List',
                sheetName: sn,
                displayName: workbook.Sheets[sn]['D2'] ? String(workbook.Sheets[sn]['D2'].v).trim() : sn
            })));
        }

        // --- CASE B: "Tooling List" is a folder (New Logic) ---
        if (stats.isDirectory()) {
            if (!toolName) {
                const files = fs.readdirSync(targetPath).filter(f => f.toLowerCase().endsWith('.xlsx') && !f.startsWith('~$'));
                let combinedToolList = [];

                files.forEach(file => {
                    try {
                        const workbook = XLSX.readFile(path.join(targetPath, file));
                        workbook.SheetNames.forEach(sn => {
                            combinedToolList.push({
                                fileName: file,
                                sheetName: sn,
                                displayName: workbook.Sheets[sn]['D2'] ? String(workbook.Sheets[sn]['D2'].v).trim() : sn
                            });
                        });
                    } catch (e) { console.error("Skip locked/bad file:", file); }
                });
                return res.json(combinedToolList);
            }

            // If we are looking for specific machine data
            const filePath = path.join(targetPath, fileName);
            if (!fs.existsSync(filePath)) return res.status(404).json({ error: "File not found" });

            const workbook = XLSX.readFile(filePath);
            const sheet = workbook.Sheets[toolName];
            if (!sheet) return res.status(404).json({ message: "Sheet not found" });

            const rows = XLSX.utils.sheet_to_json(sheet);
            const machines = [...new Set(rows.map(r => r.MACHINE))].filter(Boolean);

            const machineSummaries = machines.map(m => {
                const logs = rows.filter(r => r.MACHINE === m);
                const latest = logs[logs.length - 1];
                const rawLife = String(latest['TOOL LIFE'] || "0");
                const lifeLimit = parseInt(rawLife.replace(/[^0-9]/g, '')) || 0;
                const currentCounter = parseInt(latest['COUNTER']) || 0;
                const percentage = lifeLimit > 0 ? (currentCounter / lifeLimit) * 100 : 0;

                return {
                    machine: m,
                    counter: currentCounter,
                    lifeLimit: lifeLimit,
                    percentage: Math.min(Math.round(percentage), 100),
                    status: percentage >= 90 ? 'critical' : (percentage >= 75 ? 'warning' : 'ok')
                };
            });
            return res.json(machineSummaries);
        }

    } catch (err) {
        console.error("SERVER CRASH:", err); // Look at your terminal/CMD for this!
        res.status(500).json({ error: err.message });
    }
};

exports.uploadProgramFile = (req, res) => {
    try {
        if (!req.file) return res.status(400).json({ success: false, message: "No file uploaded" });

        const { productName, revision, process, machine } = req.body;

        // Clean folder names for Windows compatibility
        const cleanProduct = productName.replace(/[/\\?%*:|"<>]/g, '-');
        const cleanProcess = process.replace(/[/\\?%*:|"<>]/g, '-');
        const cleanMachine = machine.replace(/[/\\?%*:|"<>]/g, '-');

        // Construct Target Directory: ...\Program FIle\{Process}\{Machine}
        const targetDir = path.join(
            config.DMS_FOLDER,
            cleanProduct,
            revision,
            "Program FIle",
            cleanProcess,
            cleanMachine
        );

        if (!fs.existsSync(targetDir)) {
            fs.mkdirSync(targetDir, { recursive: true });
        }

        // Save file with its original name inside the machine folder
        const finalPath = path.join(targetDir, req.file.originalname);

        fs.copyFileSync(req.file.path, finalPath);
        fs.unlinkSync(req.file.path);

        res.json({ success: true, message: "Uploaded successfully to " + cleanMachine });

    } catch (err) {
        console.error("Detailed Server Error:", err);
        res.status(500).json({ success: false, message: "Server Error", error: err.message });
    }
};


exports.prepareFolder = async (req, res) => {
    try {
        const { productName, revision } = req.body;

        // Validation: Ensure data exists
        if (!productName || !revision) {
            console.error("❌ Prepare Folder: Missing Data", { productName, revision });
            return res.status(400).json({
                success: false,
                error: "Part Name or Revision is missing."
            });
        }

        // Clean name for Windows compatibility
        const cleanProduct = productName.replace(/[/\\?%*:|"<>]/g, '-');
        const revFolder = `REV-${revision}`;

        // Ensure config is loaded
        if (!config.DMS_FOLDER) {
            throw new Error("DMS_FOLDER path is not defined in config.");
        }

        const rootPath = path.join(config.DMS_FOLDER, cleanProduct, revFolder);

        const subFolders = [
            "Process Image",
            "Program FIle",
            "Samples",
            "Tooling List",
            "Work Instruction (WI)",
            "Drawing File",
            "CMM Program"
        ];

        // Create folders
        if (!fs.existsSync(rootPath)) {
            fs.mkdirSync(rootPath, { recursive: true });
        }

        subFolders.forEach(folder => {
            const folderPath = path.join(rootPath, folder);
            if (!fs.existsSync(folderPath)) {
                fs.mkdirSync(folderPath);
            }
        });

        res.json({ success: true, message: "Folders prepared" });

    } catch (err) {
        console.error("❌ Prepare Folder Error:", err);
        // Ensure we send back the actual error message
        res.status(500).json({ success: false, error: err.message || "Unknown Server Error" });
    }
};

exports.uploadToSubfolder = (req, res) => {
    try {
        const { productName, revision, subFolder } = req.body;
        const files = req.files; // Array of files from multer.array()

        if (!files || files.length === 0) {
            return res.status(400).json({ success: false, message: "No files received" });
        }

        const cleanProduct = productName.replace(/[/\\?%*:|"<>]/g, '-');
        const revFolder = `REV-${revision}`;
        const targetDir = path.join(config.DMS_FOLDER, cleanProduct, revFolder, subFolder);

        // Ensure target directory exists just in case
        if (!fs.existsSync(targetDir)) {
            fs.mkdirSync(targetDir, { recursive: true });
        }

        files.forEach(file => {
            const finalPath = path.join(targetDir, file.originalname);
            fs.copyFileSync(file.path, finalPath);
            fs.unlinkSync(file.path); // remove temp file
        });

        res.json({ success: true, message: `Uploaded ${files.length} files to ${subFolder}` });
    } catch (err) {
        console.error("❌ Subfolder Upload Error:", err);
        res.status(500).json({ success: false, error: err.message });
    }
};

exports.uploadGeneric = (req, res) => {
    try {
        const { productName, revision, subFolder } = req.body;
        const files = req.files; // Array of files from upload.array("files")

        if (!files || files.length === 0) {
            return res.status(400).json({ success: false, message: "No files received" });
        }

        // 1. Clean the product name for Windows folder compatibility
        const cleanProduct = productName.replace(/[/\\?%*:|"<>]/g, '-');

        // 2. Fix the Revision Folder naming logic (Prevent REV-REV-0)
        const revFolder = revision.startsWith("REV-") ? revision : `REV-${revision}`;

        // 3. Construct Target Directory
        const targetDir = path.join(config.DMS_FOLDER, cleanProduct, revFolder, subFolder);

        // 4. Create directory if it doesn't exist (recursive)
        if (!fs.existsSync(targetDir)) {
            fs.mkdirSync(targetDir, { recursive: true });
        }

        // 5. Move files from temp to final destination
        files.forEach(file => {
            const finalPath = path.join(targetDir, file.originalname);
            fs.copyFileSync(file.path, finalPath);
            fs.unlinkSync(file.path); // remove temp file
        });

        res.json({ success: true, message: `Successfully uploaded ${files.length} files to ${subFolder}` });
    } catch (err) {
        console.error("❌ Generic Upload Error:", err);
        res.status(500).json({ success: false, error: err.message });
    }
};