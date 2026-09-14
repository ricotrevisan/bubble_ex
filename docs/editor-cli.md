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

The CLI refuses `test` and `live`. Before every read or write it resolves the
exact version and requires an active child whose `parent_version` is `test`.

## Commands

```text
mix bubble.editor schema
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

## Plan format

Every plan fixes its target and base revision. Every operation fixes its prior
value.

```json
{
  "appname": "my-app",
  "version": "child-version-id",
  "base_last_change": 123456,
  "plugin_types": ["1787127143284x497506916809310200_current"],
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

An installed-plugin property edit adds `plugin_type`. The current first-release
registry supports the Modern Popover element type ending in `-AEA` and property
codes `AFA` through `AFU`, event suffixes `AEG`/`AEH`, and action suffixes
`AEC`/`AED`, as enumerated by `mix bubble.editor schema`. The plan automatically
guards the node's `%x` discriminator.

## Supported operations

| Area | First-release support |
| --- | --- |
| Owners | `%p3` web pages and `%ed` reusable definitions |
| Elements | `Page`, `CustomDefinition`, `Group`, `Text`, `Button`, `Popup`, `CustomElement`, and allowlisted installed-plugin types |
| Properties | Name; bounded text, paint, typography, size, spacing, order, visibility, and responsive/container-layout fields; registered plugin properties |
| Expressions | `TextExpression`, `GetElement`, `Message`, `ArbitraryText`, `PageData`, and `State` wherever a supported value contains typed expression nodes |
| Workflows | `ButtonClicked` and allowlisted installed-plugin event nodes |
| Actions | `ShowElement`, `HideElement`, `SetCustomState`, and allowlisted installed-plugin action nodes; map order is preserved |
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
