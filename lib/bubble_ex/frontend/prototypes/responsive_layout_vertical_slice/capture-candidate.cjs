// Capture the static candidate using the shared evidence contract.
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");
const { chromium } = require("playwright");
const { sourceNodeIds, viewports, viewportHeight, browserInspectScript } = require("./evidence-contract.cjs");

(async () => {
  const browser = await chromium.launch({ headless: true });
  const results = [];

  try {
    for (const width of viewports) {
      const page = await browser.newPage({
        viewport: { width, height: viewportHeight },
        deviceScaleFactor: 1,
        locale: "en-US",
        reducedMotion: "reduce",
      });
      await page.goto(pathToFileURL(path.join(__dirname, "dist/index.html")).href);
      await page.evaluate(async () => {
        await document.fonts.ready;
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      });
      const audit = await page.evaluate(browserInspectScript, { selectorKind: "data", ids: sourceNodeIds });
      results.push({ width, height: viewportHeight, audit });
      await page.close();
    }
  } finally {
    await browser.close();
  }

  fs.writeFileSync(
    path.join(__dirname, "evidence/candidate-browser-comparison.json"),
    JSON.stringify({ status: "captured", results }, null, 2) + "\n"
  );
})().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
