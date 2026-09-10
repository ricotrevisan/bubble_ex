# Popup and Group Focus runtime audit — 2026-09-10

The authorized app is `tiptap-plugin`, branch `83jop` (`bubble-ex`). The audit
adds only `bubbleex-overlay-boundaries` and its three element-only workflows
on that branch. Test and Live were not changed.

## Finding

The previous library code mapped a Popup's `is_visible: true` to `<dialog open>`
and mapped a static Group Focus to an ordinary visible `div`. Neither mapping
reproduces Bubble's initial overlay state or its interaction behavior.

The existing `bpndkqfs` range/Popup case excluded the popup from correlated nodes.
Its frozen payload also replaced the actual source's `is_visible: true` with
false. That case did not prove visible Popup support. The repaired case now
retains the unmodified selected source page and explicitly correlates the popup's
initial absence. Its slider is correlated with the unique `.bubble-element.SliderInput`
selector because Bubble omits that control's ID class in the runtime DOM.

Bubble's [Popup guide](https://manual.bubble.io/help-guides/design/elements/web-app/containers/popups)
says a popup requires a workflow action to open. Its
[Group Focus guide](https://manual.bubble.io/help-guides/design/elements/web-app/containers/group-focus)
describes reference-relative placement and outside-click dismissal. The controlled
experiment below independently reproduces these behaviors.

## Controlled source experiment

Case [`bptvorpv`](../../test/support/fidelity/cases/bptvorpv/case.json) contains
one Popup, one Group Focus referencing a button, and actions to show/hide the
Popup and toggle Group Focus. No data writes, account changes, or API calls are
part of those workflows. The source came from a fresh Buildprint snapshot after
`buildprint check` returned zero diagnostics for the four authored files and
`buildprint apply` succeeded on `83jop`.

The native browser automation surface had no accessible Brave window during
this follow-up (`cgWindowNotFound`). Source/compiler validation is not described
as a zero-issue Bubble editor check. The user had confirmed the earlier seven
input issues were fixed before this experiment began.

The pinned headless source harness uses Playwright 1.55.1 / Chromium
140.0.7339.186 on Linux x86-64, DPR 1, en-US, reduced motion, at 390×900 and
1440×900. It waits for Bubble's `velocity-animating` marker to clear before each
observation. HTTP Basic credentials stay in the environment and are scoped to
the authorized app origin.

| State | Observed source behavior at both widths |
|---|---|
| Initial | Popup and Group Focus have no DOM nodes |
| Popup shown | Popup is 320×110, horizontally centered, `position:fixed`, top 100px; backdrop shown |
| Popup hidden | Existing Popup DOM has `display:none` and a zero rectangle |
| Focus shown | Group Focus is 240×58 at x=16, y=196, `position:absolute`; placement follows its reference and configured offsets |
| Outside click | Group Focus becomes `display:none` with a zero rectangle |

The [source runtime observations](../../test/support/fidelity/cases/bptvorpv/source/runtime/observation.json)
include selected DOM, rectangles, and five screenshots per width. They prove the
fixture actually opens and dismisses both controls. They do not claim that a
static export executes these actions.

## Library correction

Popup and Group Focus now normalize to `:runtime_overlay` placeholders. They
retain authored box/style metadata and their entire source container, including
children and local workflows, in the placeholder binding. The full app payload
continues to preserve page workflows. Export findings explicitly say that
opening and dismissal require the Bubble runtime. HTML emits a hidden placeholder,
and CSS keeps it out of flow; no static dialog or misleading visible menu is emitted.

This narrows support rather than implementing a runtime adapter. Workflow-open
states, focus management, modal backdrops, responsive overlay placement, and
outside-click dismissal remain unsupported in the exported HTML/CSS. An app
that opens an overlay on page load still needs a runtime adapter; these frozen
cases cover the initial state of pages that do not do that.

The old renderer failed the new independent frozen reference at both widths:
Group Focus appeared in flow and shifted all three visible controls/text nodes
down by 70px. There were ten fidelity mismatches, including collapse and pixels.
Three focused unit/export regressions also failed before the correction.

The corrected new case has exact geometry, typography, document dimensions, and
four closed-overlay samples, with zero material pixel tolerance. The range case
retains its existing explicit slider-paint tolerance; no geometry or collapse
tolerance was introduced. Source capture now permits absent nodes only through
an explicit hidden-node list and rejects ambiguous selectors.

The complete range source also restored styling omitted by the old simplified
payload. Bubble's measured outer SliderInput box is transparent and borderless;
it applies configured border/background paint to its inner track and handles.
The exporter now keeps that wrapper transparent instead of adding a rounded
white panel. This restores the existing slider tolerance without increasing it.
The paired native controls remain an explicitly approximate static lowering.

The stricter ambiguity check exposed one invalid historical correlation in
`bpgwgmpz`: `bpcjyrzr` is a shared icon definition ID rendered by two reusable
instances. The previous runner treated multiple matches as "absent" and accepted
that as collapse. This ID was removed from singular geometry/collapse sampling,
with an explicit `uncorrelated_nodes` explanation in the manifest. Its source
payload, full-page PNGs, instance-wrapper geometry, and decorative semantics
remain unchanged. A structural assertion now requires both emitted decorative
icons. Individual icon geometry still needs instance-scoped source correlation.

## Reproduction and release checks

The corpus and interaction harness are described in the
[fidelity README](../../test/support/fidelity/README.md). Source payload and font
hashes are pinned in each manifest. CI compares only committed initial-state
references and does not contact Bubble.

Run `mix quality`, `scripts/fidelity_linux.sh`, and
`scripts/package_consumer_smoke.sh`. The current
[support matrix](native-element-support-matrix.md) replaces stale planning tiers
with actual static lowerings, their frozen evidence, and remaining limitations.
