// The page hook's "Animate an element" (WTF-603), in the pinned browser: the generated
// `.BubbleRuntime` hook (HOOK.js, extracted from the rendered `<Web>.Bubble` by
// test/bubble_ex/target/phoenix/animate_hook_test.exs) on a synthetic page with the
// attributes the pages render. LiveView itself is stubbed as in popup-events.mjs:
// `pushEvent` records, `js()` sets attributes.
//
// usage: node animate-hook.mjs HOOK.js
import assert from "node:assert/strict";
import fs from "node:fs";
import { chromium } from "playwright";

const hook = fs.readFileSync(process.argv[2], "utf8").replace("export default {", "window.__hook = {");
const box = 'style="width: 100px; height: 40px"';

const html = `<!doctype html><body>
  <div data-bubble-id="G" ${box}>shown</div>
  <div data-bubble-id="H" hidden ${box}>hidden</div>
  <div data-bubble-id="C" ${box}>cut short</div>
  <div data-bubble-id="E" ${box}>callout</div>
  <div data-overlay="popup" data-bubble-id="P" data-bubble-events="closed opened" hidden ${box}></div>
  <div data-overlay="popup" data-bubble-id="L" data-bubble-lazy hidden ${box}></div>
  <div id="bubble-runtime" hidden></div>
</body>`;

const fade = (visibility, duration) => ({
  visibility,
  motion: {
    duration,
    easing: "ease",
    frames: visibility === "show" ? [{ opacity: 0 }, { opacity: 1 }] : [{ opacity: 1 }, { opacity: 0 }]
  }
});

const slideIn = (duration) => ({
  visibility: "show",
  motion: {
    duration,
    easing: "ease",
    frames: [
      { opacity: 0, translate_x: 20 },
      { opacity: 1, translate_x: 0 }
    ]
  }
});

