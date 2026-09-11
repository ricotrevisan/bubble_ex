# Browser snapshot mode

The user selected a browser-captured snapshot mode on 2026-09-11 to preserve
portable initial-page appearance, including rendered database content and plugin
output. The existing app-data renderer remains available and keeps its own
benchmarks. Neither mode promises Bubble workflow execution.

Follow-up coverage for BetterLegal, Voicediq, Assistra and Kroki is recorded in
[the four-site test report](four-site-snapshot-tests.md), including capture fixes,
retained failures, and the unchanged grading checks.

## Intended contract

- Capture one explicitly requested anonymous page at a declared viewport, locale,
  device scale, and pinned browser version. Do not crawl links or submit forms.
- Capture the rendered DOM, initial control state, computed presentation, and
  required public image/font resources. Freeze animation state for the snapshot.
- Export semantic HTML/CSS with local assets. Remove source scripts, handlers,
  executable URLs, and form submission. Canvas/plugin visuals may become inert
  visual assets, while surrounding text and links remain HTML.
- Keep capture and export separate so an already captured state can be exported
  and tested offline. Enforce bounded inputs, the existing credential protection,
  and atomic output publication. Browser tooling is optional for app-data users.
- Record viewport and capture provenance. A snapshot is an initial view at that
  viewport, not a reconstructed responsive application or a workflow runtime.

## Acceptance evidence

The six grading categories and thresholds in
[the landing-page rubric](landing-page-grading.md) remain unchanged. Snapshot
references and exporter inputs will be taken from the same frozen browser state
before rendering an export. This keeps database updates, generated runtime IDs,
and advancing animations from becoming unrelated differences between input and
reference. The reference PNG is an assertion artifact, not an input to the HTML
renderer. Existing app-data captures and scores are retained separately.

Checks will compare source and offline export text, links, correlated geometry,
fonts, visible images, browser errors, and full-page pixels. Additional tests will
verify that the exported package makes no external requests and contains no
source execution, and that leaked credentials block publication.

Chromium's [virtual-time controls](https://chromedevtools.github.io/devtools-protocol/tot/Emulation/#method-setVirtualTimePolicy)
and [screenshot capture API](https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-captureScreenshot)
are being evaluated for a consistent frozen capture. These are implementation
experiments; no snapshot-mode pass or release is claimed yet.

## Implemented mode and evidence

The optional backend uses pinned Playwright 1.55.1 / Chromium 140.0.7339.186.
It freezes browser script execution and CSS animation properties, records open
shadow-root styles separately, and packages a Chromium MHTML capture with exact
font/image response bytes. The offline exporter parses and sanitizes HTML, CSS,
and SVG; it keeps links, initial controls, rendered content and raster plugin
assets, and removes source execution and form submission. The normal app-data
renderer is unchanged.

Virtual-time pause was rejected after it stalled screenshot capture. Disabling
script execution plus pausing CSS playback allowed two byte-identical source
screenshots per capture. The DOM audit and reference PNG are recorded separately
from the export input. No reference PNG is used to render the export.

The first integrated capture experiment was retained as
`_build/snapshot-baseline-1`. It exposed missing image bytes because Playwright
request routing disables Chromium's HTTP cache. The corrected capture records
image responses explicitly. The complete second baseline was locked before
export at `_build/snapshot-baseline-2/grading-baseline-lock.json`; all iterations
against that baseline retain the same inputs, audits, PNGs and thresholds.
These directories contain private browser data and are intentionally not tracked.

Final page evidence is `_build/snapshot-iteration-6/grades.json`:

| Landing page | Width | Grade | Pixel difference |
| --- | ---: | ---: | ---: |
| beta.mocharymethod.com | 390 | 100% | 0.009946% |
| beta.mocharymethod.com | 768 | 100% | 0.006345% |
| beta.mocharymethod.com | 1440 | 100% | 0.002963% |
| bubble.io | 390 | 100% | 0.061261% |
| bubble.io | 768 | 100% | 0.025673% |
| bubble.io | 1440 | 100% | 0.016065% |

All six views pass every layout, text, typography, image-loading, navigation,
and full-page pixel assertion. All six decoded credential gates pass, and the
exported pages make zero external requests during measurement. Source capture
warnings and unused/unsupported resource findings remain in the manifests;
100% refers to these fixed checks, not zero findings or application equivalence.
The historical app-data result remains 70.53% overall (Mochary 100%, Bubble
41.25/41.72/40.23); its captures and credential gate were not changed.

## Scan boundary

Binary base64 encodings can accidentally contain credential-shaped text. One
AVIF encoding did so, while its decoded bytes did not. The snapshot gate scans
markup, CSS, SVG, decoded asset bytes and provenance. Recognized raster data URLs
are decoded for scanning; their transport encodings are not mistaken for text.
SVG and HTML entity decoding remain inside the gate. Regression coverage checks
both the false-positive case and rejection of credentials in decoded asset bytes.
No detector or threshold was weakened, and no source credential was redacted to
obtain a passing result.

## Reproduction

Install the pinned parser/browser dependencies, then run:

```sh
node scripts/landing/capture-snapshot.cjs NEW_PRIVATE_BASELINE SNAPSHOT_RUNTIME
mix run scripts/landing/export-snapshot.exs PRIVATE_BASELINE NEW_OUTPUT SNAPSHOT_RUNTIME
node scripts/landing/measure-snapshot.cjs NEW_OUTPUT
node scripts/landing/grade.cjs PRIVATE_BASELINE NEW_OUTPUT/comparison.json NEW_OUTPUT/grades.json
```

Use the pinned Linux browser environment for comparisons with this evidence.
The capture command refuses an existing destination and locks its inputs before
export. The grader verifies those hashes on every run. New live captures may
contain different content or animation frames and are separate benchmarks.

The automated local fixture also verifies fetched content, open shadow CSS,
canvas output, frozen CSS animation, inert controls, no external requests, and
byte-identical initial pixels. Parser/security regressions cover SVG references,
untyped Lottie WebP data, source scripts, forms, CSS URLs, and decoded secrets.

## Release validation

- `mix quality`: passed (6 doctests, 768 tests reported, 46 excluded).
- Full pinned Linux fidelity suite: passed, 27 selected checks, including all
  existing frozen cases and the new snapshot integration/security tests.
- Fresh production-package consumer smoke test: passed.
- Regrading historical app-data iteration 44 produced identical assertion
  results and the same 70.53% score.
- Snapshot iteration 6: all six views accepted, all credential gates accepted,
  and zero external requests in every offline page measurement.
