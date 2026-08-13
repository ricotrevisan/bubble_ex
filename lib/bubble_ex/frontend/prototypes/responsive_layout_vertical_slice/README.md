# Responsive-layout vertical slice (PROTOTYPE)

> **Throwaway prototype for [BubbleEx issue #28](https://github.com/ricotrevisan/bubble_ex/issues/28).** This is not the production exporter or a proposed public schema.

## Verdict

A controlled 48-node Bubble page was hand-normalized from authored source facts and rendered as semantic HTML plus static Flexbox/Grid/media-query CSS. Against the frozen Bubble reference, the candidate is **pixel-identical at all 26 declared viewport widths**. The generated page has no JavaScript runtime, script tag, or inline event handler.

This settles the issue's vertical-slice question positively for the exercised subset. It does not claim that arbitrary Bubble pages are supported, and it does not turn the prototype model into a production contract.

## Controlled reference

- App/branch: `tiptap-plugin` / `test`
- Page/path: `bpmkbvvo` / `/version-test/bubbleex-i28-responsive-slice`
- Sanitized URL: `https://tiptap-plugin.bubbleapps.io/version-test/bubbleex-i28-responsive-slice`
- Decoded page payload SHA-256: `706f73ef49c170ab077bfe680403782f5dea94ba36ea5cae3c3878079340701b`
- Chromium: 140.0.7339.16, DPR 1, locale `en-US`, reduced motion, 900 CSS-pixel viewport height
- Font asset: Inter Latin WOFF2, SHA-256 `3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62`

The app and page use private HTTP basic auth. Credentials are not stored here. Captures contain only deterministic public fixture content.

## Run

Candidate render and structural audit:

```bash
./run.sh
```

The command renders `normalized-page.json`, installs pinned Playwright Chromium when needed, audits 26 viewports, and writes candidate screenshots plus `evidence/browser-audit.json`.

Reference capture requires credentials supplied only through the environment:

```bash
BUBBLE_BASIC_USER=... BUBBLE_BASIC_PASSWORD=... \
  npx --yes -p playwright@1.55.0 -c \
  'PW_BIN=$(command -v playwright); NODE_PATH=$(dirname "$(dirname "$PW_BIN")") node capture-reference.cjs'
```

Then capture the local candidate and compare:

```bash
npx --yes -p playwright@1.55.0 -c \
  'PW_BIN=$(command -v playwright); NODE_PATH=$(dirname "$(dirname "$PW_BIN")") node capture-candidate.cjs'
node compare.cjs
```

`compare.cjs` checks source-correlated geometry, typography, collapse behavior, document height, and PNG byte identity.

## Source discipline

`normalized-page.json` is hand-normalized only from the decoded page payload and Buildprint source, including `__bp_layout__` sidecars for otherwise-lost fixed heights. It does not copy computed DOM bounds or CSS declarations into the model. Every normalized node retains its Bubble token and source name/path.

The source includes:

- Page and Group Column/Row layouts;
- naturally wrapping Hero, feature-card, and CTA Rows;
- an inclusive `Current Page Width <= 768` hidden-and-collapsed nav rule;
- a 1120 px centered max-width clamp;
- Align-to-Parent top-right/center/bottom-left overlap and stacking;
- a nested 196×92 Fixed canvas with local XY children;
- text, headings, label-only buttons, and an email input; and
- deterministic paint, typography, gradient, border, shadow, rotation, and font facts.

No workflow, dynamic data, custom state, plugin element, authenticated asset, or custom JavaScript exists on the fixture page.

## Predeclared viewport matrix

The matrix samples representative narrow/wide states and every actual transition at `b-1`, `b`, and `b+1`:

| Widths | Transition |
|---:|---|
| 390 | representative narrow page |
| 483 / 484 / 485 | CTA input and button join one line |
| 615 / 616 / 617 | feature cards move from one to two columns |
| 637 / 638 / 639 | CTA copy and input share the first line |
| 767 / 768 / 769 | inclusive nav collapse boundary |
| 775 / 776 / 777 | hero children move from stacked to one line |
| 783 / 784 / 785 | CTA becomes one flex line |
| 919 / 920 / 921 | feature cards move from two to three columns |
| 1151 / 1152 / 1153 | 1120 px shell clamp |
| 1440 | representative wide page |

At all 26 widths:

- all 1,200 source-correlated geometry samples have 0 CSS-pixel error;
- selected typography is exact;
- document heights are exact;
- hidden/collapsed state agrees at the inclusive boundary;
- screenshots are byte-identical PNGs; and
- the candidate has no horizontal overflow.

## Mismatches and architecture implications

The final mismatch list is empty. During comparison, five local renderer/model defects were exposed and corrected:

1. **Distinct Row gaps are required.** Collapsing Bubble `row_gap` and `column_gap` into one generic gap changed natural transitions.
2. **Fill width is `width + flex-grow`, not zero-basis shorthand.** `flex: 1 1 0` redistributed CTA and hero space differently from Bubble's `width`, `flex-grow: 1`, `flex-basis: auto` behavior.
3. **Row cross-axis defaults are not CSS stretch.** Bubble's default `align-items: normal` preserves independently sized cards; forcing stretch changed wrapped-line card heights.
4. **Explicit single-default heights survive normalization.** The Buildprint layout sidecars were necessary for nav item and local Fixed heights.
5. **The exact font bytes and placeholder color are geometry/paint inputs.** Freezing Inter removed text-wrap differences; normalizing placeholder color removed the final pixel mismatch.

These are narrow, evidence-backed rules for future production modeling. They do not justify flattening source provenance or unknown values, and they do not justify adding a generated measurement runtime.

## Stop condition

The prototype answers issue #28. Production work must still define a durable normalized model and production renderer around the proved subset, preserve source provenance and explicit/unset state, and narrow unsupported cases rather than silently introducing runtime layout JavaScript.
