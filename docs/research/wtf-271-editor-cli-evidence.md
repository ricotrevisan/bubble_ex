# WTF-271 editor CLI evidence log

Updated during implementation. Sanitized only; no cookies, tokens, headers, or
unrelated app payloads belong here.

## 2026-09-14 — independent read primitive

- Opened the authenticated Bubble editor in this thread at the authorized URL:
  `tiptap-plugin`, app version `43jvs`, page `index`.
- Observed the editor read endpoint
  `POST /appeditor/load_multiple_paths/tiptap-plugin/43jvs`.
- The request body is `{path_arrays: [...], no_chunking: boolean}`. With
  `no_chunking: true`, Bubble returned complete JSON data inline plus
  `last_change: 65049763350`; no internal path codec or Buildprint was used.
- Resolved page `modern-popover-reuse-check` to storage key
  `modern_popover_reuse_check`. Its page ID is `bpmprcheckpage`.
- Its `row-actions 1` and `row-actions 2` instances are `CustomElement` nodes
  referencing reusable ID `bpre1ddfb5e4a82`. Their ID index entries point to
  their exact `%p3...%el...` paths.
- Native savepoint/restore semantics, write replay requirements, and page-root
  creation metadata remain under investigation at this point.

## 2026-09-14 — property write and rollback

- A fresh CLI read found revision `65049763350` and the existing
  `row-actions 1` name.
- A guarded one-property write renamed it, received an acknowledgement, and was
  independently read back at `65050185596`.
- `rollback` consumed the receipt's inverse plan and restored the original name
  at `65050186379`. A full editor reload showed the original tree.
- Re-running the old plan after a later page creation rejected it as stale and
  did not change the then-current revision.

## 2026-09-14 — page/reusable/plugin workflow acceptance

- The CLI created page key `wtf_271_cli_demo` at revision `65050192231`, with a
  responsive column layout, heading/body text, and two `CustomElement`
  instances. Both reference existing reusable ID `bpre1ddfb5e4a82`; the plan
  now records and guards its exact `_index.id_to_path` value.
- Fresh reads verified the reusable's two custom states, its installed plugin
  element type, a `ButtonClicked` workflow, the installed-plugin action, and
  plugin event workflows that update reusable-owned state.
- A second CLI plan maintained the page copy and was verified at `65050212672`.
- In version-test at desktop width, opening the first menu fired its plugin
  event, `Open project` updated the readout, and closing fired the close event.
  Opening/archiving in the second instance changed only its owned readout; the
  first retained its result. No real project was changed.
- At a 390 by 844 CSS-pixel viewport the page wrapped without horizontal
  clipping. A final reload after all recovery work showed both instances and
  the maintained copy with no console errors.

The reusable definition was already present on this authorized branch. Live
acceptance created and maintained its page instances and guarded/edited the
installed plugin through this CLI. Complete reusable/workflow/plugin creation
is exercised by the sanitized offline fixture, not by adding a second live
copy of the existing reusable.

## 2026-09-14 — native savepoint and failure recovery

- Editor bundle inspection identified native endpoints for branch creation,
  savepoint creation (`/appeditor/commit_test_version`), history reads, and
  restore. Only savepoint create/list were enabled because native restore
  reconciliation has not been safely exercised.
- One `WTF-271 CLI demo acceptance` savepoint request returned a non-object
  acknowledgement. The CLI did not replay it. Fresh history contained exactly
  one new `commit:WTF-271 CLI demo acceptance` marker, and a fresh definition
  read advanced to `65050223419`; the outcome was reconciled as created.
- A nested CLI removal deleted only the demo description and its ID/index
  entries at `65050254264`. Receipt rollback restored the complete node and
  owner index at `65050255970`.
- That run revealed that set-equivalent rollback could reorder `issues_sub`.
  The plan/receipt format was tightened to retain an exact post-operation list.
  A second live remove/rollback finished at `65050263219` with the serialized
  owner index unchanged byte-for-byte.
- A registered installed-plugin property (`AFU`) was changed with both value
  and `%x` type guards, verified at `65050278688`, then restored and freshly
  read as `Row actions` at `65050278876`.

## Offline verification corpus

- The fixture creates a page plus reusable, two reusable instances, a custom
  state, an installed plugin node, a button workflow, a plugin event workflow,
  ordered plugin/native actions, responsive properties, and an unknown field.
- Tests cover exact target/revision/value guards, protected targets, generated
  ID/index writes, duplicate and unresolved IDs, reference guards, nested owner
  index maintenance, same-owner moves, unsupported nodes/properties/typed
  expressions, receipt inversion, timeout-before/after reconciliation, partial
  ambiguous writes, savepoint acknowledgement reconciliation, and output
  sanitization.

## Decisions

