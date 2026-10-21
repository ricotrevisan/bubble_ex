// Captures pages of a generated app for `mix bubble.render_diff` (WTF-584): the "ours" side,
// with the same scripts/vertical_slice/render_capture.js the Bubble side uses, at the same
// widths, signed in as the same user. Uses the pinned Playwright of the fidelity gates
// (test/support/fidelity, `npm ci` there first).
//
//   CAPTURE_EMAIL=<user's email> node scripts/vertical_slice/capture_ours.mjs \
//     --base http://127.0.0.1:4422 --out <private dir> 'NAME|/path|1280,900,500' ...
//
// Each spec is a capture name, the page's path (with its thing ID or query, as on the Bubble
// side) and its widths; it writes <out>/<NAME>-<width>.json and .png (0600, <out> created
// 0700). The page loads once per spec at 1280 px and is then resized to each width (as the
// Bubble capture is), settling each time on network idle plus 3 s without DOM mutations, then
// captured again (2 s later, settled) until two captures agree. It exits 1 when a capture is
// not to be trusted (never settled or stable, an error status, redirected elsewhere), after
// writing it. An existing <out> must already be private (no group or other access).
//
// CAPTURE_EMAIL (read from the environment, never printed or written): the user to sign in
// as with a magic link from the server's local mailbox (/dev/mailbox, dev only); unset, the
// pages are captured signed out. The generated sender drops a request within a minute of an
// earlier one for the same email, so with no new link after 61 s it asks once more.
//
// Only the server at --base (127.0.0.1) is contacted: no other host resolves and every other
// origin is aborted, so webfonts and images from other hosts do not load (their boxes may
// differ from Bubble's). Capture the app in dev with its dev markers on, so the capture holds
// each marker's reason. The captures hold the pages' texts: keep <out> private.
import { chromium } from "../../test/support/fidelity/node_modules/playwright/index.mjs";
import fs from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);
const opts = {};
const specs = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith("--")) opts[argv[i].slice(2)] = argv[++i];
  else specs.push(argv[i]);
}

const usage = "usage: CAPTURE_EMAIL=... capture_ours.mjs --base http://127.0.0.1:PORT --out DIR 'NAME|/path|W1,W2' ...";
if (!opts.base || !opts.out || specs.length === 0) {
  console.error(usage);
  process.exit(2);
}

const base = new URL(opts.base);
if (base.hostname !== "127.0.0.1" || !["http:", "https:"].includes(base.protocol)) {
  console.error("--base must be an http(s) server on 127.0.0.1");
  process.exit(2);
}

const parsed = specs.map((spec) => {
  const [name, pagePath, widths] = spec.split("|");
  const ws = (widths || "").split(",").map(Number);
  if (!/^[\w.-]+$/.test(name || "") || !(pagePath || "").startsWith("/") || ws.some((w) => !(w >= 200 && w <= 4000))) {
    console.error(`bad spec ${JSON.stringify(spec)}: NAME|/path|W1,W2 (a file-safe name, widths 200-4000)\n${usage}`);
    process.exit(2);
  }
  return { name, pagePath, widths: ws };
});

const email = process.env.CAPTURE_EMAIL || null;
const out = opts.out;
// A directory the script creates is 0700; an existing one must already be private.
if (fs.existsSync(out)) {
  const st = fs.statSync(out);
  if (!st.isDirectory() || (st.mode & 0o077) !== 0) {
    console.error(`--out ${out} must be a private (0700) directory`);
    process.exit(2);
  }
} else {
  fs.mkdirSync(out, { recursive: true, mode: 0o700 });
  fs.chmodSync(out, 0o700);
}
const capture = fs.readFileSync(new URL("./render_capture.js", import.meta.url), "utf8");

const writePrivate = (file, data) => {
  fs.writeFileSync(file, "", { mode: 0o600 });
  fs.chmodSync(file, 0o600);
  fs.writeFileSync(file, data);
};

