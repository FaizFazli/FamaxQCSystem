const fs = require("fs");
const path = require("path");

const sanitizeName = (name) => {
  if (!name) return "Unknown";
  return name.trim().replace(/[\/\\?%*:|"<>]/g, "_");
};

const copyFileWithRetry = async (src, dest, retries = 3) => {
  for (let i = 0; i < retries; i++) {
    try {
      fs.copyFileSync(src, dest);
      return true;
    } catch (err) {
      if (i === retries - 1) throw err;
      await new Promise((res) => setTimeout(res, 500));
    }
  }
};

module.exports = { sanitizeName, copyFileWithRetry };