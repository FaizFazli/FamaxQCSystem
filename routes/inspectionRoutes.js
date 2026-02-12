const express = require("express");
const router = express.Router();
const fs = require("fs");
const multer = require("multer");
const { BASE_FOLDER } = require("../config/config");

// IMPORTANT: Import the controller where your logic lives
const qcController = require("../controllers/qcController");

// Setup Multer Storage
const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    const tempFolder = `${BASE_FOLDER}\\Temp`;
    if (!fs.existsSync(tempFolder)) fs.mkdirSync(tempFolder, { recursive: true });
    cb(null, tempFolder);
  },
  filename: (req, file, cb) => cb(null, `temp_${Date.now()}.pdf`),
});
const upload = multer({ storage });

// Note: We removed "/FamaxQCSystem" from these paths because 
// it is already prefixed in server.js
router.post("/createFolder", qcController.createFolder);
router.post("/moveObsoleteFiles", qcController.moveObsoleteFiles);
router.post("/saveExcelFile", upload.single("file"), qcController.saveExcelFile);
router.post("/savePdf", upload.single("pdf"), qcController.saveProcessFlowPdf);
router.post("/QCHUBInspectionSummary", upload.single("pdf"), qcController.saveHubSummary);
router.post("/saveInspectionPdf", upload.single("pdf"), qcController.saveInspectionPdf);

// This will be at http://IP/FamaxQCSystem/api/teams
router.post("/api/teams", qcController.relayToTeams);

module.exports = router;