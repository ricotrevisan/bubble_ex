# Native Bubble web-element support matrix

Updated 2026-09-11 after the input-source repair, overlay audit, and initial
landing-page renderer fixes.
This is the current implementation and evidence ledger. The earlier proposed
S1/S2 tiers and catalog research remain in the [historical matrix](native-element-support-matrix-history.md).

BubbleEx exports portable HTML/CSS for modern responsive web apps. It retains
unresolved expressions, conditions, workflows, and unsupported definitions as
metadata; it does not execute Bubble's runtime. A native lowering means code
exists. A frozen case establishes parity only for its exact source, initial
state, viewports, browser, and declared pixel tolerance. Neither means every
variant of an element is supported.

## Current lowering and evidence

Case IDs below identify the committed [fidelity corpus](../../test/support/fidelity/cases).
There are 19 cases. The [runner contract](../../test/support/fidelity/README.md)
defines the geometry, typography, collapse, document-size, semantics, and pixel gates.

| Element | Current static export | Frozen evidence | Limits |
|---|---|---|---|
| Page / Group | `main` / `div`; Fixed, Align to Parent, Row, Column; common box/paint; literal text/number data with explicit parent forwarding | `bpmkbvvo` layouts; typed literal data has unit tests and landing-page observations | Controlled layouts only; no database loading, workflow clicks, or animated collapse; data requires matching declared type |
| Text | Paragraph and explicit H1–H4 semantics; literal/resolved text | `bpmkbvvo`, `bpcybc` | Other heading enums and runtime content are not characterized |
| Text, BBCode subset | Safe `b`, `i`, `u`, `s`, `ul`, `ol`, `li`, `url` markup | `bpwipyqn` | Not full Bubble rich text, automatic link recognition, or arbitrary HTML |
| Image | Public/resolved Stretch, Rescale, Zoom, Adjust-height; portable assets | `bprkyexk`, `bpgwgmpz` | No authenticated image fetching, PDF thumbnails, or runtime sources |
| Shape | Decorative paint, border, radius, rotation, dimensions | `bpmkbvvo` | Workflow behavior remains metadata |
| Button | Label; static Font Awesome 4 icon and icon+label; unambiguous single navigation action can lower to a link | `bpmkbvvo`, `bpiordvb` | No general click-workflow execution; other icon families/variants remain unsupported |
| Link | Text or static Font Awesome 4 icon/icon+label; explicit destination; new tab, nofollow, literal disabled | `bptaixqv`, `bpaupfbj` | Unresolved destinations stay bindings; no inferred navigation |
| Icon | Static Font Awesome 4, Material outlined, and Phosphor regular/bold/fill SVG bundled locally | `bpgwgmpz` covers FA4; Material/Phosphor have unit and landing-page observations | Other families, spin, and runtime variants remain placeholders |
| Floating Group | Always-visible, top-right, Column container | `bpgwgmpz` | Other anchors, reusable bases, and show/hide states lack parity evidence |
| Multiline Input | Fixed-height or static fit-height `textarea` | `bpqqfagk`, `bpuzekut` | Fit-height is the captured initial content; Bubble autosize/validation is not executed |
| Checkbox | Literal checked/unchecked native checkbox | `bpqqfagk` | Dynamic state, binding, and workflows are not executed |
| Dropdown / Radio Buttons | Literal/static choices as native controls | `bpqqfagk` | Dynamic choices remain placeholders; native interaction is not Bubble workflow behavior |
| Input: Text / Email / Password | Native input type, literal value/placeholder | `bpmkbvvo`, `bpewigqu` | No auto-binding or Bubble validation/masking engine |
| Input: Integer / Decimal / Percentage / Currency / US Phone | Text input with applicable input mode and captured initial formatting | `bpqkcldq`, `bpjehwxg` | Static formatting only; percentage `0.25` displays `25%`, currency `19.99` displays `$19.99`; no editing-mask parity |
| Input: Date / Euro date / Address / Text (numbers only) | Text input; numeric input mode where applicable | `bpqkcldq`, `bpjehwxg`, `bpizatjd`, `bpoyzixi` | Dates/address are captured empty placeholders; no Google autocomplete, date parsing, or live numeric filtering |
| Date/Time Picker (`DateInput`) | Date and date+time variants as text inputs | `bpizatjd`, `bpoyzixi` | Captured empty state only; no picker UI, time-only lowering, timezone, or date validation contract |
| File Uploader (`FileInput`) | Native file input | `bpoyzixi` | Local browser selection only; no upload, storage, privacy, or service behavior |
| Picture Uploader (`PictureInput`) | Native file input accepting images | `bpdimzwm` | No Bubble upload/preview pipeline; browser file-picker behavior is intrinsic |
| Slider Input | Simple native range; paired native ranges for two handles | `bplvejcw`, `bpndkqfs` | Static geometry/paint within declared tolerances; two native controls do not reproduce Bubble's coupled-handle rules |
| Search Box (`AutocompleteDropdown`) | Static text choices as search input + datalist | `bplvejcw` | Dynamic/Google search remains a placeholder; native suggestions differ from Bubble |
| Popup | Hidden runtime placeholder; complete container definition retained | `bpndkqfs`, `bptvorpv` initial states | **No visible Popup support.** Opening, backdrop, placement, focus, and dismissal require runtime behavior |
| Group Focus | Hidden runtime placeholder; reference and complete container definition retained | `bptvorpv` initial state | **No anchored menu behavior.** Showing, reference placement, and outside-click dismissal are characterized only in Bubble |
| Repeating Group | One horizontal show-all row from a bounded literal list; direct Image/Text/Shape/Icon templates; other variants remain placeholders | `bpgwgmpz` empty boundary; literal lists have unit tests and landing-page observations | No searches, nested templates, pagination, animation, or virtualization; at most 100 items and 1,000 projected leaves |
| HTML: literal basic SVG | Sanitized paths, circles, rectangles, groups, and simple numeric rotations | Unit tests and landing-page observations | No scripts, animation, external references, arbitrary markup, or dynamic HTML; other geometry and transforms remain unsupported |
| HTML: supported style template | One sanitized style block with literal numbers or unique-element width/height measurements in pixel declarations | Export tests, browser load/resize/fallback checks, and landing-page observation | No source scripts, general expressions, ambiguous references, transformed measurements, feedback, or workflow-driven updates; the local helper is generated by the exporter |
| Table / Video / Map / Alert / other HTML / Built on Bubble | Unsupported placeholders | No native parity case | No promotion based only on an approximate box |
| Reusable definition / instance | Static definitions and recursive expansion with stable instance IDs; supplied literal scalar parameters in instance scope, including nested forwarding | `bpgwgmpz` static expansion; parameters have unit tests and landing-page observations | Missing references/cycles emit findings; parameter defaults/conditions, runtime states, and Popup/Floating reusable bases lack full parity evidence |

