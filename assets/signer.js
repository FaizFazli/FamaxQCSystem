// Who is signing, and how they prove it.
//
// Every screen that records a decision — a stock movement, a concession, a cost, a
// buy-off approval — has to answer two questions: whose name goes on the record, and
// what proves it is them. Until 2026-08-07 the answer was a name picked from
// EmployeeTable and that person's PIN. It did not work:
//
//   * 4 of 55 employees had a PIN at all, so the other 51 could not sign anything.
//   * All four shared the SAME PIN. Anyone who knew it could sign as any of them,
//     which is not identity, it is a shared door code.
//
// The answer now is the account already signed in. AdminCredential holds 13 accounts
// with 13 distinct passwords, both logins (index.html and FamaxMES/login.html)
// already authenticate against AdminCredential.Password, and sessionStorage.userId
// already says which account is at the keyboard. Signing is therefore re-typing the
// password of the account you are already using — a deliberate act, bound to the
// session, with no list of valid names on screen to pick from.
//
// WHAT THIS IS AND IS NOT.
//   It proves somebody at this keyboard knows this account's password. It does not
//   prove which human that is, and on a shared role account (Production, Quality,
//   QA/QC, BD) it cannot: the record will say "Production". That is a real loss of
//   detail against a named employee, and it is the trade that was chosen — a shared
//   role account named on the record beats four people sharing one PIN, because at
//   least the account is the one that was actually logged in.
//
//   The password is compared in the browser against a column the anon key can read.
//   That is not a new weakness introduced here — RLS is off on AdminCredential and
//   both login pages already do exactly this — but it does mean this is a control
//   against carelessness, not against somebody determined. A real fix is Supabase
//   Auth and a hashed password, which is a change to how the whole app signs in.
//
// WHY A SHARED FILE.
//   Seven screens ask for a signature. The PIN check was written once and copied,
//   and by the time it was replaced there were seven slightly different versions of
//   it. This is one implementation; when the rule changes it changes here.
//
// Usage:
//   <script src="../../assets/app-config.js"></script>
//   <script src="../../assets/signer.js"></script>
//
//   const who = await Signer.current();          // { ok, userId, name, position }
//   const res = await Signer.verify(password);   // re-reads the password, then checks
//   if (!res.ok) showError(res.error);
//   else record({ by: res.name, position: res.position });

(function () {
    'use strict';

    function base() {
        var c = window.APP_CONFIG || {};
        return { url: c.url, key: c.key };
    }

    function sessionUserId() {
        try {
            if (sessionStorage.getItem('isLoggedIn') !== 'true') return null;
            var id = sessionStorage.getItem('userId');
            return id && String(id).trim() ? String(id).trim() : null;
        } catch (e) {
            return null;   // storage blocked; treated as not signed in
        }
    }

    // Always a fresh read. A cached password would keep working after it was changed,
    // and the whole point of this box is that it reflects the account as it is now.
    async function fetchAccount(userId) {
        var b = base();
        if (!b.url || !b.key) throw new Error('APP_CONFIG is missing — assets/app-config.js did not load.');
        var url = b.url + '/rest/v1/AdminCredential'
            + '?UserId=eq.' + encodeURIComponent(userId)
            + '&select=UserId,Name,Access,Password&limit=1';
        var res = await fetch(url, { headers: { apikey: b.key, Authorization: 'Bearer ' + b.key } });
        if (!res.ok) throw new Error('Could not reach the credential store (' + res.status + ').');
        var rows = await res.json();
        return (rows && rows[0]) || null;
    }

    var NOT_SIGNED_IN = 'You are not signed in, so nothing can be recorded in your name. '
        + 'Sign in from the dashboard and try again.';

    // Who the record will name. Display only — never gates anything on its own.
    async function current() {
        var userId = sessionUserId();
        if (!userId) return { ok: false, error: NOT_SIGNED_IN };
        try {
            var row = await fetchAccount(userId);
            if (!row) {
                return {
                    ok: false,
                    error: 'The signed-in account (' + userId + ') no longer exists. Sign in again.'
                };
            }
            return {
                ok: true,
                userId: row.UserId || userId,
                // The name on the record. Falls back to the login id rather than
                // going blank — an unnamed signature is worse than a terse one.
                name: (row.Name && String(row.Name).trim()) || userId,
                // Access doubles as the position on records that carry one. It is
                // what this system knows about the signer's role; there is no job
                // title on AdminCredential.
                position: (row.Access && String(row.Access).trim()) || null,
                access: (row.Access && String(row.Access).trim()) || null
            };
        } catch (e) {
            return { ok: false, error: e.message || String(e) };
        }
    }

    // The check itself. Re-reads the account so a password changed a minute ago takes
    // effect immediately, and so a session left open on a deleted account cannot sign.
    async function verify(password) {
        var typed = String(password == null ? '' : password).trim();
        if (!typed) return { ok: false, error: 'Enter your password to sign this.' };

        var who = await current();
        if (!who.ok) return who;

        var row;
        try {
            row = await fetchAccount(who.userId);
        } catch (e) {
            return { ok: false, error: e.message || String(e) };
        }
        if (!row) return { ok: false, error: 'The signed-in account no longer exists. Sign in again.' };

        var actual = String(row.Password == null ? '' : row.Password);
        // Compared untrimmed on the stored side: a password with a trailing space is
        // still that account's password, and silently trimming it here would let a
        // different string through.
        if (typed !== actual) {
            return { ok: false, error: 'That is not the password for ' + who.name + '.' };
        }
        return { ok: true, userId: who.userId, name: who.name, position: who.position, access: who.access };
    }

    window.Signer = {
        current: current,
        verify: verify,
        signedInUserId: sessionUserId
    };
})();
