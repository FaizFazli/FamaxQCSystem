const express = require("express");
const router = express.Router();
const multer = require("multer");
const dmsController = require("../controllers/dmsController");

// Setup temporary upload folder
const upload = multer({ dest: "temp/" });

// View Route (GET)
router.get("/details/:productName/:revision", dmsController.getPartData);
router.get("/download", dmsController.downloadFile);
router.get("/list", dmsController.listFolders);
router.get("/tooling-status/:productName/:revision", dmsController.getToolingStatus);
// Upload Route (POST) - ENSURE THE NAME MATCHES dmsController.saveDmsFile
router.post("/upload", upload.single("file"), dmsController.saveDmsFile);
// Route for specific Program File uploads (includes Process and Machine folders)
router.post("/upload-program", upload.single("file"), dmsController.uploadProgramFile);
// Route to create the folder structure
router.post("/prepare", dmsController.prepareFolder);
// Route for multi-file upload to specific subfolder
router.post("/upload-multi", upload.array("files"), dmsController.uploadToSubfolder);

router.post("/upload-generic", upload.array("files"), dmsController.uploadGeneric);



module.exports = router;