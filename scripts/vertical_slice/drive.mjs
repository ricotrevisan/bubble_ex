// Drives one generated page in a real browser (WTF-378), with the pinned
// Playwright of the fidelity gates (test/support/fidelity, `npm ci` there
// first). Only the slice's own server is contacted: every request to
// another origin is aborted and recorded.
//
//   node scripts/vertical_slice/drive.mjs --base http://127.0.0.1:4378 \
//     --path /some-page [--thing <Bubble ID>] --email user@example.test \
//     --out <private dir> [--log <server log file>]
//
// 1. Visits the page signed out, then signs in with a magic link from the
//    local mailbox (/dev/mailbox) and visits it again.
// 2. Fills every visible text input with synthetic text, then clicks each
//    element the page wires (`phx-click`, by `data-bubble-id`), one at a
//    time on a fresh load, and records what happened: navigation, a
//    LiveView error or crash (`phx-error`, a server 500), console errors,
//    whether anything in the DOM changed.
// Writes <out>/drive.json and screenshots <out>/*.png (the caller keeps
// <out> private).
import { chromium } from "../../test/support/fidelity/node_modules/playwright/index.mjs";
import fs from "node:fs";
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
const result = { page: pagePath, visits: [], sign_in: null, clicks: [], blocked_requests: [] };

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
  result.blocked_requests.push(url.origin);
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
page.on("console", (msg) => msg.type() === "error" && consoleErrors.push(msg.text().slice(0, 300)));
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
    clickables: [...document.querySelectorAll("[phx-click][data-bubble-id]")].map((e) => ({
      id: e.getAttribute("data-bubble-id"),
      visible: !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length),
    })),
    inputs: document.querySelectorAll("input, textarea, select").length,
    phx_error: !!document.querySelector(".phx-error"),
    html_sha: [...document.body.innerHTML].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7),
  }));

const visit = async (label) => {
  consoleErrors = [];
  const logFrom = logSize();
  const response = await page.goto(new URL(pagePath, base).href);
  await settle();
  const snap = await snapshot();
  await page.screenshot({ path: path.join(out, `${label}.png`), fullPage: true });
  const entry = {
    label,
    status: response && response.status(),
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

// 2. Magic-link sign-in through the local mailbox.
try {
  await page.goto(new URL("/sign-in", base).href);
  await settle();
  await page.fill('input[type="email"], input[name$="[email]"]', args.email);
  await page.click('form[action$="/magic_link/request"] button[type="submit"], form[action$="/magic_link/request"] button');
  await page.waitForTimeout(1500);
  await page.goto(new URL("/dev/mailbox", base).href);
  const mailbox = await page.content();
  const ids = [...mailbox.matchAll(/href="\/dev\/mailbox\/([^"]+)"/g)].map((m) => m[1]);
  let link = null;
  for (const id of ids) {
    await page.goto(new URL(`/dev/mailbox/${id}`, base).href);
    const html = await page.content();
    if (!html.includes(args.email)) continue;
    const m = html.match(/https?:\/\/[^"'\s<]+magic_link[^"'\s<]*/);
    if (m) {
      link = m[0].replace(/&amp;/g, "&");
      break;
    }
  }
  if (!link) throw new Error("no magic link in the local mailbox");
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
  result.sign_in = { ok: true, landed };
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
fs.writeFileSync(path.join(out, "drive.json"), JSON.stringify(result, null, 2), { mode: 0o600 });
console.log(
  `drove ${pagePath}: sign-in ${result.sign_in.ok ? "ok" : "failed"}, ` +
    `${result.clicks.length} clicks, ` +
    `${result.clicks.filter((c) => c.phx_error || c.server_errors.length).length} with errors`,
);