const shake = {
  visibility: null,
  motion: { duration: 400, easing: "ease", frames: [0, -11, 11, -11, 0].map((x) => ({ translate_x: x })) }
};

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
    window.__pushed = [];
    window.__handlers = {};
    // The page renders L's contents and replies after the render.
    h.pushEvent = (name, payload) => {
      window.__pushed.push([name, payload]);
      if (name !== "bubble:overlay") return;
      return new Promise((resolve) =>
        setTimeout(() => {
          const el = document.querySelector(`[data-bubble-id="${payload.element}"]`);
          if (payload.open) el.setAttribute("data-bubble-loaded", "");
          else el.removeAttribute("data-bubble-loaded");
          resolve({ open: payload.open });
        }, 50)
      );
    };
    h.handleEvent = (name, fn) => (window.__handlers[name] = fn);
    h.js = () => ({
      removeAttribute: (el, a) => el.removeAttribute(a),
      setAttribute: (el, a, v) => el.setAttribute(a, v)
    });
    h.liveSocket = { isConnected: () => true, js: () => ({ exec: () => {} }) };
    h.mounted();
  });

  const animate = (id, detail) =>
    page.evaluate(
      ([id, detail]) =>
        document
          .querySelector(`[data-bubble-id="${id}"]`)
          .dispatchEvent(new CustomEvent("bubble:animate", { bubbles: true, detail })),
      [id, detail]
    );

  const step = (id, event) =>
    page.evaluate(
      ([id, event]) =>
        document.querySelector(`[data-bubble-id="${id}"]`).dispatchEvent(new CustomEvent(event, { bubbles: true })),
      [id, event]
    );

  const state = (id) =>
    page.evaluate((id) => {
      const el = document.querySelector(`[data-bubble-id="${id}"]`);
      return {
        hidden: el.hidden,
        running: el.getAnimations().length,
        opacity: Number(getComputedStyle(el).opacity),
        transform: getComputedStyle(el).transform
      };
    }, id);

  const take = () => page.evaluate(() => window.__pushed.splice(0));
  const report = (element, event) => ["bubble:popup", { scope: "", element, event }];

  // An exit: shown while it runs, hidden once it ends, its motion gone.
  await animate("G", fade("hide", 300));
  let s = await state("G");
  assert.equal(s.hidden, false, "an exit keeps it shown while it runs");
  assert.equal(s.running, 1, "an exit runs its motion");
  // Halfway through (paused there, not timed): faded part of the way.
  const half = await page.evaluate(() => {
    const el = document.querySelector('[data-bubble-id="G"]');
    const [a] = el.getAnimations();
    a.pause();
    a.currentTime = 150;
    const opacity = Number(getComputedStyle(el).opacity);
    a.play();
    return opacity;
  });
  assert.ok(half > 0 && half < 1, `an exit fades it (opacity ${half})`);
  await page.waitForTimeout(400);
  assert.deepEqual(await state("G"), { hidden: true, running: 0, opacity: 1, transform: "none" }, "an exit hides it once it ends");

  // An entrance: shown as it starts, with its motion; nothing left after.
  await animate("H", slideIn(300));
  s = await state("H");
  assert.equal(s.hidden, false, "an entrance shows it as it starts");
  assert.equal(s.running, 1, "an entrance runs its motion");
  assert.notEqual(s.transform, "none", "a slide moves it");
  await page.waitForTimeout(450);
  assert.deepEqual(await state("H"), { hidden: false, running: 0, opacity: 1, transform: "none" }, "an entrance ends shown, in place");

  // A later step on an element cuts its animation short: an exit stopped
  // by a show never hides it.
  await animate("C", fade("hide", 300));
  await page.waitForTimeout(50);
  await step("C", "bubble:show");
  await page.waitForTimeout(400);
  assert.deepEqual(await state("C"), { hidden: false, running: 0, opacity: 1, transform: "none" }, "a show stops an exit");
  await animate("C", fade("hide", 300));
  await page.waitForTimeout(50);
  await animate("C", fade("show", 100));
  await page.waitForTimeout(400);
  assert.equal((await state("C")).hidden, false, "an entrance stops an exit");

  // A toggle during an exit hides it at once, and the exit's end does
  // nothing more.
  await animate("C", fade("hide", 300));
  await page.waitForTimeout(50);
  await step("C", "bubble:toggle");
  assert.deepEqual(await state("C"), { hidden: true, running: 0, opacity: 1, transform: "none" }, "a toggle during an exit hides it");
  await page.waitForTimeout(400);
  assert.equal((await state("C")).hidden, true, "the exit cut short does not act later");
  await step("C", "bubble:show");

  // A callout only moves it.
  await animate("E", shake);
  s = await state("E");
  assert.equal(s.hidden, false);
  assert.equal(s.running, 1, "a callout runs its motion");
  await page.waitForTimeout(500);
  assert.deepEqual(await state("E"), { hidden: false, running: 0, opacity: 1, transform: "none" }, "a callout leaves it as it was");

  // A Popup: an entrance opens it (reported), an exit closes it once it
  // ends (reported then); an exit of a closed one runs nothing.
  await take();
  await animate("P", fade("show", 100));
  assert.deepEqual(await take(), [report("P", "opened")], "an entrance opens a popup");
  await animate("P", fade("hide", 200));
  assert.deepEqual(await take(), [], "not closed while its exit runs");
  await page.waitForTimeout(350);
  assert.deepEqual(await take(), [report("P", "closed")], "closed once its exit ends");
  assert.equal((await state("P")).hidden, true);
  await animate("P", fade("hide", 200));
  assert.deepEqual(
    await take(),
    [["bubble:popup", { scope: "", element: "P", event: "closed", skipped: true }]],
    "an exit of a closed popup runs nothing"
  );

  // A hide during a Popup's exit closes it once: the exit cut short reports
  // nothing that runs (skipped), the hide reports it closed.
  await animate("P", fade("show", 50));
  await page.waitForTimeout(100);
  await take();
  await animate("P", fade("hide", 300));
  await page.waitForTimeout(50);
  await step("P", "bubble:hide");
  await page.waitForTimeout(400);
  assert.deepEqual(
    await take(),
    [["bubble:popup", { scope: "", element: "P", event: "closed", skipped: true }], report("P", "closed")],
    "a hide during an exit: closed once"
  );

  // A show during its exit keeps it open; the exit's expected "is closed"
  // is forgotten (skipped).
  await animate("P", fade("show", 50));
  await page.waitForTimeout(100);
  await take();
  await animate("P", fade("hide", 300));
  await page.waitForTimeout(50);
  await step("P", "bubble:show");
  await page.waitForTimeout(400);
  assert.deepEqual(
    await take(),
    [
      ["bubble:popup", { scope: "", element: "P", event: "closed", skipped: true }],
      ["bubble:popup", { scope: "", element: "P", event: "opened", skipped: true }]
    ],
    "a show during an exit: still open"
  );
  assert.equal((await state("P")).hidden, false);
  await step("P", "bubble:hide");
  await take();

  // From a server-side workflow (`bubble:exec`).
  await page.evaluate((detail) =>
    window.__handlers["bubble:exec"]({ ops: [{ op: "animate", to: '[data-bubble-id="G"]', ...detail }] }),
    fade("show", 100)
  );
  assert.equal((await state("G")).hidden, false, "a server-side entrance shows it");
  await page.waitForTimeout(200);

  // A popup rendered only while open: asked for first, opened once its
  // contents are rendered, then its motion runs.
  await take();
  await animate("L", fade("show", 300));
  assert.deepEqual(await take(), [["bubble:overlay", { scope: "", element: "L", open: true }]], "a lazy popup asks for its contents");
  assert.equal((await state("L")).hidden, true, "closed until they are rendered");
  await page.waitForTimeout(120);
  s = await state("L");
  assert.equal(s.hidden, false, "then open");
  assert.equal(s.running, 1, "with its entrance's motion");
  await page.waitForTimeout(400);

  // Its exit drops its contents only once the motion ended.
  await animate("L", fade("hide", 300));
  await page.waitForTimeout(100);
  assert.deepEqual(await take(), [], "nothing asked while its exit runs");
  await page.waitForTimeout(400);
  assert.deepEqual(await take(), [["bubble:overlay", { scope: "", element: "L", open: false }]], "closed once its exit ends");
  assert.equal((await state("L")).hidden, true);

  assert.deepEqual(errors, [], "no page errors");
  console.log("PASS animate hook");
} finally {
  await browser.close();
}
