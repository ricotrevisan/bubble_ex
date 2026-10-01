// Drives one generated page in a real browser (WTF-378), with the pinned
// Playwright of the fidelity gates (test/support/fidelity, `npm ci` there
// first). Only the slice's own server is contacted: every request to
// another origin is aborted and recorded in `blocked_requests`, except the
// image requests for exactly the URLs the pages link from other hosts
// (`--assets`, the generated `.wtf/assets.json`: `external` images stay
// linked, as in Bubble, WTF-465; never Bubble's storage, see
// linked_images.mjs), which are expected and only counted, as
// `external_images_expected` (distinct URLs).
//
//   node scripts/vertical_slice/drive.mjs --base http://127.0.0.1:4378 \
//     --path /some-page [--thing <Bubble ID>] --email user@example.test \
//     --out <private dir> [--log <server log file>] [--assets <.wtf/assets.json>]
//
// 1. Visits the page signed out, then signs in with a magic link from the
//    local mailbox (/dev/mailbox) and visits it again.
// 2. Fills every visible text input with synthetic text, then clicks each
//    element the page wires (`phx-click`, by `data-bubble-id`), one at a
//    time on a fresh load, and records what happened: navigation, a
//    LiveView error or crash (`phx-error`, a server 500), console errors,
//    whether anything in the DOM changed.
// Each visit also records its load and settle times and, as counts, its
// layout sanity (elements with no area, past the right edge, wired
// elements covered at their center), and the raw ISO timestamps in its
// visible text: Bubble shows dates formatted, so a nonzero count is an
// unformatted date (WTF-456).
// Writes <out>/drive.json and screenshots <out>/*.png (the caller keeps
// <out> private).
import { chromium } from "../../test/support/fidelity/node_modules/playwright/index.mjs";
import fs from "node:fs";
import { expectedImage, linkedImageUrls, withoutFragment } from "./linked_images.mjs";
import path from "node:path";

const args = Object.fromEntries(
  process.argv
    .slice(2)
    .reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
);

for (const required of ["base", "path", "email", "out"]) {
  if (!args[required]) {
    console.error(`missing --${required}`);
    process.exit(2);
  }
}

const base = new URL(args.base);
if (base.hostname !== "127.0.0.1") {
  console.error("--base must be a server on 127.0.0.1");
  process.exit(2);
}

const out = args.out;
fs.mkdirSync(out, { recursive: true, mode: 0o700 });
const pagePath = args.thing ? `${args.path}/${args.thing}` : args.path;
const result = {
  page: pagePath,
  visits: [],
  sign_in: null,
  clicks: [],
  blocked_requests: [],
  external_images_expected: 0,
};

// The URLs of the images the pages link from other hosts, and those the
// drive blocked.
const linked = args.assets ? linkedImageUrls(JSON.parse(fs.readFileSync(args.assets, "utf8"))) : new Set();
const linkedImages = new Set();

// Nothing but the slice's own server, three ways: no host name resolves
// but 127.0.0.1 (a request that escaped the routes below fails DNS), every
// HTTP request and WebSocket to another origin is aborted and recorded, and
// no service worker runs (its fetches would bypass the routes).
const browser = await chromium.launch({
  args: ["--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"],
});
const context = await browser.newContext({
  viewport: { width: 1280, height: 900 },
  serviceWorkers: "block",
});

await context.route("**/*", (route) => {
  const url = new URL(route.request().url());
  if (url.origin === base.origin || url.protocol === "data:") return route.continue();
  if (expectedImage(url.href, route.request().resourceType(), linked)) linkedImages.add(withoutFragment(url.href));
  else result.blocked_requests.push(url.origin);
  return route.abort();
});

// The LiveView socket is same-origin (ws://127.0.0.1:<port>): passed through.
await context.routeWebSocket(/.*/, (ws) => {
  const url = new URL(ws.url());
  if (url.host === base.host) return ws.connectToServer();
  result.blocked_requests.push(`${url.protocol}//${url.host}`);
  return ws.close({ code: 1008, reason: "blocked by the vertical slice" });
});

// The server's log (--log), to correlate what a click did on the server:
// its error and warning lines (a refused workflow, a crash).
const logSize = () => (args.log && fs.existsSync(args.log) ? fs.statSync(args.log).size : 0);
const serverLog = (from) => {
  if (!args.log) return [];
  const fd = fs.openSync(args.log, "r");
  const size = fs.fstatSync(fd).size;
  const buf = Buffer.alloc(Math.max(0, size - from));
  fs.readSync(fd, buf, 0, buf.length, from);
  fs.closeSync(fd);
  return buf
    .toString("utf8")
    .split("\n")
    .filter((l) => /\[(error|warning)\]|\*\* \(/.test(l))
    .map((l) => l.replace(/\x1b\[[0-9;]*m/g, "").slice(0, 300));
};

const page = await context.newPage();
let consoleErrors = [];
// A linked image the drive blocked is expected: its load error is not one.
const expectedError = (msg) => linkedImages.has(withoutFragment(msg.location().url));
page.on("console", (msg) => msg.type() === "error" && !expectedError(msg) && consoleErrors.push(msg.text().slice(0, 300)));
page.on("pageerror", (err) => consoleErrors.push(`pageerror: ${String(err).slice(0, 300)}`));

const settle = async () => {
  await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});
  await page.waitForSelector("[data-phx-main].phx-connected, [data-phx-session].phx-connected", { timeout: 10_000 }).catch(() => {});
  await page.waitForTimeout(400);
};

