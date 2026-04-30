const fs = require("fs");
const path = require("path");
const XLSX = require("xlsx");
const config = require("../config/config");

// --- 1. GET DATA FOR UI ---
exports.getPartData = async (req, res) => {
    try {
        const { productName, revision } = req.params;
        const rootPath = path.join(config.DMS_FOLDER, productName, revision);

        if (!fs.existsSync(rootPath)) return res.status(404).json({ message: "Folder not found" });

        const data = {
            instructionModules: [],
            wiPdf: null,
            programCode: "",
            programFileName: "",
            tooling: [],
            samples: [],
            processImages: []
        };

        const getFiles = (sub) => {
            const p = path.join(rootPath, sub);
            return fs.existsSync(p) ? fs.readdirSync(p) : [];
        };

        const wiFiles = getFiles("Work Instruction (WI)");
        data.wiPdf = wiFiles.find(f => f.toLowerCase().endsWith('.pdf'));

        const excelFiles = wiFiles.filter(f => /\.(xlsx|xls|xlsm|ods)$/i.test(f));
        console.log(`--- Scanning ${productName} ---`);
        console.log(`Found ${excelFiles.length} files. Parsing content...`);

        excelFiles.forEach(file => {
            try {
                const filePath = path.join(rootPath, "Work Instruction (WI)", file);
                const wb = XLSX.readFile(filePath);
                const sheet = wb.Sheets[wb.SheetNames[0]];

                // Read as Array of Arrays first to see the real structure
                const rows = XLSX.utils.sheet_to_json(sheet, { header: 1 });

                if (rows.length < 2) return; // Skip empty files

                // Find which column has the instruction (Searching first 5 rows)
                let headerRowIndex = 0;
                let insColIdx = -1;
                let imgColIdx = -1;

                // Look for headers in the first 5 rows (in case row 1 is a logo)
                for (let i = 0; i < Math.min(5, rows.length); i++) {
                    const row = rows[i];
                    insColIdx = row.findIndex(cell =>
                        cell && ['instruction', 'step', 'process', 'action', 'description', 'task', 'work'].some(t => String(cell).toLowerCase().includes(t))
                    );
                    imgColIdx = row.findIndex(cell =>
                        cell && ['image', 'img', 'photo', 'picture'].some(t => String(cell).toLowerCase().includes(t))
                    );
                    if (insColIdx !== -1) {
                        headerRowIndex = i;
                        break;
                    }
                }

                // FALLBACK: If no header found, assume Column A is instruction and Column B is image
                if (insColIdx === -1) insColIdx = 0;
                if (imgColIdx === -1) imgColIdx = 1;

                const steps = [];
                // Start reading data from the row AFTER the header
                for (let i = headerRowIndex + 1; i < rows.length; i++) {
                    const text = rows[i][insColIdx];
                    if (text && String(text).trim() !== "") {
                        steps.push({
                            Instruction: text,
                            Image: rows[i][imgColIdx] || null
                        });
                    }
                }

                if (steps.length > 0) {
                    data.instructionModules.push({
                        moduleName: file.replace(/\.(xlsx|xls|xlsm|ods)$/i, '').replace(/_/g, ' '),
                        steps: steps
                    });
                    console.log(`✅ Loaded ${steps.length} steps from ${file}`);
                }
            } catch (err) {
                console.error(`❌ Error parsing ${file}:`, err.message);
            }
        });

        data.instructionModules.sort((a, b) => a.moduleName.localeCompare(b.moduleName));

        // Program and Images logic remains the same...
        const progFiles = getFiles("Program File");
        const codeFile = progFiles.find(f => /\.(txt|nc|gcode)$/i.test(f));
        if (codeFile) {
            data.programFileName = codeFile;
            data.programCode = fs.readFileSync(path.join(rootPath, "Program File", codeFile), 'utf8');
        }
        const imgRegex = /\.(jpg|jpeg|png|gif)$/i;
        data.tooling = getFiles("Tooling List").filter(f => imgRegex.test(f));
        data.samples = getFiles("Samples").filter(f => imgRegex.test(f));
        data.processImages = getFiles("Process Image").filter(f => imgRegex.test(f));

        res.json(data);
    } catch (err) {
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
};


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