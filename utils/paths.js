const path = require("path");
const config = require("../config/config");
const { sanitizeName } = require("./excelUtils");

/**
 * The one place the part folder name is decided.
 * Every endpoint that touches a part folder calls this, so the folders
 * cannot drift apart and leave Excel and PDF in separate places.
 */
exports.partFolder = (partDescription, partNo) => {
    const desc = sanitizeName(partDescription || "");
    // sanitizeName turns "" into "Unknown", so test the raw value first -
    // a part with no number gets a bare description folder, not "DESC (Unknown)".
    const no = String(partNo || "").trim() ? sanitizeName(partNo) : "";
    const name = no ? `${desc} (${no})` : desc;
    return path.join(config.BASE_FOLDER, name);
};