const snapshot = async () =>
  page.evaluate(() => ({
    url: location.pathname + location.search,
    elements: document.querySelectorAll("[data-bubble-id]").length,
    visible_text: (document.body.innerText || "").length,
    // Raw ISO timestamps in the visible text: Bubble shows dates formatted
    // (WTF-456), so any is a date the page failed to format (a count only).
    iso_timestamps: ((document.body.innerText || "").match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/g) || []).length,
    clickables: [...document.querySelectorAll("[phx-click][data-bubble-id]")].map((e) => ({
      id: e.getAttribute("data-bubble-id"),
      visible: !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length),
    })),
    inputs: document.querySelectorAll("input, textarea, select").length,
    phx_error: !!document.querySelector(".phx-error"),
    // Layout sanity, as counts: rendered elements with no area, elements
    // past the viewport's right edge (a horizontal overflow), and wired
    // elements another element covers at their center.
    layout: (() => {
      const all = [...document.querySelectorAll("[data-bubble-id]")];
      const shown = all.filter((e) => getComputedStyle(e).display !== "none" && getComputedStyle(e).visibility !== "hidden");
      const rects = shown.map((e) => e.getBoundingClientRect());
      const covered = [...document.querySelectorAll("[phx-click][data-bubble-id]")].filter((e) => {
        const r = e.getBoundingClientRect();
        if (!r.width || !r.height) return false;
        const x = r.left + r.width / 2;
        const y = r.top + r.height / 2;
        if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return false;
        const hit = document.elementFromPoint(x, y);
        return !!hit && hit !== e && !e.contains(hit);
      }).length;
      return {
        shown: shown.length,
        zero_area: rects.filter((r) => r.width === 0 || r.height === 0).length,
        past_right_edge: rects.filter((r) => r.right > document.documentElement.clientWidth + 1).length,
        page_width: document.documentElement.scrollWidth,
        page_height: document.documentElement.scrollHeight,
        covered_clickables: covered,
      };
    })(),
    html_sha: [...document.body.innerHTML].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7),
  }));

const visit = async (label) => {
  consoleErrors = [];
  const logFrom = logSize();
  const started = Date.now();
  const response = await page.goto(new URL(pagePath, base).href);
  const loadedMs = Date.now() - started;
  await settle();
  const connectedMs = Date.now() - started;
  const snap = await snapshot();
  await page.screenshot({ path: path.join(out, `${label}.png`), fullPage: true });
  const entry = {
    label,
    status: response && response.status(),
    load_ms: loadedMs,
    settled_ms: connectedMs,
    ...snap,
    console_errors: consoleErrors,
    server_log: serverLog(logFrom),
  };
  delete entry.html_sha;
  result.visits.push(entry);
  return snap;
};

// 1. Signed out.
await visit("signed-out");

