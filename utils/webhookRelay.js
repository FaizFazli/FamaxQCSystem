// Posting to a webhook, and deciding honestly whether it arrived.
//
// Two callers need this and they run in different places: controllers/qcController.js, serving the
// browser's "Send alert now", and scripts/calibration-alert.js, run by Windows Task Scheduler with
// no server in the picture at all. If each had its own copy, the daily digest and the manual one
// could disagree about what counts as delivered — which is the one thing an alert must never be
// vague about.
//
// The delivery test is the interesting part. A 2xx is NOT proof of delivery here, twice over:
//
//   * A classic O365 connector answers HTTP 200 with an error STRING in the body. The status says
//     fine, the body says the card was rejected, and only the body is telling the truth.
//   * Power Automate answers 202 Accepted the moment it has QUEUED the run — before a single step
//     of the flow has executed. The "Post card" step can fail a second later and nothing reaches
//     the channel. So 202 is reported as queuedOnly and callers say "queued", not "sent".
//
// Unconfigured is its own outcome, not a failure. `configured: false` tells the caller to say
// "paste the URL into config.js"; ok:false with an error message would send somebody looking for
// a broken webhook that does not exist yet.

const axios = require("axios");

const DEFAULT_TIMEOUT_MS = 20000;

/**
 * @param {string} label  what to call this channel in messages and logs, e.g. "Teams"
 * @param {string} url    the webhook URL, or "" / undefined if it has not been set up
 * @param {object} payload  what to POST
 * @returns {Promise<{configured:boolean, ok:boolean, message:string,
 *                    upstreamStatus?:number, upstreamBody?:string, queuedOnly?:boolean}>}
 *          Never throws — a transport failure comes back as ok:false with the reason.
 */
async function relayOneChannel(label, url, payload, timeoutMs) {
    if (!url) {
        return { configured: false, ok: false, message: `${label} webhook is not configured` };
    }
    try {
        const response = await axios.post(url, payload, {
            validateStatus: () => true,          // never throw on 4xx/5xx — we want to see it
            timeout: timeoutMs || DEFAULT_TIMEOUT_MS,
        });

        const raw = typeof response.data === "string"
            ? response.data
            : JSON.stringify(response.data ?? "");
        const looksLikeError = /error|failed|invalid|unauthorized/i.test(raw || "");
        const ok = response.status >= 200 && response.status < 300 && !looksLikeError;

        console.log(`[relay:${label}] upstream ${response.status} ok=${ok} `
            + `body=${(raw || "").slice(0, 300)}`);

        return {
            configured: true,
            ok,
            message: ok ? `Sent to ${label}` : `${label} endpoint did not accept the message`,
            upstreamStatus: response.status,
            upstreamBody: (raw || "").slice(0, 500),
            queuedOnly: response.status === 202,
        };
    } catch (error) {
        console.error(`[relay:${label}] request failed:`, error.message);
        return { configured: true, ok: false, message: error.message };
    }
}

module.exports = { relayOneChannel, DEFAULT_TIMEOUT_MS };
