// Opened-overlay fidelity for bptvorpv (WTF-407). The exported page is
// static: a runtime shows a Popup or Group Focus by removing its `hidden`
// attribute. This check does exactly that in the pinned browser and compares
// the overlay and content geometry with the committed source observation
// (source/runtime/observation.json), captured from the authorized Bubble
// branch; it never contacts Bubble.
//
// usage: node overlay-states.mjs CASE_DIR CANDIDATE.html
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { chromium } from "playwright";

const [caseDir, htmlPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(path.join(caseDir, "case.json"), "utf8"));
const observation = JSON.parse(
  fs.readFileSync(path.join(caseDir, "source", "runtime", "observation.json"), "utf8")
);
assert.equal(observation.sourcePayloadSha256, manifest.source.payload_sha256);

// Which overlay a runtime reveals for each observed state, and the nodes compared.
const states = {
  initial: { show: null, ids: ["bptvorpw", "bptvorqc", "bptvorpx", "bptvorqd"] },
  "popup-open": { show: "bptvorpw", ids: ["bptvorpw", "bptvorpx", "bptvorpy", "bptvorqc"] },
  "popup-closed": { show: null, ids: ["bptvorpw", "bptvorpx", "bptvorpy"] },
  "focus-open": { show: "bptvorqc", ids: ["bptvorqc", "bptvorqd", "bptvorpw"] },
  "focus-dismissed": { show: null, ids: ["bptvorqc", "bptvorqd"] },
};

const browser = await chromium.launch({ headless: true });
assert.equal(browser.version(), manifest.browser.chromium);
const mismatches = [];
let samples = 0;

try {
  for (const width of manifest.viewports) {
    const page = await browser.newPage({
      viewport: { width, height: manifest.browser.viewport_height },
      deviceScaleFactor: manifest.browser.dpr || 1,
      locale: manifest.browser.locale || "en-US",
      reducedMotion: "reduce",
    });
    await page.goto(pathToFileURL(path.resolve(htmlPath)).href);
    await page.evaluate(async () => { await document.fonts.ready; });

    for (const result of observation.results.filter((r) => r.width === width)) {
      const state = states[result.state];
      assert(state, `unknown observed state ${result.state}`);
      const candidate = await page.evaluate(({ show, ids }) => {
        for (const overlay of document.querySelectorAll("[data-overlay]")) overlay.hidden = true;
        if (show) document.querySelector(`[data-bubble-id="${show}"]`).hidden = false;
        return Object.fromEntries(ids.map((id) => {
          const matches = document.querySelectorAll(`[data-bubble-id="${id}"]`);
          if (matches.length !== 1) return [id, { matchCount: matches.length }];
          const { x, y, width, height } = matches[0].getBoundingClientRect();
          return [id, { x, y, width, height, position: getComputedStyle(matches[0]).position }];
        }));
      }, state);

      for (const id of state.ids) {
        const reference = result.elements[id];
        const actual = candidate[id];
        samples += 1;
        if (actual.matchCount !== undefined) {
          mismatches.push({ width, state: result.state, id, detail: actual });
          continue;
        }
        const expected = reference.absent
          ? { x: 0, y: 0, width: 0, height: 0 }
          : reference.box;
        const errors = Object.fromEntries(
          ["x", "y", "width", "height"].map((k) => [k, actual[k] - expected[k]])
        );
        const hiddenOk = reference.absent || reference.display === "none"
          ? actual.width === 0 && actual.height === 0
          : null;
        const exact = hiddenOk ?? Object.values(errors).every((e) => e === 0);
        const positioned = reference.absent || reference.display === "none" ||
          reference.position === actual.position || !["fixed", "absolute"].includes(reference.position);
        if (!exact || !positioned) {
          mismatches.push({ width, state: result.state, id, errors, reference: reference.position, candidate: actual.position });
        }
      }
    }
    await page.close();
  }
} finally {
  await browser.close();
}

if (mismatches.length) {
  console.error(JSON.stringify(mismatches, null, 2));
  process.exit(1);
}
console.log(`PASS bptvorpv overlay states: ${samples} samples across ${manifest.viewports.length} viewports`);
