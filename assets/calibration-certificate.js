// Uploading a calibration certificate image — the rules, in one place.
//
// Two screens attach certificates now: the entry form, where a new certificate arrives with its
// image, and the masterlist's equipment editor, where a certificate already recorded from the
// spreadsheets gets its scan attached afterwards. All 31 certificates loaded from the two
// workbooks arrived with no image at all, because the sheets never recorded one — so the second
// case is not an edge case, it is most of the data.
//
// The important thing this file centralises is the ALLOW-LIST AND THE SIZE LIMIT. They have to
// match what storage.buckets declares for calibration_certificate, exactly, because the bucket is
// what actually enforces them — anyone holding the anon key can POST straight at storage without
// going near either page. What lives here is so the person choosing a file is told immediately
// rather than after a save and a 415 from a service they have never heard of.
//
// Two copies of that list is how one page ends up offering a file the bucket refuses. One copy,
// and widening it is a two-line change: here, and
// sql/2026-08-25_external_calibration_certificate_upload.sql.
(function (root, factory) {
    if (typeof module === "object" && module.exports) module.exports = factory();
    else root.CalibrationCertificate = factory();
})(typeof self !== "undefined" ? self : this, function () {

    var BUCKET = "calibration_certificate";
    var ACCEPT_TYPES = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"];
    var MAX_BYTES = 10 * 1024 * 1024;   // 10 MB, as the bucket declares

    // Safari hands over a .heic with an empty file.type, and an empty contentType is rejected by a
    // bucket that declares an allow-list. The extension is the only thing left to go on.
    var EXT_TYPES = {
        jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png",
        webp: "image/webp", heic: "image/heic", heif: "image/heif",
    };

    function extOf(name) {
        return (String(name || "").split(".").pop() || "").toLowerCase();
    }

    function mimeOf(file) {
        return file.type || EXT_TYPES[extOf(file.name)] || "";
    }

    function kb(n) {
        return n < 1024 * 1024
            ? Math.round(n / 1024) + " KB"
            : (n / 1024 / 1024).toFixed(1) + " MB";
    }

    /** @returns {{ok:boolean, error?:string}} — the message is written to be shown as-is. */
    function validate(file) {
        if (!file) return { ok: false, error: "No file was chosen." };
        var type = mimeOf(file);
        if (ACCEPT_TYPES.indexOf(type) === -1) {
            return {
                ok: false,
                error: type
                    ? file.name + " is a " + type + " — the certificate has to be a JPG, PNG, "
                      + "WEBP or HEIC image."
                    : file.name + " is not a recognised image.",
            };
        }
        if (file.size > MAX_BYTES) {
            return { ok: false, error: file.name + " is " + kb(file.size) + " — the limit is 10 MB." };
        }
        return { ok: true };
    }

    /* One object per certificate, keyed by instrument and calibration date so the bucket listing
       can be read by a person: 11/2026-08-20-1724....jpg. The timestamp is there because a
       certificate can be replaced, and overwriting the old object would silently rewrite what an
       earlier record points at. */
    function key(equipmentId, calDate, file) {
        var ext = EXT_TYPES[extOf(file.name)] ? extOf(file.name) : "jpg";
        var day = String(calDate || "undated").slice(0, 10);
        return equipmentId + "/" + day + "-" + Date.now() + "." + ext;
    }

    /**
     * Put the file in the bucket and hand back both halves of what the row needs.
     * Throws with a message fit to show; callers are expected to clean up with remove()
     * if whatever they do next fails.
     * @returns {Promise<{path:string, url:string}>}
     */
    async function upload(supabaseClient, opts) {
        var path = key(opts.equipmentId, opts.calDate, opts.file);
        var res = await supabaseClient.storage.from(BUCKET).upload(path, opts.file, {
            upsert: false,
            contentType: mimeOf(opts.file),
        });
        if (res.error) {
            throw new Error("The certificate image could not be uploaded: " + res.error.message);
        }
        var pub = supabaseClient.storage.from(BUCKET).getPublicUrl(path);
        return { path: path, url: pub.data.publicUrl };
    }

    /** Best-effort cleanup of an object whose row never got written. Never throws. */
    async function remove(supabaseClient, path) {
        if (!path) return false;
        try {
            await supabaseClient.storage.from(BUCKET).remove([path]);
            return true;
        } catch (e) {
            // Worth a console line, not worth replacing the real error with a cleanup failure
            // the person at the keyboard can do nothing about.
            console.error("Could not remove the orphaned certificate image", path, e);
            return false;
        }
    }

    return {
        BUCKET: BUCKET,
        ACCEPT_TYPES: ACCEPT_TYPES,
        MAX_BYTES: MAX_BYTES,
        extOf: extOf,
        mimeOf: mimeOf,
        kb: kb,
        validate: validate,
        key: key,
        upload: upload,
        remove: remove,
    };
});
