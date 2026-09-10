# Landing-page acceptance rubric (version 1)

Scope: the anonymous initial landing pages of `https://beta.mocharymethod.com/`
and `https://bubble.io/`, at viewport widths 390, 768 and 1440 CSS pixels,
height 900, DPR 1, Chromium 140 / Playwright 1.55.1 on Linux. No form
submissions, login, or navigation beyond these pages is authorized.

The reference is the September 10, 2026 capture, not the current moving site.
`scripts/landing/grade.cjs` verifies a SHA-256 baseline lock before grading.
Payloads have credential-shaped settings redacted; the original page structure
is unchanged. Private audit inputs stay outside Git. The original reference is
retained alongside the explicitly recorded screenshot correction below.

Each viewport receives six equally weighted category scores:

1. **Visual appearance:** at most 1% differing pixels across the complete page,
   using Pixelmatch threshold 0.1 with antialias differences ignored. Different
   screenshot sizes are padded with white, never cropped or resized. No masks.
2. **Layout and initial visibility:** document width and height within 2 CSS
   pixels; every uniquely identifiable source Bubble node has the same initial
   visibility, and visible node boxes are within 2 pixels on each axis. Repeated
   IDs must have matching occurrence counts and boxes in document order.
3. **Visible content:** the complete captured visible text, with whitespace
   normalized, is identical. Source capture is limited to 20,000 characters by
   the original measurement harness; screenshot comparison covers the full page.
4. **Typography:** visible correlated text nodes have equal computed font family,
   font size and line height (numeric values within 0.5 CSS pixels). Missing nodes
   fail. This checks the measured fields, not an assertion about all typography.
5. **Assets and runtime health:** all visible exported image elements load, the
   visible image count equals the reference, and no new page errors occur.
   Pixel comparison additionally checks what those images display.
6. **Navigation:** visible anchor labels and canonical destinations match the
   reference, including occurrence counts. Exported local pages may map back to
   their original public paths; dangling local files fail. This does not exercise
   workflow buttons, login, or off-page destinations.

Categories containing several assertions use the fraction passing. Category
scores are averaged across three widths, then across the two sites. Display
scores are truncated to two decimals; a rounded 100 is never accepted. Acceptance
requires every assertion passing at every width, not merely a high average.
Missing captures, ambiguous correlations, and failed measurements cannot pass.

**Independent release gates:** the normal export credential gate must pass for
both unmodified public sources; the full automated quality and frozen-case
fidelity suites must pass; fixes must be deployed to the library's main branch.
A diagnostic export made from redacted settings can earn a page score, but cannot
by itself satisfy the normal-export gate or the overall 100% acceptance target.

The rubric and denominators are fixed before renderer changes. Any genuinely
necessary later rubric correction must be recorded explicitly, with both old and
new scores. Unsupported elements remain failures where visible; neither source
editing, hiding differences, screenshot embedding, nor site-specific HTML copies
are acceptable fixes.

Grader correction (implementation revision 2): an anchor with no `href` is
recorded as having no destination on both sides. Revision 1 accidentally resolved
JavaScript `null` as a literal `/null` URL, creating false dangling-file failures.
The anchor still participates in the label/destination comparison. Thresholds,
categories, and references are unchanged; prior scores are retained in the audit.

Reference revision 2 (September 11): the original Mochary 1440-pixel screenshot
shows a different layout from its paired DOM audit. Fresh captures reproduce the
original audit exactly at all three widths, and reproduce the original 390- and
768-pixel PNGs byte for byte. Hashes of the source page, shared styles, reusables,
and theme settings also match the original payload. Repeated desktop screenshots
and their viewport crops agree with each other and with the audit. A separate
reference directory therefore replaces only that inconsistent desktop PNG;
`benchmark-revision.json` records its old/new hashes and is included in the lock.
The original benchmark and scores remain available. No thresholds, audit fields,
payloads, or Bubble screenshots changed. Bubble's animated captures did not meet
the same consistency check and were not substituted.

Checkpoint scores (iteration 14; same candidate measured against both references):

| Reference | Mochary 390 / 768 / 1440 | Bubble 390 / 768 / 1440 | Combined |
|---|---|---|---|
| Original | 100 / 100 / 83.33 | 30.51 / 35.02 / 33.50 | 63.72 |
| Revision 2 | 100 / 100 / 100 | 30.51 / 35.02 / 33.50 | 66.50 |

Mochary passes the diagnostic page tests at revision 2. Bubble and the independent
release gates are not accepted. These scores describe the captured pages, not
general application functionality or interactive workflow parity.

Iteration 20, with the same revision 2 reference: Mochary remains 100 at all
widths; Bubble scores 35.08 / 35.54 / 34.14, for a combined 67.45. This iteration
adds Phosphor icons, shared-style breakpoints, margin-aware fill sizing, and
reusable instance sizing corrections. Missing runtime content still fails.

Iteration 21 adds bounded literal horizontal lists. Mochary remains 100 at all
widths; Bubble scores 35.25 / 35.70 / 34.28, for a combined 67.53. The fourteen
logo images have matching cell dimensions, but their animated positions still
fail, as do missing runtime content and reusable parameter values.

To repeat a candidate with the private captured inputs:

```sh
mix run scripts/landing/export.exs "$BASELINE_DIR" _build/landing-candidate
# Run the next command inside the pinned Linux Playwright 1.55.1 image,
# mounting this repository at the same absolute path.
node scripts/landing/measure.cjs _build/landing-candidate
node scripts/landing/grade.cjs "$BASELINE_DIR" _build/landing-candidate/comparison.json _build/landing-candidate/grades.json
```

The baseline lock is created on first use and rejects subsequent input changes.
It establishes consistency of the supplied capture, not authenticity of an
arbitrary new baseline. Keep the original captures and revision evidence.
