// PROTOTYPE validation only. Browser automation is measurement equipment, not generated output.
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");
const { chromium } = require("playwright");
const { viewports, viewportHeight } = require("./evidence-contract.cjs");

const prototypeDir = __dirname;
const outDir = path.join(prototypeDir, "dist");
const evidenceDir = path.join(prototypeDir, "evidence");

function check(condition, message) {
  if (!condition) throw new Error(message);
}

function withinTolerance(actual, expected, tolerance = 1) {
  return Math.abs(actual - expected) <= tolerance;
}

function sameLine(a, b, tolerance = 1) {
  return withinTolerance(a.y, b.y, tolerance);
}

(async () => {
  fs.mkdirSync(evidenceDir, { recursive: true });
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

      await page.goto(pathToFileURL(path.join(outDir, "index.html")).href);
      await page.evaluate(async () => {
        await document.fonts.ready;
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      });

      const audit = await page.evaluate(() => {
        const query = (id) => {
          const matches = document.querySelectorAll(`[data-exporter-id="${id}"]`);
          if (matches.length !== 1) throw new Error(`${id}: expected once, found ${matches.length}`);
          return matches[0];
        };
        const inspect = (id) => {
          const element = query(id);
          const rect = element.getBoundingClientRect();
          const css = getComputedStyle(element);
          return {
            tag: element.tagName.toLowerCase(),
            box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
            display: css.display,
            visibility: css.visibility,
            position: css.position,
            flexDirection: css.flexDirection,
            flexWrap: css.flexWrap,
            rowGap: css.rowGap,
            columnGap: css.columnGap,
            gridTemplateColumns: css.gridTemplateColumns,
            overflow: css.overflow,
            fontFamily: css.fontFamily,
          };
        };
        const ids = [...document.querySelectorAll("[data-exporter-id]")].map((element) => element.dataset.exporterId);
        return {
          scripts: document.scripts.length,
          eventHandlers: [...document.querySelectorAll("*")].flatMap((element) =>
            [...element.attributes].filter((attribute) => attribute.name.startsWith("on"))
          ).length,
          scrollWidth: document.documentElement.scrollWidth,
          clientWidth: document.documentElement.clientWidth,
          scrollHeight: document.documentElement.scrollHeight,
          interAvailable: document.fonts.check("16px Inter"),
          nodeCount: ids.length,
          ids,
          page: inspect("bpmkbvvo"),
          header: inspect("bpmkbvvp"),
          nav: inspect("bpmkbvvr"),
          hero: inspect("bpmkbvvw"),
          heroCopy: inspect("bpmkbvvx"),
          heroArtwork: inspect("bpmkbvwe"),
          featureRow: inspect("bpmkbvwt"),
          featureCards: [inspect("bpmkbvwu"), inspect("bpmkbvwy"), inspect("bpmkbvxc")],
          fixedCanvas: inspect("bpmkbvwm"),
          fixedA: inspect("bpmkbvwn"),
          fixedB: inspect("bpmkbvwo"),
          cta: inspect("bpmkbvxg"),
          ctaCopy: inspect("bpmkbvxh"),
          ctaInput: inspect("bpmkbvxi"),
          ctaButton: inspect("bpmkbvxj"),
          semantics: {
            page: inspect("bpmkbvvo").tag,
            heroHeading: inspect("bpmkbvvz").tag,
            featureHeading: inspect("bpmkbvwr").tag,
            button: inspect("bpmkbvwc").tag,
            input: inspect("bpmkbvxi").tag,
            shapeHidden: query("bpmkbvwf").getAttribute("aria-hidden"),
          },
          heroOrder: [...query("bpmkbvvw").children].map((element) => element.dataset.exporterId),
          artworkOrder: [...query("bpmkbvwe").children].map((element) => element.dataset.exporterId),
        };
      });

      check(audit.scripts === 0, `${width}: generated output contains scripts`);
      check(audit.eventHandlers === 0, `${width}: generated output contains inline event handlers`);
      check(audit.scrollWidth === audit.clientWidth, `${width}: horizontal overflow ${audit.scrollWidth} > ${audit.clientWidth}`);
      check(audit.nodeCount === 48, `${width}: expected 48 source-correlated nodes, found ${audit.nodeCount}`);
      check(audit.heroArtwork.display === "grid", `${width}: Align-to-Parent did not compile to grid`);
      check(audit.fixedCanvas.position === "relative", `${width}: Fixed parent is not a containing block`);
      check(audit.fixedA.position === "absolute" && audit.fixedB.position === "absolute", `${width}: Fixed children are not locally positioned`);
      check(JSON.stringify(audit.heroOrder) === JSON.stringify(["bpmkbvvx", "bpmkbvwe"]), `${width}: hero source order changed`);
      check(JSON.stringify(audit.artworkOrder) === JSON.stringify(["bpmkbvwf", "bpmkbvwg", "bpmkbvwk"]), `${width}: artwork source order changed`);
      check(audit.hero.flexDirection === "row" && audit.hero.flexWrap === "wrap", `${width}: hero no longer uses a naturally wrapping Row`);
      check(audit.featureRow.flexDirection === "row" && audit.featureRow.flexWrap === "wrap", `${width}: cards no longer use a naturally wrapping Row`);
      check(audit.nav.display === (width <= 768 ? "none" : "flex"), `${width}: wrong collapsed-navigation state`);

      const expectedShellWidth = Math.min(1120, width - 32);
      check(withinTolerance(audit.hero.box.width, expectedShellWidth), `${width}: shell width ${audit.hero.box.width}, expected ${expectedShellWidth}`);
      check(withinTolerance(audit.header.box.width, expectedShellWidth), `${width}: header width ${audit.header.box.width}, expected ${expectedShellWidth}`);

      if (width < 776) {
        check(audit.heroArtwork.box.y > audit.heroCopy.box.y, `${width}: hero did not wrap below its source-derived minimum`);
      } else {
        check(sameLine(audit.heroCopy.box, audit.heroArtwork.box), `${width}: hero wrapped at or above its source-derived minimum`);
      }

      const [cardA, cardB, cardC] = audit.featureCards.map((item) => item.box);
      if (width < 616) {
        check(cardA.y < cardB.y && cardB.y < cardC.y, `${width}: expected one card per line`);
      } else if (width < 920) {
        check(sameLine(cardA, cardB) && cardC.y > cardA.y, `${width}: expected two cards then one`);
      } else {
        check(sameLine(cardA, cardB) && sameLine(cardB, cardC), `${width}: expected three cards on one line`);
      }

      const copy = audit.ctaCopy.box;
      const input = audit.ctaInput.box;
      const button = audit.ctaButton.box;
      if (width < 484) {
        check(copy.y < input.y && input.y < button.y, `${width}: expected three CTA lines`);
      } else if (width < 638) {
        check(copy.y < input.y && sameLine(input, button), `${width}: expected CTA copy above input/button`);
      } else if (width < 784) {
        check(sameLine(copy, input, 20) && button.y > input.y, `${width}: expected CTA copy/input above button`);
      } else {
        check(sameLine(copy, input, 20) && sameLine(input, button, 20), `${width}: expected one CTA flex line`);
      }

      check(
        JSON.stringify(audit.semantics) === JSON.stringify({
          page: "main", heroHeading: "h1", featureHeading: "h2", button: "button", input: "input", shapeHidden: "true"
        }),
        `${width}: semantic output changed: ${JSON.stringify(audit.semantics)}`
      );

      const screenshot = `candidate-${width}x${viewportHeight}.png`;
      await page.screenshot({ path: path.join(evidenceDir, screenshot), fullPage: true });
      results.push({ width, height: viewportHeight, screenshot, audit });
      await page.close();
      console.log(`PASS ${width}x${viewportHeight}`);
    }

    const report = {
      status: "pass",
      scope: "Static-CSS candidate generated from hand-normalized controlled Bubble source facts",
      chromium: browser.version(),
      deviceScaleFactor: 1,
      sourcePageId: "bpmkbvvo",
      sourcePayloadSha256: "706f73ef49c170ab077bfe680403782f5dea94ba36ea5cae3c3878079340701b",
      boundaries: { ctaInputButtonJoin: 484, featureOneToTwo: 616, ctaCopyInputJoin: 638, navCollapse: 768, heroWrap: 776, ctaSingleLine: 784, featureTwoToThree: 920, shellClamp: 1152 },
      results,
    };
    fs.writeFileSync(path.join(evidenceDir, "browser-audit.json"), JSON.stringify(report, null, 2) + "\n");
    console.log(`Wrote ${path.relative(process.cwd(), path.join(evidenceDir, "browser-audit.json"))}`);
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
