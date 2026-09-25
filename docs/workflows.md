# Workflow inventory

BubbleEx inventories supplied Bubble app data without running JavaScript,
expressions, actions, workflow endpoints, or network requests. It describes
structure and intent; it does not reproduce Bubble's runtime or backend.

```elixir
{:ok, text} = File.read("app.bubble.json")
{:ok, payload} = Jason.decode(text)
{:ok, inventory} = BubbleEx.workflow_inventory(payload)
{:ok, result} = BubbleEx.export_workflows(payload, "private/workflows")

# In-memory artifacts:
{:ok, %{json: json, markdown: markdown}} = BubbleEx.Workflows.render(payload)
```

```sh
mix bubble.workflows app.bubble.json -o private/workflows
```

The output directory must be absent or empty. Existing evidence is not
overwritten. The files are `inventory.json` and `WORKFLOWS.md`. `AppTree.generate/3`
also includes `workflow-inventory.json` and a root `WORKFLOWS.md`, supplementing
its existing per-page readable views and lossless split. Legacy per-page views
and their coverage retain their original behavior; the inventory is the source
for workflow availability, conditions, references, and diagnostics.

## Inputs and availability

Use a decoded editor export or a payload obtained from an authorized app's
available generated assets using `BubbleEx.Apps.Parser`. Do not obtain inventory
inputs through workflow sample endpoints: a GET workflow can still execute
behavior. The inventory API and CLI are deliberately offline.

Recognized workflow collections are `workflows`, `%wf`, and root `api`. Collections
can be maps or arrays. Discovery retains these collections at any source path,
including pages, reusables, mobile views and unfamiliar owner structures. Owner
availability recognizes `pages`/`%p3`, `element_definitions`/`%ed`, `mobile_views`,
and `api`. Compact `%w` is not a workflow alias; it is also used for layout width.

Missing sections, metadata-only owners, absent workflow fields, and malformed
collections are reported explicitly. `empty` means the supplied recognized
scopes explicitly contain no workflow entries and none are unavailable; it is
never a claim about unsupplied server data. `unavailable` means no entries were
found and some scopes were not supplied. `partial` means missing data alongside
entries, malformed scopes, or unclassified definitions. `present` describes
collection availability, not semantic completeness. A missing `actions` field
is `unavailable`; an explicit empty action map/list is empty with known ordering.

Every collection entry is accounted for, even a scalar or malformed object.
Nonnegative integer `length` members are retained separately as collection
metadata, including on owner and action maps; they are not workflow definitions.
A workflow actually keyed `length` with an object value is still inventoried.
Typed action-bearing records outside known collections are retained under
`unclassified_definitions`. They may be change history or unfamiliar layouts;
they are not counted as active workflows. Unknown source formats without
recognizable workflow structure cannot establish an app-wide absence of workflows.

## Version 3 output contract

- `schema_version: 3`, `explanation_vocabulary_version: 1`, `scope: "supplied_data_only"`, `execution: "never"`, and
  `source_sha256` identify the format and source. The hash covers canonical JSON:
  recursively sorted object keys, original array order, and preserved nulls.
  It is not the hash of the input file's whitespace.
- `scopes` records each inspected or unavailable location, status, count and
  diagnostics. Malformed collection values are retained as `raw`.
- `workflows` retains source key, JSON pointer, complete `raw` definition, event,
  actions, action ordering and diagnostics. Events and actions retain type,
  ID, properties, conditions and reference records. `label` retains the original type label; `explanation` is readable intent where
  supported, otherwise the original label. `description` contains the structured
  explanation, conditions, flags, assignments, unknown pieces and support state.
  `interpretation` mirrors its state except malformed inventory nodes, which
  retain `malformed`. No state means validated runtime behavior.
- `unclassified_definitions` retains candidates separately. `collection_metadata`
  and each workflow's `action_metadata` retain non-definition source members.
- `coverage` reports workflow/action entries, malformed workflow entries,
  candidate entries/actions, unavailable/malformed scopes, and diagnostic count.
  These are accounting counts, not a fidelity or correctness score.
- `diagnostics` are `BubbleEx.Diagnostic` records, serialized as objects with
  `code`, `severity`, `outcome`, `stage` (`"parse"`), `subject`, `path`,
  `details` and `message`. `subject.workflow` is set only for entries of a
  workflow collection (the collection key, or the `id` member in an array); an
  unclassified candidate has no workflow subject and carries its location key as
  `details.source_key`. The top-level list and every workflow, event and action
  list are deduplicated on stage, code, subject and path, and ordered by
  severity, subject, code and path; scope and condition lists hold at most one
  record. Severity and outcome come from the code registry
  (`BubbleEx.Diagnostic.Codes`). Workflow codes are `unsupported_type`,
  `workflow_uninterpreted_field`, `properties_not_evaluated`,
  `unresolved_condition`, `unresolved_reference`, `workflow_unresolved_order`,
  `workflow_alias_collision`, `unclassified_definition`,
  `workflow_malformed_node`, `malformed_actions`, `malformed_properties`,
  `malformed_owner`, `malformed_collection`, `actions_unavailable`, and
  `unavailable_data`.

