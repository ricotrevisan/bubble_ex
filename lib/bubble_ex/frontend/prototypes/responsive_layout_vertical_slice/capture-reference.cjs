// Private-credential reference capture; committed outputs contain only the controlled page and sanitized URL.
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");
const { sourceNodeIds, viewports, viewportHeight, browserInspectScript } = require("./evidence-contract.cjs");

const username = process.env.BUBBLE_BASIC_USER;
const password = process.env.BUBBLE_BASIC_PASSWORD;
if (!username || !password) throw new Error("Set BUBBLE_BASIC_USER and BUBBLE_BASIC_PASSWORD");

const referenceUrl = "https://tiptap-plugin.bubbleapps.io/version-test/bubbleex-i28-responsive-slice";
const evidenceDir = path.join(__dirname, "evidence");

(async () => {
  fs.mkdirSync(evidenceDir, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    httpCredentials: { username, password },
    locale: "en-US",
    reducedMotion: "reduce",
  });
  const results = [];

  try {
    for (const width of viewports) {
      const page = await context.newPage();
      await page.setViewportSize({ width, height: viewportHeight });
      await page.goto(referenceUrl, { waitUntil: "domcontentloaded", timeout: 120000 });
      await page.waitForSelector(".bpmkbvvo", { timeout: 120000 });
      await page.waitForTimeout(750);
      await page.evaluate(async () => {
        await document.fonts.ready;
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      });
      const audit = await page.evaluate(browserInspectScript, { selectorKind: "class", ids: sourceNodeIds });
      if (audit.scrollWidth !== audit.clientWidth) {
        throw new Error(`${width}: reference horizontal overflow ${audit.scrollWidth} > ${audit.clientWidth}`);
      }
      const screenshot = `reference-${width}x${viewportHeight}.png`;
      await page.screenshot({ path: path.join(evidenceDir, screenshot), fullPage: true });
      results.push({ width, height: viewportHeight, screenshot, audit });
      await page.close();
      console.log(`CAPTURED ${width}x${viewportHeight}`);
    }
  } finally {
    await context.close();
    await browser.close();
  }

  fs.writeFileSync(
    path.join(evidenceDir, "reference-browser-audit.json"),
    JSON.stringify({
      status: "captured",
      scope: "Controlled Bubble test page",
      url: referenceUrl,
      chromium: browser.version(),
      deviceScaleFactor: 1,
      sourcePageId: "bpmkbvvo",
      results,
    }, null, 2) + "\n"
  );
})().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
