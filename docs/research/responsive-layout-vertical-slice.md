# Responsive-layout vertical slice

- **Decision date:** 2026-08-13
- **Issue:** [#28 — Prove responsive layout translation with a vertical slice](https://github.com/ricotrevisan/bubble_ex/issues/28)
- **Prototype:** [`324c300`](https://github.com/ricotrevisan/bubble_ex/tree/324c300e6229428028ae89c10d75fcd367bc1506/lib/bubble_ex/frontend/prototypes/responsive_layout_vertical_slice) on `prototype/issue-28-responsive-layout`
- **Controlled Bubble page:** `tiptap-plugin` Test page `bpmkbvvo` at the sanitized path `/version-test/bubbleex-i28-responsive-slice`
- **BubbleEx baseline:** [`c2df366`](https://github.com/ricotrevisan/bubble_ex/tree/c2df36680b8726dafae7dde8683c2c6aa77a3f5b)

## Verdict

**Yes for the exercised vertical slice.**

One controlled 48-node modern Bubble page was hand-normalized from authored source facts and rendered as semantic HTML plus static Flexbox/Grid/media-query CSS. The generated page contains no script tag, inline event handler, or generated layout runtime.

Against the frozen Bubble reference, the candidate is pixel-identical at all 26 declared viewport widths. The comparison covers 1,200 source-correlated geometry samples, selected computed typography, collapsed navigation, document height, and full-page PNG bytes.

This proves acceptable visual equivalence for the representative subset exercised here. It does not claim arbitrary Bubble-page support and does not promote the prototype model to a production schema.

## Controlled evidence

The dedicated conformance page exists only on the authorized `tiptap-plugin` Test branch. No existing page, workflow, data type, plugin, setting, Live branch, or app data was changed. A Buildprint savepoint preceded the page edit.

Evidence identity:

- page ID: `bpmkbvvo`;
- page payload SHA-256: `706f73ef49c170ab077bfe680403782f5dea94ba36ea5cae3c3878079340701b`;
- sanitized URL: `https://tiptap-plugin.bubbleapps.io/version-test/bubbleex-i28-responsive-slice`;
- browser: Chromium 140.0.7339.16, DPR 1, locale `en-US`, reduced motion, viewport height 900;
- frozen Inter Latin WOFF2 SHA-256: `3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62`.

Credentials, editor cookies, and unrelated app payloads are not committed. The captured page is deterministic and contains only literal fixture content: no workflow, dynamic data, custom state, plugin element, authenticated asset, or custom JavaScript.

## Viewport matrix and result

Every actual transition is sampled at `b-1`, `b`, and `b+1`:

| Widths | Observed transition | Result |
|---:|---|:---:|
| 390 | representative narrow page | identical |
| 483 / 484 / 485 | CTA input and button join one line | identical |
| 615 / 616 / 617 | feature cards move from one to two columns | identical |
| 637 / 638 / 639 | CTA copy and input share the first line | identical |
| 767 / 768 / 769 | inclusive hidden-and-collapsed nav boundary | identical |
| 775 / 776 / 777 | hero children move from stacked to one line | identical |
| 783 / 784 / 785 | CTA becomes one flex line | identical |
| 919 / 920 / 921 | feature cards move from two to three columns | identical |
| 1151 / 1152 / 1153 | 1120 px shell clamp | identical |
| 1440 | representative wide page | identical |

The final comparison reports:

- 26 of 26 byte-identical candidate/reference PNG pairs;
- maximum geometry error 0 CSS px across 1,200 samples;
- exact selected typography and document heights;
- exact inclusive nav collapse behavior; and
- no candidate horizontal overflow.

## Architecture-affecting mismatches found and resolved

The final mismatch list is empty, but comparison exposed five evidence-backed defects in the synthetic mapping:

1. **Preserve Row gaps separately.** Bubble `row_gap` and `column_gap` cannot be flattened into one generic gap without changing natural wrap behavior.
2. **Lower Fill width with auto basis.** Bubble Fill behaves as authored width plus `flex-grow: 1` and auto basis. `flex: 1 1 0` redistributed CTA and hero space incorrectly.
3. **Do not force CSS stretch.** Bubble Row's default cross-axis behavior preserved independent card heights; unconditional `align-items: stretch` changed wrapped-line geometry.
4. **Retain explicit-default and sidecar sizes.** Buildprint `__bp_layout__` provenance supplied otherwise-lost nav and nested Fixed heights. Discarding that information made exact local XY layout impossible.
5. **Freeze font and placeholder paint.** Exact Inter bytes fixed line wrapping and page height; the authored placeholder color was the final screenshot mismatch.

The earlier architecture findings still stand: child placement is parent-contextual; Align-to-Parent needs an overlap/stacking plane; Fixed needs a local containing block and explicit size; ordered viewport rules differ from natural transitions; hidden-and-collapsed differs from invisibility; semantics stay separate from layout; assets are geometry inputs; and production normalization must preserve intent/provenance/unknowns instead of flattening early.

## Decision

Close issue #28 as proved for this declared subset. Follow-up production work should design the durable normalized model and renderer around these rules, keep static CSS as the constraint, and narrow unsupported behavior rather than introducing a generated measurement/resize runtime.
