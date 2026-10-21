// Records capture for `slice.exs records` (WTF-584): evaluate this expression in a Bubble page
// after its data settles, next to render_capture.js; it returns, as a JSON string, the records
// the page holds in browser memory (the client's record cache, `db._locals`), each with its
// data type and raw Bubble fields, so a slice can load the same records under the same IDs:
//
//   {"source": "bubble", "path": "/...", "user_id": "<id>" | null,
//    "records": {"<id>": {"type": "custom.thing" | "user", "raw": {...}}}}
//
// A user's `authentication` keeps only its email, confirmed status and the names of other
// sign-in methods (the client also holds e.g. a temporary password). The records are app data:
// store the file privately, never in a repository. Records Bubble only counts on the server, or
// lists it never sent to the browser, are not in the cache, so not here.
(() => {
  const page = document.querySelector(".bubble-element.Page");
  const sources = (n) => n.bubble_data.bubble_instance._p_context.datasources;
  let db = null;
  let userId = null;
  try { db = sources(page).current_page_item().db; } catch (_) {}
  try {
    const u = sources(page).current_user();
    userId = (u && typeof u.raw === "function" && u.raw()._id) || null;
    if (!db && u && u.db) db = u.db;
  } catch (_) {}
  if (!db) {
    for (const n of document.querySelectorAll(".bubble-element")) {
      try { const u = sources(n).current_user(); if (u && u.db) { db = u.db; break; } } catch (_) {}
    }
  }
  if (!db || !db._locals) return JSON.stringify({ source: "bubble", error: "no client record cache (db._locals)" });

  // Plain JSON values only, bounded (the cache can reference large or cyclic structures).
  const plain = (v, depth) => {
    if (v == null || typeof v === "boolean" || typeof v === "number" || typeof v === "string") return v;
    if (typeof v !== "object" || depth > 4) return undefined;
    if (Array.isArray(v)) return v.slice(0, 1000).map((x) => plain(x, depth + 1));
    const o = {};
    for (const k of Object.keys(v).slice(0, 500)) {
      if (k.startsWith("_") && k !== "_id") continue;
      try { const x = plain(v[k], depth + 1); if (x !== undefined) o[k] = x; } catch (_) {}
    }
    return o;
  };
  const auth = (a) => {
    if (!a || typeof a !== "object") return undefined;
    const o = {};
    for (const [k, v] of Object.entries(a)) {
      if (k === "email") {
        const e = typeof v === "string" ? { email: v } : v && typeof v === "object" ? v : {};
        o.email = {};
        if (typeof e.email === "string") o.email.email = e.email;
        if (e.email_confirmed != null) o.email.email_confirmed = e.email_confirmed;
      } else o[k] = {};
    }
    return o;
  };

  const records = {};
  for (const [id, v] of Object.entries(db._locals)) {
    if (!v || typeof v !== "object") continue;
    let raw = null;
    try { raw = typeof v.raw === "function" ? v.raw() : v.raw; } catch (_) {}
    raw = raw && typeof raw === "object" ? plain(raw, 0) : null;
    if (raw && "authentication" in raw) {
      const a = auth(raw.authentication);
      if (a) raw.authentication = a; else delete raw.authentication;
    }
    const type = typeof v.type === "string" ? v.type : null;
    records[id] = { type, raw };
  }
  return JSON.stringify({ source: "bubble", path: location.pathname, user_id: userId, records });
})()
