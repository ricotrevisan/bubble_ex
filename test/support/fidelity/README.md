# Frozen-case fidelity gates

Implements [issue #30](https://github.com/ricotrevisan/bubble_ex/issues/30).

A frozen case is the only thing we call visually correct. The suite contains
19 frozen cases: `bpmkbvvo` (#28), `bprkyexk` (#35), `bptaixqv` (#36),
`bpewigqu` (#37), `bpcybc` (#38), `bpqqfagk` (static native controls), and
`bpgwgmpz` (the Issue #42 complex composition), and `bpwipyqn` (#44 BBCode Text), and `bpiordvb` (icon / icon+label Button), and `bpaupfbj` (icon / icon+label Link), and `bpuzekut` (fit-height MultiLineInput), and `bpqkcldq` (date / integer Input), and `bpjehwxg` (decimal / percent / currency / US phone / euro-date Input), and `bpizatjd` (Address Input / DateInput), and `bpoyzixi` (numbers Input / datetime DateInput / FileInput), and `bpdimzwm` (PictureInput), and `bplvejcw` (simple Slider / static Search), and `bpndkqfs` (range Slider / closed Popup), and `bptvorpv` (closed Popup / Group Focus runtime boundaries). The Text cases pin
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

The `:fidelity` tag also runs the generated geometry-style helper's load, resize,
missing/ambiguous-reference, transform, and feedback regression checks. Those
checks use a local synthetic export, not another frozen Bubble reference case.
The same tag checks aspect-ratio Shapes at three viewport sizes in four native
container layouts; that also uses synthetic exports rather than new references.
A synthetic fit-height textarea check covers authored minimum/maximum bounds,
a breakpoint minimum, and clearing its contents after growth.

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
- full-page PNGs satisfy the case's explicit material changed-pixel,
  channel-delta, and mean-absolute-error bounds; omitted bounds default to zero
  material pixel differences
- no scripts / `on*` handlers; exporter ids on correlated nodes
- a11y checks apply only to emitted controls

Pixelmatch 7.1.0 classifies material pixel differences at a zero color
threshold and excludes only detected edge antialiasing from the gated metrics. The
report also records raw changed-pixel, channel-delta, and mean-error telemetry,
so host font-rasterizer drift stays visible without making CI host-dependent.

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

## Input source validation repair (2026-09-10)

The Integer, extra Input formats, Address/DateInput, and numbers/datetime/FileInput
cases were repaired and recaptured from authorized branch `83jop`. Earlier
versions contained invalid Bubble enum values and did not prove the advertised
format support. See [the audit](../../../docs/research/frozen-input-validation-audit.md).
The gate now rejects invalid control enums and compares captured Input values.

References use Linux font metrics. On macOS, use `scripts/fidelity_linux.sh`
from the repository root (Docker required) to run the browser in the pinned
Playwright Linux image. Elixir runs locally. Install the fidelity npm dependencies
first. Platform font-metric differences must not be hidden by geometry tolerances.

For an authorized source recapture, `run.mjs --capture-source URL --case DIR
--report DIR/reference/browser-audit.json` requires `BUBBLE_RECAPTURE=1` and an
exact match with the manifest's source URL. Optional `BUBBLE_CAPTURE_USERNAME`
and `BUBBLE_CAPTURE_PASSWORD` supply origin-scoped HTTP Basic credentials.
Run this measurement on Linux. Review source payload changes and update their
canonical SHA pins separately; this command does not modify payloads or pins.

## Overlay source characterization (2026-09-10)

`bpndkqfs` now preserves the actual source `is_visible: true` Popup definition
and checks that it stays closed; the previous payload had changed that flag.
`bptvorpv` freezes the initial state of valid Popup and Group Focus controls.
Both overlays lower to hidden runtime placeholders. Their source-only interaction
captures do not establish interactive export support. See the
[overlay audit](../../../docs/research/overlay-runtime-audit.md).

Source capture allows absent nodes only when explicitly listed in
`source_hidden_node_ids`, which must be a subset of `node_ids`. A listed node
must be absent or `display:none` with zero dimensions. Duplicate selector matches
fail the source and candidate gates. The overlay experiment independently opens
both controls and confirms their identities before freezing their initial absence.

To repeat the authorized runtime experiment, run
`node test/support/fidelity/characterize-overlays.mjs test/support/fidelity/cases/bptvorpv`
in the pinned Linux x86-64 image with the same environment variables as source
capture. It waits for Bubble's observed animation marker to clear and writes
selected DOM, geometry, and screenshots under `source/runtime/`. It asserts
initial closure, workflow opening/closing, and outside-click dismissal. These
artifacts are not compared to the static candidate.
