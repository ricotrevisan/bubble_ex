const fs = require("fs");
const path = require("path");
const { textNodeIds } = require("./evidence-contract.cjs");

const evidenceDir = path.join(__dirname, "evidence");
const candidate = JSON.parse(fs.readFileSync(path.join(evidenceDir, "candidate-browser-comparison.json"), "utf8"));
const reference = JSON.parse(fs.readFileSync(path.join(evidenceDir, "reference-browser-audit.json"), "utf8"));
const candidateByWidth = new Map(candidate.results.map((result) => [result.width, result]));
const geometry = [];
const typography = [];
const collapsed = [];
const documentHeights = [];
const screenshots = [];
const mismatches = [];

function recordMismatch(category, width, id, detail) {
  mismatches.push({ category, width, ...(id ? { id } : {}), detail });
}

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
  if (heightError !== 0) recordMismatch("document_height", width, null, { error: heightError });

  for (const [id, referenceElement] of Object.entries(referenceResult.audit.elements)) {
    const candidateElement = candidateResult.audit.elements[id];
    if (!candidateElement) throw new Error(`${width}: candidate audit missing ${id}`);

    if (referenceElement.absent) {
      const collapsedByAncestor = !candidateElement.absent && candidateElement.box.width === 0 && candidateElement.box.height === 0;
      const result = {
        width,
        id,
        referenceAbsent: true,
        candidateAbsent: Boolean(candidateElement.absent),
        candidateDisplay: candidateElement.display,
        candidateBox: candidateElement.box,
        collapsedByAncestor,
        pass: collapsedByAncestor,
      };
      collapsed.push(result);
      if (!result.pass) recordMismatch("collapse", width, id, result);
      continue;
    }

    if (candidateElement.absent) {
      recordMismatch("presence", width, id, { referenceAbsent: false, candidateAbsent: true });
      continue;
    }

    const errors = Object.fromEntries(
      ["x", "y", "width", "height"].map((property) => [property, candidateElement.box[property] - referenceElement.box[property]])
    );
    const maxAbsError = Math.max(...Object.values(errors).map(Math.abs));
    geometry.push({ width, id, errors, maxAbsError });
    if (maxAbsError !== 0) recordMismatch("geometry", width, id, { errors, maxAbsError });

    if (textNodeIds.has(id)) {
      const properties = ["fontFamily", "fontSize", "fontWeight", "lineHeight", "color"];
      const values = Object.fromEntries(
        properties.map((property) => [property, { reference: referenceElement[property], candidate: candidateElement[property] }])
      );
      const result = { width, id, pass: properties.every((property) => referenceElement[property] === candidateElement[property]), properties: values };
      typography.push(result);
      if (!result.pass) recordMismatch("typography", width, id, values);
    }
  }

  const referencePng = fs.readFileSync(path.join(evidenceDir, referenceResult.screenshot));
  const candidateScreenshot = `candidate-${width}x${height}.png`;
  const candidatePng = fs.readFileSync(path.join(evidenceDir, candidateScreenshot));
  const byteIdentical = referencePng.equals(candidatePng);
  screenshots.push({ width, height, reference: referenceResult.screenshot, candidate: candidateScreenshot, byteIdentical });
  if (!byteIdentical) recordMismatch("screenshot", width, null, { reference: referenceResult.screenshot, candidate: candidateScreenshot });
}

const report = {
  status: mismatches.length === 0 ? "pass" : "fail",
  verdict: mismatches.length === 0 ? "pixel_identical" : "mismatch",
  sourcePageId: reference.sourcePageId,
  sourcePayloadSha256: "706f73ef49c170ab077bfe680403782f5dea94ba36ea5cae3c3878079340701b",
  viewportCount: reference.results.length,
  geometry: {
    sampleCount: geometry.length,
    maxAbsError: geometry.length ? Math.max(...geometry.map((result) => result.maxAbsError)) : null,
    allExact: geometry.every((result) => result.maxAbsError === 0),
  },
  typography: { sampleCount: typography.length, allExact: typography.every((result) => result.pass) },
  collapse: { sampleCount: collapsed.length, allExact: collapsed.every((result) => result.pass), results: collapsed },
  documentHeight: { allExact: documentHeights.every((result) => result.error === 0), results: documentHeights },
  screenshots: { allByteIdentical: screenshots.every((result) => result.byteIdentical), results: screenshots },
  mismatches,
};

fs.writeFileSync(path.join(evidenceDir, "comparison.json"), JSON.stringify(report, null, 2) + "\n");
console.log(`${report.status.toUpperCase()} ${report.verdict}: ${report.viewportCount} viewports, ${geometry.length} geometry samples`);
if (report.status === "fail") process.exitCode = 1;
