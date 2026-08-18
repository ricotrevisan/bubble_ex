# Native Bubble web-element support matrix

**Decision date:** 2026-08-13

**Issue:** [#27 — Establish the native element support matrix](https://github.com/ricotrevisan/bubble_ex/issues/27)

**BubbleEx baseline:** [`c2df366`](https://github.com/ricotrevisan/bubble_ex/tree/c2df366)

**Scope:** Bubble web apps using the responsive renderer introduced in 2022. Native mobile, legacy-responsive pages, and installed plugin elements are excluded.

## Research question and acceptance contract

Issue #27 contains a question, not a checklist: which native element types and modern-renderer variants exist in the observed runtime and controlled corpus; what semantics and styling each needs; and which exact subset is a coherent first implementation slice.[I27] Read with the parent Wayfinder, the answer must also honor these settled constraints: portable HTML/CSS, semantic HTML only where intent is unambiguous, intrinsic native HTML behavior only in v1, no Bubble workflow/condition/plugin execution, and dimension-preserving placeholders for unsupported/plugin nodes.[W22]

Accordingly, this note treats the issue as accepted when it provides:

1. an authoritative native **web** catalog and an explicit plugin boundary;
2. a correlation between that catalog, the observed first-party app payload, and available authorized controlled-fixture evidence;
3. a type-and-variant matrix with proposed HTML semantics, type-specific styling/behavior, and support tier;
4. an exact first slice, including excluded variants rather than only type names; and
5. evidence gaps that must remain findings or fixture gates instead of guesses.

## Decision

Adopt the matrix below as a **planning support matrix**, not as a claim that every listed variant has renderer parity. Bubble's official reference currently documents 28 native web element kinds plus reusable-element definition/instance machinery.[B-CATALOG] The first-party `bubble.io` payload proves a broader observed subset. The authorized issue #28 **partial parity fixture** adds controlled source → DOM/CSS evidence for Page, Group in all four layout modes, plain Text paint/geometry, Shape, label-only Button, and an Email Input in its static empty/placeholder state.[C28] Frozen cases #35–#37 extend that narrow evidence to public Image modes, text-only Link, and static Text/Password Input. Unexercised variants remain selected for S1 without a parity claim.

The exact first implementation slice is:

- **Structural:** Page and Group, with Fixed, Align to Parent, Row, and Column layout normalized at the common layout seam.
- **Static content:** Text (plain/literal or payload-resolved content; raw tag unset/`normal`, `h1`, `h2`, `h3`, or `h4` only), Image (public/resolved source; Stretch, Rescale, Zoom, and Adjust-element-height), and Shape.
- **Explicit controls:** Button **Label only**, Link **Text only with an explicit resolved internal or external destination**, and Input formats **Text, Email, and Password**.

This is deliberately narrower than “support every property on eight types.” Icon, icon-only/icon+label Button, icon Link, Bubble BBCode/rich Text, masked/numeric/date Input formats, and workflow-derived click behavior are not in slice 1. They require an icon asset/glyph contract, a safe rich-text contract, Bubble-specific formatting characterization, or prohibited-in-v1 workflow execution respectively.[B-VISUAL][B-INPUT][W22]

| Slice-1 item | Included variants | Explicitly excluded from slice 1 |
|---|---|---|
| Page | modern root; none/solid/gradient/public-image background | video/parallax background; legacy renderer |
| Group | Fixed, Align to Parent, Row, Column; resolved common box/style/layout properties | data loading; click workflows; animated collapse |
| Text | plain literal or payload-resolved content; raw tag unset/`normal`, `h1`, `h2`, `h3`, or `h4` (`h1`/`h2`/`h3` occur in #28; explicit `normal` occurs in #35–#38; explicit `h4` occurs in #38) | BBCode, mixed rich spans, automatic link/email recognition, workflow clicks, unobserved tag enums |
| Image | public/resolved source; Stretch, Rescale, Zoom, Adjust-element-height; alt text | authenticated source fetch; PDF thumbnail behavior; workflow clicks |
| Shape | resolved decorative background/gradient/border/radius/opacity/rotation | click workflow semantics |
| Button | Label; resolved label; native disabled state | Icon, Icon + label, workflow execution, Button-to-Link inference |
| Link | Text; explicit resolved internal or external destination; new-tab/nofollow; literal disabled lowers without `href` while preserving destination metadata | icon Link; unresolved/conditional navigation; inferred destination |
| Input | Text, Email, Password; resolved initial value; placeholder/required/disabled | every other Bubble content format, auto-binding, Bubble-specific mask/validation behavior |

A type is not “supported” merely because a `<div>` can approximate its box. Slice-1 support requires normalized identity/source pointers, common box/style/layout translation, explicit unresolved bindings/findings, and the type-specific rules listed here.[R23][C25][C26]

## Evidence boundary

### What is actually observed

A fresh, credential-free fetch of `https://bubble.io/` on 2026-08-13 was decoded with the repository's public path, `BubbleEx.Apps.fetch_app/2` → `BubbleEx.HTTP` → `BubbleEx.Apps.Parser.parse_app_json/1`.[REPO] The delivered app payload contains 128 page roots and 36 reusable-definition roots. Traversing only those roots and their `%el` child maps (not workflows, expressions, styles, or plugin registries) found the following native-looking element discriminators:

| Raw discriminator | Count | Explicit variant values observed in that payload |
|---|---:|---|
| `Page` | 128 | — |
| `Group` | 1,032 | `container_layout`: `fixed` 6, `relative` 214, `row` 346, `column` 466 |
| `Text` | 481 | explicitly set `tag_type`: `normal` 7, `h2` 1, `h4` 1; unset values were not interpreted |
| `Shape` | 143 | — |
| `Button` | 140 | explicitly set `button_type`: `label_icon` 27, `icon` 22; unset values were not interpreted |
| `Link` | 132 | only one explicit `show_icon: false`; unset values were not interpreted |
| `Icon` | 127 | — |
| `Image` | 89 | explicit run rendering: `zoom` 28, `rescale` 2, `stretch` 5; unset values were not interpreted |
| `RepeatingGroup` | 33 | explicit scroll directions `flex_row` 5, `horizontal` 1; cell container layouts also vary |
| `HTML` | 26 | one explicit false value for the observed iframe-like flag; raw alias remains unverified |
| `Popup` | 21 | Row 2 and Column 19 container layouts |
| `Input` | 16 | explicit formats: `text` 1, `email` 3, `password` 2, `date` 1; unset values were not interpreted |
| `MultiLineInput` | 11 | — |
| `GroupFocus` | 10 | Column 6 and observed `relative` 4 container layouts |
| `Dropdown` | 7 | all seven explicitly `dynamic` choices |
| `PictureInput` | 2 | — |
| `Alert` | 1 | — |
| `FloatingGroup` | 1 | Column container layout |
| `CustomDefinition` | 36 | explicit reusable base type: Group 21, Popup 9, Floating Group 2; four unset |
| `CustomElement` | 54 | reusable instances, distinct from installed plugin discriminators |

The same trees also contained plugin-owned names such as `materialicons-Materialicon`, `ionic-IonicIcon`, `select2-MultiDropdown`, opaque plugin IDs, and other non-native nodes. Their presence confirms why “unknown `%x`” cannot be treated as a native element.[OBS]

These are **app-payload observations**, not a runtime DOM contract or a complete app-wide element census. The payload exposes metadata for 128 pages but the recursively counted element trees are the 36 `%ed` `CustomDefinition` roots; the page records observed under `%p3` do not themselves expose child `%el` trees. The result therefore inventories delivered reusable-definition trees plus page-root metadata, not every element on 128 pages and not only the current index DOM. Counts may change whenever Bubble republishes the site. Raw aliases and values are transport observations, not stable Bubble APIs.[OBS][R23]

### Controlled conformance evidence

Issue #28 supplies an authorized, deterministic **partial parity fixture** on the Basic-Auth-protected `tiptap-plugin` Test branch. It is not the public, credential-free, complete capture bundle specified by issue #24: it does not commit the decoded JSON, initial HTML/packages, serialized Bubble DOM, timestamps, or an asset manifest. Its hand-normalized fixture does preserve Bubble IDs/source paths and contains 48 correlated nodes: Page ×1, Group ×15, Text ×20, Shape ×7, label-only Button ×4, and Email Input ×1. Group modes are Column ×7, Row ×6, Align to Parent ×1, and Fixed ×1; the Page is a separate Column root with a solid background. Cases cover natural wrapping, min/max/fill sizing, a 1120 px clamp, ordered responsive collapse at resolved width 768, overlap/stacking, local fixed XY placement, group/page gradients, borders, shadows, shape rotation, and bundled-font metrics.[C24][C28]

The frozen reference identity is page `bpmkbvvo`, decoded page payload SHA-256 `706f73ef49c170ab077bfe680403782f5dea94ba36ea5cae3c3878079340701b`; the payload itself is not committed. At 26 behavior-derived widths, the static candidate matched 1,200 source-correlated geometry samples with 0 CSS-pixel error, 614 exact selected typography samples, 48 behaviorally equivalent collapse samples, exact document height, no horizontal overflow, and 26 byte-identical full-page PNG pairs. The generated page contains no scripts or inline event handlers.[C28]

Pixel and geometry equality establish equivalent static output, not identical DOM structure or Bubble semantic tags. Bubble removes the controlled collapsed subtree while the candidate retains zero-size descendants beneath `display: none`; the comparison checks collapsed layout behavior. Bubble's reference nodes are generally generic runtime containers, while candidate `main`/`header`/`section`/`article`/heading/control tags are exporter semantics selected independently of layout.[C28]

This evidence validates only the exercised variants and states. Frozen cases now cover public Image Stretch/Rescale/Zoom/Adjust-height (#35), text-only resolved/disabled Link (#36), and static Text/Password Input alongside the #28 Email Input (#37). It does **not** validate authenticated/dynamic Image, icon/dynamic Link, Input focus/invalid/required/disabled behavior, Button disabled/interaction states, Text truncation/fit-height/BBCode, page image backgrounds, or arbitrary style/condition precedence. A row or variant becomes parity-tested only after a frozen controlled case exercises it at behavior-derived viewports.[C24][R23][C28]

## Common rendering contract

All elements share four responsibilities before type-specific rendering:

1. **Box/layout:** translate parent layout plus ordered child controls, dimensions, min/max/fit sizing, aspect ratio, margins, padding, alignment, gap, overflow, visibility, and collapse behavior. Bubble documents Fixed, Align to Parent, Row, and Column as the four container layouts.[B-LAYOUT][B-RESP]
2. **Style layers:** preserve shared style, local override, responsive rule, and conditional delta separately; render applicable opacity, typography, background/gradient/image, border/radius, shadow, rotation, and tooltip properties. Do not flatten away provenance.[B-GENERAL][B-STYLE][B-COND][C25]
3. **Bindings and behavior:** render literals/payload-resolved values; preserve unresolved values and conditions as bindings. Workflows, custom states, API actions, and plugin code remain metadata in v1.[W22][C26]
4. **Accessibility:** use native HTML semantics only when the element's documented intent is explicit. Native controls retain keyboard/focus/disabled behavior; generic visual containers must not acquire invented roles.[HTML]

## Native web support matrix

**Tiers:** **S1** = exact first implementation slice above; **S2** = next native slice after controlled characterization; **D** = defer because the behavior is data/runtime/service-heavy; **P** = preserve as an explicit placeholder/finding in v1. Tier is a planning decision, not validation status. “Observed payload” is the 2026-08-13 public payload inventory. The independent “Controlled-fixture evidence” column records only variants exercised by frozen cases; `None` means no controlled case, not that the documented kind does not exist.[C28]

| Native kind | Documented variants / intrinsic behavior | Observed payload | Controlled-fixture evidence | Proposed HTML semantics | Type-specific styling and behavior contract | Tier |
|---|---|---:|---|---|---|:---:|
| **Page** *(controlled: solid-background modern root)* | Web-page root; page background can be color, gradient, image, or video; modern container layout applies.[B-PAGE] | `Page` ×128 | #28: solid-background Column root; static parity | One document shell; page content inside `<main>` only when it is the page's dominant content.[HTML] | Page min/max width, viewport overflow, responsive root, title/metadata; do not nest page roots. S1 handles none/solid/gradient/public-image background, not video/parallax. | **S1** |
| **Group** *(controlled: all four layouts)* | Generic data/layout container; Fixed, Align to Parent, Row, or Column; may collapse when hidden.[B-GROUP][B-LAYOUT] | `Group` ×1,032; all four raw layout values represented, with `relative` only provisionally correlated to Align to Parent | #28: 15 nodes; Column ×7, Row ×6, Align to Parent ×1, Fixed ×1; static parity | `<div>`; no invented landmark or interactive role.[HTML] | Common layout/box contract, backgrounds/borders, overflow, collapse. Data source remains binding metadata. | **S1** |
| **Repeating Group** | Repeated cell/list/grid; fixed or dynamic rows/columns, vertical/horizontal/wrapped/reverse scroll, show-all, masonry, separators.[B-RG] | `RepeatingGroup` ×33 | None in issue #28 | `<ul>/<ol>` only when list intent is known; otherwise generic grid/container. A semantic `<table>` must not be inferred.[HTML] | Cell template expansion, data/pagination/loading, virtualization/scroll, masonry and current-cell context are deeper than static layout. | **D** |
| **Table** | Static and repeating rows/columns, horizontal/vertical orientation, sticky rows/columns, separators.[B-TABLE] | none | None in issue #28 | `<table>` only for tabular data with rows/cells; vertical orientation needs characterization before semantic transposition.[HTML] | Column sizing, row groups, sticky headers/cells, repeated data and responsive overflow. | **D** |
| **Popup** | Modal-like group above other content, overlay/grayout/blur, Escape close option, show/hide workflow.[B-POPUP] | `Popup` ×21 | None in issue #28 | `<dialog>` only if modal/dialog intent and visibility are preserved; otherwise hidden placeholder/container.[HTML] | Top layer, focus/escape behavior, overlay, scroll lock, visibility workflow. Intrinsic `<dialog>` behavior is insufficient proof of Bubble parity. | **D** |
| **Floating Group** | Attached to screen edge, remains while page scrolls; horizontal/vertical attachment and z-index.[B-FLOAT] | `FloatingGroup` ×1 | None in issue #28 | Generic `<div>` | `position: fixed`/`sticky` choice, attachment offsets, containing block, z-index, parallax require captures. | **S2** |
| **Group Focus** | Anchored to a reference element, remains visible while focused; offsets; typically dropdown/menu.[B-FOCUS] | `GroupFocus` ×10 | None in issue #28 | Generic anchored container; do not guess `menu`, `listbox`, or popover semantics.[HTML][ARIA] | Anchor geometry, focus retention/dismissal, collision/viewport behavior, stacking. | **D** |
| **Text** *(frozen: literal paint/geometry; exporter semantics for `normal`/`h1`/`h2`/`h3`/`h4`)* | Static/dynamic text; optional BBCode, recognized links/email, truncation, shrink/stretch height, optional SEO HTML tag.[B-VISUAL] | `Text` ×481; explicit `normal`, `h2`, `h4` tags | #28 freezes literal `h1`/`h2`/`h3` paint/geometry; #35–#38 freeze explicit `normal` paint/geometry and structurally pin `<p>`; #38 freezes explicit `h4` paint/geometry with fixed-width two-line wrapping and structurally pins `<h4>`. Candidate tags are exporter design choices, not Bubble DOM parity. | S1 preserves explicit observed `h1`/`h2`/`h3`/`h4`; unset/`normal` uses `<p>` or neutral `<div>/<span>` from block context. This is a planned exporter lowering, not Bubble DOM parity; never derive a heading level from font size.[HTML] | Typography, wrapping, line/letter/word spacing, alignment, ellipsis/intrinsic height. **S1 excludes BBCode, auto-linkification, mixed rich spans, and unobserved tag enums.** | **S1** |
| **Image** *(frozen: public Stretch / Rescale / Zoom / Adjust-height)* | Static/dynamic source; Stretch, Rescale, Zoom, Adjust element height; alt text.[B-VISUAL] | `Image` ×89; `stretch`, `rescale`, `zoom` observed | #35: four public-source modes on `bprkyexk`; case-correct, not slice-complete | `<img src alt>` for image content.[HTML] | CSS `object-fit`: `fill`, `contain`, `cover` respectively; Adjust-height uses intrinsic aspect ratio/auto height. Preserve crop, border/radius, opacity, failed/authenticated asset finding.[CSS-IMG] | **S1** |
| **Button** *(controlled: label-only static state)* | Label, Icon + label, or Icon; icon leading/trailing; combined content horizontal/vertical; disabled/clickable state; triggers workflow.[B-VISUAL] | `Button` ×140; `label_icon`, `icon` explicit | #28: four label-only buttons in static state; paint/geometry parity | `<button type="button">`; never `<a>` from workflow inference.[HTML][I21] | Native focus/keyboard/disabled behavior; label typography/background/border. **S1 is label-only and stores workflow metadata without executing it.** | **S1** |
| **Link** *(frozen: text-only internal / external / new-tab / disabled)* | Text or icon; explicit internal page/external URL, data/parameters, new tab, disabled, nofollow, wrapping.[B-VISUAL] | `Link` ×132 | #36: resolved external/internal, new-tab + nofollow, wrapping, and literal disabled on `bptaixqv`; case-correct, not slice-complete | Enabled, resolved destination → `<a href>` with correct `target`/`rel`. Literal disabled → non-navigating `<a>` without `href`, with destination retained as source metadata. Unresolved destination or disabled condition → non-navigating content plus canonical binding/finding; never guess activation.[HTML][C26] | Link typography/wrapping/focus/disabled presentation. **S1 is text-only**; do not convert Buttons to links.[I21] | **S1** |
| **Icon** | Material UI, Phosphor, Bootstrap, Ionic, Font Awesome 4/6 free, Feather; color and spin.[B-VISUAL] | native `Icon` ×127; plugin icon nodes also present | None in issue #28 | Decorative icon is hidden from the accessibility tree; an interactive icon needs an accessible control/name, not a bare glyph.[ARIA][HTML] | Exact library/version/glyph/font-or-SVG extraction, animation, licensing/redistribution, and accessible-name source need a contract. | **S2** |
| **Shape** *(controlled: decorative)* | Primarily visual; may trigger click workflow.[B-VISUAL] | `Shape` ×143 | #28: seven decorative shapes; solid paint/border/radius/rotation/placement parity | Decorative `<div aria-hidden="true">`; if a workflow gives it control intent, preserve metadata rather than invent v1 behavior.[ARIA] | Background/gradient, border/radius, opacity, rotation, dimensions/aspect ratio. | **S1** |
| **Video** | YouTube or Vimeo player; autoplay, loop, Vimeo control color; plugin-only Ziggeo extension.[B-VISUAL] | none | None in issue #28 | Provider `<iframe>` or `<video>` only after provider/source is resolved; include an accessible title.[HTML] | Aspect ratio, autoplay policy, consent/cookies, loop, provider parameters and CSP; Ziggeo remains plugin scope. | **D** |
| **Map** | Google Maps; zero/single/list markers, titles, map type/style, zoom/drag, center/zoom, custom marker images.[B-VISUAL] | none | None in issue #28 | Named embedded region/iframe or static fallback; no native HTML map widget exists.[HTML][ARIA] | External service/API/consent, dynamic markers, interaction, provider styling. Use a dimension-preserving placeholder in static v1. | **P** |
| **Alert** | Temporary workflow-shown message; fade in/out; optional page-top width.[B-VISUAL] | `Alert` ×1 | None in issue #28 | `role="alert"` only for urgent dynamically inserted content; otherwise `status` or ordinary text must be chosen from intent, not the Bubble type name alone.[ARIA] | Live-region timing, visibility workflow, animation and top overlay are not intrinsic static behavior. | **D** |
| **HTML** | Runs author-provided HTML/scripts; optional iframe isolation; optional stretch-to-content.[B-VISUAL] | `HTML` ×26 | None in issue #28 | Sandboxed `<iframe>` is the safer default representation; direct markup requires an explicit trusted/sanitized policy.[HTML] | Treat as active content, not native renderer output. Never execute it during export; preserve source/binding and dimensions, emit security finding. | **P** |
| **Built on Bubble** | Bubble badge/logo or text link opening Bubble in a new tab; color variants and border.[B-VISUAL] | none | None in issue #28 | Explicit `<a>` with image/text when its first-party asset and destination resolve.[HTML] | Asset provenance, color variant, border and accessible text. | **S2** |
| **Input** *(frozen: static Text / Email / Password)* | Single-line formats: Text, Email, Password, Integer, Decimal, Address, US Phone, Percentage, Currency, Date, Euro date, Text (numbers only); required/disabled, initial value, mask/validation.[B-INPUT] | `Input` ×16; explicit `text`, `email`, `password`, `date` | #28: empty Email placeholder; #37: empty Text placeholder and benign masked Password literal on `bpewigqu`; case-correct for the static subset | `<input>` with matching native type only where semantics align.[HTML] | Placeholder/value, typography, border/background, focus/disabled/required. **S1 only Text (`type=text`), Email, Password**. Google address validation, numeric/currency/date parsing, focus/invalid/required/disabled behavior remain deferred. | **S1** |
| **Multiline Input** | Multi-line plain text, character limit, optional stretch to fit.[B-INPUT] | `MultiLineInput` ×11 | None in issue #28 | `<textarea>`.[HTML] | Native value/placeholder/maxlength/disabled; auto-height needs characterization. | **S2** |
| **Checkbox** | Labeled checkbox; checked/unchecked/dynamic initial state; optionally required checked.[B-INPUT] | none | None in issue #28 | Labeled `<input type="checkbox">`.[HTML] | Preserve checked/required/disabled and label hit target; dynamic status remains binding. | **S2** |
| **Dropdown** | Static or dynamic choices; Bubble explicitly says it uses the browser's native dropdown component.[B-INPUT] | `Dropdown` ×7; all explicitly dynamic | None in issue #28 | Labeled `<select>`/`<option>`.[HTML] | Browser-native styling limits are part of the contract; placeholder/default/dynamic options and disabled/required state. | **S2** |
| **Search Box** | Static, dynamic, or geographic autocomplete; optional free entry; live matching.[B-INPUT] | none | None in issue #28 | `<input type="search">` plus combobox/listbox only if the autocomplete interaction is implemented correctly.[HTML][ARIA] | Query/data/provider behavior, popup keyboard model, typed-vs-selected value and Google service make it runtime-heavy. | **D** |
| **Radio Buttons** | Static/dynamic exclusive choices; configurable columns and control color.[B-INPUT] | no native discriminator observed; similarly named reusable instances exist | None in issue #28 | Group of labeled `<input type="radio">`; group label is required when source provides one.[HTML] | Option layout, selected/default/required/disabled and dynamic captions. | **S2** |
| **Slider Input** | Simple one-handle or Range two-handle; horizontal/vertical; min/max/step and track/handle colors.[B-INPUT] | none | None in issue #28 | Simple → `<input type="range">`; two-handle Range requires two coordinated inputs or a custom accessible widget.[HTML][ARIA] | Orientation, track/fill/thumb styling, keyboard values and two-handle constraints vary by browser. | **D** |
| **Date/Time Picker** | Date or Date & Time, time zone, format, min/max date/hour, interval, month/year controls.[B-INPUT] | no dedicated type observed; one `Input` had raw `date` format | None in issue #28 | `<input type="date">` or `datetime-local` only as an intentional native-behavior fallback.[HTML] | Browser UI does not prove Bubble timezone/parsing/format/interval parity. Preserve those settings and emit degradation finding until characterized. | **D** |
| **Picture Uploader** | Image file selection, camera option on mobile, preview, private attachment/storage, resize.[B-INPUT] | `PictureInput` ×2 | None in issue #28 | `<input type="file" accept="image/*">` plus preview only when local selection behavior is deliberately implemented.[HTML] | Upload/storage/privacy workflows are out of scope; static exporter preserves default/placeholder and metadata. | **D** |
| **File Uploader** | File selection, filename display, private attachment/storage, max size.[B-INPUT] | none | None in issue #28 | `<input type="file">`.[HTML] | Actual upload/storage is workflow/service behavior; max-size validation and privacy cannot be promised by static HTML alone. | **D** |
| **Reusable definition / instance** | Definition base type is Group, Popup, or Floating Group; instances share definition but have parameters, states, and workflows.[B-REUSE] | `CustomDefinition` ×36; `CustomElement` ×54 | None in issue #28 | Expand/reference the base element semantics; reusable-ness itself adds no HTML role.[C25][HTML] | Normalize definition once, instances as references with parameters/overrides; deterministic derived expansion; workflows/states remain bindings. | **S2** |

### Explicitly not native web elements

Bubble's own long-form input documentation identifies Rich Text Editor, Multi-FileUploader, and Multiselect Dropdown as Bubble-made **plugins that must be installed**.[B-PLUGIN-BOUNDARY] They are not native merely because Bubble publishes them. The “Sign in with Apple” entry in the visual reference is labeled native-mobile-only, so it is outside this web matrix.[B-VISUAL] Any opaque or namespaced raw discriminator, including plugin-provided icons, defaults to the plugin/placeholder path until an owning first-party registry proves otherwise.[OBS][R23]

## First-slice validation ledger

Issue #28 satisfies the static-layout feasibility gate for the exercised subset, not the production S1 implementation gate.[C28]

| Gate | Current evidence | Status |
|---|---|:---:|
| Page and nested Groups in all four layouts | One controlled solid-background Page; nested Row/Column/Align-to-Parent/Fixed groups; responsive collapse and natural wrapping | **Partial** — validated for this page; image backgrounds, broader nesting/defaults, and full #24 bundle remain open |
| Plain Text and planned semantics | Literal `normal`/`h1`/`h2`/`h3`/`h4` Text has frozen paint/geometry; exporter structure pins `<p>` and `<h1>`–`<h4>` | **Partial** — truncation and exhaustive fit-height remain open |
| Image modes/assets | Frozen case `bprkyexk` (#35) exercises public Stretch, Rescale, Zoom, and Adjust-element-height | **Partial** — case-correct for that page; not S1 slice-complete |
| Shape paint/geometry | Seven decorative shapes cover solid paint, borders/radii, rotation, overlap, and local XY | **Partial** — validated for fixture; Shape-specific gradient and interaction variants remain open |
| Label-only Button | Four label-only buttons match static geometry/paint | **Partial** — focus/pressed/disabled states remain open |
| Text-only Link | Frozen case `bptaixqv` (#36) exercises resolved external/internal destinations, new-tab + nofollow, wrapping, and literal disabled | **Partial** — case-correct for that page; dynamic/conditional destinations and icon variants remain open |
| Text/Email/Password Input | #28 freezes an empty Email placeholder; `bpewigqu` (#37) freezes an empty Text placeholder and a benign masked Password literal | **Partial** — case-correct for the static subset; focus/invalid/required/disabled and dynamic content remain open |
| Behavior-derived viewports | 26 widths cover each actual transition at `b-1`, `b`, and `b+1`, plus representative narrow/wide widths; bounds/styles/screenshots are committed | **Partial** — validated for fixture; serialized Bubble DOM and remaining #24 bundle artifacts are open |

On 2026-08-18, an authorized live review recaptured all five frozen cases at all 34 declared viewports under the pinned browser contract. Every live PNG was byte-identical to its committed reference, and all tracked geometry and typography values were exact; no references moved. This satisfies the #30 Q10 live-review requirement for the current suite.

S1 remains the exact selected implementation slice above. “Controlled” and “frozen” apply only to the named fixture variants; they do not silently widen support.[C24][C28]

## Architecture rules learned from controlled evidence

The final issue #28 mismatch list is empty, but independent Bubble comparison corrected five mapping assumptions that affect production design:[C28]

1. preserve Row `row_gap` and `column_gap` separately;
2. lower Fill width as authored width plus `flex-grow: 1` with auto basis, not zero-basis shorthand;
3. preserve Bubble's non-stretch Row cross-axis default;
4. retain explicit-default and source-sidecar sizes required for nested Fixed layout; and
5. freeze font bytes and input placeholder paint because assets and native-control defaults affect geometry/pixels.

These refine the common rendering contract; they do not promote the prototype schema or hand-normalized CSS declarations into the production normalized model.[C25][C28]

## Uncertainties and evidence gaps

### Remaining evidence gaps

- **Controlled coverage is partial.** The frozen Image, Link, and static Text/Email/Password Input cases are case-correct, while authenticated/dynamic Image, icon/dynamic Link, Input interaction/validation states, Button interaction/disabled states, Text truncation/fit-height, page image backgrounds, and many native kinds remain without controlled evidence.[C28]
- **Raw enum correlation is partial.** The controlled source confirms the four authored Group layouts for its page, but the public payload alias `container_layout: relative` is still only provisionally correlated to Align to Parent outside that controlled source path.[OBS][B-LAYOUT][C28]
- **Unset raw properties are not defaults.** The aggregate deliberately does not infer that an unset Button is Label or that an unset Image uses a particular rendering mode.
- **Style precedence remains only partly characterized.** The controlled literal/static slice validates its authored layers and one viewport rule; it does not establish exporter-ready precedence for every property, shared style, condition, or interaction state.[B-GENERAL][B-STYLE][B-COND][R23][C28]
- **Icon resources are unresolved.** Documentation names seven libraries, but exact glyph identifiers, versions, delivery format, redistribution permissions, fallback metrics, and accessible-name sources remain uncaptured.[B-VISUAL]
- **Rich text is unresolved.** Bubble documents BBCode, automatic links/email, and mixed rich formatting. No safe, lossless conversion policy or controlled case exists.[B-VISUAL]

### Non-blocking boundaries

- Plugin/custom types stay as dimension-preserving placeholders with metadata; this is an intentional product boundary, not missing native support.[W22]
- Dynamic values, conditions, and workflow metadata use the accepted binding/finding contracts rather than guessed presentation values.[C26]
- Button-to-link inference remains outside v1 and belongs to issue #21.[I21][W22]
- The public payload and controlled slice serve different purposes: catalog breadth versus narrow conformance depth.[OBS][C28]

## Reproduction ledger

### First-party app snapshot

Retrieved 2026-08-13 from `https://bubble.io/` without credentials:

| Artifact | Bytes | SHA-256 / identity |
|---|---:|---|
| Initial HTML | 51,823 | `25959f122b330e6eb958cc6497594d0e79023412fa6de70cbc7bff5da7b53a84` |
| Dynamic package | 6,884,302 | SHA-256 `1c6dda13e4252600cc0fc27165e85ee63ca57cbc698079e095b0f60bfd086036`; URL package identity `801b128afaa3f40ae7c08439beea3995f7adf36d02d34c1fab339b1a93b12a97` |
| Decoded compact JSON (not committed) | 5,391,377 | `916d6677b7327efd3f72910c0fdf86c1ef57428e9befb42498529b5ac9f735b2` |

Inventory method: fetch with `BubbleEx.Apps.fetch_app("https://bubble.io/", include_payload: true)` at baseline `c2df366`; start at maps under `%p3` and `%ed`; count each root and recursively visit only its `%el` child map; record `%x` and the explicitly present variant fields. This avoids counting workflow actions, expression nodes, styles, or plugin registry definitions as rendered elements.[REPO]

No Bubble bundle, app payload, or third-party app content is committed with this report. The exact historical aggregate is therefore hash-identified but not independently recomputable after `bubble.io` changes; use it as dated discovery evidence, not a durable conformance fixture. A future refresh should commit a credential-free aggregate JSON plus its extraction script, containing only discriminator/explicit-variant counts and source hashes.[OBS]

### Authorized partial issue #28 parity fixture

The authorized partial-fixture evidence is committed on prototype branch commit [`324c300`](https://github.com/ricotrevisan/bubble_ex/tree/324c300f977ef153937fe3f853457afb9cdefddc/lib/bubble_ex/frontend/prototypes/responsive_layout_vertical_slice). The sanitized reference identity and reproducible candidate/reference audit contract are recorded in its README, normalized fixture, capture scripts, `evidence/browser-audit.json`, and `evidence/comparison.json`. The main-branch decision record is [`cb17e68`](https://github.com/ricotrevisan/bubble_ex/blob/cb17e689f5980862b238812accb3c34b1c0b53a1/docs/research/responsive-layout-vertical-slice.md).[C28]

| Artifact fact | Value |
|---|---|
| Controlled app/page | `tiptap-plugin` Test / `bpmkbvvo` (`bubbleex-i28-responsive-slice`) |
| Decoded page payload SHA-256 | `706f73ef49c170ab077bfe680403782f5dea94ba36ea5cae3c3878079340701b` |
| Frozen font SHA-256 | `3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62` |
| Browser contract | Chromium 140.0.7339.16; DPR 1; `en-US`; reduced motion; 900 CSS-pixel viewport height |
| Viewports | 26 widths from 390 through 1440, including `b-1`/`b`/`b+1` around all actual transitions |
| Comparison result | 1,200 exact geometry samples; 614 exact selected typography samples; 48 exact collapsed-node samples; exact document heights; 26 byte-identical PNG pairs; zero mismatches |

The committed captures contain only literal controlled fixture content. Credentials, editor cookies, private app payloads, and unrelated app content are excluded.[C28]

### Documentation snapshot

All Bubble manual sources below were retrieved 2026-08-13 as first-party Markdown. Hashes make later doc drift visible.

| Source id | SHA-256 |
|---|---|
| `[B-CATALOG]` `llms.txt` | `0fe0494a37b511518a91dcf952afb2b7e532c3dc3bc27c24058844bd9a20424e` |
| `[B-PAGE]` Page reference | `886f33b9a6c71f56676e94e2f439271d2a9c8244675c32e15a759852af7318d9` |
| `[B-VISUAL]` Visual Elements reference | `01e1b358aa3bf607c7169a1986da7e2737137dc2593947136409123789908d64` |
| `[B-CONTAINERS]` Containers reference | `79d90c1aa5a5744699a0b2128cb8b51f3e39eb1a01590def054a31b7c0b29719` |
| `[B-GROUP]` Group guide | `2d15fcad7191e3d7a2c27f97ee9b619e6565e96c0c7783995d4e8259cb2af419` |
| `[B-RG]` Repeating Group guide | `6499c002ec450549658af6039ba7a0ccc5d622aaaae6fb53de63e2fa3ed15618` |
| `[B-TABLE]` Table guide | `e6bd7a361aa2fb15d4f2d4cec17af21cfd1d7fcf0ec9db2a36102124656e36fa` |
| `[B-POPUP]` Popup guide | `085f7e9c74b15f71d82056bab70833adbebe677ef9b7f511a37901c13404e754` |
| `[B-FLOAT]` Floating Group guide | `b00e6aeaf45c31a4b95b46ca19d63b0d49609901135e3b0e1f042b6f1b7f7a35` |
| `[B-FOCUS]` Group Focus guide | `45faa6385f380f2b8b302236d66455730ca776b89c21a493c92afc78ece47d76` |
| `[B-INPUT]` Input Forms reference | `cdb67ea701f452ed3e85a39bd1266b9797365d110cd7f04be91622a31813de78` |
| `[B-PLUGIN-BOUNDARY]` Text/numbers, file uploads, selection controls | `8f64f1ce0b9a6f2f1a492c6b909d7e6c874b5f14013c25c58925e41baa31cfb8`; `73d671899507bda8932356cde7297e812c217d9b1477ec1968515a9664786b3a`; `bb69cb33a22c323b49166baedae27a922eaed3a182b649a6846b377e7a613b7a` |
| `[B-REUSE]` Reusable Elements reference | `c869d37d6e95019e02a22888bbd2832af60cb87807206e16076f0e3da7f9ffe0` |
| `[B-LAYOUT]` Container Layout Types | `f0298a1b917872411ebdfc691b756ca4a79affe4162f39277afed9b0a9a65416` |
| `[B-GENERAL]` General properties | `cf8de217155a92521f9e339a52d809e049e3c5249348254b3ffc5b2a14c07e3a` |
| `[B-STYLE]` Styling properties | `29ebe06c811e8236870067a3ae5e0fdfc117642e46d9114afc0e8b49e6f89def` |
| `[B-RESP]` Responsive properties | `242ddfe6bdf811def6ae7bf3e461f7822d63f49946d4f8b5222c884758d15578` |
| `[B-COND]` Conditional formatting | `111c64aaed134490f0b90cfd49bc3a2a166e9ceacc48b8cfb37c8b1c4c181032` |

## Sources

### Bubble and BubbleEx

- `[I27]` BubbleEx, [issue #27](https://github.com/ricotrevisan/bubble_ex/issues/27), issue question.
- `[W22]` BubbleEx, [issue #22](https://github.com/ricotrevisan/bubble_ex/issues/22), settled exporter scope and constraints.
- `[I21]` BubbleEx, [issue #21](https://github.com/ricotrevisan/bubble_ex/issues/21), future Button-to-Link research boundary.
- `[C24]` BubbleEx, [issue #24 resolution](https://github.com/ricotrevisan/bubble_ex/issues/24#issuecomment-5230468827), controlled-corpus and capture contract.
- `[C25]` BubbleEx, [issue #25 resolution](https://github.com/ricotrevisan/bubble_ex/issues/25#issuecomment-5275476241), normalized-model decisions.
- `[C26]` BubbleEx, [issue #26 resolution](https://github.com/ricotrevisan/bubble_ex/issues/26#issuecomment-5275661171), binding/finding/coverage decisions.
- `[C28]` BubbleEx, [issue #28 controlled parity result](https://github.com/ricotrevisan/bubble_ex/issues/28#issuecomment-5281111102), [immutable prototype `324c300`](https://github.com/ricotrevisan/bubble_ex/tree/324c300f977ef153937fe3f853457afb9cdefddc/lib/bubble_ex/frontend/prototypes/responsive_layout_vertical_slice), and [decision record `cb17e68`](https://github.com/ricotrevisan/bubble_ex/blob/cb17e689f5980862b238812accb3c34b1c0b53a1/docs/research/responsive-layout-vertical-slice.md).
- `[R23]` BubbleEx, [modern-renderer observable contract](https://github.com/ricotrevisan/bubble_ex/blob/993ba0e282fae4f58e67986a68490edd17b7fff0/docs/research/modern-renderer-observable-contract.md), immutable commit `993ba0e`.
- `[REPO]` BubbleEx, [`BubbleEx.Apps`](https://github.com/ricotrevisan/bubble_ex/blob/c2df366/lib/bubble_ex/apps.ex), [`BubbleEx.HTTP`](https://github.com/ricotrevisan/bubble_ex/blob/c2df366/lib/bubble_ex/http.ex), and [`BubbleEx.Apps.Parser`](https://github.com/ricotrevisan/bubble_ex/blob/c2df366/lib/bubble_ex/apps/parser.ex).
- `[OBS]` Bubble, first-party `https://bubble.io/` HTML, content-addressed dynamic package, and decoded app payload; aggregate-only reproduction ledger above.
- `[B-CATALOG]` Bubble, [complete documentation index](https://manual.bubble.io/llms.txt).
- `[B-PAGE]` Bubble, [Page Element](https://manual.bubble.io/core-resources/elements/page-element.md).
- `[B-VISUAL]` Bubble, [Visual Elements](https://manual.bubble.io/core-resources/elements/visual-elements.md).
- `[B-CONTAINERS]` Bubble, [Containers](https://manual.bubble.io/core-resources/elements/containers.md). Matrix aliases into focused first-party guides: `[B-GROUP]` [Group](https://manual.bubble.io/help-guides/design/elements/web-app/containers/groups.md), `[B-RG]` [Repeating Group](https://manual.bubble.io/help-guides/design/elements/web-app/containers/repeating-groups.md), `[B-TABLE]` [Table](https://manual.bubble.io/help-guides/design/elements/web-app/containers/table-elements.md), `[B-POPUP]` [Popup](https://manual.bubble.io/help-guides/design/elements/web-app/containers/popups.md), `[B-FLOAT]` [Floating Group](https://manual.bubble.io/help-guides/design/elements/web-app/containers/floating-groups.md), and `[B-FOCUS]` [Group Focus](https://manual.bubble.io/help-guides/design/elements/web-app/containers/group-focus.md).
- `[B-INPUT]` Bubble, [Input Forms](https://manual.bubble.io/core-resources/elements/input-forms.md).
- `[B-PLUGIN-BOUNDARY]` Bubble, [text and number inputs](https://manual.bubble.io/help-guides/design/elements/web-app/input-forms/text-and-numbers.md), [file uploads](https://manual.bubble.io/help-guides/design/elements/web-app/input-forms/file-uploads.md), and [selection controls](https://manual.bubble.io/help-guides/design/elements/web-app/input-forms/selection-controls.md), each identifying the Bubble-made installable plugin entries.
- `[B-REUSE]` Bubble, [Reusable Elements](https://manual.bubble.io/core-resources/elements/reusable-elements.md).
- `[B-LAYOUT]` Bubble, [Container Layout Types](https://manual.bubble.io/core-resources/elements/container-layout-types.md).
- `[B-GENERAL]` Bubble, [General properties](https://manual.bubble.io/core-resources/elements/shared-properties.md).
- `[B-STYLE]` Bubble, [Styling properties](https://manual.bubble.io/core-resources/elements/styling-properties.md).
- `[B-RESP]` Bubble, [Responsive properties](https://manual.bubble.io/core-resources/elements/responsive-properties.md).
- `[B-COND]` Bubble, [Conditional formatting](https://manual.bubble.io/core-resources/elements/conditional-formatting.md).

### Web platform specifications

- `[HTML]` WHATWG, HTML Living Standard sections for [`main`](https://html.spec.whatwg.org/multipage/grouping-content.html#the-main-element), [links](https://html.spec.whatwg.org/multipage/text-level-semantics.html#the-a-element), [images](https://html.spec.whatwg.org/multipage/embedded-content.html#the-img-element), [embedded content/`iframe`](https://html.spec.whatwg.org/multipage/iframe-embed-object.html#the-iframe-element), [tables](https://html.spec.whatwg.org/multipage/tables.html#the-table-element), [buttons](https://html.spec.whatwg.org/multipage/form-elements.html#the-button-element), [`textarea`](https://html.spec.whatwg.org/multipage/form-elements.html#the-textarea-element), [`select`](https://html.spec.whatwg.org/multipage/form-elements.html#the-select-element), [input states](https://html.spec.whatwg.org/multipage/input.html#states-of-the-type-attribute), and [`dialog`](https://html.spec.whatwg.org/multipage/interactive-elements.html#the-dialog-element). Retrieved 2026-08-13; SHA-256 `6585a1852d52a7ce1f4382b8a919423bcfd6c76f1945ba4146d2bad89227aaf6` identifies only the multipage index response, while the section anchors identify the normative claims.
- `[CSS-IMG]` CSS Working Group, [CSS Images Module Level 3, `object-fit`](https://drafts.csswg.org/css-images-3/#the-object-fit) — `fill`, `contain`, and `cover`; retrieved 2026-08-13, SHA-256 `5dcf665f41d9d99677f7c2b1fda077df2a67cb86181ff5c78e168ac42e268059`.
- `[ARIA]` W3C, Accessible Rich Internet Applications 1.3 sections for [`aria-hidden`](https://w3c.github.io/aria/#aria-hidden), [`alert`](https://w3c.github.io/aria/#alert), [`status`](https://w3c.github.io/aria/#status), [`combobox`](https://w3c.github.io/aria/#combobox), [`listbox`](https://w3c.github.io/aria/#listbox), and [name-from-author/content rules](https://w3c.github.io/aria/#namecalculation). Retrieved 2026-08-13; SHA-256 `2fc2a3b949fe83f149e7b48ac33911c03a2c31dae47db8288d3ff047eb221600` identifies the retrieved full ARIA document.
