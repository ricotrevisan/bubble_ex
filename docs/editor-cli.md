# Bubble editor CLI

`mix bubble.editor` provides guarded, experimental editing of isolated Bubble
web-app branches. It uses Bubble's native editor endpoints directly; Buildprint
is not in the operational path.

The protocol is undocumented. Keep changes small, use a dedicated child branch,
and retain the generated receipt until editor and runtime verification finish.

## Authentication and target safety

Put an authenticated Bubble editor cookie in the process environment. Do not
put it in a plan, shell history, receipt, or issue comment.

```sh
export BUBBLE_EX_EDITOR_COOKIE='(read from your secret manager)'
mix bubble.editor versions my-app child-version-id
```

Read-only commands (`read`, `versions`, `schema`, `savepoint-list`) accept
`test`, `live`, or an active child. Page reads resolve the exact accessible,
non-deleted version before loading paths. Mutations (`apply`, rollback,
`savepoint-create`) and mutation-plan `check` still refuse `test` and `live` and
require an active child whose `parent_version` is `test`. Low-level mutations
independently recheck that identity immediately before submission; constructing
a readable target never grants write permission.

Authenticated editor traffic is pinned to **exactly `https://bubble.io`**. An
alternate origin (including a different port, query, or userinfo) is rejected,
also on manually constructed target structs. Editor requests never follow
redirects or automatically retry. Failure messages/contexts retain only safe
error kinds and numeric HTTP status, never upstream bodies, parser exceptions,
cookies or arbitrary transport reasons.

## Commands

```text
mix bubble.editor schema
mix bubble.editor schema APP VERSION [PLUGIN_GROUP ...]
mix bubble.editor generate-ids COUNT
mix bubble.editor versions APP VERSION
mix bubble.editor savepoint-list APP VERSION
mix bubble.editor savepoint-create APP VERSION MESSAGE
mix bubble.editor read APP VERSION '["%p3","page_key"]'
mix bubble.editor check PLAN.json
mix bubble.editor apply PLAN.json --receipt RECEIPT.json
mix bubble.editor rollback RECEIPT.json --receipt ROLLBACK_RECEIPT.json
```

`read`, `check`, and `apply` always request inline, unchunked fresh state.
`check` makes no mutation. `apply` sends one write batch, never retries it, then
reads every guarded path again. `rollback` applies the receipt's inverse as a
new guarded plan, so it can itself be rejected as stale.

`generate-ids` produces opaque random IDs in the `bx_` namespace. Whole-node
plans generate `_index.id_to_path`, `issues_list`, and `issues_sub` operations.
The pre-write read requires every new ID path to be `null`, making a collision a
stale-plan failure rather than an overwrite.

## Native page discovery API

Reuse `BubbleEx.Editor` directly from an application; no Buildprint, separate
client implementation, or editor export is needed:

```elixir
alias BubbleEx.Editor
alias BubbleEx.Editor.{Snapshot, Target}

with {:ok, target} <- Target.readable("my-app", "test", cookie),
     {:ok, pages} <- Editor.discover_pages(target),
     reference when not is_nil(reference) <- Enum.find(pages, &(&1.name == "index")),
     {:ok, snapshot} <- Editor.read_page(target, reference) do
  Snapshot.fetch(snapshot, reference.path)
end
```

`Target.new/4` remains child-only for existing editing callers;
`Target.readable/4` explicitly enables read identities including `test`/`live`.
Both keep the cookie redacted in `Inspect`. Supply `cookie` from environment or
a secret store, never from request params. Do not serialize target structs.

All native editor requests use isolated shared HTTP construction: only the
explicit editor cookie/headers and native body are retained. Ambient credential,
header, query and payload options are discarded from BubbleEx application/process
defaults, and Req global defaults/plugins are not merged. Trusted transport/budget
configuration and test adapters remain supported; unrelated ordinary HTTP calls
keep their existing defaults behavior.

`discover_pages/2` verifies authenticated editor access/version first, then
fetches the anonymous app runtime HTML and dynamic bundle with **no editor
cookie or authorization header**. Enforced anonymous HTTP mode allowlists
transport/budget configuration and discards credential-generating options
(including AWS signing), arbitrary headers, query params and request payloads
from both application and process defaults. It reuses `Apps.Parser` (including
native `Object.assign` page patches), then reads only shallow page metadata;
element/workflow descendants are not indexed for discovery. All present native
and readable ID/name fields must agree. All requests are bounded, GET-only on
the runtime, and refuse
redirects. Editor/runtime denial or malformed input stops the operation: no
fallback to another endpoint, version, cookie-bearing runtime request, or guessed
page path. The default initial runtime route is `index`; an explicitly selected
route can be supplied as `runtime_page: "login"`.

The result is a sorted list of `%BubbleEx.Editor.PageRef{}` values:

- `appname`, `version`: exact editor target identity
- `key`, `id`, `name`: distinct native page map key, Bubble ID, display name
- `path`: `["%p3", key]`, never a path guessed from the display name
- `source`: `kind: :runtime`, runtime URL, source JSON pointer (native or readable
  key form preserved)

Discovery covers the runtime's **exposed inventory**, not a complete editor
export; mobile views and reusables are excluded. Missing/ambiguous IDs, duplicate
keys/IDs or an empty inventory fail closed. A runtime requiring authentication,
an app with only a custom-domain runtime, or an inaccessible initial route is
not silently bypassed. Custom-host/runtime-cookie support should be designed
explicitly rather than forwarding the editor session.

