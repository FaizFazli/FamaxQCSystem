const express = require("express");
const bodyParser = require("body-parser");
const cors = require("cors");
const path = require("path");
const os = require("os");
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

app.get("/FamaxSystem", (req, res) => {
    res.sendFile(path.join(__dirname, "index.html"));
});

app.get("/FamaxMES", (req, res) => {
    res.sendFile(path.join(__dirname, "FamaxMES", "index.html"));
});

// The LAN address other machines use to reach this server. Read at startup so a
// changed IP never needs a code edit — the frontend derives its own URLs from
// window.location, so this is just what you tell people to open.
const VIRTUAL_ADAPTER = /vEthernet|WSL|Hyper-V|VirtualBox|VMware|Loopback/i;

function lanAddress() {
    const nets = os.networkInterfaces();
    const found = [];
    for (const name of Object.keys(nets)) {
        for (const net of nets[name] || []) {
            if (net.family !== "IPv4" || net.internal) continue;
            if (net.address.startsWith("169.254.")) continue;  // no DHCP lease
            found.push({ name, address: net.address });
        }
    }
    // Real NICs first — a WSL/Hyper-V switch also reports a private IPv4, but no
    // other machine on the floor can reach the server through it.
    const real = found.filter((n) => !VIRTUAL_ADAPTER.test(n.name));
    return (real[0] || found[0] || {}).address || "localhost";
}

app.listen(80, () => {
    console.log(`✅ Server running at http://${lanAddress()}/FamaxQCSystem`);
});