- Use `load_multiple_paths` with `no_chunking: true` as the fresh-state and
  readback primitive.
- Make branch resolution, `last_change`, and exact expected values independent
  gates. Do not infer compare-and-set support in Bubble's write endpoint.
- Never retry a write automatically. Reconcile against intended and prior
  values after any unknown outcome.
- Use random `bx_` IDs and require every generated `id_to_path` slot to be null
  in the same fresh preflight read. Do not claim ownership of Bubble's counter.
- Require external `%ci`/`%ei` references to include their exact current index
  path. Resolve references created in the same plan and reject duplicates.
- Keep full accepted inventory in `buildprint-editor-cli-scope.md`; this file
  records implementation evidence rather than replacing that scope.

## Remaining limitations

- Native savepoint restore and branch creation endpoints are documented
  research findings, not enabled commands. Branch inspection works against an
  existing isolated child; branch merge and deployment remain prohibited.
- This is not a full BubbleScript compiler. Conditions beyond the explicitly
  typed nodes, backend workflows, schema/privacy edits, API Connector, runtime
  records/files/logs, mobile/global roots, and unsupported plugin field types fail or are
  outside the command surface.
- No full before/after `bubble.json` export diff was taken. Safety instead rests
  on leaf-only updates, exact path readback, generated index guards, editor
  reload, and runtime exercise.

## Installed-plugin discovery follow-up (2026-09-16)

Replaced the product-specific `plugin_property_keys` / `plugin_node_suffixes`
registries with `BubbleEx.Editor.PluginSchema`. Read the selected branch's
`settings.client_safe.plugins`, then fetch each selected installed version via
native `GET /appeditor/get_raw_plugin?plugin_id=ID&version=VERSION`. The editor
bundle and authenticated browser requests corroborated this route. Independent
CLI GET requires an Origin/Referer header; without it Bubble returns 400
`No origin`. Cookies remain process-local and absent from fixtures/receipts.

Live CLI discovery at revision `65050278876` returned:

- Modern Dropdown/Popover: 25 web element/event/action nodes; schema hash
  `f8d4f63073245aa683a1299cb86a908e8bd73bfe92265e0061f09b7a1e71e9d4`.
- Tiptap: 76 nodes, including descriptive `toc_element` / `heading_clicked`
  IDs; schema hash
  `7001d6e01f8752cdcbdbca3dd2589da48f8ae30ea0bf31621e46e66b371b9272`.

The actual Popover actions are AEB Open, AEC Close, AED Toggle. The earlier
manual interpretation of AED as Open was incorrect. Definitions provide names,
typed fields, states, event/action ownership and options without executing code.
Fixtures retain sampled declarative metadata only, not headers or plugin JS.

Plans now pin schema hashes; check/apply refetch authoritative definitions and
reject missing/stale pins, unknown fields, unsupported types and wrong node
roles. Installed version and instance discriminator are fresh-read guards.
Mutable `current` versions are not assumed stable. Reconciliation was corrected
so unchanged guards do not misclassify timeout-before-commit as ambiguous.

Controlled acceptance: CLI check passed; AFU on the existing Popover instance
was edited at `65063665952`, independently read from the authenticated browser,
then rolled back at `65063669467`. A second browser read verified `Row actions`
restored. No Main/test/live writes, merges, deployment or Buildprint were used.
This follow-up did not repeat the entire demo runtime exercise recorded above.

Reproduction: run `mix bubble.editor schema tiptap-plugin 43jvs` with the two
plugin groups from `live_plugin_property_plan.json` and the Tiptap group
`1670612027178x122079323974008830_current`. Refresh the plan's base revision and
schema pin from fresh reads before check/apply; the checked-in live fixture is
historical and deliberately stale after rollback. Retain an apply receipt and
use `rollback RECEIPT --receipt NEW_RECEIPT` to restore. Temporary receipts for
this run are in `/tmp/bubbleex-schema-acceptance.husZoB/` (not durable storage).

Validation: `mix quality` passed (836 tests, 6 doctests, 47 excluded). Coverage
includes arbitrary plugin identities, string node IDs, schema/version changes,
type/enum validation, mobile exclusion, sanitized transport failures, no-write
schema/field rejection, receipt pins and guarded timeout recovery.

Boundaries: support remains semantic, not universal. Literal DynamicValue
text/number/boolean, static text/number/color/dropdown/checkbox fields and their
declared lists are validated. Dynamic plugin expression bindings without result
type proof, unsupported field editors, global/server actions and mobile nodes
are rejected. Native expression handling is unchanged. No atomic schema lock
is claimed: concurrent plugin changes during a write remain a race requiring
quiet development and runtime verification. Boolean built-in plugins are skipped
by discovery; selected inaccessible/malformed schemas fail closed.
