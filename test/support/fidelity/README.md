# Frozen-case fidelity gates

Implements [issue #30](https://github.com/ricotrevisan/bubble_ex/issues/30).

A frozen case is the only thing we call visually correct. The suite contains
only frozen cases; today that is `bpmkbvvo` (the #28 page), `bprkyexk`
(the #35 Image modes page), `bptaixqv` (the #36 text-only Link page), and
`bpewigqu` (the #37 Text/Password Input page). Their explicit `normal` Text
nodes also pin exporter-owned `<p>` semantics for #38; `h4` still requires its
own authorized frozen case. PR CI renders the candidate from
`BubbleEx.Frontend.export_payload/3` against **committed** references. It never
talks to live Bubble.

## Run

```bash
cd test/support/fidelity && npm install && npx playwright install chromium
mix test --only fidelity
# or
mix bubble.fidelity
```

`mix quality` does not run the browser gate (no Playwright required locally).

## What a pass means

Under the pinned browser (Playwright 1.55.0, Chromium 140.0.7339.16, DPR 1,
`en-US`, reduced motion, height 900, Inter SHA pinned in `case.json`):

- geometry 0 CSS px on every correlated sample
- selected typography exact
- document `scrollHeight` exact
- collapse is behavioral (reference absent ⇒ candidate 0×0)
- every present reference node exists on the candidate
- no candidate horizontal overflow
- full-page PNGs are byte-identical
- no scripts / `on*` handlers; exporter ids on correlated nodes
- a11y only on emitted controls

## How references move

- **Exporter-intentional change:** the same PR updates exporter-owned snapshots
  (`case.json` semantics) and, if pixels move, the review is the PNG/report
  diff. Do not silently refresh Bubble references.
- **Bubble / browser / font recapture:** authorized live recapture only.
  `mix bubble.fidelity --recapture` is refused unless `BUBBLE_RECAPTURE=1`,
  and even then this tree does not fetch live Bubble. Recapture is required
  before a slice-complete claim or exporter release.
