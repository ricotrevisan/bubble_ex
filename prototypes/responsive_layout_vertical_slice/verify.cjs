// PROTOTYPE validation only. Browser automation is not part of generated output.
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");
const { chromium } = require("playwright");

const prototypeDir = __dirname;
const outDir = path.join(prototypeDir, "dist");
const evidenceDir = path.join(prototypeDir, "evidence");
const widths = [390, 767, 768, 769, 795, 796, 797, 1151, 1152, 1153, 1440];
const height = 900;

function check(condition, message) {
  if (!condition) throw new Error(message);
}

function close(actual, expected, tolerance = 1) {
  return Math.abs(actual - expected) <= tolerance;
}

(async () => {
  fs.mkdirSync(evidenceDir, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const results = [];

  try {
    for (const width of widths) {
      const page = await browser.newPage({
        viewport: { width, height },
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
        const one = (selector) => {
          const matches = document.querySelectorAll(selector);
          if (matches.length !== 1) throw new Error(`${selector}: expected once, found ${matches.length}`);
          return matches[0];
        };
        const inspect = (selector) => {
          const element = one(selector);
          const rect = element.getBoundingClientRect();
          const css = getComputedStyle(element);
          return {
            tag: element.tagName.toLowerCase(),
            box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
            display: css.display,
            position: css.position,
            flexDirection: css.flexDirection,
            gap: css.gap,
            gridTemplateColumns: css.gridTemplateColumns,
            overflow: css.overflow,
          };
        };

        return {
          scripts: document.scripts.length,
          eventHandlers: [...document.querySelectorAll("*")].flatMap((element) =>
            [...element.attributes].filter((attribute) => attribute.name.startsWith("on"))
          ).length,
          scrollWidth: document.documentElement.scrollWidth,
          clientWidth: document.documentElement.clientWidth,
          hero: inspect(".e-hero"),
          heroCopy: inspect(".e-hero-copy"),
          heroVisual: inspect(".e-hero-visual"),
          navLinks: inspect(".e-nav-links"),
          featureRow: inspect(".e-feature-row"),
          fixedCluster: inspect(".e-fixed-cluster"),
          fixedChild: inspect(".e-cluster-a"),
          semantics: {
            page: inspect(".e-page-index").tag,
            title: inspect(".e-hero-title").tag,
            link: inspect(".e-link-platform").tag,
            button: inspect(".e-primary-cta").tag,
            input: inspect(".e-email").tag,
            shapeHidden: one(".e-visual-halo").getAttribute("aria-hidden"),
          },
          sourceOrder: [...one(".e-hero").children].map((element) => element.dataset.exporterId),
        };
      });

      check(audit.scripts === 0, `${width}: generated output contains scripts`);
      check(audit.eventHandlers === 0, `${width}: generated output contains inline event handlers`);
      check(audit.scrollWidth === audit.clientWidth, `${width}: horizontal overflow ${audit.scrollWidth} > ${audit.clientWidth}`);
      check(audit.heroVisual.display === "grid", `${width}: Align-to-Parent did not compile to grid`);
      check(audit.fixedCluster.position === "relative", `${width}: Fixed parent is not a containing block`);
      check(audit.fixedChild.position === "absolute", `${width}: Fixed child is not locally positioned`);
      check(JSON.stringify(audit.sourceOrder) === JSON.stringify(["hero-copy", "hero-visual"]), `${width}: source order changed`);

      const narrow = width < 768;
      check(audit.hero.flexDirection === "row", `${width}: hero no longer uses natural Row wrapping`);
      check(audit.featureRow.flexDirection === "row", `${width}: feature cards no longer use natural Row wrapping`);
      check(audit.navLinks.display === (narrow ? "none" : "flex"), `${width}: wrong collapsed-navigation state`);

      const expectedShellWidth = Math.min(1120, width - 32);
      check(close(audit.hero.box.width, expectedShellWidth), `${width}: shell width ${audit.hero.box.width}, expected ${expectedShellWidth}`);

      const wrapped = width < 796;
      if (wrapped) {
        check(audit.heroVisual.box.y > audit.heroCopy.box.y, `${width}: hero did not naturally wrap`);
      } else {
        const copyCenter = audit.heroCopy.box.y + audit.heroCopy.box.height / 2;
        const visualCenter = audit.heroVisual.box.y + audit.heroVisual.box.height / 2;
        check(close(copyCenter, visualCenter, 2), `${width}: unwrapped hero columns are not center-aligned`);
      }

      check(
        JSON.stringify(audit.semantics) === JSON.stringify({
          page: "main", title: "h1", link: "a", button: "button", input: "input", shapeHidden: "true"
        }),
        `${width}: semantic output changed: ${JSON.stringify(audit.semantics)}`
      );

      const screenshot = `candidate-${width}x${height}.png`;
      await page.screenshot({ path: path.join(evidenceDir, screenshot), fullPage: true });
      results.push({ width, height, screenshot, audit });
      await page.close();
      console.log(`PASS ${width}x${height}`);
    }

    const report = {
      status: "pass",
      scope: "CSS expressiveness against synthetic normalized fixture; not Bubble visual parity",
      chromium: browser.version(),
      deviceScaleFactor: 1,
      breakpoint: 768,
      heroWrap: 796,
      shellClamp: 1152,
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
