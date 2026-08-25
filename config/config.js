module.exports = {
    BASE_FOLDER: "C:\\Users\\FamaxQC_Doc",
    DMS_FOLDER: "\\\\FAMAX\\Famax DMS",
    MASTER_DOC_DIR: "Master_Document",
    TEAMS_WEBHOOK_URL: "https://defaulte0eb2e967e5f4ebc9891a07922257d.ce.environment.api.powerplatform.com:443/powerautomate/automations/direct/cu/13/workflows/5935cb754369419f89e344ac37a88d8d/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=3D2ffGQdNm79yCROLRMmoDllpds_sYVgikUh7XO9aP8",

    // --- External calibration alert -------------------------------------
    // Two Power Automate flows, both "When an HTTP request is received".
    // docs/external-calibration-setup.md has the trigger schema for each and
    // what to paste where; until these are filled in, the alert reports the
    // channel as "not configured" rather than pretending it sent.
    //
    // These are URLs with a `sig=` in them: anyone holding one can post to the
    // channel or send mail as the flow owner. That is why they live here,
    // server-side, and not in ext_cal_alert_config where the anon key would
    // reach them. How MANY days of warning is a setting; this is a credential.
    //
    // TEAMS may be pointed at TEAMS_WEBHOOK_URL above to reuse the existing
    // channel. It is separate so calibration can be sent somewhere quieter
    // without moving every other notification with it.
    CALIBRATION_ALERT: {
        TEAMS_WEBHOOK_URL: "https://defaulte0eb2e967e5f4ebc9891a07922257d.ce.environment.api.powerplatform.com:443/powerautomate/automations/direct/cu/08/workflows/2669d995b95b4ccb813e6a366a7d514f/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=xEx9LAMqQTPhhwnIPzudSJG8P1bkvaILXCvqtqxu7v4",
        EMAIL_WEBHOOK_URL: "",   // TODO: paste the calibration email flow URL

        // The "Open the masterlist" link on a SCHEDULED alert. The page can work its own address
        // out from window.location; a task running at 07:00 with no browser cannot, so it has to
        // be told. Use the LAN address people actually type, not localhost — the link is followed
        // from a phone or another desk, where localhost is that device, not this server.
        // Left empty the alert simply omits the button rather than shipping a dead link.
        // Hostname rather than the IP on purpose: this machine's 192.168.2.227 is a DHCP lease,
        // and the day it renews to something else every alert card already sent carries a dead
        // button. FMX-L-022 keeps resolving on the LAN whatever the lease does.
        APP_URL: "http://FMX-L-022/screen_page/calibration/external_calibration_masterlist.html",
    },

    // Where server-side scripts reach the database.
    //
    // The browser derives this from window.location (assets/app-config.js) so the same files work
    // on every machine. A scheduled task has no window to derive from, so it is stated here.
    // localhost is correct because the only thing that runs these scripts is the machine hosting
    // the Supabase containers — the same machine that runs server.js.
    //
    // The key is the public anon key, identical to the one that ships in assets/app-config.js.
    // It is not a secret and never has been; it is repeated rather than parsed out of that file
    // so a scheduled task cannot break because a frontend file was reformatted.
    SUPABASE: {
        URL: "http://localhost:8000",
        ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzg3MDIxODkxLCJleHAiOjIxMDIzODE4OTF9.2zOycIdulGiO-ksORsmDn7Rp4wZnlBSiRCy3mZ3zOzM",
    },
    INSPECTION_PATHS: {
        IPQC: "C:\\Users\\IPQC_Part_Summary",
        BuyOff: "C:\\Users\\BuyOff_Part_Summary",
        IQC: "C:\\Users\\IQC_Part_Summary",
        OQC: "C:\\Users\\OQC_Part_Summary",
        HUB: "C:\\Users\\QCHUBInspectionSummary"
    }
};