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

Iteration 23 resolves literal reusable parameters and restores acceptance of
inert Message editor metadata. Mochary remains 100; Bubble scores
40.93 / 41.38 / 39.95, for a combined 70.37. All visible exported images load;
their total count still differs from the reference. Iteration 22 exposed a
regression introduced after the iteration 21 capture: stricter argument checks
rejected Message metadata on both logo lists. The original iteration 21 score
must therefore not be treated as validation of the final PR75 commit. Regression
tests now include that observed metadata and keep unknown arguments rejected.

Iteration 26 fixes stale image-height bounds and icon styles overriding initial
visibility, and supports showing native elements at authored breakpoints.
Mochary remains 100; Bubble scores 41.04 / 41.46 / 40.00, for a combined 70.41.
The corrected image is 24 × 24 at all three widths, matching fresh source
observations. Source content generated from group data, database searches, and
plugins still differs; none of those failures is excluded from the score.

Iteration 28 adds typed literal group data and explicit parent-data forwarding.
Mochary remains 100; Bubble scores 41.11 / 41.60 / 40.11, for a combined 70.47.
This iteration also exposed intermittent `bpqqfagk` frozen screenshot failures:
the dropdown text sometimes shifts down by one pixel. Its exported HTML and CSS
are identical to the preceding implementation, geometry remains exact, and
repeated captures of the same package both pass and fail. The failed artifacts
are retained. PR78 subsequently passed every CI job without retries, including
all nineteen frozen cases, and was deployed. This establishes a passing CI run,
not repeatability of that case; the [capture investigation](dropdown-capture-instability.md)
remains open.

Iteration 29 applies minimum-size breakpoint overrides to fixed dimensions and
their bounds. Bubble's two mobile background images now have the observed
200 px and 310 px widths, and its app showcase also follows its authored width
changes. Page height improves from 14,073 to 13,609 px at 390 px and from 12,773
to 12,605 px at 768 px. The combined score remains 70.47 because complete box
comparisons still fail on position; no fractional credit was added for improving
only some coordinates. Mochary remains 100 at all widths.

Iteration 31 retains authored element IDs and supported inline head CSS. Bubble's
document widths now match 390 / 768 / 1440 rather than 590 / 1168 / 1980, and its
document heights become 13,409 / 12,405 / 11,333. Mochary remains 100; Bubble
scores 41.12 / 41.60 / 40.12, with the combined score still truncated to 70.47.
The visual category still fails. Its percentage of differing pixels rises as
the excess canvas width is removed; that percentage alone must not be described
as a before/after visual improvement. No pixel threshold or reference changed.

The page styles are additional rendering inputs captured from the two authorized
landing URLs. They are held separately from the reference captures and locked
by SHA-256; a second fetch reproduced their discovered style blocks exactly.
The input hashes are `85375431a3416accff5a9f388f5488fa722979e146bd64e204ffe3de02321d90`
for `mochary.json` and `210bd1f33239dea9d0edb7a72ab4781b25f81c849db2fea66ff788ac41933405`
for `bubble.json`. No existing reference PNG, DOM audit, payload, or baseline lock
was edited. Pass the private source-style directory as the optional third
argument to `scripts/landing/export.exs` to reproduce this iteration; omit it
to repeat the older app-payload-only export input. The script verifies its
separate `lock.json` before reading these inputs.
The final parser hardening was exported again as iteration 32. All 28 Mochary
and 170 Bubble HTML/CSS/asset files are byte-identical to iteration 31, so the
measured rendering is unchanged. The local frozen run again encountered the
documented dropdown shift; that case's HTML, page CSS, and shared CSS remain
byte-identical to the preceding implementation.

Iteration 33 preserves literal image sources in supported page-width conditions.
The two Bubble hero images now select their mobile artwork at 390 px and desktop
artwork at 768 / 1440 px. A pinned Chromium probe confirms that both selected
images load and their boxes are identical to iteration 32. The remaining mobile
16 px vertical offset is unchanged. Alternate files use the existing asset
download and credential protections; overlapping sources follow the last matching
authored condition. Runtime expressions and compound conditions remain unresolved.
Mochary remains 100 at all widths. Bubble remains 41.12 / 41.60 / 40.12 and the
combined score remains 70.47: correcting two images does not pass the complete
visual assertion. No reference, category, or threshold changed.

