# WTF-271 editor CLI acceptance plan

This plan turns the first-release portion of
[`buildprint-editor-cli-scope.md`](buildprint-editor-cli-scope.md) into bounded,
observable cases. The authorized live target is `tiptap-plugin`, child app
version `43jvs` (`wtf-271-editor-diff`). Main/test and live are excluded.

## Safety invariants

1. Every plan names the Bubble ID and exact child app version. The CLI resolves
   that version immediately before a read or write and rejects `test`, `live`,
   deleted versions, and versions not parented by `test`.
2. Every plan carries the `last_change` from a fresh read and every operation
   carries an exact expected value. A changed revision or value makes the plan
   stale; no write is sent.
3. The CLI writes only allowlisted page/reusable paths and supported semantic
   nodes. Index writes are generated internally. Unknown fields in existing
   maps are preserved because updates target leaves, never re-encode owners.
4. Writes are never automatically retried. A missing/invalid acknowledgement
   triggers a fresh read. The result is classified as applied, not applied, or
   mixed/ambiguous and returned with sanitized evidence.
5. Every acknowledged write is read back from a fresh request. A receipt stores
   the before/after values, acknowledgement revision, verification revision,
   and an inverse guarded plan. Rollback is another guarded write; for nested
   nodes it also restores the exact serialized owner issue-index order. It does
   not erase Bubble's append-only editor history.

## Executable acceptance cases

| ID | Case | Pass condition | Result |
| --- | --- | --- | --- |
| A1 | Authenticated branch read | `versions` identifies `43jvs` as an active child of test; `read` returns an exact subtree and `last_change` without Buildprint. | Passed live |
| A2 | First property edit | Rename one existing element on `43jvs`; write acknowledgement and fresh readback agree; rollback restores the old value and is read back. | Passed live |
| A3 | Stale plan | Change the base revision or expected value in a fixture/live plan; `check` and `apply` reject it before transport records a write. | Passed live and offline |
| A4 | Ambiguous outcome | Simulate timeout-after-commit, timeout-before-commit, and partial application. Reconciliation reports applied, not-applied, and ambiguous respectively and never resubmits. | Passed offline; malformed native savepoint acknowledgement reconciled live |
| A5 | Unknown preservation | Set a supported leaf on a fixture owner containing unknown keys; the resulting write touches only that leaf and the unknown values remain byte-for-byte equivalent in readback. | Passed by leaf-only write inspection and fresh readback |
| A6 | Bounded creation/removal | Create a page subtree containing supported nodes and generated ID indexes; read it fresh; remove only those nodes/indexes; unrelated paths remain unchanged. | Page creation and nested remove/restore passed live; complete page/reusable removal is offline only |
| A7 | Useful demo | Create/maintain one responsive page with two instances of an existing reusable that owns custom states and frontend workflows and contains an installed plugin instance; persisted page/reusable/workflow/plugin references validate. | Passed live using the branch's existing reusable; complete definition creation passed offline |
| A8 | Runtime/editor verification | Reload the exact editor branch, run its version-test page at desktop and narrow widths, and exercise the plugin workflow/state feedback independently in both reusable instances. | Passed live |
| A9 | Unsupported edits | Unknown roots, element kinds, expression nodes, actions, plugin types, cross-owner moves, and schema/runtime/deploy operations fail clearly before a write. | Passed offline |

## First-release support boundary

- Owners: web pages (`%p3`) and reusable definitions (`%ed`).
- Elements: `Page`, `CustomDefinition`, `Group`, `Text`, `Button`, `Popup`,
  `CustomElement`, plus installed plugin element types from freshly discovered contracts.
- Leaf properties: names; literal text; responsive size/min/max, padding, margin,
  gap, order, visibility/collapse, alignment/container layout; bounded paint and
  typography fields; discovered plugin fields with supported literal value types.
- Expressions: literal JSON values plus `TextExpression`, `GetElement`,
  `Message`, `ArbitraryText`, `PageData`, and `State` typed nodes.
- Frontend events/actions: element click, installed plugin event, show/hide
  element, set custom state, and discovered element-owned installed plugin
  actions. Action order is preserved.
- Moves: reorder and same-owner reparent only. Cross-owner moves are rejected.

Runtime records, logs, files, plugin publishing, migrations, hosted history,
Bubble branch merge, deployment, privacy/schema destruction, backend workflows,
API Connector/secrets, and mobile/global roots are not accepted in this release.
