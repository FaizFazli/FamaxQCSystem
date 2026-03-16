const fs = require("fs");
const path = require("path");

exports.sanitizeName = (name) => {
    return name ? name.trim().replace(/[\/\\?%*:|"<>]/g, "_") : "Unknown";
};

exports.findMasterDocument = (documentType) => {
    const masterFolder = path.join(__dirname, "..", "Master_Document");
    if (!fs.existsSync(masterFolder)) return null;
    const files = fs.readdirSync(masterFolder);
    const found = files.find((f) => f.toUpperCase().includes(documentType.toUpperCase()));
    return found ? path.join(masterFolder, found) : null;
};

exports.insertImageIntoSheet = (workbook, sheet) => {
    const famaxPath = "C:\\Users\\Acer\\IPQC_Project\\FamaxQCSystem\\assets\\Famax.png";
    const confPath = "C:\\Users\\Acer\\IPQC_Project\\FamaxQCSystem\\assets\\Confidential.png";

    if (!fs.existsSync(famaxPath) || !fs.existsSync(confPath)) return;

    const logoFamax = workbook.addImage({ filename: famaxPath, extension: "png" });
    const logoConf = workbook.addImage({ filename: confPath, extension: "png" });

    const sizeFamax = { width: 125, height: 51 };
    const sizeConf = { width: 189, height: 56 };

    // PAGE 1 Header
    sheet.addImage(logoFamax, { tl: { col: 0, row: 0 }, br: { col: 2, row: 3 }, editAs: "absolute", ext: sizeFamax });
    sheet.addImage(logoConf, { tl: { col: 18, row: 0 }, br: { col: 21, row: 3 }, editAs: "absolute", ext: sizeConf });

    // RECURRING LOGOS (This ensures Page Breaks are visible on all 10 pages)
    for (let i = 0; i < 10; i++) {
        const row = i * 48;
        // Famax Logos
        [21, 42, 63].forEach(col => {
            sheet.addImage(logoFamax, { tl: { col: col, row: row }, br: { col: col + 2, row: row + 3 }, editAs: "absolute", ext: sizeFamax });
        });
        // Confidential Logos
        [39, 60, 81].forEach(col => {
            sheet.addImage(logoConf, { tl: { col: col, row: row }, br: { col: col + 3, row: row + 3 }, editAs: "absolute", ext: sizeConf });
        });
    }
};