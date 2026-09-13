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

## Version 1 output contract

- `schema_version`, `scope: "supplied_data_only"`, `execution: "never"`, and
  `source_sha256` identify the format and source. The hash covers canonical JSON:
  recursively sorted object keys, original array order, and preserved nulls.
  It is not the hash of the input file's whitespace.
- `scopes` records each inspected or unavailable location, status, count and
  diagnostics. Malformed collection values are retained as `raw`.
- `workflows` retains source key, JSON pointer, complete `raw` definition, event,
  actions, action ordering and diagnostics. Events and actions retain type,
  ID, properties, conditions and reference records. A label describes the type's
  intent only; `label_only` does not mean validated runtime support.
- `unclassified_definitions` retains candidates separately. `collection_metadata`
  and each workflow's `action_metadata` retain non-definition source members.
- `coverage` reports workflow/action entries, malformed workflow entries,
  candidate entries/actions, unavailable/malformed scopes, and diagnostic count.
  These are accounting counts, not a fidelity or correctness score.
- `diagnostics` includes source pointers and stable codes such as
  `unsupported_type`, `uninterpreted_field`, `properties_not_evaluated`,
  `unresolved_condition`, `unresolved_reference`, `unresolved_order`,
  `alias_collision`, `unclassified_definition`, `malformed_node`,
  `malformed_actions`, `malformed_properties`, `malformed_owner`,
  `malformed_collection`, `actions_unavailable`, and `unavailable_data`.

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
remain lossless. Literal booleans have literal descriptions. Existing AppTree
expression rendering may provide a partial display for a narrow condition shape;
it remains unresolved. Complex expressions, operators and plugin semantics are
not evaluated or guessed. All other properties remain present and carry an
explicit non-evaluation diagnostic. Disabled flags, scheduling parameters,
privacy settings, data changes and custom-state values remain in those records.

Reference recognition covers element IDs (`element_id`/`%ei`), page destinations,
workflow IDs, backend `api_event`, previous-step `action_id`, and creation data
types (`type_to_create`/`%tt`). Page-navigation `element_id` means a page ID.
Element resolution is scoped to the owner; previous-step resolution is scoped
to the workflow. Reusable self IDs are supported. A unique source match is
`resolved`; missing definitions are `unavailable`; duplicate identities are
`ambiguous`. Resolution identifies a source record only, not runtime validity
or execution availability. Dynamic data expressions and field/operator semantics
outside this slice are preserved and explicitly uninterpreted. References never
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
