const express = require("express");
const router = express.Router();
const multer = require("multer");
const dmsController = require("../controllers/dmsController");

// Setup temporary upload folder
const upload = multer({ dest: "temp/" });

// View Route (GET)
router.get("/details/:productName/:revision", dmsController.getPartData);
router.get("/download", dmsController.downloadFile);
// Upload Route (POST) - ENSURE THE NAME MATCHES dmsController.saveDmsFile
router.post("/upload", upload.single("file"), dmsController.saveDmsFile);


module.exports = router;