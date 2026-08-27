// Single source of truth for the frontend's backend connection.
// IP is auto-detected from the address the app is opened on, so this file is
// identical on every machine — no per-machine edits, no merge conflicts.
// (Assumes Supabase :8000 and the web server :80 run on the same host as the app.)
(function () {
  var IP = window.location.hostname || "192.168.0.5";   // e.g. 192.168.2.195, localhost

  window.APP_CONFIG = {
    // Supabase REST/storage base (port 8000)
    url: "http://" + IP + ":8000",
    // App/static host base (port 80) — used for /FamaxQCSystem/... endpoints
    host: "http://" + IP,
    // Public Supabase anon key (same across environments)
    key: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzg3MDIxODkxLCJleHAiOjIxMDIzODE4OTF9.2zOycIdulGiO-ksORsmDn7Rp4wZnlBSiRCy3mZ3zOzM",
  };

  // When a page is embedded in the index.html content iframe, tag it so pages can
  // hide their own title header (avoids a double header). Standalone pages are unaffected.
  try {
    if (window.self !== window.top) {
      document.documentElement.classList.add("is-framed");
    }
  } catch (e) {
    // cross-origin access to window.top throws → we're framed
    document.documentElement.classList.add("is-framed");
  }
})();
