const express = require("express");
const bodyParser = require("body-parser");
const cors = require("cors");
const path = require("path");
const inspectionRoutes = require("./routes/inspectionRoutes");

const app = express();

app.use(cors());
app.use(bodyParser.json({ limit: '50mb' }));
app.use(bodyParser.urlencoded({ limit: '50mb', extended: true }));

// --- API Endpoints ---
// This handles ALL /FamaxQCSystem/... routes
app.use("/FamaxQCSystem", inspectionRoutes); 

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

app.listen(80, () => {
    console.log("✅ Server running at http://192.168.2.113/FamaxQCSystem");
});