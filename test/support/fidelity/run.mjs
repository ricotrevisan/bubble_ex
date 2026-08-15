#!/usr/bin/env node
// Frozen-case fidelity runner (#30). Browser automation is measurement
// equipment, not generated output. Compares a candidate HTML file to the
// committed Bubble reference for one case.

import fs from "fs";
import path from "path";
import { pathToFileURL } from "url";
import { createRequire } from "module";

const require = createRequire(import.meta.url);

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const caseDir = arg("--case");
const htmlPath = arg("--html");
const reportPath = arg("--report");

if (!caseDir || !htmlPath || !reportPath) {
  console.error("usage: node run.mjs --case CASE_DIR --html CANDIDATE.html --report OUT.json");
  process.exit(2);
}

const caseJson = JSON.parse(fs.readFileSync(path.join(caseDir, "case.json"), "utf8"));
const reference = JSON.parse(
  fs.readFileSync(path.join(caseDir, "reference", "browser-audit.json"), "utf8")
);

const viewports = caseJson.viewports;
const viewportHeight = caseJson.browser.viewport_height;
const nodeIds = caseJson.node_ids;
const textNodeIds = new Set(caseJson.text_node_ids);
const pin = caseJson.browser;

function inspectScript(ids) {
  return ({ ids }) => {
    const properties = [
      "display",
      "visibility",
      "position",
      "flexDirection",
      "flexWrap",
      "rowGap",
      "columnGap",
      "justifyContent",
      "alignItems",
      "gridTemplateColumns",
      "overflow",
      "fontFamily",
      "fontSize",
      "fontWeight",
      "lineHeight",
      "color",
    ];
    const elements = {};
    for (const id of ids) {
      const matches = document.querySelectorAll(`[data-bubble-id="${id}"]`);
      const element = matches.length === 1 ? matches[0] : null;
      if (!element) {
        elements[id] = { absent: true };
        continue;
      }
      const rect = element.getBoundingClientRect();
      const computedStyle = getComputedStyle(element);
      elements[id] = {
        tag: element.tagName.toLowerCase(),
        box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
        ...Object.fromEntries(properties.map((property) => [property, computedStyle[property]])),
      };
    }
    return {
      clientWidth: document.documentElement.clientWidth,
      scrollWidth: document.documentElement.scrollWidth,
      scrollHeight: document.documentElement.scrollHeight,
      elements,
    };
  };
}

function recordMismatch(mismatches, category, width, id, detail) {
  mismatches.push({ category, width, ...(id ? { id } : {}), detail });
}

