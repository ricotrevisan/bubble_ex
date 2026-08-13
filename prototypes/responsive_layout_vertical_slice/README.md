# Responsive-layout vertical slice (PROTOTYPE)

> **Throwaway prototype for [BubbleEx issue #28](https://github.com/ricotrevisan/bubble_ex/issues/28).** This is not the production exporter or a proposed public schema.

## Question

Can an exporter-owned normalized page model compile to readable semantic HTML and static Flexbox/Grid/media-query CSS across responsive transitions, without a generated JavaScript layout runtime?

This branch answers the **CSS-expressiveness** part with one synthetic product page. It does **not** establish visual equivalence with Bubble: issue #24 defined a controlled-capture contract, but the repository contains no authorized frozen Bubble capture to use as an independent reference. Treat the result as a feasibility spike and the missing capture as a hard evidence gate.

## Run

From this directory:

```bash
./run.sh
```

The command installs pinned Playwright Chromium if needed, then:

1. renders `normalized-page.json` with the deliberately shallow `render.exs`;
2. writes static `dist/index.html` and `dist/styles.css`;
3. opens the result with JavaScript-free output at every declared viewport;
4. performs DOM, semantics, geometry, overflow, and layout-mode assertions; and
5. writes full-page screenshots plus `evidence/browser-audit.json`. `evidence/comparison-status.json` separately records why no Bubble-vs-candidate mismatch comparison is claimed and which architecture findings survive the spike.

The generated page itself has no runtime dependency and can also be opened directly:

```bash
xdg-open dist/index.html
```

## Slice

The 50-node fixture exercises:

- Page and nested Group containers;
- Column, Row, Align-to-Parent, and Fixed layout modes;
- natural responsive Row wrapping plus base Column containers;
- hidden-and-collapsed navigation;
- a centered, max-width-clamped content shell;
- overlapping decoration and locally positioned children;
- explicit `h1`/`h2`/`h3`, links, buttons, and email input semantics; and
- natural text wrapping and intrinsic page-height changes.

The renderer maps Row/Column to Flexbox, Align-to-Parent to a layered 3×3 CSS Grid alignment plane, Fixed to a local positioned containing block, and resolved visibility/box deltas to media queries. The hero keeps Row mode and wraps naturally from child sizing constraints; the fixture does not assume that Bubble container mode is conditionally mutable. It does not execute workflows, conditions, expressions, plugins, or layout JavaScript.

The fixture is intentionally narrow. Its `source` fields are traceability examples, not claims that the synthetic page came from a Bubble payload. Box/style values remain prototype-level and are not a substitute for the layered/provenance-bearing normalized contract decided in issue #25.

## Predeclared viewport matrix

Viewport height is 900 CSS px, DPR 1, pinned Chromium 140.0.7339.16. Full-page screenshots are captured at:

| Width | Reason |
|---:|---|
| 390 | representative narrow page |
| 767 / 768 / 769 | immediately below, at, and above the 768 px visibility/box-rule transition |
| 795 / 796 / 797 | immediately below, at, and above the natural hero Row wrap transition |
| 1151 / 1152 / 1153 | immediately below, at, and above the 1120 px shell + 32 px gutter clamp |
| 1440 | representative wide page |

All widths must satisfy:

- exactly one expected semantic element at each checked seam;
- no `<script>` or inline event handlers;
- no horizontal page overflow;
- source order remains `hero-copy`, then `hero-visual`;
- Row remains Row while wrap line assignment changes at 796 px; collapse state changes at 768 px;
- shell width within 1 CSS px of `min(1120px, viewport - 32px)`;
- Align-to-Parent compiles to Grid; Fixed children are positioned inside a local containing block; and
- narrow children stack while wide hero children remain center-aligned.

## Result

All eleven browser audits pass. The static output shows that this representative combination is expressible without a JavaScript layout runtime.

That result is **not a Bubble parity score**. A yes/no visual-equivalence verdict requires the missing authorized capture bundle: frozen app/version identity, payload hash, source-to-element mapping, DOM, selected computed styles and bounds, fonts/assets, screenshots, browser/DPR, and captures at behavior-derived widths. The synthetic screenshots cannot serve as their own independent oracle.

## Architecture observations to carry forward

1. Layout compilation is parent-contextual: a child placement means different CSS under Row, Column, Align-to-Parent, and Fixed parents.
2. Align-to-Parent needs a shared layering/alignment plane and an explicit stacking contract; a nine-cell enum alone does not explain collisions.
3. Fixed children need a guaranteed local containing block and explicit parent height because absolute children do not contribute intrinsic size.
4. Responsive conditions need ordered, inclusive boundary semantics. The 767/768/769 visibility discontinuity and the independent 795/796/797 natural-wrap transition are intentional and testable.
5. Hidden-and-collapsed must remain distinct from visually hidden; `display: none` also changes parent gaps and intrinsic size.
6. Semantic tag choice is independent of layout mode. Generic Groups remain neutral even when their CSS changes.
7. Exact text wrapping and resulting document height depend on frozen font metrics; image crop parity likewise depends on frozen assets and focal-point metadata.
8. The production model must preserve sizing intent, style layers/provenance, unresolved rules, source refs, and unsupported data rather than the prototype's final CSS-like box values.
9. If an authorized reference exposes parent-size conditions, intrinsic-size feedback, or runtime measurement, first test container queries/static CSS; do not silently add a generated layout runtime.

## Stop condition

Do not close issue #28 with a claim of “acceptable visual equivalence” from this artifact alone. Resume at the independent-reference seam, then compare source-correlated DOM/geometry first and screenshots second. A local mapping defect can change this renderer; a repeated mismatch requiring a new sizing, anchoring, visibility, precedence, or asset distinction must change the normalized architecture or narrow support.
