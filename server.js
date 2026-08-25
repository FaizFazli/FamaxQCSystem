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

// --- Keep the server side of the app off the web ------------------------
//
// The two express.static(__dirname) mounts below serve the WHOLE application
// folder, and until this guard existed that included everything in it:
//
//     http://<server>/config/config.js      both Power Automate webhook URLs,
//                                           sig= and all, plus the Supabase key
//     http://<server>/.git/config           the entire repository, so every
//                                           credential ever committed
//     http://<server>/controllers/…         server logic
//     http://<server>/sql/…                 every migration
//
// All of it readable in a browser by anyone who can reach the machine. A comment
// in config.js used to claim those webhook URLs were safe because they lived
// "server-side" rather than in the database; that was simply wrong, and this is
// what makes it true.
//
// A denylist rather than an allowlist on purpose. An allowlist would have to
// name every folder the pages legitimately load from — assets, screen_page,
// FamaxMES, Master_Document, User Manual Document — and the day somebody adds
// another one the app breaks in a way that looks like a missing file. A
// denylist fails the other way: a new server-side folder is exposed until it is
// added here, which is why the list is next to the mounts it protects.
//
// Mounted AFTER /docs and /dms-docs so it cannot interfere with them: /docs is
// the parts document share, nothing to do with the repo's own docs folder.
const PRIVATE_DIRS = new Set([
    "config", "controllers", "routes", "utils", "scripts",
    "sql", "migrations", "node_modules", "temp",
]);
const PRIVATE_FILES = new Set([
    "server.js", "package.json", "package-lock.json",
]);

app.use((req, res, next) => {
    let p;
    try {
        p = decodeURIComponent(req.path);
    } catch (e) {
        return res.sendStatus(400);          // malformed %-escape
    }
    // Backslashes because Windows accepts them as separators, so /config\config.js
    // reaches the same file and must be caught by the same test.
    p = p.replace(/\\/g, "/").replace(/^\/FamaxQCSystem/i, "").replace(/^\/+/, "");
    const first = (p.split("/")[0] || "").toLowerCase();
    if (!first) return next();

    // 404, not 403: "there is nothing here" tells a probe less than "there is
    // something here and you may not have it".
    if (first.startsWith(".")) return res.sendStatus(404);      // .git and friends
    if (PRIVATE_DIRS.has(first) || PRIVATE_FILES.has(first)) return res.sendStatus(404);
    next();
});

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