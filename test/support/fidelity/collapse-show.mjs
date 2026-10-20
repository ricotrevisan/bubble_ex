// Elements hidden on page load that collapse when hidden show once shown, in
// the pinned browser (the a361e4e regression: a static `hidden` class kept them hidden
// whatever their conditionals or a step did). The generated `.BubbleRuntime`
// hook (HOOK.js) on PAGE.html: the elements' opening tags as the page renders
// them, with Tailwind's display utilities and bubble.css's `[hidden]` rule
// (test/bubble_ex/target/phoenix/visibility_test.exs writes both). LiveView
// is stubbed as in popup-events.mjs.
//
// usage: node collapse-show.mjs HOOK.js PAGE.html
import assert from "node:assert/strict";
import fs from "node:fs";
import { chromium } from "playwright";

const hook = fs.readFileSync(process.argv[2], "utf8").replace("export default {", "window.__hook = {");
const html = fs.readFileSync(process.argv[3], "utf8");

const browser = await chromium.launch({ headless: true });

try {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.setContent(html);
  await page.addScriptTag({ content: hook });

  await page.evaluate(() => {
    const h = Object.create(window.__hook);
    h.el = document.getElementById("bubble-runtime");
    h.pushEvent = () => {};
    h.handleEvent = () => {};
    h.js = () => ({
      removeAttribute: (el, a) => el.removeAttribute(a),
      setAttribute: (el, a, v) => el.setAttribute(a, v)
    });
    h.liveSocket = { isConnected: () => true, js: () => ({ exec: () => {} }) };
    h.mounted();
  });

  // Shown: laid out, not invisible, its text read.
  const shown = (id) =>
    page.evaluate((id) => {
      const el = document.querySelector(`[data-bubble-id="${id}"]`);
      return (
        el.getClientRects().length > 0 &&
        getComputedStyle(el).visibility !== "hidden" &&
        el.innerText.trim() !== ""
      );
    }, id);

  for (const id of ["bCollOut", "bCollWf"]) assert.equal(await shown(id), false, `${id} hidden on page load`);

  // Server-evaluated: the render that makes its condition true drops the attribute.
  await page.evaluate(() => document.querySelector('[data-bubble-id="bCollOut"]').removeAttribute("hidden"));
  assert.equal(await shown("bCollOut"), true, "its condition shows bCollOut");

  // A workflow's Show step, through the hook.
  await page.evaluate(() =>
    document
      .querySelector('[data-bubble-id="bCollWf"]')
      .dispatchEvent(new CustomEvent("bubble:show", { bubbles: true }))
  );
  assert.equal(await shown("bCollWf"), true, "a step shows bCollWf");

  assert.deepEqual(errors, [], "no page errors");
  console.log("PASS collapse-when-hidden shows");
} finally {
  await browser.close();
}