async function main() {
  let chromium;
  try {
    ({ chromium } = require("playwright"));
  } catch {
    fs.writeFileSync(
      reportPath,
      JSON.stringify({ status: "fail", error: "playwright_missing" }, null, 2) + "\n"
    );
    console.error("playwright is not installed (need 1.55.0)");
    process.exit(1);
  }

  const browser = await chromium.launch({ headless: true });
  const version = browser.version();
  const candidateByWidth = new Map();
  const workDir = path.dirname(reportPath);

  try {
    if (pin.chromium && version !== pin.chromium) {
      const report = {
        status: "fail",
        error: "chromium_pin_mismatch",
        chromium: version,
        pinned: pin.chromium,
      };
      fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
      console.error(`chromium ${version} != pinned ${pin.chromium}; recapture required`);
      process.exit(1);
    }

    for (const width of viewports) {
      const page = await browser.newPage({
        viewport: { width, height: viewportHeight },
        deviceScaleFactor: pin.dpr || 1,
        locale: pin.locale || "en-US",
        reducedMotion: "reduce",
      });
      await page.goto(pathToFileURL(htmlPath).href);
      await page.evaluate(async () => {
        await document.fonts.ready;
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      });
      const audit = await page.evaluate(inspectScript(nodeIds), { ids: nodeIds });
      const screenshot = `candidate-${width}x${viewportHeight}.png`;
      await page.screenshot({ path: path.join(workDir, screenshot), fullPage: true });
      candidateByWidth.set(width, { width, height: viewportHeight, screenshot, audit });
      await page.close();
    }
  } finally {
    await browser.close();
  }

  const geometry = [];
  const typography = [];
  const collapsed = [];
  const documentHeights = [];
  const screenshots = [];
  const mismatches = [];

  for (const referenceResult of reference.results) {
    const { width, height } = referenceResult;
    const candidateResult = candidateByWidth.get(width);
    if (!candidateResult) throw new Error(`Missing candidate viewport ${width}`);

    const heightError = candidateResult.audit.scrollHeight - referenceResult.audit.scrollHeight;
    documentHeights.push({
      width,
      reference: referenceResult.audit.scrollHeight,
      candidate: candidateResult.audit.scrollHeight,
      error: heightError,
    });
    if (heightError !== 0) recordMismatch(mismatches, "document_height", width, null, { error: heightError });

    if (candidateResult.audit.scrollWidth !== candidateResult.audit.clientWidth) {
      recordMismatch(mismatches, "overflow", width, null, {
        scrollWidth: candidateResult.audit.scrollWidth,
        clientWidth: candidateResult.audit.clientWidth,
      });
    }

    for (const [id, referenceElement] of Object.entries(referenceResult.audit.elements)) {
      const candidateElement = candidateResult.audit.elements[id];
      if (!candidateElement) {
        recordMismatch(mismatches, "presence", width, id, { candidateMissing: true });
        continue;
      }

      if (referenceElement.absent) {
        const collapsedByAncestor =
          !candidateElement.absent &&
          candidateElement.box.width === 0 &&
          candidateElement.box.height === 0;
        const result = {
          width,
          id,
          pass: Boolean(candidateElement.absent) || collapsedByAncestor,
        };
        collapsed.push(result);
        if (!result.pass) recordMismatch(mismatches, "collapse", width, id, result);
        continue;
      }

      if (candidateElement.absent) {
        recordMismatch(mismatches, "presence", width, id, { referenceAbsent: false, candidateAbsent: true });
        continue;
      }

      const errors = Object.fromEntries(
        ["x", "y", "width", "height"].map((property) => [
          property,
          candidateElement.box[property] - referenceElement.box[property],
        ])
      );
      const maxAbsError = Math.max(...Object.values(errors).map(Math.abs));
      geometry.push({ width, id, errors, maxAbsError });
      if (maxAbsError !== 0) recordMismatch(mismatches, "geometry", width, id, { errors, maxAbsError });

      if (textNodeIds.has(id)) {
        const properties = ["fontFamily", "fontSize", "fontWeight", "lineHeight", "color"];
        const values = Object.fromEntries(
          properties.map((property) => [
            property,
            { reference: referenceElement[property], candidate: candidateElement[property] },
          ])
        );
        const pass = properties.every(
          (property) => referenceElement[property] === candidateElement[property]
        );
        typography.push({ width, id, pass, properties: values });
        if (!pass) recordMismatch(mismatches, "typography", width, id, values);
      }
    }

    const referencePng = fs.readFileSync(path.join(caseDir, "reference", `${width}x${height}.png`));
    const candidatePng = fs.readFileSync(path.join(workDir, candidateResult.screenshot));
    const byteIdentical = referencePng.equals(candidatePng);
    screenshots.push({ width, height, byteIdentical });
    if (!byteIdentical) recordMismatch(mismatches, "screenshot", width, null, {});
  }

  const report = {
    status: mismatches.length === 0 ? "pass" : "fail",
    case: caseJson.id,
    chromium: version,
    viewportCount: viewports.length,
    geometry: {
      sampleCount: geometry.length,
      maxAbsError: geometry.length ? Math.max(...geometry.map((result) => result.maxAbsError)) : null,
    },
    typography: { sampleCount: typography.length },
    collapse: { sampleCount: collapsed.length },
    documentHeight: { allExact: documentHeights.every((result) => result.error === 0) },
    screenshots: { allByteIdentical: screenshots.every((result) => result.byteIdentical) },
    mismatches,
  };

  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
  console.log(
    `${report.status.toUpperCase()} ${caseJson.id}: ${viewports.length} viewports, ${mismatches.length} mismatches`
  );
  if (report.status === "fail") process.exit(1);
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
