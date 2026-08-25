// The daily external-calibration alert.
//
// A due date nobody is told about is the reason this whole module exists — item 11 on
// REC-QAS010-05 lapsed on 24 JUL 2026 and sat in a spreadsheet until somebody happened to look.
// The button on the masterlist fixes that only for the days somebody opens the masterlist. This
// is the part that runs whether anyone opens anything or not.
//
// Run by Windows Task Scheduler, once a morning:
//   node scripts/calibration-alert.js
//   Run-CalibrationAlert.bat   (the same thing, double-clickable, with a log)
//
// It builds the SAME card and the SAME email as the page does, from assets/calibration-alert.js,
// and posts them through the SAME relay the page's endpoint uses, from utils/webhookRelay.js.
// Nothing about the message is written twice, so the digest QA reads at 08:00 cannot drift from
// the one they can trigger by hand at 14:00.
//
// It does not need server.js to be running. It reads Supabase over REST and posts to the
// webhooks directly, so a stopped web server delays nothing.
//
// FLAGS
//   --force    send even if a successful digest already went out today
//   --dry-run  build and print everything, send nothing, log nothing
//
// EXIT CODES — the thing Task Scheduler shows in "Last Run Result", so they have to mean something:
//   0  sent, or there was correctly nothing to send
//   1  a channel failed, or the run could not complete
// A failed send exits non-zero on purpose. A task that always reports success is a task nobody
// ever checks.

const config = require("../config/config");
const { relayOneChannel } = require("../utils/webhookRelay");
const CA = require("../assets/calibration-alert.js");

const FORCE = process.argv.includes("--force");
const DRY = process.argv.includes("--dry-run");

const SB = (config.SUPABASE || {});
const REST = SB.URL + "/rest/v1";
const HEADERS = {
    apikey: SB.ANON_KEY,
    Authorization: "Bearer " + SB.ANON_KEY,
    "Content-Type": "application/json",
};

function log(...a) {
    // Timestamped, because the only place these lines are ever read is a log file days later,
    // where "failed" with no time attached is nearly useless.
    console.log(new Date().toISOString().replace("T", " ").slice(0, 19), "|", ...a);
}

async function rest(pathAndQuery, init) {
    const res = await fetch(REST + pathAndQuery, { headers: HEADERS, ...(init || {}) });
    if (!res.ok) {
        throw new Error("Supabase " + res.status + " on " + pathAndQuery
            + " - " + (await res.text()).slice(0, 300));
    }
    // 204 on an insert with no representation requested.
    return res.status === 204 ? null : res.json();
}

// Local calendar day, not UTC. The plant is at UTC+8, so a UTC "today" rolls over at 08:00 local
// and a digest sent at 09:00 would look like yesterday's to the dedupe below.
function localDayStartISO() {
    const now = new Date();
    return new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString();
}

