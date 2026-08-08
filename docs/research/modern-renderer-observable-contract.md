# Bubble modern renderer: observable contract and characterization targets

**Decision date:** 2026-08-08  
**BubbleEx baseline:** [`6c04ccc`](https://github.com/ricotrevisan/bubble_ex/tree/6c04ccc7dffc0e1433a3c76f46509123c2f16754)  
**Scope:** Bubble's responsive web renderer introduced in 2022; legacy rendering is excluded.

## Decision

Build the exporter against an **observable, versioned contract**, not Bubble's shipped renderer implementation:

1. ingest a decoded Bubble app map and preserve every source value and source path;
2. normalize page, reusable-element, element, style, responsive, asset, and expression data into exporter-owned schemas;
3. characterize expected output from authorized apps using app data, DOM snapshots, computed styles, screenshots, and public documentation;
4. emit HTML/CSS/assets and explicit bindings/findings without executing or redistributing Bubble runtime code;
5. treat unknown keys, element variants, and expression nodes as preserved unsupported data rather than dropping or guessing them.

This boundary is technically sufficient for a first exporter and materially safer than porting, decompiling, translating, or shipping Bubble's runtime. Deep runtime reverse engineering and publication of platform testing results remain legal-review gates, not implementation tasks.

## Evidence and confidence

### Verified

- Bubble documents one responsive page adapting across screen sizes and says its responsive engine was introduced in 2022, with older pages potentially requiring page-by-page conversion.[1]
- Bubble documents parent/child container semantics and four container layouts: Fixed, Align to Parent, Column, and Row.[2]
- The parent layout, child settings, and sibling order jointly determine placement. Documented controls include dimensions, spacing, alignment, ordering, wrapping, and overflow.[2]
- Bubble documents reusable elements, element styles, style variables, and condition-driven property changes as distinct authoring concepts.[3][4]
- The public `bubble.io` page fetched on 2026-08-08 exposed content-addressed `early_js`, `pre_run_jquery_js`, `run_js`, `static_js`, and `dynamic_js` assets. Its dynamic bundle populated `window.app`, `_bubble_page_load_data`, and preload state. BubbleEx's existing parser successfully decoded that bundle into an app map.[5][6]
- The decoded sample contained top-level identity/version, page, reusable-element, global-element/expression, style, settings, option-set, plugin, domain, and index data. Element records contained type (`%x`), properties (`%p`), nested elements (`%el`), ids, names, and source paths. Layout-relevant properties included `container_layout`, row/column gaps, alignment, order, fit/fixed/min/max dimensions, margins, padding, overflow, responsive visibility, breakpoints, and collapse behavior.[5]
- BubbleEx already has a single-path decoder for the dynamic `const app = JSON.parse(...)` payload and lossless app-tree splitting/reassembly. The normalized frontend model should consume that decoded map rather than grow a second JavaScript decoder.[6][7]
- Source-map probes for each inspected package URL returned the original JavaScript bytes, not source-map JSON. HTTP 200 therefore did not establish source-map availability.[5]
- Bubble Terms §3(b), effective 2025-05-21, restrict modification/derivative works, decompilation/reverse engineering/translation to human-readable form (except where applicable law allows), and disclosure of testing or benchmarking results.[8]

### Interpretation

- Flexbox is the natural first translation for Row and Column; a nine-cell CSS Grid is a plausible translation for Align to Parent; positioned CSS is the faithful baseline for Fixed. These mappings must be validated against fixtures rather than assumed exact.
- Obfuscated raw keys are transport details, not a stable public model. Stable normalized field names should be backed by source pointers and raw-value retention so a Bubble bundle change is diagnosable.
- Runtime-observed DOM classes such as `bubble-element`, `bubble-r-container`, `flex`, and `column` are useful characterization clues but are not exporter API contracts and should never appear as required normalized fields.
- A structurally similar DOM does not prove visual equivalence. Computed styles and screenshots across viewports are required.

### Unknown

- Whether all modern apps use the same raw key aliases and bootstrap seams.
- Exact precedence among style defaults, per-element overrides, responsive rules, and conditions for every property.
- The complete native element/variant inventory and plugin boundary.
- Authenticated/private app behavior and authenticated assets.
- Whether Bubble would treat a specific proposed public characterization suite or published output as prohibited testing/benchmark disclosure. Obtain legal advice or written permission before that work.

## Observable input contract

The normalizer should accept a decoded map and produce stable records while retaining a source envelope.

### Candidate source regions

| Source region observed | Normalized responsibility | Rule |
|---|---|---|
| `_id`, `app_version`, `app_json_version`, `last_change*`, `generation_fiber_id` | app/version identity | Preserve exact values; never silently merge versions. |
| `%p3` | pages | Normalize each page root and tree; preserve original map key separately from inner id. |
| `%ed` | reusable/custom element definitions | Normalize definition, parameters, tree, responsive metadata, and plugin/custom boundary. |
| `styles` | shared styles | Resolve references without destroying local overrides. |
| `global_elements`, `global_expressions` | shared references | Preserve stable identity and references. |
| `settings`, `mobile_views`, `domains`, `primary_domain`, `favicon` | app presentation/settings | Consume only renderer-relevant values; carry the rest as source metadata. |
| `plugin_special` | plugin metadata | Never execute. Produce placeholder/support metadata. |
| `_index.id_to_path` | source identity/path lookup | Use as evidence and lookup assistance, not as the sole source of truth. |

The current public sample used aliases such as `%p3`, `%ed`, `%x`, `%p`, and `%el`. These names are observed facts, not promised Bubble APIs. Characterization must detect and report alias drift.

### Required normalized seams

Every normalized node should carry:

- stable exporter id;
- source app version and raw source path;
- original map key and inner Bubble id where both exist;
- kind/type and variant;
- ordered children;
- resolved style plus original style references and overrides;
- layout constraints independent of final CSS syntax;
- visibility/collapse/condition metadata;
- asset references with provenance and fetch status;
- expression values as constant, resolvable payload value, or lossless unresolved binding;
- support status and findings;
- a raw source fragment or pointer sufficient for future re-normalization.

## Renderer seams to characterize

### Layout

- **Fixed:** x/y relative to parent, width/height, parent resizing, overflow, and stacking.
- **Align to Parent:** all nine cells, multiple children in one cell, stretching, min/max size, and overlap.
- **Row:** order, wrap threshold, row/column gap, horizontal/vertical alignment, growth/shrink, fixed versus fit dimensions, margins, padding, and overflow.
- **Column:** order, expansion with visible children, gap/alignment, fit height, min/max size, margins, padding, and overflow.
- **Nested containers:** every pair of parent/child layout modes to at least depth three.
- **Responsive state:** page breakpoints, responsive visibility, collapse-when-hidden, min/max CSS dimensions, and viewport transitions.

### Elements and semantics

Characterize each native type as a tuple of **type + variant + content shape + intrinsic behavior**, not merely a type name. Start with Page, Group, Text, Image, Button, Link, Input, Icon/Shape, and Repeating Group because all appeared in the inspected public sample. Reusable/custom definitions require a separate definition/instance contract. Plugin/custom elements must become dimension-preserving placeholders with metadata unless deliberately supported.

Use semantic HTML only when intent is explicit in app data. Do not infer navigation from button workflows in v1. Preserve workflow metadata without executing it.

### Styles and conditions

Record style reference, inherited defaults, element overrides, conditional property deltas, and final computed values separately. Characterize typography, colors, backgrounds/gradients, borders/radii, opacity, spacing, alignment, dimensions, and visibility. A flattened final style alone is insufficient because bindings and conditions need provenance.

### Expressions and bindings

Classify values as:

1. literal constants;
2. values fully resolvable from the app payload;
3. unresolved expressions preserved as structured nodes;
4. unsupported/corrupt source with a finding.

Readable placeholders are presentation only. Stable binding ids must derive from app version + source path + property, not from placeholder text. Preserve expression chains and arguments losslessly; do not execute workflows, API actions, arbitrary plugin JavaScript, or user-specific server evaluation.

### Assets

For each public asset: preserve source URL, fetch result, content type, byte size, hash, local relative path, and every referring source path. Deduplicate by content hash while preserving URL provenance. Authenticated, denied, malformed, or failed assets remain references plus findings. Credentials must never enter manifests or generated artifacts.

## Prioritized characterization targets

### P0 — blocks the normalized model

- [ ] Capture one authorized modern app with one page and one reusable element using each of Fixed, Align to Parent, Row, and Column.
- [ ] For each fixture, retain decoded app JSON, sanitized source metadata, DOM snapshot, selected computed styles, screenshots, exact viewport, exact bundle URLs/hashes, and capture timestamp.
- [ ] Prove original map key versus inner id handling and stable child order.
- [ ] Map raw aliases to normalized fields with raw source pointers and an unknown-key report.
- [ ] Characterize style precedence: shared style → local override → condition/responsive delta.
- [ ] Characterize literal, payload-resolvable, and unresolved expression examples.
- [ ] Establish the plugin/custom placeholder boundary without executing plugin code.

### P1 — blocks responsive translation

- [ ] Fixed x/y positioning under parent resize.
- [ ] All nine Align-to-Parent cells, including stretch and collision cases.
- [ ] Row wrapping immediately below/at/above threshold; gaps and alignment.
- [ ] Column expansion/collapse as children become hidden or visible.
- [ ] Nested mixed-layout containers to depth three.
- [ ] Fit/fixed/min/max width and height combinations.
- [ ] Margins, padding, overflow scrolling, ordering, and responsive alignment.
- [ ] Breakpoints, `responsive_show*`, `collapse_when_hidden`, and conditional visibility.

### P1 — blocks native support matrix

- [ ] Page, Group, Text, Image, Button, Link, Input, Icon, Shape, and Repeating Group variants.
- [ ] Reusable definition versus instance parameters and nested trees.
- [ ] Text tags, rich text, links, typography, wrapping, and intrinsic height.
- [ ] Image source, fit/aspect ratio, alt/title, borders, and failed asset behavior.
- [ ] Form disabled/placeholder/value states while preserving only intrinsic HTML behavior.
- [ ] Unknown native type and custom/plugin placeholder dimensions.

### P2 — closes regression gaps

- [ ] Deterministic output under repeated exports.
- [ ] Cross-browser screenshot/computed-style agreement for the supported viewport matrix.
- [ ] Unknown-key and unsupported-node coverage budgets.
- [ ] Bundle/app-version drift detection and fixture update policy.
- [ ] Accessibility assertions where semantics are explicit; findings where intent is ambiguous.

## Implications for dependent decisions

### Define the normalized frontend model

That decision can now start from a strict source-envelope + stable-model split. It should define exporter-owned app/page/definition/node/style/layout/asset/expression/finding schemas and make raw source identity first-class. It must not expose `%p3`, `%ed`, `%p`, `%x`, or other observed aliases as public API names.

### Establish the native element support matrix

That research should inventory **type + variant + property families + intrinsic behavior** from the controlled corpus. The first coherent slice is Page/Group/Text/Image/Button/Link/Input/Icon/Shape, with Repeating Group evaluated separately because its cell/data behavior is materially deeper. Custom/plugin types default to placeholders.

## Legal and operational boundary

This is a technical planning record, not legal advice.

Allowed-by-design exporter work should remain on user-authorized app data and observable rendered output. Do not ship Bubble runtime code, derived readable runtime code, source maps, proprietary CSS/JS, credentials, or third-party app content. Do not bypass access controls. Do not claim compatibility from one public sample.

Before deeper runtime inspection, decompilation, translation, publication of detailed platform test results, or a benchmark comparing Bubble's renderer and BubbleEx, obtain qualified legal review or written Bubble permission. Terms §3(b) is explicit enough that “the asset was publicly downloadable” is not a safe permission theory.[8]

## Reproduction ledger

Retrieved at `2026-08-08T14:59:20Z` from `https://bubble.io/`:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| HTML | 51,878 | `0fe464939efa82b4228c38c0f69374a9b4888576889a642f3757aa2676f2d928` |
| `early.js` | 24,223 | `450e62180e870526d437f065fa76a5d4e31517905e37a98184ef79b0fc2abd5b` |
| `pre_run_jquery.js` | 89,795 | `a0fe8723dcf55da64d06b25446d0a8513e52527c45afcb37073465f9c6f352af` |
| `run.js` | 4,671,718 | `dbe0f30a62ad1f6a4f750678b0b7f4e1250be772d9882ad1a11ab767f7e694aa` |
| `static.js` | 5,044,245 | `fbc9f0d0d0231607c1280a4d2953d4ff4732f82fcc892dcc84f348a8265ae04f` |
| `dynamic.js` | 6,761,601 | `dee848dd98e1e68770a062cbf3c80d0f19ef68fc5dcc1bf66831574513c0adfe` |

The corresponding `.map` probes returned byte-identical JavaScript with non-JSON content types and invalid source-map shapes. No runtime assets or decoded app payloads are committed to this repository.

## Sources

1. Bubble, [Responsive design](https://manual.bubble.io/help-guides/design/responsive-design.md), retrieved 2026-08-08, SHA-256 `b6c14eb23f1caa3b6b40518d0fb2795e5e24cd37ae73101d38b3477bea723c0f`.
2. Bubble, [Building responsive pages](https://manual.bubble.io/help-guides/design/responsive-design/building-responsive-pages.md), retrieved 2026-08-08, SHA-256 `5b9749dbdc4a2e3982f15eaf4073e2e9e1aafc0ea8ad0ecc3b5724b08edeca7c`.
3. Bubble, [Elements](https://manual.bubble.io/help-guides/design/elements.md), retrieved 2026-08-08, SHA-256 `a2c6e59e6d14493cda1d60e6fbc8e1242cc63fe63f30230b0809cbaf5af1de78`.
4. Bubble, [Variables and styles](https://manual.bubble.io/help-guides/design/variables-and-styles.md), retrieved 2026-08-08, SHA-256 `07dfbbbeebf4def3acf141f49ac570707a0366de9522b5de26206331d539cf3c`.
5. First-party public Bubble page and content-addressed package assets, exact URLs recorded in the research session; hashes and sizes are reproduced above. No proprietary bundle content is included here.
6. BubbleEx [`BubbleEx.Apps.Parser`](https://github.com/ricotrevisan/bubble_ex/blob/6c04ccc7dffc0e1433a3c76f46509123c2f16754/lib/bubble_ex/apps/parser.ex) and [parser tests](https://github.com/ricotrevisan/bubble_ex/blob/6c04ccc7dffc0e1433a3c76f46509123c2f16754/test/bubble_ex/apps/parser_test.exs).
7. BubbleEx [`BubbleEx.AppTree.Splitter`](https://github.com/ricotrevisan/bubble_ex/blob/6c04ccc7dffc0e1433a3c76f46509123c2f16754/lib/bubble_ex/app_tree/splitter.ex) and [`BubbleEx.AppTree.Expr`](https://github.com/ricotrevisan/bubble_ex/blob/6c04ccc7dffc0e1433a3c76f46509123c2f16754/lib/bubble_ex/app_tree/expr.ex).
8. Bubble, [Terms §3(b)](https://bubble.io/terms), last revised 2025-04-21 and effective 2025-05-21; retrieved 2026-08-08, SHA-256 `840f5a9439da204780bec32dc6f7cf2e7f1ae629274f303abfb4a833746ab08c`.