`read_page/3` verifies reference app/version/path/key before any request, reads
only that editor path, then requires the returned page's type (`Page`), ID and
name to match. Missing, renamed, substituted, malformed or conflicting-identity
pages fail without emitting their contents. Rediscover after such a failure.
References are identity checks, not authorization tokens: Bubble's authenticated
editor still decides access. Successful snapshots intentionally contain raw
page design/workflow data; keep them in memory and do not log, export or expose
them as HTTP error contexts. Callers presenting metadata can convert references
with `Map.from_struct/1`; only explicit page-selection reads should expose
content to an authorized operator.

## Plan format

Every plan fixes its target and base revision. Every operation fixes its prior
value.

```json
{
  "appname": "my-app",
  "version": "child-version-id",
  "base_last_change": 123456,
  "references": {
    "existing-reusable-id": "%ed.existing_reusable"
  },
  "operations": [
    {
      "op": "set",
      "path": ["%p3", "page", "%el", "heading", "%p", "%3"],
      "expected": "Old copy",
      "value": "New copy"
    }
  ]
}
```

The operations are:

- `set`: change one allowlisted leaf.
- `put`: create a complete supported page, reusable, element, or workflow node.
- `remove`: remove one complete supported node.
- `move`: move an element within the same page or reusable owner.

External `%ci` and `%ei` references in created nodes must appear in
`references`, mapped to their exact current `_index.id_to_path` value. IDs
created by the same plan resolve automatically. Duplicate and unresolved IDs
are rejected.

Nested `put` and `remove` operations must also provide the owner ID and exact
decoded descendant-ID order:

```json
{
  "op": "remove",
  "path": ["%p3", "page", "%el", "description"],
  "expected": {"%x": "Text", "id": "description-id", "%p": {"%3": "Copy"}},
  "owner_id": "page-id",
  "owner_issue_ids": ["description-id", "other-id"]
}
```

This guards Bubble's owner-level `issues_sub` index. Receipts also retain the
exact post-edit order so rollback restores the serialized index value.

### Installed plugins: discover, do not inventory

`schema APP VERSION [PLUGIN_GROUP ...]` reads the branch's installed plugin
versions and fetches their native editor definitions. Its output contains names,
field IDs/types/options, element-owned actions/events/states, and a schema hash.
No plugin source code is executed or emitted. Boolean built-in plugin entries
are skipped; inaccessible or malformed selected contracts fail closed.

For plugin edits, add `plugin_types: [GROUP]` and
`plugin_schema_hashes: {GROUP: HASH}` to the JSON plan, using the discovered
values. A plugin property `set` also supplies `plugin_type: GROUP-NODE_ID`.
Check/apply independently rediscover the declared installed contracts, verify
the hashes, and validate field IDs and values. A supplied plan cannot authorize
an invented field. The node discriminator and installed version are guarded in
the fresh state read. Rollback retains the schema pins, so an intervening plugin
update requires a reviewed new plan, not a blind inverse replay.

Supported plugin field editors: StaticText, Color, Dropdown with declared
options, StaticNumber, Checkbox, and literal DynamicValue text/number/boolean
(including declared lists). Unknown editor types, informational fields and
dynamic expression bindings without result-type validation fail explicitly.
Global/server plugin actions are not enabled. Discovery is extensible across
plugin identities; support is bounded by field and expression semantics, not a
catalogue of plugin IDs. There is no atomic lock against concurrent plugin
definition changes; keep editor/plugin development quiet during apply and verify
runtime behavior afterward.

## Supported operations

| Area | First-release support |
| --- | --- |
| Owners | `%p3` web pages and `%ed` reusable definitions |
| Elements | `Page`, `CustomDefinition`, `Group`, `Text`, `Button`, `Popup`, `CustomElement`, and discovered installed-plugin types |
| Properties | Name; bounded text, paint, typography, size, spacing, order, visibility, and responsive/container-layout fields; discovered plugin fields with supported value types |
| Expressions | `TextExpression`, `GetElement`, `Message`, `ArbitraryText`, `PageData`, and `State` wherever a supported value contains typed expression nodes |
| Workflows | `ButtonClicked` and discovered element-owned plugin event nodes |
| Actions | `ShowElement`, `HideElement`, `SetCustomState`, and discovered element-owned plugin action nodes; map order is preserved |
| Structure | Whole-root creation/removal, nested creation/removal with owner index guards, and same-owner moves |

Unknown node types and typed expressions fail before a write. Unknown fields
inside complete supported nodes are retained. Leaf edits do not re-encode their
owners, so unrelated/unknown fields are not sent back to Bubble.

## Failure and recovery model

- A changed `last_change`, expected property, reference path, node type, or
  generated-ID slot rejects the plan before writing.
- A write is submitted once. If its acknowledgement is missing or malformed, a
  fresh read classifies it as fully applied, not applied, or mixed/ambiguous.
  Mixed outcomes require manual inspection; the CLI does not guess or replay.
- A receipt contains only target metadata, revisions, touched paths, sanitized
  acknowledgement fields, and a guarded inverse plan. It contains no cookie.
- Native savepoint creation is also single-submit. Bubble may return a non-JSON
  acknowledgement; the CLI compares fresh restore history and revision data to
  reconcile a newly created marker without replaying the request.
- `savepoint-list` emits only message and timestamp fields. Native savepoint
  restore is not exposed yet because restore outcome/reconciliation semantics
  have not been safely exercised.

Branch creation/merge, deployment, runtime records/files/logs, plugin
publishing, backend workflows, schema/privacy changes, API Connector secrets,
and mobile/global app settings remain outside this release.
