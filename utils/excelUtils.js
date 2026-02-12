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
    const famaxPath = "C:\\Users\\Faiz Ikhwani\\Desktop\\FamaxQCSystem\\assets\\Famax.png";
    const confPath = "C:\\Users\\Faiz Ikhwani\\Desktop\\FamaxQCSystem\\assets\\Confidential.png";

    if (fs.existsSync(famaxPath)) {
        const logo = workbook.addImage({ filename: famaxPath, extension: "png" });
        sheet.addImage(logo, { tl: { col: 0, row: 0 }, br: { col: 2, row: 3 }, editAs: "absolute" });
    }
    if (fs.existsSync(confPath)) {
        const logo = workbook.addImage({ filename: confPath, extension: "png" });
        sheet.addImage(logo, { tl: { col: 18, row: 0 }, br: { col: 21, row: 3 }, editAs: "absolute" });
    }
};