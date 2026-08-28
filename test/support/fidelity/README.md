# Frozen-case fidelity gates

Implements [issue #30](https://github.com/ricotrevisan/bubble_ex/issues/30).

A frozen case is the only thing we call visually correct. The suite contains
seven frozen cases: `bpmkbvvo` (#28), `bprkyexk` (#35), `bptaixqv` (#36),
`bpewigqu` (#37), `bpcybc` (#38), `bpqqfagk` (static native controls), and
`bpgwgmpz` (the Issue #42 complex composition). The Text cases pin
exporter-owned `<p>` and heading semantics without comparing tags to Bubble.
The Issue #42 case also pins two portable pages, nested reusable expansion, a
local image/font/icon set, an always-visible Floating Group, and the intentional
Repeating Group runtime boundary. PR CI renders candidates through
`BubbleEx.Frontend.export_payload/3` against **committed** references. It never
talks to live Bubble.

## Run

```bash
cd test/support/fidelity && npm ci && npx playwright install chromium
mix test --only fidelity
# or
mix bubble.fidelity
```

`mix quality` does not run the browser gate (no Playwright required locally).

## What a pass means

Under the pinned browser (Playwright 1.55.1, Chromium 140.0.7339.186, DPR 1,
`en-US`, reduced motion, case-declared viewport height, and an Inter SHA pinned
in `case.json`):

- the canonical decoded source payload and local font bytes match pinned SHA-256 values
- geometry is exact on every correlated sample
- selected primary typography is exact; fallback-list spelling is normalized
- document `scrollHeight`, `clientWidth`, and `scrollWidth` match the source
- collapse is behavioral (reference absent ⇒ candidate 0×0)
- every present reference node exists on the candidate
- full-page PNGs satisfy the case's explicit changed-pixel, channel-delta, and
  mean-absolute-error bounds; omitted bounds default to byte-equivalent pixels
- no scripts / `on*` handlers; exporter ids on correlated nodes
- a11y checks apply only to emitted controls

Pixel allowances are quantitative and must include a rationale in `case.json`.
They cover pinned-browser raster behavior only. They do not weaken geometry,
typography, presence, collapse, document-size, or semantic checks. Intentional
source overflow, such as Issue #42's 416px document at a 390px viewport, must be
reproduced rather than rejected.

## Latest authorized live review

On 2026-08-18, the original five frozen cases were recaptured from the
authorized Bubble Test app at all 34 declared viewports with Chromium
140.0.7339.16. Every live PNG was byte-identical to its committed reference,
and all tracked geometry and typography values were exact. No references moved.
The gate now uses the security-patched Playwright 1.55.1 / Chromium
140.0.7339.186 pair; the full suite passes its explicit geometry and pixel
bounds without moving those source references.

On 2026-08-28, `bpgwgmpz` was captured from the authorized Issue #42 controlled
fixture at 390×844 and 1512×844 with the same pinned browser. The frozen payload
is credential-free and exports only the two selected pages. The static-controls
case was also reconciled with the current authorized source/font evidence rather
than preserving stale text metrics; three runtime IDs that Bubble regenerated
retain their original authorized computed-style records and are covered by the
current byte-identical full-page screenshots.

## How references move

- **Exporter-intentional change:** the same PR updates exporter-owned snapshots
  (`case.json` semantics) and, if pixels move, the review is the PNG/report
  diff. Do not silently refresh Bubble references.
- **Bubble / browser / font recapture:** authorized live recapture only.
  `mix bubble.fidelity --recapture` is refused unless `BUBBLE_RECAPTURE=1`,
  and even then this tree does not fetch live Bubble. Recapture is required
  before a slice-complete claim or exporter release.