// 2. Magic-link sign-in through the local mailbox. Only a message that
//    arrives after the request counts: an earlier one (another drive of
//    the same server, the same user) holds a spent link. The generated
//    sender's Oban job is unique per email for 60 s, completed jobs
//    included, so a request within a minute of an earlier one is dropped,
//    not delayed. With no new link 61 s after the request, the drive asks
//    once more (by then the window has passed) and keeps polling.
const mailboxIds = async () => {
  await page.goto(new URL("/dev/mailbox", base).href);
  const html = await page.content();
  return [...html.matchAll(/href="\/dev\/mailbox\/([0-9a-f]{32})"/g)].map((m) => m[1]);
};
try {
  const known = new Set(await mailboxIds());
  const requestLink = async () => {
    await page.goto(new URL("/sign-in", base).href);
    await settle();
    await page.fill('input[type="email"], input[name$="[email]"]', args.email);
    await page.click('form[action$="/magic_link/request"] button[type="submit"], form[action$="/magic_link/request"] button');
  };
  const RETRY_AFTER_MS = 61_000;
  const DEADLINE_MS = RETRY_AFTER_MS + 45_000;
  const started = Date.now();
  let requested = Date.now();
  let requests = 1;
  await requestLink();
  let link = null;
  const checked = new Set(known);
  while (!link && Date.now() - started < DEADLINE_MS) {
    if (requests === 1 && Date.now() - requested >= RETRY_AFTER_MS) {
      await requestLink();
      requested = Date.now();
      requests++;
    }
    await page.waitForTimeout(1000);
    for (const id of await mailboxIds()) {
      if (checked.has(id)) continue;
      checked.add(id);
      await page.goto(new URL(`/dev/mailbox/${id}`, base).href);
      const html = await page.content();
      if (!html.includes(args.email)) continue;
      const m = html.match(/https?:\/\/[^"'\s<]+magic_link[^"'\s<]*/);
      if (m) {
        link = m[0].replace(/&amp;/g, "&");
        break;
      }
    }
  }
  if (!link) {
    const elapsed = Math.round((Date.now() - started) / 1000);
    throw new Error(`no new magic link in the local mailbox after ${elapsed} s and ${requests} request(s)`);
  }
  const linkUrl = new URL(link);
  await page.goto(new URL(linkUrl.pathname + linkUrl.search, base).href);
  await settle();
  // AshAuthentication may ask to confirm the sign-in.
  const confirm = page.locator('form[action*="magic_link"] button[type="submit"], form[action*="magic_link"] button').first();
  if (await confirm.count()) {
    await Promise.all([
      page.waitForURL((u) => !u.pathname.includes("magic_link"), { timeout: 10_000 }),
      confirm.click(),
    ]);
    await settle();
  }
  const landed = new URL(page.url()).pathname;
  if (landed.includes("magic_link") || landed.startsWith("/sign-in")) throw new Error(`still on ${landed.split("/")[1]}`);
  result.sign_in = { ok: true, landed, requests };
} catch (err) {
  result.sign_in = { ok: false, error: String(err).slice(0, 300) };
}

// 3. Signed in.
const signedIn = await visit("signed-in");

// 4. Every wired element, once, on a fresh load.
const fillInputs = async () => {
  const inputs = page.locator('input:visible:not([type="hidden"]):not([type="checkbox"]):not([type="radio"]):not([type="file"]), textarea:visible');
  const n = await inputs.count();
  for (let i = 0; i < n; i++) {
    const input = inputs.nth(i);
    const type = (await input.getAttribute("type")) || "text";
    const value = type === "email" ? "slice-subscriber@example.test" : type === "number" ? "3" : "Slice sample text";
    await input.fill(value).catch(() => {});
  }
  return n;
};

for (const { id } of signedIn.clickables) {
  consoleErrors = [];
  const serverErrors = [];
  const onResponse = (r) => r.status() >= 500 && serverErrors.push(`${r.status()} ${new URL(r.url()).pathname}`);
  page.on("response", onResponse);
  await page.goto(new URL(pagePath, base).href);
  await settle();
  const filled = await fillInputs();
  await page.waitForTimeout(300);
  const before = await snapshot();
  const target = page.locator(`[phx-click][data-bubble-id="${id}"]`).first();
  const visible = await target.isVisible().catch(() => false);
  const logFrom = logSize();
  let clickError = null;
  let forced = false;
  try {
    await target.click({ timeout: 3_000 });
  } catch (err) {
    // Covered by another element (or hidden): dispatch the click on the
    // element itself (a forced pointer click would land on the cover), and
    // record that it was forced.
    clickError = String(err).split("\n")[0].slice(0, 200);
    forced = true;
    await target.dispatchEvent("click").catch((e) => {
      clickError = String(e).split("\n")[0].slice(0, 200);
    });
  }
  await page.waitForTimeout(1200);
  await settle();
  const after = await snapshot();
  await page.screenshot({ path: path.join(out, `click-${id.replace(/[^A-Za-z0-9_-]/g, "_")}.png`), fullPage: true });
  page.off("response", onResponse);
  result.clicks.push({
    element: id,
    visible,
    inputs_filled: filled,
    forced,
    click_error: forced ? clickError : null,
    server_log: serverLog(logFrom),
    navigated: before.url !== after.url ? after.url : null,
    dom_changed: before.html_sha !== after.html_sha,
    phx_error: after.phx_error,
    server_errors: serverErrors,
    console_errors: consoleErrors,
  });
}

await browser.close();
result.blocked_requests = [...new Set(result.blocked_requests)].sort();
result.external_images_expected = linkedImages.size;
fs.writeFileSync(path.join(out, "drive.json"), JSON.stringify(result, null, 2), { mode: 0o600 });
console.log(
  `drove ${pagePath}: sign-in ${result.sign_in.ok ? "ok" : "failed"}, ` +
    `${result.clicks.length} clicks, ` +
    `${result.clicks.filter((c) => c.phx_error || c.server_errors.length).length} with errors, ` +
    `${result.blocked_requests.length} blocked origins, ` +
    `${result.external_images_expected} linked external images (expected), ` +
    `${Math.max(0, ...result.visits.map((v) => v.iso_timestamps || 0))} raw ISO timestamps shown`,
);
