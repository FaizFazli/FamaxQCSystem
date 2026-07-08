const express = require("express");
const bodyParser = require("body-parser");
const cors = require("cors");
const path = require("path");
const inspectionRoutes = require("./routes/inspectionRoutes");
const dmsRoutes = require("./routes/dmsRoutes"); // Add this
const app = express();
const config = require("./config/config"); 


app.use(cors());
app.use(bodyParser.json({ limit: '50mb' }));
app.use(bodyParser.urlencoded({ limit: '50mb', extended: true }));

// --- API Endpoints ---
// This handles ALL /FamaxQCSystem/... routes
app.use("/FamaxQCSystem", inspectionRoutes); 
app.use("/FamaxDMS", dmsRoutes);

// 2. EXPOSE THE DOCUMENTS FOLDER AS STATIC
// This allows <img src="http://IP/docs/PartA/image.png"> to work
app.use("/docs", express.static(config.BASE_FOLDER));
app.use("/dms-docs", express.static(config.DMS_FOLDER));

// --- Static Files ---
app.use(express.static(__dirname)); 
app.use("/FamaxQCSystem", express.static(__dirname));

// --- HTML Routes ---
app.get("/", (req, res) => {
    res.sendFile(path.join(__dirname, "index.html"));
});

app.get("/FamaxQCSystem", (req, res) => {
    res.sendFile(path.join(__dirname, "index.html"));
});

app.get("/FamaxMES", (req, res) => {
    res.sendFile(path.join(__dirname, "FamaxMES", "index.html"));
});

app.listen(80, () => {
    console.log("✅ Server running at http://192.168.0.5/FamaxQCSystem");
});