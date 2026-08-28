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

/**
 * Clear the "#VALUE!" left behind by Excel's in-cell images.
 *
 * The master templates put the Famax and Confidential logos in the header with Excel 365's
 * "Place in Cell" (A1 and S1 on the IPQC and BUYOFF forms; A1/I1/I4 on IQC; the W/AE columns
 * on OQC). Excel stores one of those as a RICH VALUE: the cell is written as an error cell
 * carrying "#VALUE!" as a fallback, plus a vm="N" attribute pointing into xl/metadata.xml and
 * xl/richData/, which is where the actual picture lives.
 *
 *     <c r="A1" s="99" t="e" vm="1"><v>#VALUE!</v></c>
 *
 * The "#VALUE!" is only what a reader is meant to show if it does not understand rich values.
 * ExcelJS does not: it reads the fallback, and on write it drops both vm= and the whole
 * xl/richData/ part. The picture is gone and the fallback is all that is left, which is why the
 * generated sheets show #VALUE! in the header where a logo belongs.
 *
 * insertImageIntoSheet below already redraws both logos as ordinary floating images, which
 * survive the round trip. So these cells have nothing left to say and are cleared.
 *
 * Only LITERAL error cells are touched. A cell whose error comes from a formula is left exactly
 * as it is - the (V10) templates carry a number of genuine #REF! formulas, and quietly deleting
 * those would hide a real problem rather than fix this one.
 */
exports.clearInCellImageErrors = (sheet) => {
    const ValueType = require("exceljs").ValueType;
    let cleared = 0;

    sheet.eachRow({ includeEmpty: false }, (row) => {
        row.eachCell({ includeEmpty: false }, (cell) => {
            if (cell.type !== ValueType.Error) return;
            if (cell.formula) return;                 // a real formula that errors - leave it
            // On a merged block only the master holds the value; writing to a slave is ignored.
            const target = cell.isMerged && cell.master ? cell.master : cell;
            target.value = null;
            cleared++;
        });
    });

    return cleared;
};

exports.insertImageIntoSheet = (workbook, sheet) => {
    // Relative to this file, like findMasterDocument above. These used to be absolute paths
    // into C:\Users\Acer\IPQC_Project\FamaxQCSystem — the machine the app was first written on.
    // They stopped resolving the moment the app moved, and stopped being resolvable at all once
    // it ran in a Linux container, where a C:\ path cannot exist. The workbook still generated;
    // it just came out with no logos, because the guard below returns without saying anything.
    const famaxPath = path.join(__dirname, "..", "assets", "Famax.png");
    const confPath = path.join(__dirname, "..", "assets", "Confidential.png");

    if (!fs.existsSync(famaxPath) || !fs.existsSync(confPath)) {
        // Loud, because silence here is what let the logos go missing unnoticed.
        console.warn(`[excel] logo missing, generating without it: ${famaxPath} / ${confPath}`);
        return;
    }

    const logoFamax = workbook.addImage({ filename: famaxPath, extension: "png" });
    const logoConf = workbook.addImage({ filename: confPath, extension: "png" });

    // "twoCell", not "absolute", is what makes these behave like the in-cell logos the
    // templates used to carry: the picture is tied to the two corners below, so it moves and
    // resizes with the cells instead of floating over them at a fixed screen position. It
    // matters here because pageSetup.fitToPage rescales every row and column at print time -
    // an absolute-anchored logo stays where it was and drifts off its header.
    //
    // The corners are chosen to match the merged header blocks exactly, so the logo fills the
    // cell and nothing else:  col 0->2 / row 0->3 is A1:B3, and col 18->21 is S1:U3.
    //
    // No `ext`. Passing both `br` and `ext` is contradictory - ExcelJS takes `br` and silently
    // ignores `ext` - and leaving it in reads as though it sets the size, which it does not.
    const ANCHOR = "twoCell";

    // PAGE 1 Header
    sheet.addImage(logoFamax, { tl: { col: 0, row: 0 }, br: { col: 2, row: 3 }, editAs: ANCHOR });
    sheet.addImage(logoConf, { tl: { col: 18, row: 0 }, br: { col: 21, row: 3 }, editAs: ANCHOR });

    // RECURRING LOGOS (This ensures Page Breaks are visible on all 10 pages)
    for (let i = 0; i < 10; i++) {
        const row = i * 48;
        // Famax Logos
        [21, 42, 63].forEach(col => {
            sheet.addImage(logoFamax, { tl: { col: col, row: row }, br: { col: col + 2, row: row + 3 }, editAs: ANCHOR });
        });
        // Confidential Logos
        [39, 60, 81].forEach(col => {
            sheet.addImage(logoConf, { tl: { col: col, row: row }, br: { col: col + 3, row: row + 3 }, editAs: ANCHOR });
        });
    }
};