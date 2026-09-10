// Authorized source experiment; this is not exported application behavior.
// Run in the same pinned Linux browser as run.mjs. Credentials stay in env.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";

const caseDir = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(path.join(caseDir, "case.json")));
const url = `https://${manifest.source.bubble_id}.bubbleapps.io/version-${manifest.source.app_version}/${manifest.source.page_path}`;
assert.equal(process.env.BUBBLE_RECAPTURE, "1");
assert.equal(manifest.id, "bptvorpv");
assert.equal(process.platform, manifest.browser.platform);
assert.equal(process.arch, manifest.browser.arch);

const ids = [...manifest.node_ids, "bptvorpx", "bptvorpy", "bptvorqd"];
const browser = await chromium.launch({ headless: true });
assert.equal(browser.version(), manifest.browser.chromium);
const results = [];
const out = path.join(caseDir, "source", "runtime");
fs.mkdirSync(out, { recursive: true });

try {
  for (const width of manifest.viewports) {
    const page = await browser.newPage({
      viewport: { width, height: manifest.browser.viewport_height },
      deviceScaleFactor: 1, locale: "en-US", reducedMotion: "reduce",
      httpCredentials: { username: process.env.BUBBLE_CAPTURE_USERNAME,
        password: process.env.BUBBLE_CAPTURE_PASSWORD, origin: new URL(url).origin },
    });
    await page.goto(url);
    await page.waitForSelector(".bubble-element.Page");
    await page.waitForLoadState("networkidle");
    const node = (id) => page.locator(`.bubble-element.${id}`);
    const visible = (id) => node(id).isVisible();
    const record = async (state) => {
      await page.waitForFunction(() => !document.querySelector(".velocity-animating"));
      await page.evaluate(async () => { await document.fonts.ready; });
      const elements = await page.evaluate((ids) => Object.fromEntries(ids.map((id) => {
        const matches = document.querySelectorAll(`.bubble-element.${id}`);
        const element = matches.length === 1 ? matches[0] : null;
        if (!element) return [id, { matchCount: matches.length, absent: true }];
        const style = getComputedStyle(element);
        const box = element.getBoundingClientRect().toJSON();
        return [id, { matchCount: 1, box, display: style.display, position: style.position,
          visibility: style.visibility, outerHTML: element.outerHTML }];
      })), ids);
      const screenshot = `${width}-${state}.png`;
      await page.screenshot({ path: path.join(out, screenshot), fullPage: true });
      results.push({ width, state, elements, screenshot });
    };
    assert.equal(await visible("bptvorpw"), false);
    assert.equal(await visible("bptvorqc"), false);
    await record("initial");
    await node("bptvorqa").click();
    await node("bptvorpy").waitFor({ state: "visible" });
    await record("popup-open");
    await node("bptvorpy").click();
    await node("bptvorpw").waitFor({ state: "hidden" });
    await record("popup-closed");
    await node("bptvorqb").click();
    await node("bptvorqd").waitFor({ state: "visible" });
    await record("focus-open");
    await node("bptvorpz").click();
    await node("bptvorqc").waitFor({ state: "hidden" });
    await record("focus-dismissed");
    await page.close();
  }
  fs.writeFileSync(path.join(out, "observation.json"), JSON.stringify({
    url, chromium: browser.version(), platform: process.platform, arch: process.arch,
    sourcePayloadSha256: manifest.source.payload_sha256,
    scope: "source characterization only; exported workflows are not executed", results,
  }, null, 2) + "\n");
} finally {
  await browser.close();
}
