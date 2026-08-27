// TEMPLATE. Copy this to config/config.js and fill it in — the app will not start without it.
//
//     copy config\config.example.js config\config.js
//
// config/config.js is NOT tracked by git, because every machine needs different values: its own
// document folders, its own Supabase key, its own webhook URLs, its own APP_URL. It used to be
// tracked, and every pull overwrote the server's settings with a developer's laptop's.
//
// That means two things worth knowing:
//
//   * A fresh clone has no config/config.js at all. server.js, controllers/qcController.js,
//     controllers/dmsController.js, routes/inspectionRoutes.js and scripts/calibration-alert.js
//     all require it, and server.js serves every page — so without this file nothing runs.
//
//   * When a pull changes THIS file, it will not change yours. Compare the two after any pull
//     that touches it; a setting added here is one your config.js does not have yet.
//
// docs/external-calibration-production.md walks through filling this in on the production server.

module.exports = {
    // ---- Document storage -------------------------------------------------
    // Where the QC system reads and writes part documents. BASE_FOLDER is local to the machine
    // running server.js; DMS_FOLDER is usually a UNC path to the share.
    BASE_FOLDER: "C:\\Users\\FamaxQC_Doc",
    DMS_FOLDER: "\\\\FAMAX\\Famax DMS",
    MASTER_DOC_DIR: "Master_Document",

    // ---- Teams notifications (the general one) ----------------------------
    // The Power Automate flow behind screen_page/notification/teamsNotification.html.
    TEAMS_WEBHOOK_URL: "PASTE THE TEAMS FLOW URL",

    // --- External calibration alert -------------------------------------
    // Two Power Automate flows, both "When an HTTP request is received".
    // docs/external-calibration-setup.md has the trigger schema for each and
    // what to paste where; until these are filled in, the alert reports the
    // channel as "not configured" rather than pretending it sent.
    //
    // These are URLs with a `sig=` in them: anyone holding one can post to the
    // channel or send mail as the flow owner. They live here rather than in
    // ext_cal_alert_config because that table is readable with the anon key, and
    // how MANY days of warning is a setting while this is a credential.
    //
    // "Server-side" is only true because server.js now refuses to serve this
    // folder. It did serve it — http://<server>/config/config.js returned this
    // file, sig= and all, to anyone who could reach the machine. If that guard is
    // ever removed, this is public again.
    //
    // TEAMS may be pointed at TEAMS_WEBHOOK_URL above to reuse the existing
    // channel. It is separate so calibration can be sent somewhere quieter
    // without moving every other notification with it.
    CALIBRATION_ALERT: {
        TEAMS_WEBHOOK_URL: "PASTE THE CALIBRATION TEAMS FLOW URL",
        EMAIL_WEBHOOK_URL: "PASTE THE CALIBRATION EMAIL FLOW URL",

        // The "Open the masterlist" link on a SCHEDULED alert. The page can work its own address
        // out from window.location; a task running at 07:00 with no browser cannot, so it has to
        // be told. Use the LAN address people actually type, not localhost — the link is followed
        // from a phone or another desk, where localhost is that device, not this server.
        // Left empty the alert simply omits the button rather than shipping a dead link.
        //
        // Prefer the hostname over the IP where the address is a DHCP lease: the day it renews,
        // every alert card already sent carries a dead button. A reserved or static IP is fine.
        APP_URL: "http://YOUR-SERVER/screen_page/calibration/external_calibration_masterlist.html",
    },

    // Where server-side scripts reach the database.
    //
    // The browser derives this from window.location (assets/app-config.js) so the same files work
    // on every machine. A scheduled task has no window to derive from, so it is stated here.
    // localhost is correct because the only thing that runs these scripts is the machine hosting
    // the Supabase containers — the same machine that runs server.js.
    //
    // ANON_KEY is the public anon key of THIS machine's Supabase — the same string as the `key:`
    // line in assets/app-config.js on this machine. It is not a secret. It is repeated rather
    // than parsed out of that file so a scheduled task cannot break because a frontend file was
    // reformatted. Two installs are free to have different keys, so copy it from the machine you
    // are configuring, never from another one.
    SUPABASE: {
        URL: "http://localhost:8000",
        ANON_KEY: "PASTE THIS MACHINE'S SUPABASE ANON KEY",
    },

    // ---- Where inspection PDFs are filed ----------------------------------
    INSPECTION_PATHS: {
        IPQC: "C:\\Users\\IPQC_Part_Summary",
        BuyOff: "C:\\Users\\BuyOff_Part_Summary",
        IQC: "C:\\Users\\IQC_Part_Summary",
        OQC: "C:\\Users\\OQC_Part_Summary",
        HUB: "C:\\Users\\QCHUBInspectionSummary"
    }
};