Installed plugin elements remain placeholders, including Bubble-made plugins
such as Rich Text Editor and Multiselect Dropdown. Native mobile and the legacy
responsive renderer are outside this web contract. Catalog provenance is retained
in the historical matrix; current lowering is defined by
[`Normalize`](../../lib/bubble_ex/frontend/normalize.ex).

The landing-page work additionally lowers compact shared styles, user design
tokens, authored aspect-ratio image borders, floating reusable anchors, and
exact page-width breakpoint paint/spacing conditions, including shared styles and
literal thresholds. Fetched exports can apply
direct logged-out visibility and snapshot a literal formatted year while
retaining the original bindings. Material outlined icons also work in static
icon buttons and links. These are bounded implementations with unit tests and
private observations; they do not expand the 19 committed cases' parity claims.
See the [landing-page rubric](landing-page-grading.md) for the separate acceptance
test and remaining release gates.

## Corrections to earlier support claims

The four repaired input cases now use valid Bubble enums and source literals
from authorized branch `83jop`. Invalid enum aliases could render fallback text
fields while still passing a screenshot comparison. The source validator and
independent Input-value checks now reject those cases. See the
[input audit](frozen-input-validation-audit.md).

The old `bpndkqfs` case did not prove a visible Popup. It excluded the popup from
correlated nodes and changed `is_visible` to false in the frozen payload. The
recapture now keeps the actual `is_visible: true` source, correlates the popup,
and verifies its initially closed state. BubbleEx no longer maps that flag to
`<dialog open>` or treats Group Focus as an ordinary visible group.

The new `bptvorpv` case freezes the initial state at 390×900 and 1440×900 with
zero material pixel tolerance. Separate source-only captures record Popup
opening/closing and Group Focus opening/outside-click dismissal. Those captures
explain the runtime boundary; they are **not** interactive export parity evidence.
See the [overlay audit](overlay-runtime-audit.md) for the reproduction and results.

## Remaining gates

- A future runtime adapter needs its own contract and interaction evidence for
  overlays, data-driven controls, workflows, focus, and dismissal. Hidden initial
  parity cannot satisfy that gate.
- Every new format or enum needs valid editor/schema evidence and a source
  capture before it can establish a frozen-case claim.
- Input editing/validation states, other Floating Group anchors, reusable overlay
  bases, authenticated assets, and the unsupported native kinds remain gaps.
- Existing controlled cases do not establish exhaustive theme/style precedence,
  accessibility, browser, or responsive coverage for arbitrary apps.
- Shared reusable icon IDs need instance-scoped source geometry correlation.
  `bpgwgmpz` retains both icons' structure and full-page pixels; its former
  ambiguous "absent" icon sample was withdrawn in the overlay audit.