Source `path` fields are RFC 6901 JSON pointers into the supplied payload.
Unavailable-scope paths identify expected locations that may be absent. Decode
`~1` to `/` and `~0` to `~`; array segments are zero-based indexes. Dereferencing
each workflow/action pointer must reproduce its `raw` value exactly. This allows
independent auditing without trusting the generated prose. No raw values are
redacted, normalized away, or substituted in these records.

## Supported explanation and reference slices

Event labels currently cover clicks, page load, custom events, backend API
events, conditions becoming true and recurring timers. Action labels cover
show/hide/toggle, reset inputs, focus, navigation, URLs, create/change/delete data,
custom states, custom events, backend scheduling, return data and termination.
Other types, including plugins, retain their exact type and source and receive
`unsupported_type`. This vocabulary is deliberately small.

Conditions at node level or in `properties`/`%p` (`condition`, `only_when`, `%c`)
retain `raw`, `path`, `text`, `status`, diagnostics and a structured `expression`.
The event's conditions and each action's conditions remain separate. Multiple
condition representations are preserved individually; their combination is
unresolved. Absence means no condition field was supplied, never an invented
`true`. A supplied false is a supported literal condition; null, zero, empty
strings and bare nonboolean references are not boolean conditions.

The `description` tree uses `kind`, `status`, `text`, `path`, `children`, and
`raw` where a value is supplied. Missing values have no `raw` key. `intent`
contains the event/data-action intent; data actions also expose `target` and
`assignments`, whose ordered children have `field`, `operation`, and `value`.
Names retain stable IDs and definition `evidence` pointers. Pointer-only evidence
identifies a source record; source-bearing records dereference exactly to `raw`.
Operator children are ordered operands; left-to-right `next` chains build nested
operators, while `args` expressions form their own subtrees. Parentheses in
Markdown reflect that tree. Child source spans can overlap their parent: a
reference's source includes the chain whose operators the parent describes.

`fully_supported` means all pieces in that explanation are described by the
bounded static vocabulary with the required source identities available.
`partial` means supported pieces coexist with unknown, missing or ambiguous
pieces. `unresolved` means the explanation has no supported semantic projection
(or a malformed/ambiguous construct prevents it). `unavailable` means required
source or scope is absent. Each subtree carries its own state. None is a runtime
execution guarantee, type checker, or claim about privacy rules or record values.
A disabled workflow/action can still be fully explained; its flags remain visible.

`explanation_coverage` counts states separately for workflow/action nodes,
conditions, and recognized `NewThing`/`ChangeThing` actions. Counts cover active
collection entries only, excluding history candidates. State maps are sparse;
an absent state has count zero. This is independent of `coverage` accounting and
of app-data `availability`. Parent states do not count as additional conditions.

### Bounded vocabulary (version 1)

| Construct | Source forms | Explanation boundary |
| --- | --- | --- |
| JSON literals | string, number, boolean, null | Preserve exact value; no truthiness/coercion |
| Text assembly | `TextExpression`, `entries`/`%e` | Ordered strings/dynamic expressions; ambiguous entry order unresolved |
| Current user | `CurrentUser` | Current session user reference, not a fetched record |
| Page record | `CurrentPageItem` | Direct page scope with supplied `page_item_type`; no reusable-page assumption |
| Element / prior result | `GetElement`, `PreviousStep`; `element_id`/`%ei`, `action_id`/`%ai` | Scoped unique identities; prior result must precede the action in known order |
| Reusable self | `ThisElement` | Supplied reusable owner; custom parameters remain unresolved |
| Page dimensions | `PageData` with exact `Current Page Width` / `Current Page Height` name | Named built-in source; other page data is unresolved |
| Field access | `Message` whose name exactly matches a field in the receiver's known data type | `user_types`, `fields`/`%f3`, `display`/`%d`, `value`/`%v`; never infer field semantics from names |
| Comparison | `equals`, `not_equals`, `greater_than`, `less_than`, `greater_or_equal_than`, `less_or_equal_than` | Explicit binary operator with supplied operand |
| Boolean grouping | `and_`, `or_` | Preserve receiver grouping and nested argument grouping |
| Unary checks | `is_true`, `is_false`, `is_empty`, `is_not_empty`, `logged_in`, `not_logged_in` | No supplied arguments; login checks require the current-user source |
| Create record | `NewThing`; `type_to_create`/`thing_type`/`%tt`, `initial_values`/`%i2` | Type reference and ordered field assignments |
| Change record | `ChangeThing`; `to_change`/`%tc`, `changes`/`%cs` | Dynamic target and ordered field assignments |
| Assignment | `key`/`%k`, `value`/`%v`; absent `action_kind`/`%ak` or an exact `Empty` node | Set only; other mutation kinds explicitly unknown |

