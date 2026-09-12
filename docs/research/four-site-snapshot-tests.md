# Four additional browser snapshot page tests

Tested the four user-authorized anonymous landing pages on 2026-09-11.
BetterLegal redirects normally from `https://betterlegal.bubbleapps.io/` to
`https://app2.betterlegal.com/`. No login, form submission, source-app changes,
or link crawling was performed.

## Fixed checks and final results

Used the unchanged six categories and thresholds in
[the landing-page rubric](landing-page-grading.md): full-page pixels, correlated
geometry, text, typography, visible assets, and navigation. Each view uses
390/768/1440 × 900, DPR 1, en-US, reduced motion, Playwright 1.55.1 and Chromium
140.0.7339.186 on Linux amd64. Full-page pixel difference must be at most 1%;
geometry tolerance is 2 pixels. No masks, cropping, resizing, or excluded
failing elements were introduced. The source PNG is never an exporter input.

| Page | 390 grade | 768 grade | 1440 grade | Pixel difference at 390 / 768 / 1440 |
| --- | ---: | ---: | ---: | --- |
| BetterLegal | 100% | 100% | 100% | 0.015216% / 0.007313% / 0.005993% |
| app.voicediq.com | 100% | 100% | 100% | 0% / 0% / 0% |
| assistra.ai | 100% | 100% | 100% | 0.012735% / 0.007215% / 0.001549% |
| kroki-pay.bubbleapps.io | 100% | 100% | 100% | 0.064893% / 0.043387% / 0.029181% |

All twelve final views pass every assertion, the normal decoded credential
publication gate, and the zero-external-request check. The six original Mochary
and Bubble snapshot views also remain 100% against their original locked inputs,
with identical pixel differences. Findings still report unused or unsupported
resources and source-page errors; a passing grade does not mean zero findings,
working Bubble workflows, or correctness for every possible source state.

## Defects found and fixed

- **Inactive tracking fallbacks painted in source screenshots.** Disabling script
  execution in Chromium can reveal raw body `noscript` text during painting even
  when the DOM audit still reports the original geometry. Keeping these fallbacks
  hidden preserves the JavaScript-enabled initial appearance. A local fixture
  reproduced the contradiction (marker y=0, but its top-left pixel was not red)
  and now verifies the DOM and pixels agree.
- **Reversed stylesheet precedence.** MHTML hoists inline styles ahead of linked
  styles, allowing Bubble's reset CSS to override later plugin styling. Capture
  now records the CSSOM cascade order, media/disabled state and adopted sheets;
  export restores that order and sanitizes the CSS. This fixes Assistra's spacing
  and icons and Kroki's hidden tracking-frame layout.
- **Embedded document state and local assets.** Each embedded frame receives the
  same preparation as the main page and is correlated through its MHTML frame ID.
  A non-opaque sandbox origin allows its local CSS, fonts and images to load when
  opening the export from disk. Source scripts remain removed and each document
  receives its own restrictive CSP. Kroki's YouTube previews remain HTML and local
  image assets; no full-page or iframe screenshot fallback was needed.
- **Missing scroll offsets.** Assistra's scrolling row retained its DOM but lost
  `scrollLeft`. Captured scroll offsets now use a fixed library initializer that
  runs initially and once after load. Values stay in data attributes, never code.
  CSP permits only the initializer's SHA-256 hash; it introduces no workflows,
  network access, timers, or source handlers.
- **CSS raw-text safety.** Restored CSS escapes `</style` terminators, preventing
  serialized CSS strings from introducing new HTML. A regression verifies the
  resulting document contains only the generated CSP meta element. Original
  decoded CSS, including removed comments, remains inside the credential gate.
- **Malformed navigation.** Capture marks invalid source destinations before
  MHTML can rewrite them into a valid-looking homepage URL. Export leaves these
  anchors without a destination and reports `invalid_navigation`. It does not
  invent a destination or repair the site's review data.

## Evidence history and source limitations

Private evidence lives under `_build/four-site-snapshot/` and is not committed:

1. `baseline-1` retained eleven captures and a failed Voicediq mobile acquisition.
   `baseline-2` completed only that missing acquisition and verified all eleven
   previous inputs and PNGs were byte-identical. `iteration-2` scored **86.39%**.
2. That first benchmark demonstrated a capture defect: BetterLegal and Kroki's
   reference PNGs showed inactive fallback text that was absent from both their
   initial page layout and captured DOM. After reproducing and fixing the capture
   pipeline, `baseline-3` was acquired and locked before export. Earlier inputs,
   scores, and failures were retained. Live database content can differ between
   separate captures, so these are distinct paired benchmarks.
3. `baseline-3` had one unstable Voicediq desktop screenshot pair. Both subsequent
   production captures were stable. `baseline-4` uses the **first** follow-up,
   captured before exporting either follow-up, and verifies the other eleven
   inputs/PNGs are byte-identical to `baseline-3`. The failed acquisition remains
   recorded in `baseline-3`; `iteration-3` therefore scores **91.66%**, including
   zero for its missing stable source. `iteration-4/grades.json` is the final
   completed benchmark, with its immutable input hashes and all assertions.
4. `previous-six-export/grades.json` replays the original six snapshot inputs.
   The generic grader also reproduced their pre-change assertion results. The
   historical app-data renderer and its earlier 70.53% benchmark are unchanged.

One earlier Kroki tablet source state supplied `href="//"` for a randomly selected
review. Its navigation failure remains in the original benchmark. The current
captured reviews contain valid destinations and pass. This is a source-data
limitation, not evidence that every future review link will work. No source data
or reference link was repaired to obtain the final grade. Likewise, the stable
final captures do not erase the two recorded acquisition failures.

## Reproduction

The capture harness now accepts an optional JSON file of unique `[slug, URL]`
pairs; omitting it still selects the original Mochary and Bubble pages:

```json
[
  ["betterlegal", "https://betterlegal.bubbleapps.io/"],
  ["voicediq", "https://app.voicediq.com/"],
  ["assistra", "https://assistra.ai/"],
  ["kroki-pay", "https://kroki-pay.bubbleapps.io/"]
]
```

```sh
node scripts/landing/capture-snapshot.cjs NEW_PRIVATE_BASELINE SNAPSHOT_RUNTIME sites.json
mix run scripts/landing/export-snapshot.exs PRIVATE_BASELINE NEW_OUTPUT SNAPSHOT_RUNTIME
node scripts/landing/measure-snapshot.cjs NEW_OUTPUT
node scripts/landing/grade.cjs PRIVATE_BASELINE NEW_OUTPUT/comparison.json NEW_OUTPUT/grades.json
```

Use the pinned Linux browser environment for matching results. The harness
records per-view failures and continues the batch; failed views remain failures
in the grade. New unstable acquisitions retain both PNGs and private capture data
under `failed/` for diagnosis. Every accepted capture is locked before export.
