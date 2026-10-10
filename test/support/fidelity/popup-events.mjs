// The page hook's popup and page-width reports (WTF-520), in the pinned browser: the
// generated `.BubbleRuntime` hook (HOOK.js, extracted from the rendered
// `<Web>.Bubble` by test/bubble_ex/target/phoenix/popup_hook_test.exs) on a
// synthetic page with the attributes the pages render. LiveView itself is
// stubbed: `pushEvent` records, `js()` sets attributes, `exec` dispatches.
//
// usage: node popup-events.mjs HOOK.js
import assert from "node:assert/strict";
import fs from "node:fs";
import { chromium } from "playwright";

const hook = fs.readFileSync(process.argv[2], "utf8").replace("export default {", "window.__hook = {");
const escape = JSON.stringify([["dispatch", { event: "bubble:hide" }]]).replace(/"/g, "&quot;");
const box = 'style="width: 100px; height: 40px"';

const html = `<!doctype html><body>
  <div data-overlay="popup" data-bubble-id="P" data-bubble-events="closed opened"
       data-bubble-escape="${escape}" role="dialog" aria-modal="true" hidden ${box}><button>Ok</button></div>
  <div data-bubble-scope="inst1"><div data-overlay="popup" data-bubble-id="Q" data-bubble-events="opened" hidden ${box}></div></div>
  <div data-overlay="popup" data-bubble-id="R" hidden ${box}></div>
  <div id="bubble-runtime" data-bubble-reads-width hidden></div>
</body>`;

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
    window.__connected = true;
    window.__pushed = [];
    window.__handlers = {};
    h.pushEvent = (name, payload) => window.__pushed.push([name, payload]);
    h.handleEvent = (name, fn) => (window.__handlers[name] = fn);
    h.js = () => ({
      removeAttribute: (el, a) => el.removeAttribute(a),
      setAttribute: (el, a, v) => el.setAttribute(a, v)
    });
    h.liveSocket = {
      isConnected: () => window.__connected,
      js: () => ({
        exec: (el, cmd) =>
          JSON.parse(cmd).forEach(([kind, o]) => {
            if (kind === "dispatch") el.dispatchEvent(new CustomEvent(o.event, { bubbles: true }));
          })
      })
    };
    h.mounted();
    window.__h = h;
  });

  const step = (id, event) =>
    page.evaluate(
      ([id, event]) =>
        document.querySelector(`[data-bubble-id="${id}"]`).dispatchEvent(new CustomEvent(event, { bubbles: true })),
      [id, event]
    );

  const take = () => page.evaluate(() => window.__pushed.splice(0));
  const report = (scope, element, event) => ["bubble:popup", { scope, element, event }];

  // The viewport's width (WTF-520): reported once mounted.
  const width = (w) => ["bubble:page_width", { width: w }];
  assert.deepEqual(await take(), [width(page.viewportSize().width)], "the width once mounted");

  await step("P", "bubble:show");
  assert.deepEqual(await take(), [report("", "P", "opened")], "a step opens it");
  await step("P", "bubble:show");
  assert.deepEqual(await take(), [], "showing an open popup reports nothing");

  await page.keyboard.press("Escape");
  assert.deepEqual(await take(), [report("", "P", "closed")], "Escape closes it");
  await step("P", "bubble:hide");
  assert.deepEqual(await take(), [], "hiding a closed popup reports nothing");

  await step("P", "bubble:toggle");
  await step("P", "bubble:toggle");
  assert.deepEqual(await take(), [report("", "P", "opened"), report("", "P", "closed")], "toggle");

  await step("Q", "bubble:show");
  await step("Q", "bubble:hide");
  assert.deepEqual(await take(), [report("inst1", "Q", "opened")], "the instance's scope; closed not listed");

  await step("R", "bubble:show");
  assert.deepEqual(await take(), [], "a popup with no listed events reports nothing");

  await page.evaluate(() =>
    window.__handlers["bubble:exec"]({ ops: [{ op: "show", to: '[data-bubble-id="P"]' }] })
  );
  assert.deepEqual(await take(), [report("", "P", "opened")], "a server-side step's show");

  // A resize reports the new width once, after its debounce; the same
  // width again reports nothing.
  await page.setViewportSize({ width: 700, height: 600 });
  await page.waitForTimeout(400);
  assert.deepEqual(await take(), [width(700)], "a resize reports the new width");
  await page.evaluate(() => window.dispatchEvent(new Event("resize")));
  await page.waitForTimeout(400);
  assert.deepEqual(await take(), [], "an unchanged width reports nothing");

  // Disconnected: nothing is sent; a reconnect reports the width again
  // (the server mounted afresh).
  await page.evaluate(() => (window.__connected = false));
  await page.setViewportSize({ width: 650, height: 600 });
  await page.waitForTimeout(400);
  assert.deepEqual(await take(), [], "nothing is sent while disconnected");
  await page.evaluate(() => {
    window.__connected = true;
    window.__h.reconnected();
  });
  assert.deepEqual(await take(), [width(650)], "a reconnect reports again");

  // A page that does not read the width never reports it.
  await page.evaluate(() => {
    window.__h.el.removeAttribute("data-bubble-reads-width");
    window.__h.reconnected();
  });
  await page.setViewportSize({ width: 900, height: 600 });
  await page.waitForTimeout(400);
  assert.deepEqual(await take(), [], "a page not reading the width reports nothing");

  assert.deepEqual(errors, []);
  console.log("PASS popup reports: steps, Escape, toggle, open twice, instance scope, server steps, page width (mount, resize, reconnect, off)");
} finally {
  await browser.close();
}