Expression aliases are `type`/`%x`, `properties`/`%p`, `next`/`%n`,
`name`/`%nm`, `args`/`%a`. `is_slidable` is retained editor metadata.
Named/compact collisions preclude full support. Unknown properties and operator
subtrees remain explicit and lossless. Numeric text/assignment map keys use the
same complete, unique nonnegative-integer rule as action ordering. Field IDs
with no schema stay visible; built-in fields absent from supplied schema are
not guessed. Searches, plugin/custom-state operators, list mutations, option
sets, arbitrary user-defined operators, create-if-missing behavior and runtime
record lookup are outside this vocabulary.

This extends `AppTree.Expr` through its structured explanation helper. The
legacy `render_condition/1` and `render_text/1` remain unchanged for existing
AppTree consumers; workflow explanations do not use operator humanization as
proof. The [verification record](research/workflow-explanation-validation.md)
distinguishes editor comparisons from payload-only evidence.

### Migration from version 2

Version 3 changes only the diagnostic records. Each is now a
`BubbleEx.Diagnostic`: `code` is an atom in Elixir (a string in JSON), and
records gain `severity`, `outcome`, `stage`, `subject` and `details`. Lists are
deduplicated and ordered as described above instead of following source order,
so `coverage.diagnostics` counts records after deduplication. Four codes shared
with the expression parser are renamed so each code has one severity and
outcome: `unresolved_order`, `alias_collision`, `malformed_node` and
`uninterpreted_field` become `workflow_unresolved_order` (warning, degraded),
`workflow_alias_collision` (warning, preserved), `workflow_malformed_node`
(warning, preserved) and `workflow_uninterpreted_field` (info, preserved). A
`workflow_alias_collision` points at the colliding member (for example
`/…/type`) rather than at the node, so collisions on different members stay
distinct.

### Migration from version 1

Version 2 adds the structured `description`, `label`, vocabulary version and
`explanation_coverage`. Condition `status: "literal"` becomes
`"fully_supported"` for booleans; nonliteral conditions now have support states
and expression trees. Node `interpretation` and readable `explanation` change
as described above. Consumers should branch on `schema_version`, use
`description.status` for semantic coverage, and retain the original `raw`/`path`
for source auditing. Workflow/action counts, ordering rules, canonical hash,
source keys, IDs, raw values, candidates and availability retain their contracts.
New compact previous-step and editor creation-type references can increase
reference counts. Non-evaluation diagnostics describe static inspection, not
failure to explain. The package remains on its existing unreleased version;
this is an explicit inventory format revision, including AppTree's root reports.

Reference recognition covers element IDs (`element_id`/`%ei`), page destinations,
workflow IDs, backend `api_event`, previous-step `action_id`, and creation data
types (`type_to_create`/`%tt`). Page-navigation `element_id` means a page ID.
Element resolution is scoped to the owner; previous-step resolution is scoped
to the workflow. Reusable self IDs are supported. A unique source match is
`resolved`; missing definitions are `unavailable`; duplicate identities are
`ambiguous`. Resolution identifies a source record only, not runtime validity
or execution availability. Dynamic data expressions and field/operator semantics
outside the bounded vocabulary are preserved and explicitly uninterpreted. References never
cause recursive workflow expansion or execution.

Array actions retain their order. Map actions use nonnegative numeric keys only
when every key parses completely and numeric identities are unique. Numeric
sorting puts `2` before `10`. Mixed keys, negative keys or collisions such as
`01`/`1` retain all entries in lexical display order with `unresolved_order`;
that display order is not asserted to be execution order. Numeric gaps are
preserved. Unknown fields and conflicting named/compact fields remain in `raw`
with diagnostics; named fields are used for the display projection.

## Privacy and validation

Reports contain source literals and may include private values. Keep raw
captures and real-app reports private; do not publish them as fixtures. Public
tests use synthetic data and existing sanitized fixtures. The Markdown report
escapes generated headings and uses fences long enough to contain raw source
strings safely. Neither report is a credential-sanitization boundary.

The [milestone verification record](research/workflow-inventory-validation.md)
records controlled editor comparisons, authorized external accounting, and
limitations. It does not assert complete Bubble runtime support.
