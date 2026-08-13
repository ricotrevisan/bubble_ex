# Responsive-layout vertical slice

- **Decision date:** 2026-08-13
- **Issue:** [#28 — Prove responsive layout translation with a vertical slice](https://github.com/ricotrevisan/bubble_ex/issues/28)
- **Prototype:** [`b55b34a`](https://github.com/ricotrevisan/bubble_ex/tree/b55b34ad93d5644985437bda7e2c2ff7d2b9014a/lib/bubble_ex/frontend/prototypes/responsive_layout_vertical_slice) on the throwaway `prototype/issue-28-responsive-layout` branch
- **BubbleEx baseline:** [`c2df366`](https://github.com/ricotrevisan/bubble_ex/tree/c2df36680b8726dafae7dde8683c2c6aa77a3f5b)

## Verdict

**Static-CSS feasibility: yes. Bubble visual equivalence: not yet proven.**

The prototype deterministically renders one 50-node synthetic normalized page into semantic HTML and static CSS. It exercises Page/Group nesting, all four modern layout concepts, a responsive visibility rule, natural Row wrapping, a max-width clamp, overlaps, local Fixed coordinates, and native text/link/button/input semantics. Row and Column compile to Flexbox, Align-to-Parent to a layered Grid alignment plane, Fixed to a local positioned containing block, and resolved viewport deltas to media queries. The emitted page contains no script or inline event handler.

All eleven declared browser audits pass. This proves that the representative **exporter-owned layout combination** is expressible with HTML/CSS and no generated layout runtime.

It does not prove “acceptable visual equivalence” with Bubble. Issue #24 settled the controlled-capture contract but this repository still has no frozen authorized Bubble capture containing payload identity, source-correlated DOM, computed styles/bounds, fonts/assets, and screenshots. The synthetic candidate cannot be its own independent oracle. The prototype therefore records comparison status as `blocked_missing_authorized_reference` rather than manufacturing a parity score.

## What the prototype contains

The throwaway branch preserves the complete primary source:

- `normalized-page.json` — deliberately narrow prototype input with illustrative source refs;
- `render.exs` — shallow normalized fixture → HTML/CSS compiler;
- `dist/index.html` and `dist/styles.css` — generated static output;
- `verify.cjs` and `run.sh` — one-command pinned-browser validation;
- `evidence/browser-audit.json` — DOM, geometry, layout, overflow, and semantic results;
- eleven full-page screenshots; and
- `evidence/comparison-status.json` — the missing-oracle blocker and architecture findings.

The fixture is not the public normalized schema decided by issue #25. Its CSS-ready box/style values deliberately avoid pretending that the unresolved production schema has already been designed.

## Viewport matrix and results

All captures use Chromium 140.0.7339.16, a 900 CSS-pixel viewport height, DPR 1, and full-page screenshots.

| Width | Seam | Result |
|---:|---|:---:|
| 390 | representative narrow page | pass |
| 767 / 768 / 769 | immediately below, at, and above the visibility/box-rule boundary | pass |
| 795 / 796 / 797 | immediately below, at, and above natural Row wrap | pass |
| 1151 / 1152 / 1153 | immediately below, at, and above the 1120 px shell + 32 px gutter clamp | pass |
| 1440 | representative wide page | pass |

At every width the validator confirms:

- one expected semantic node at each checked seam;
- stable source order and correct wrap/collapse state;
- no script, inline handler, or horizontal page overflow;
- shell width within 1 CSS px of `min(1120px, viewport - 32px)`;
- Grid output for Align-to-Parent;
- a local containing block and local absolute coordinates for Fixed children; and
- expected narrow stacking or wide center alignment.

These are candidate-contract checks, not Bubble-vs-candidate visual comparisons.

## Architecture-affecting findings

No Bubble-to-candidate mismatch was measured because the independent reference is absent. The spike nevertheless exposed requirements that must survive normalization and be tested against the eventual capture:

1. **Placement is parent-contextual.** The same child fields mean different output under Row, Column, Align-to-Parent, and Fixed. Layout planning needs parent mode and ordered siblings, not isolated node rendering.
2. **Align-to-Parent needs an overlap contract.** A nine-cell pin is insufficient without explicit size, offset, collision, and stacking behavior. A shared Grid alignment plane is plausible, not yet a parity rule.
3. **Fixed needs a wrapper invariant.** The parent must establish a local containing block and an explicit intrinsic-size policy because positioned children do not size it.
4. **Rule boundaries and natural transitions are independent.** Ordered/inclusive viewport predicates must remain distinct from emergent wrap and min/max transitions; the prototype intentionally separates 768 px visibility from 796 px wrapping.
5. **Collapse is not generic invisibility.** Hidden-and-collapsed changes gaps and intrinsic size, while hidden-with-space must preserve them.
6. **Semantics and layout are separate.** A Group changing layout does not acquire a landmark or interactive role. Element intent chooses the HTML tag.
7. **Assets affect geometry.** Exact text wrapping requires frozen font metrics; exact image crop requires frozen bytes, intrinsic dimensions, and focal-point metadata.
8. **The production model cannot flatten early.** Preserve sizing intent, explicit/unset state, min/max/fit behavior, ordered style layers and provenance, unresolved rules, source refs, and unknown values instead of only final CSS declarations.
9. **Static CSS remains the constraint.** If the controlled reference exposes parent-size predicates or intrinsic-size feedback, test container queries and static CSS before narrowing support. Do not add a generated measurement/resize runtime merely to pass the prototype.

## What remains before issue #28 can claim parity

1. Publish or identify one authorized, public, credential-free modern Bubble conformance page.
2. Freeze its app version, decoded payload hash, assets/fonts, browser environment, and source-to-case IDs.
3. Capture DOM, selected computed styles, bounds, scroll dimensions, and screenshots at behavior-derived widths, including `b-1`, `b`, and `b+1` around every actual transition.
4. Hand-normalize only captured source facts, retaining raw source refs and unknowns; do not copy computed output into the model.
5. Run the same candidate capture twice, compare structure/geometry first and screenshots second, and record every mismatch as a local mapping defect, model change, wrapper invariant, asset contract, support narrowing, or evidence defect.

Until that oracle exists, keep issue #28 open and use this prototype only as evidence that the static HTML/CSS architecture is technically plausible.
