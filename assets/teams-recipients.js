// Teams notification recipients — the single source of truth for who gets @mentioned.
//
// Recipients live in the "NotificationRecipient" table (see sql/2026-07-29_notification_recipient.sql)
// so replacing someone who resigned is an edit in the app, not a code change and release.
//
// Every rendered form of a mention — the plain "@Name" preview, the "<at>Name</at>" token in the card
// body, and the msteams entity carrying the email — is generated here from the SAME row. That is what
// makes it structurally impossible for the displayed name and the address actually pinged to disagree,
// which is exactly how the old hardcoded ENG mention ended up showing "Azim Bakar" while pointing at
// Nor Aiman's address.
//
// Usage:
//   await TeamsRecipients.load();
//   TeamsRecipients.plainText('ENG')    -> "@Nor Aiman @Muhammad Zahid"
//   TeamsRecipients.mentionText('ENG')  -> "<at>Nor Aiman</at> <at>Muhammad Zahid</at>"
//   TeamsRecipients.entities('ENG')     -> [{ type:'mention', text:'<at>Nor Aiman</at>',
//                                             mentioned:{ id:'…@…', name:'Nor Aiman' } }, …]
//
// IMPORTANT: a card must never contain an <at> token without a matching entity — Teams rejects it.
// Because mentionText() and entities() are driven by the same list, they are always consistent:
// when a role has no active recipients BOTH return empty, so callers can simply omit the msteams block.
(function () {
  var TABLE = "NotificationRecipient";

  // Radio buttons on the send form use "QA" | "ENG" | "Management"; the table stores uppercase.
  function normRole(role) {
    return (role || "").toString().trim().toUpperCase();
  }

  function client() {
    if (!window.APP_CONFIG) throw new Error("APP_CONFIG missing — load /assets/app-config.js first");
    return {
      base: window.APP_CONFIG.url + "/rest/v1",
      headers: {
        apikey: window.APP_CONFIG.key,
        Authorization: "Bearer " + window.APP_CONFIG.key,
        "Content-Type": "application/json",
        Prefer: "return=representation",
      },
    };
  }

  var cache = [];      // active recipients, ordered
  var loaded = false;

  var TeamsRecipients = {
    /** Fetch active recipients. Safe to call repeatedly (e.g. after an admin edit). */
    load: async function () {
      var c = client();
      var res = await fetch(
        c.base + "/" + TABLE + "?select=*&active=is.true&order=role.asc,sort_order.asc,display_name.asc",
        { headers: c.headers }
      );
      if (!res.ok) throw new Error("Failed to load recipients (" + res.status + ")");
      cache = await res.json();
      loaded = true;
      return cache;
    },

    /** Every recipient including inactive ones — for the admin modal only. */
    loadAll: async function () {
      var c = client();
      var res = await fetch(
        c.base + "/" + TABLE + "?select=*&order=role.asc,sort_order.asc,display_name.asc",
        { headers: c.headers }
      );
      if (!res.ok) throw new Error("Failed to load recipients (" + res.status + ")");
      return res.json();
    },

    isLoaded: function () {
      return loaded;
    },

    /** Active recipients for a role, e.g. [{ display_name, email }]. */
    forRole: function (role) {
      var r = normRole(role);
      return cache.filter(function (x) {
        return normRole(x.role) === r;
      });
    },

    /** "@Nor Aiman @Muhammad Zahid" — for the read-only preview textarea. */
    plainText: function (role) {
      return this.forRole(role)
        .map(function (p) {
          return "@" + p.display_name;
        })
        .join(" ");
    },

    /** "<at>Nor Aiman</at> <at>Muhammad Zahid</at>" — for the adaptive card body. */
    mentionText: function (role) {
      return this.forRole(role)
        .map(function (p) {
          return "<at>" + p.display_name + "</at>";
        })
        .join(" ");
    },

    /** msteams.entities[] — tokens built from the same display_name used by mentionText(). */
    entities: function (role) {
      return this.forRole(role).map(function (p) {
        return {
          type: "mention",
          text: "<at>" + p.display_name + "</at>",
          mentioned: { id: p.email, name: p.display_name },
        };
      });
    },

    // ---- admin CRUD (used by the Manage Recipients modal) ----
    create: async function (row) {
      var c = client();
      var res = await fetch(c.base + "/" + TABLE, {
        method: "POST",
        headers: c.headers,
        body: JSON.stringify(row),
      });
      if (!res.ok) throw new Error(await res.text());
      return res.json();
    },

    update: async function (id, patch) {
      var c = client();
      var res = await fetch(c.base + "/" + TABLE + "?id=eq." + encodeURIComponent(id), {
        method: "PATCH",
        headers: c.headers,
        body: JSON.stringify(patch),
      });
      if (!res.ok) throw new Error(await res.text());
      return res.json();
    },

    remove: async function (id) {
      var c = client();
      var res = await fetch(c.base + "/" + TABLE + "?id=eq." + encodeURIComponent(id), {
        method: "DELETE",
        headers: c.headers,
      });
      if (!res.ok) throw new Error(await res.text());
      return true;
    },

    ROLES: ["QA", "ENG", "MANAGEMENT"],
  };

  window.TeamsRecipients = TeamsRecipients;
})();
