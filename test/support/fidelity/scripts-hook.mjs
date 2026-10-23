// The page's scripts hook (WTF-608): the generated `.BubbleScripts` hook (HOOK.mjs,
// extracted from the rendered `<Web>.BubbleScripts` by
// test/bubble_ex/target/phoenix/scripts_test.exs) in Node, with LiveView stubbed:
// `pushEvent` records (and answers `bubble:publishers` as the page would), the
// element's `bubble:script` event runs a script as the runtime's `exec` sends it.
//
// usage: node scripts-hook.mjs HOOK.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

globalThis.window = globalThis;
const shown = { closest: () => null, getClientRects: () => [{}] };
const hidden = { closest: () => ({}), getClientRects: () => [{}] };
const undisplayed = { closest: () => null, getClientRects: () => [] };
globalThis.document = {
  body: { dataset: {} },
  querySelectorAll: (selector) => (selector.includes("bHtml") ? [shown, hidden, undisplayed] : [])
};
globalThis.CSS = { escape: (s) => s };
globalThis.MutationObserver = class {
  constructor(fn) { this.fn = fn; }
  observe() {}
  disconnect() {}
};
globalThis.requestAnimationFrame = (fn) => fn();

const source = fs.readFileSync(process.argv[2], "utf8");
const module = path.join(path.dirname(process.argv[2]), "hook-module.mjs");
fs.writeFileSync(module, source);
const { default: hook } = await import(module);

const pushed = [];
const listeners = {};
const el = { addEventListener: (name, fn) => (listeners[name] = fn) };

const ctx = Object.assign(Object.create(hook), {
  el,
  pushEvent(event, payload, reply) {
    pushed.push([event, payload]);
    if (event === "bubble:publishers")
      reply({
        publishers: [
          { scope: "", element: "bPub", suffix: "picked" },
          { scope: "", element: "bBad", suffix: "x];alert(1);//" }
        ]
      });
  }
});

ctx.mounted();
assert.equal(typeof window.bubble_fn_picked, "function");
// The HTML element's script ran for the shown element only, once.
assert.equal(document.body.dataset.html, "shown");
document.body.dataset.html = "again";
ctx.shown();
assert.equal(document.body.dataset.html, "again");
assert.equal(Object.keys(window).filter((k) => k.startsWith("bubble_fn_x")).length, 0);

// The script runs with its input, writes the page and publishes.
listeners["bubble:script"]({ detail: { op: "script", key: "aJs", params: { param1: "blue", other: "x" } } });
assert.equal(document.body.dataset.picked, "blue");
assert.deepEqual(pushed.at(-1), ["bubble:publish", { scope: "", element: "bPub", value: "blue" }]);

// A published value is data: things by ID, dates as ms, objects dropped, outputs kept.
window.bubble_fn_picked(new Date(5));
assert.deepEqual(pushed.at(-1)[1], { scope: "", element: "bPub", value: { date: 5 } });
window.bubble_fn_picked({ toString: () => "x" });
assert.deepEqual(pushed.at(-1)[1], { scope: "", element: "bPub", outputs: {} });
window.bubble_fn_picked({ output1: "a", output9: "b", outputlist1: [1, { a: 1 }] });
assert.deepEqual(pushed.at(-1)[1], {
  scope: "",
  element: "bPub",
  outputs: { output1: "a", outputlist1: [1, null] }
});

// An unknown key runs nothing; a throwing script is logged, not raised.
const before = pushed.length;
listeners["bubble:script"]({ detail: { key: "__proto__", params: {} } });
listeners["bubble:script"]({ detail: { key: "nope", params: {} } });
assert.equal(pushed.length, before);

console.log("PASS scripts hook");