const browser = await chromium.launch({ args: ["--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"] });
let failed = false;
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, serviceWorkers: "block" });
  await context.route("**/*", (route) => {
    const url = new URL(route.request().url());
    return url.origin === base.origin || url.protocol === "data:" ? route.continue() : route.abort();
  });
  await context.routeWebSocket(/.*/, (ws) =>
    new URL(ws.url()).host === base.host ? ws.connectToServer() : ws.close({ code: 1008, reason: "blocked" }),
  );
  // The time of the last DOM mutation, for settling.
  await context.addInitScript(() => {
    window.__captureMutated = performance.now();
    const watch = () =>
      new MutationObserver(() => { window.__captureMutated = performance.now(); }).observe(document.documentElement, {
        subtree: true, childList: true, characterData: true, attributes: true,
      });
    if (document.documentElement) watch(); else document.addEventListener("DOMContentLoaded", watch);
  });

  const page = await context.newPage();
  const connected = () =>
    page.waitForSelector("[data-phx-main].phx-connected, [data-phx-session].phx-connected", { timeout: 15_000 }).catch(() => {});
  const settle = async (max = 30_000) => {
    const t0 = Date.now();
    await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});
    while (Date.now() - t0 < max) {
      if ((await page.evaluate(() => performance.now() - window.__captureMutated)) >= 3000) return Date.now() - t0;
      await page.waitForTimeout(500);
    }
    return null;
  };

  if (email) await signIn(page, context, connected);

  for (const { name, pagePath, widths } of parsed) {
    await page.setViewportSize({ width: 1280, height: 900 });
    const response = await page.goto(new URL(pagePath, base).href, { timeout: 20_000 });
    await connected();
    for (const w of widths) {
      await page.setViewportSize({ width: w, height: 900 });
      await page.waitForTimeout(1500);
      // Settled, then captured again until two captures agree: data that lands after a quiet
      // spell (a slow first load) changes the second.
      // They agree when the same elements show the same texts (boxes may move by subpixels).
      const shape = (j) => JSON.stringify(JSON.parse(j).elements.map((e) => [e.id, e.visible, e.text]));
      const t0 = Date.now();
      let quiet = (await settle()) !== null;
      let json = await page.evaluate(capture);
      let stable = false;
      for (let tries = 0; tries < 5 && !stable; tries++) {
        await page.waitForTimeout(2000);
        quiet = (await settle()) !== null;
        const again = await page.evaluate(capture);
        stable = quiet && shape(again) === shape(json);
        json = again;
      }
      const settled = Date.now() - t0;
      // A capture to distrust: never quiet or never stable, an error status, or another page
      // (a redirect, e.g. to the sign-in page). It is written, and the run fails.
      const status = response && response.status();
      const landed = new URL(page.url()).pathname;
      const problems = [
        !stable && "UNSTABLE",
        !(status >= 200 && status < 400) && `status ${status}`,
        landed !== new URL(pagePath, base).pathname && "redirected",
      ].filter(Boolean);
      if (problems.length) failed = true;
      writePrivate(path.join(out, `${name}-${w}.json`), json);
      const png = await page.screenshot({ fullPage: true });
      writePrivate(path.join(out, `${name}-${w}.png`), png);
      const d = JSON.parse(json);
      console.log(
        [name, w, "status", status, "settled_ms", settled, problems.length ? problems.join(",") : "stable",
          "elements", d.elements.length, "visible", d.elements.filter((e) => e.visible).length].join(" "),
      );
    }
  }
} catch (error) {
  // Never the email or the magic link's token (a navigation timeout names the URL).
  console.error(
    String(error && error.message ? error.message : error)
      .replaceAll(email || "\u0000", "<email>")
      .replace(/magic_link[^\s"'<]*/g, "magic_link<redacted>"),
  );
  failed = true;
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);

// A magic-link sign-in from the local mailbox: only a message that arrives after the request
// and names the email counts (an earlier one holds a spent link).
async function signIn(page, context, connected) {
  const mailboxIds = async () => {
    const html = await (await context.request.get(new URL("/dev/mailbox", base).href)).text();
    return [...html.matchAll(/href="\/dev\/mailbox\/([0-9a-f]{32})"/g)].map((m) => m[1]);
  };
  const checked = new Set(await mailboxIds());
  const requestLink = async () => {
    await page.goto(new URL("/sign-in", base).href);
    await connected();
    await page.waitForTimeout(500);
    await page.locator('input[type="email"], input[name$="[email]"]').first().fill(email);
    await page.locator('form[action$="/magic_link/request"] button').first().click();
  };
  const RETRY_AFTER_MS = 61_000;
  const started = Date.now();
  let requests = 1;
  await requestLink();
  let link = null;
  while (!link && Date.now() - started < RETRY_AFTER_MS + 45_000) {
    if (requests === 1 && Date.now() - started >= RETRY_AFTER_MS) {
      await requestLink();
      requests++;
    }
    await page.waitForTimeout(1000);
    for (const id of await mailboxIds()) {
      if (checked.has(id)) continue;
      checked.add(id);
      const html = await (await context.request.get(new URL(`/dev/mailbox/${id}`, base).href)).text();
      if (!html.includes(email)) continue;
      const m = html.match(/https?:\/\/[^"'\s<]+magic_link[^"'\s<]*/);
      if (m) { link = m[0].replace(/&amp;/g, "&"); break; }
    }
  }
  if (!link) throw new Error(`no new magic link in the local mailbox after ${requests} request(s)`);
  const u = new URL(link);
  await page.goto(new URL(u.pathname + u.search, base).href);
  await page.waitForTimeout(1500);
  // AshAuthentication may ask to confirm the sign-in.
  const confirm = page.locator('form[action*="magic_link"] button').first();
  if (await confirm.count()) {
    await Promise.all([page.waitForURL((x) => !x.pathname.includes("magic_link"), { timeout: 10_000 }), confirm.click()]);
  }
  if (new URL(page.url()).pathname.includes("sign-in")) throw new Error("the magic link did not sign in");
  console.log("signed in");
}