Iterations 34–35 restore SVG icon geometry. The sanitizer previously rejected
circles and rectangles used by thirteen distinct glyph/weight combinations,
producing 22 asset findings across their occurrences. A local-file reproduction
failed; replacing only the circle with an equivalent path passed. Numeric circle
and rectangle geometry and bounded simple rotations are now supported, while
active content, external references, and other transforms remain rejected.
The shape definitions follow the [SVG basic-shapes specification](https://www.w3.org/TR/SVG2/shapes.html).

Browser inspection also found five arrow occurrences resolving another weight's
symbol because inline SVG IDs collided. Iteration 35 gives each rendered icon a
stable instance-specific symbol ID; the same probe then reports zero conflicts.
All 22 icon asset findings are gone. Thirteen original/sanitized glyph pairs at
16 / 24 / 32 px produce 39 byte-identical Chromium screenshots. The full page
grade remains 70.47 (Mochary 100 at every width; Bubble 41.12 / 41.60 / 40.12).
These focused corrections do not pass the complete visual or content assertions.

Iterations 38–39 resolve the header spacer's supported geometry style. Its source
template reads the header's height through a reusable parameter. The export's
header was already 80 px at 390 px, but the unresolved style left its spacer at
96 px. Applying only the authored rule to the preceding candidate corrected the
spacer and hero position. The renderer now supports one sanitized style block
with simple numeric pixel declarations and unique-element dimension references,
including parameter forwarding. A local helper measures after fonts/load and on
viewport resize; these bindings remain separate from general Bubble execution.

The first browser regression exposed CSS variable fallback semantics: an unset
variable in an important declaration does not restore the lower-priority default.
Dependent styles therefore start inactive and activate only with valid references.
Missing, ambiguous, transformed, placeholder, or self-resizing measurements leave
them inactive. Tests cover those cases and viewport changes. The mobile spacer
and hero now start at 80 px, and document height changes from 13,409 to 13,393 px.
Mochary remains 100; Bubble scores 41.24 / 41.60 / 40.12, for a combined 70.49.
The complete appearance/content and normal-source credential gates still fail.

Iterations 40–41 correct child document order inside positioned containers.
The captured app cards place each app name before its category, while the export
used stale flow order and placed the category first. Fixed and align-to-parent
containers now use an authored layer index; containers without one retain the
existing order fallback. Row and column ordering is unchanged. A failing export
regression covers compact and readable layer keys, and all eight name/category
pairs now match the source sequence at every measured width. The full-page grade
remains 70.49 because the complete content assertion still fails. No source
capture, grading rule, or threshold changed.

Iteration 42 restores the footer copyright line. Its direct current-date year
extraction was unresolved, although formatted-year snapshots were already
supported. Substituting only the supported operation in a private probe restored
the text. Direct year extraction now uses the recorded snapshot time, retains
the original binding, and rejects additional arguments, timezone overrides, and
operation chains. A fetched reusable export test covers the UTC year boundary.
The copyright line matches at all three widths. Mochary remains 100; Bubble
scores 41.25 / 41.62 / 40.14, for a combined 70.50. Runtime content and appearance
gaps and the original credential gates remain.

Iteration 43 corrects a Shape's aspect-ratio height. The exported 900 px spacer
had the authored 1000:600 ratio but retained an old 150 px fixed height. Changing
only the candidate height rule yielded the source's 540 px height; a live
read-only style observation confirmed that Bubble omits its stale vertical
bounds. Valid fixed-height aspect Shapes now use width-derived height. Browser
regressions cover three viewport sizes and four native container layouts; invalid
or disabled ratios retain ordinary dimensions. The full-page grade remains 70.50:
the spacer's dimensions match, but upstream offsets and other content still fail
complete assertions. The source captures and rubric are unchanged.

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
