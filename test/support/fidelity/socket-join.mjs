// A slow LiveView join keeps its websocket (WTF-554), in the pinned browser: the
// generated assets/js/app.js (APP.js, its imports stubbed) on Phoenix's own client
// (PHOENIX.mjs), against a fake server that works like Phoenix.Socket: it handles
// the frames of a connection in order, and a channel join blocks the connection
// until the LiveView has mounted, loaded its data and rendered (Phoenix.Channel.Server.join/4),
// so the heartbeat sent after the join is answered only then.
//
// A join slower than a LongPoll fallback threshold made the client close the
// websocket and fall back (`longPollFallbackMs`), the page showing the error
// state. The control run (the threshold the generator used to set) must still do
// that, or the harness no longer reproduces it.
//
// usage: node socket-join.mjs PHOENIX.mjs APP.js
import assert from "node:assert/strict";
import fs from "node:fs";
import { chromium } from "playwright";

const phoenix = fs.readFileSync(process.argv[2], "utf8");
const app = fs.readFileSync(process.argv[3], "utf8");
const JOIN_MS = 3000;
const WATCH_MS = JOIN_MS + 3000;

// The generated app.js with its imports replaced: `LiveSocket` builds Phoenix's
// Socket with the options as LiveView does (and a logger), then joins one
// LiveView channel, as a page with one LiveView does on connect.
const appBody = app
  .split("\n")
  .filter((line) => !/^import\b/.test(line))
  .join("\n");

const stubs = `
import {Socket} from "/phoenix.mjs"
const colocatedHooks = {}
class LiveSocket {
  constructor(url, phxSocket, opts) {
    window.__opts = opts
    this.socket = new phxSocket(url, {...opts, logger: (kind, msg) => window.__log.push(kind + ": " + msg)})
  }
  connect() {
    this.socket.connect()
    this.socket.channel("lv:phx-page", {}).join().receive("ok", () => (window.__joined = performance.now()))
  }
}
`;

const fakeServer = `
window.__log = []; window.__opened = 0; window.__closed = 0
class FakeWebSocket {
  constructor(url) {
    this.url = url; this.readyState = 0; this.bufferedAmount = 0; this.binaryType = "arraybuffer"
    this.queue = Promise.resolve()
    window.__opened++
    setTimeout(() => { this.readyState = 1; this.onopen && this.onopen({}) }, 10)
  }
  send(data) {
    const [joinRef, ref, topic, event] = JSON.parse(data)
    const delay = event === "phx_join" ? ${JOIN_MS} : 0
    this.queue = this.queue.then(() => new Promise((done) => setTimeout(() => {
      if (this.readyState === 1)
        this.onmessage({data: JSON.stringify([joinRef, ref, topic, "phx_reply", {status: "ok", response: {}}])})
      done()
    }, delay)))
  }
  close(code, reason) {
    if (this.readyState >= 2) return
    this.readyState = 3; window.__closed++
    setTimeout(() => this.onclose && this.onclose({code: code || 1000, reason: reason || "", wasClean: true}), 0)
  }
}
Object.assign(FakeWebSocket, {CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3})
window.WebSocket = FakeWebSocket
`;

const page_html = (script) => `<!doctype html><html><head>
<meta name="csrf-token" content="test-token">
<script>${fakeServer}</script>
<script type="module">${stubs}\n${script}</script>
</head><body></body></html>`;

const browser = await chromium.launch({ headless: true });

async function run(script) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.route("http://socket.test/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/phoenix.mjs") return route.fulfill({ contentType: "text/javascript", body: phoenix });
    if (path === "/") return route.fulfill({ contentType: "text/html", body: page_html(script) });
    return route.fulfill({ status: 404, body: "" });
  });
  await page.goto("http://socket.test/");
  await page.waitForTimeout(WATCH_MS);
  const result = await page.evaluate(() => ({
    log: window.__log,
    opened: window.__opened,
    closed: window.__closed,
    joined: window.__joined != null,
    fellBack: window.__log.some((l) => l.includes("falling back")),
    memorized: sessionStorage.getItem("phx:fallback:LongPoll"),
  }));
  await page.close();
  assert.deepEqual(errors, []);
  return result;
}

try {
  // The control: the threshold the generator used to set drops the websocket.
  const control = await run(appBody.replace("new LiveSocket(\"/live\", Socket, {", "new LiveSocket(\"/live\", Socket, {\n  longPollFallbackMs: 2500,"));
  assert.ok(control.fellBack, "control: expected a LongPoll fallback, got " + JSON.stringify(control));
  assert.ok(control.closed >= 1, "control: expected the websocket closed");
  console.log("PASS control: a 2.5 s fallback threshold drops the websocket of a 3 s join");

  // The generated app.js: the websocket stays open through the slow join.
  const generated = await run(appBody);
  assert.equal(generated.fellBack, false, JSON.stringify(generated));
  assert.equal(generated.closed, 0, JSON.stringify(generated));
  assert.equal(generated.opened, 1, JSON.stringify(generated));
  assert.equal(generated.joined, true, JSON.stringify(generated));
  assert.equal(generated.memorized, null, JSON.stringify(generated));
  console.log("PASS generated: a 3 s join keeps its websocket");
} finally {
  await browser.close();
}
