// External calibration alert — what the message SAYS, in one place.
//
// Two things send this alert and they run in different places: the "Send alert now" button on
// screen_page/calibration/external_calibration_masterlist.html, in a browser, and
// scripts/calibration-alert.js, in Node, off Windows Task Scheduler. If each built its own card
// they would drift — one would learn about DUE_URGENT and the other would not, and the daily
// digest would quietly stop matching what QA sees on screen.
//
// So neither builds anything. This file takes rows already read from v_ext_cal_masterlist and
// returns the finished Teams card and the finished email, and it fetches nothing itself: no
// supabase-js in a Node script, no axios in a browser, and it can be reasoned about without a
// database. The two callers differ only in how they GET the rows and where they POST the result.
//
// Usage (identical on both sides):
//   const groups  = CalibrationAlert.bucket(rows);
//   const card    = CalibrationAlert.buildTeamsCard({ groups, cfg, mentionText, entities, ... });
//   const mail    = CalibrationAlert.buildEmail({ groups, cfg, to, ... });
(function (root, factory) {
    if (typeof module === "object" && module.exports) module.exports = factory();
    else root.CalibrationAlert = factory();
})(typeof self !== "undefined" ? self : this, function () {

    // ------------------------------------------------------------------
    // Formatting
    // ------------------------------------------------------------------

    // The spreadsheet wrote dates as "28 NOV 2025" and the printed record still does. Keeping
    // that format means a card can be read side by side with REC-QAS010-05 without translating.
    var MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                  "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];

    function fmtDate(iso) {
        if (!iso) return "—";
        // Split rather than new Date(iso): a bare "2026-07-24" is parsed as UTC midnight, and in
        // UTC+8 toLocaleDateString then renders it as the 24th only by luck of the offset sign.
        // West of Greenwich the same code prints the 23rd. Dates here are calendar dates, not
        // instants, so they must never go near a timezone.
        var p = String(iso).slice(0, 10).split("-");
        if (p.length !== 3) return String(iso);
        var m = parseInt(p[1], 10) - 1;
        return parseInt(p[2], 10) + " " + (MONTHS[m] || p[1]) + " " + p[0];
    }

    // "32 days overdue" / "in 6 days" / "today". Signed day counts read as arithmetic homework;
    // this is the sentence somebody would actually say.
    function duePhrase(days) {
        if (days === null || days === undefined) return "no due date";
        if (days < 0) return Math.abs(days) + (Math.abs(days) === 1 ? " day overdue" : " days overdue");
        if (days === 0) return "due today";
        return "due in " + days + (days === 1 ? " day" : " days");
    }

    // One instrument as one line. Serial is what tells the two counting scales apart — both read
    // "CS / DIGITAL COUNTING SCALE (6000g x 0.2g)" and only one of them is overdue — so it is
    // never dropped for brevity.
    function label(r) {
        var bits = [r.equipment_code];
        if (r.description) bits.push(String(r.description).replace(/\s*\n\s*/g, " ").trim());
        var head = bits.join(" — ");
        var sn = (r.serial_no || "").trim();
        if (sn && sn.toUpperCase() !== "N/A") head += "  (S/N " + sn + ")";
        return head;
    }

    function esc(s) {
        return String(s === null || s === undefined ? "" : s)
            .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;");
    }

    // ------------------------------------------------------------------
    // Bucketing
    // ------------------------------------------------------------------
    //
    // The buckets are NOT recomputed from days_to_due here. v_ext_cal_masterlist already decided
    // them, against the thresholds in ext_cal_alert_config, and re-deriving them in JavaScript is
    // how the page badge and the alert end up disagreeing about what "due soon" means. This reads
    // cal_status and sorts; that is all.
    //
    // NOT_REQUIRED, INACTIVE and VALID are absent on purpose — the lamp is not news, a scrapped
    // instrument is not news, and an in-date CMM is not news. include_not_due puts VALID back for
    // a monthly status mail.

    function bucket(rows) {
        var by = { OVERDUE: [], DUE_URGENT: [], DUE_SOON: [], NEVER_CALIBRATED: [], VALID: [] };
        (rows || []).forEach(function (r) {
            if (by[r.cal_status]) by[r.cal_status].push(r);
        });
        // Worst first inside each bucket: most overdue at the top, soonest due at the top.
        var byDue = function (a, b) {
            var x = a.days_to_due, y = b.days_to_due;
            if (x === null || x === undefined) return 1;
            if (y === null || y === undefined) return -1;
            return x - y;
        };
        Object.keys(by).forEach(function (k) { by[k].sort(byDue); });

        by.actionable = by.OVERDUE.length + by.DUE_URGENT.length
                      + by.DUE_SOON.length + by.NEVER_CALIBRATED.length;
        return by;
    }

    // The one-line summary that goes in the mail subject, the card title and the alert log. Same
    // sentence everywhere, so a row in ext_cal_alert_log can be matched to the mail it describes.
    function summaryLine(groups) {
        var parts = [];
        var od = groups.OVERDUE.length + groups.NEVER_CALIBRATED.length;
        var soon = groups.DUE_URGENT.length + groups.DUE_SOON.length;
        if (od) parts.push(od + (od === 1 ? " overdue" : " overdue"));
        if (soon) parts.push(soon + " due soon");
        return parts.length ? parts.join(", ") : "nothing due";
    }

    // ------------------------------------------------------------------
    // Teams
    // ------------------------------------------------------------------

    var SECTIONS = [
        { key: "OVERDUE",          heading: "OVERDUE",              colour: "Attention" },
        { key: "NEVER_CALIBRATED", heading: "NEVER CALIBRATED",     colour: "Attention" },
        { key: "DUE_URGENT",       heading: "DUE THIS WEEK",        colour: "Warning" },
        { key: "DUE_SOON",         heading: "DUE SOON",             colour: "Warning" },
        { key: "VALID",            heading: "IN DATE",              colour: "Good" },
    ];

    /**
     * @param groups       from bucket()
     * @param cfg          the ext_cal_alert_config row
     * @param mentionText  TeamsRecipients.mentionText('CALIBRATION') — "<at>Name</at> …", or ""
     * @param entities     TeamsRecipients.entities('CALIBRATION')    — matching msteams entities
     * @param sender       who pressed the button, or "Scheduled task"
     * @param appUrl       deep link back to the masterlist, or "" to omit the button
     */
    function buildTeamsCard(opts) {
        var groups = opts.groups, cfg = opts.cfg || {};
        var body = [];

        var clear = groups.actionable === 0;
        body.push({
            type: "TextBlock",
            text: (clear ? "✅ CALIBRATION STATUS — ALL IN DATE"
                         : "🔧 EXTERNAL CALIBRATION — ACTION REQUIRED"),
            weight: "Bolder",
            size: "Large",
            color: clear ? "Good" : "Attention",
            wrap: true,
        });

        body.push({
            type: "TextBlock",
            text: clear
                ? "Every externally calibrated instrument on REC-QAS010-05 is in date."
                : "The following equipment on REC-QAS010-05 needs a calibration booked. "
                  + "Warning window: " + (cfg.lead_days || 30) + " days.",
            wrap: true,
            spacing: "Small",
            isSubtle: true,
        });

        SECTIONS.forEach(function (sec) {
            var rows = groups[sec.key] || [];
            if (!rows.length) return;
            // VALID only appears when somebody asked for the full status list.
            if (sec.key === "VALID" && !cfg.include_not_due) return;

            body.push({
                type: "TextBlock",
                text: sec.heading + "  (" + rows.length + ")",
                weight: "Bolder",
                color: sec.colour,
                spacing: "Medium",
                separator: true,
                wrap: true,
            });
            body.push({
                type: "FactSet",
                facts: rows.map(function (r) {
                    return {
                        title: label(r),
                        value: (r.next_due_date ? fmtDate(r.next_due_date) : "no certificate on file")
                             + "  ·  " + duePhrase(r.days_to_due)
                             + (r.location ? "  ·  " + r.location : ""),
                    };
                }),
            });
        });

        // A card with <at> tokens and no matching entity is rejected outright by Teams, so both
        // come from the same call or neither is used. teams-recipients.js guarantees that pairing.
        if (mentionOk(opts)) {
            body.push({
                type: "TextBlock",
                text: "Attention: " + opts.mentionText,
                wrap: true,
                spacing: "Medium",
                separator: true,
            });
        }

        body.push({
            type: "TextBlock",
            text: "_" + (opts.sender || "Famax QC System") + " · " + summaryLine(groups) + "_",
            wrap: true,
            isSubtle: true,
            size: "Small",
            spacing: "Small",
        });

        var content = {
            type: "AdaptiveCard",
            $schema: "http://adaptivecards.io/schemas/adaptive-card.json",
            version: "1.4",
            body: body,
        };
        if (opts.appUrl) {
            content.actions = [{
                type: "Action.OpenUrl",
                title: "Open the masterlist",
                url: opts.appUrl,
            }];
        }
        if (mentionOk(opts)) content.msteams = { entities: opts.entities };

        return { type: "message", attachments: [{
            contentType: "application/vnd.microsoft.card.adaptive",
            content: content,
        }] };
    }

    function mentionOk(opts) {
        return !!(opts.mentionText && opts.entities && opts.entities.length);
    }

    // ------------------------------------------------------------------
    // Email
    // ------------------------------------------------------------------
    //
    // Returns exactly what the Power Automate "Send an email (V2)" step needs and nothing more:
    // to / subject / html. The plain-text copy rides along for a client that will not render HTML
    // — a phone notification preview, most often, which is where an overdue instrument is most
    // likely to actually be seen.
    //
    // Inline styles only. Every mail client strips <style> blocks, Outlook most aggressively, and
    // a table that loses its borders in Outlook is the one place this has to stay legible.

    function buildEmail(opts) {
        var groups = opts.groups, cfg = opts.cfg || {};
        var clear = groups.actionable === 0;

        var subject = clear
            ? "Calibration status — all instruments in date"
            : "Calibration alert — " + summaryLine(groups) + " (REC-QAS010-05)";

        var html = [];
        html.push('<div style="font-family:Segoe UI,Roboto,Helvetica,Arial,sans-serif;'
            + 'font-size:14px;color:#1e293b;line-height:1.5;">');
        html.push('<h2 style="margin:0 0 4px;font-size:18px;color:'
            + (clear ? "#047857" : "#b45309") + ';">'
            + (clear ? "Calibration status — all in date" : "External calibration — action required")
            + "</h2>");
        html.push('<p style="margin:0 0 16px;color:#64748b;">Inspection, Measuring &amp; Test '
            + "Equipment Master List (EXTERNAL) — REC-QAS010-05"
            + (clear ? "" : ". Warning window: " + (cfg.lead_days || 30) + " days.") + "</p>");

        SECTIONS.forEach(function (sec) {
            var rows = groups[sec.key] || [];
            if (!rows.length) return;
            if (sec.key === "VALID" && !cfg.include_not_due) return;

            var tone = sec.colour === "Attention" ? "#b91c1c"
                     : sec.colour === "Warning" ? "#b45309" : "#047857";

            html.push('<h3 style="margin:20px 0 8px;font-size:14px;color:' + tone + ';">'
                + esc(sec.heading) + " (" + rows.length + ")</h3>");
            html.push('<table cellpadding="0" cellspacing="0" border="0" '
                + 'style="border-collapse:collapse;width:100%;max-width:760px;font-size:13px;">');
            html.push('<tr style="background:#f1f5f9;">'
                + th("Equipment") + th("Serial") + th("Location")
                + th("Last cal.") + th("Due") + th("Status") + "</tr>");
            rows.forEach(function (r, i) {
                var bg = i % 2 ? "#ffffff" : "#f8fafc";
                html.push('<tr style="background:' + bg + ';">'
                    + td(esc(r.equipment_code) + " — "
                        + esc(String(r.description || "").replace(/\s*\n\s*/g, " ")))
                    + td(esc(r.serial_no || "—"))
                    + td(esc(r.location || "—"))
                    + td(fmtDate(r.last_cal_date))
                    + td(fmtDate(r.next_due_date))
                    + td('<span style="color:' + tone + ';font-weight:600;">'
                        + esc(duePhrase(r.days_to_due)) + "</span>")
                    + "</tr>");
            });
            html.push("</table>");
        });

        if (clear) {
            html.push('<p style="margin:16px 0 0;">No instrument is overdue or falling due inside '
                + "the warning window.</p>");
        }
        if (opts.appUrl) {
            html.push('<p style="margin:24px 0 0;"><a href="' + esc(opts.appUrl)
                + '" style="background:#0078d4;color:#ffffff;text-decoration:none;padding:10px 18px;'
                + 'border-radius:8px;display:inline-block;font-weight:600;">Open the masterlist</a></p>');
        }
        html.push('<p style="margin:24px 0 0;color:#94a3b8;font-size:12px;">Sent by '
            + esc(opts.sender || "the Famax QC System") + ". Recipients are managed under the "
            + "CALIBRATION role on the calibration masterlist page.</p>");
        html.push("</div>");

        var text = [];
        text.push(clear ? "Calibration status — all instruments in date"
                        : "External calibration — action required (REC-QAS010-05)");
        SECTIONS.forEach(function (sec) {
            var rows = groups[sec.key] || [];
            if (!rows.length) return;
            if (sec.key === "VALID" && !cfg.include_not_due) return;
            text.push("");
            text.push(sec.heading + " (" + rows.length + ")");
            rows.forEach(function (r) {
                text.push("  - " + label(r) + " — due " + fmtDate(r.next_due_date)
                    + " (" + duePhrase(r.days_to_due) + ")");
            });
        });

        return {
            to: opts.to || [],
            subject: subject,
            html: html.join(""),
            text: text.join("\n"),
        };
    }

    function th(s) {
        return '<th align="left" style="padding:8px 10px;border-bottom:2px solid #cbd5e1;'
            + 'font-weight:600;color:#475569;">' + s + "</th>";
    }
    function td(s) {
        return '<td style="padding:8px 10px;border-bottom:1px solid #e2e8f0;">' + s + "</td>";
    }

    return {
        bucket: bucket,
        summaryLine: summaryLine,
        buildTeamsCard: buildTeamsCard,
        buildEmail: buildEmail,
        fmtDate: fmtDate,
        duePhrase: duePhrase,
        label: label,
        SECTIONS: SECTIONS,
    };
});