async function main() {
    if (!SB.URL || !SB.ANON_KEY) {
        throw new Error("config.SUPABASE is not set - the script has no database to read.");
    }

    const [cfgRows, rows, people] = await Promise.all([
        rest("/ext_cal_alert_config?select=*&id=eq.1&limit=1"),
        rest("/v_ext_cal_masterlist?select=*&order=line_no"),
        rest("/NotificationRecipient?select=*&role=eq.CALIBRATION&active=is.true"
             + "&order=sort_order.asc,display_name.asc"),
    ]);

    const cfg = (cfgRows && cfgRows[0]) || { lead_days: 30, second_lead_days: 7,
        teams_enabled: true, email_enabled: true, include_not_due: false };

    const groups = CA.bucket(rows || []);
    const summary = CA.summaryLine(groups);
    log(`${(rows || []).length} instruments | ${summary}`);

    // Nothing due is the good outcome, and it is silent. A daily "all clear" trains people to
    // ignore the alert, which is precisely how the one that matters gets ignored too.
    if (!groups.actionable && !cfg.include_not_due) {
        log("Nothing overdue or inside the warning window - nothing sent.");
        return 0;
    }

    if (!cfg.teams_enabled && !cfg.email_enabled) {
        log("Both channels are switched off in ext_cal_alert_config - nothing sent.");
        return 0;
    }

    // Dedupe. Task Scheduler retries a failed run, and a machine that wakes late can fire a
    // missed task the moment it comes up — neither should chase the same people twice with the
    // same list. Only a SUCCESSFUL send counts: a failed one this morning is exactly the run that
    // should be allowed to try again.
    if (!FORCE && !DRY) {
        const sentToday = await rest("/ext_cal_alert_log?select=id,channel,sent_at"
            + "&ok=is.true&trigger_source=eq.SCHEDULED"
            + "&sent_at=gte." + encodeURIComponent(localDayStartISO()) + "&limit=1");
        if (sentToday && sentToday.length) {
            log("A scheduled digest already went out today - nothing sent. Use --force to override.");
            return 0;
        }
    }

    const to = (people || []).map((p) => p.email).filter(Boolean);
    // The mention pieces, built the same way assets/teams-recipients.js builds them in the
    // browser: one row produces both the <at> token and its entity, so the name shown and the
    // address pinged can never be two different people. A card carrying an <at> with no matching
    // entity is rejected outright by Teams, which is why both are empty or both are filled.
    const mentionText = (people || []).map((p) => "<at>" + p.display_name + "</at>").join(" ");
    const entities = (people || []).map((p) => ({
        type: "mention",
        text: "<at>" + p.display_name + "</at>",
        mentioned: { id: p.email, name: p.display_name },
    }));

    const appUrl = (config.CALIBRATION_ALERT && config.CALIBRATION_ALERT.APP_URL) || "";
    const sender = "Scheduled task";
    const results = [];

    if (cfg.teams_enabled) {
        const card = CA.buildTeamsCard({ groups, cfg, mentionText, entities, sender, appUrl });
        if (DRY) {
            log("[dry-run] Teams card:\n" + JSON.stringify(card, null, 2));
            results.push({ channel: "TEAMS", ok: true, dry: true });
        } else {
            const r = await relayOneChannel("Teams", config.CALIBRATION_ALERT.TEAMS_WEBHOOK_URL, card);
            results.push({ channel: "TEAMS", ...r });
        }
    }

    if (cfg.email_enabled) {
        if (!to.length) {
            // Not a silent skip. Email switched on with nobody listed is a configuration mistake
            // that would otherwise look exactly like a quiet morning.
            log("EMAIL is enabled but no active CALIBRATION recipients exist - nothing to send to.");
            results.push({
                channel: "EMAIL", ok: false, configured: true,
                message: "No active CALIBRATION recipients",
            });
        } else {
            const mail = CA.buildEmail({ groups, cfg, to, sender, appUrl });
            if (DRY) {
                log("[dry-run] Email to " + to.join(", ") + "\nSubject: " + mail.subject
                    + "\n\n" + mail.text);
                results.push({ channel: "EMAIL", ok: true, dry: true });
            } else {
                const r = await relayOneChannel(
                    "Email", config.CALIBRATION_ALERT.EMAIL_WEBHOOK_URL, mail);
                results.push({ channel: "EMAIL", ...r });
            }
        }
    }

    if (DRY) {
        log("Dry run - nothing was sent and nothing was logged.");
        return 0;
    }

    // One log row per channel attempted, successes and failures alike. A failed send that leaves
    // no row is indistinguishable from a day on which nothing was due.
    const overdue = groups.OVERDUE.length + groups.NEVER_CALIBRATED.length;
    const dueSoon = groups.DUE_URGENT.length + groups.DUE_SOON.length;
    try {
        await rest("/ext_cal_alert_log", {
            method: "POST",
            body: JSON.stringify(results.map((r) => ({
                trigger_source: "SCHEDULED",
                channel: r.channel,
                ok: !!r.ok,
                overdue_count: overdue,
                due_soon_count: dueSoon,
                detail: r,
                sent_by: "scheduled-task",
            }))),
        });
        await rest("/ext_cal_alert_config?id=eq.1", {
            method: "PATCH",
            body: JSON.stringify({
                last_run_at: new Date().toISOString(),
                last_run_summary: summary,
            }),
        });
    } catch (e) {
        // The alert going out matters more than the record of it going out, so a logging failure
        // is reported and does not change the exit code decided by the sends themselves.
        log("WARNING: the alert was sent but could not be logged -", e.message);
    }

    results.forEach((r) => {
        log(r.channel + ": " + (r.ok ? "sent" : "FAILED")
            + (r.queuedOnly ? " (queued by Power Automate - check the flow run history)" : "")
            + (r.message ? " - " + r.message : ""));
    });

    return results.every((r) => r.ok) ? 0 : 1;
}

main()
    .then((code) => process.exit(code))
    .catch((err) => {
        log("The calibration alert could not run:", err.message);
        console.error(err);
        process.exit(1);
    });
