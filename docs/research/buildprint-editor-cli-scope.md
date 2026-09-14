# Buildprint app-editing CLI inventory

Inspected 2026-09-14 against installed Buildprint CLI **5.0.12**. Tracking:
[WTF-271](https://linear.app/ricowtf/issue/WTF-271).

## Recommendation

Replace the **app-definition editing loop** for our web demo apps first:
read a branch, plan and validate a scoped edit, apply, then verify persisted
state. Prioritize pages, elements, responsive layout, reusables, custom states,
bindings, and the frontend workflows needed to connect installed plugins.

This is an inventory and proposed scope, not an implementation or a promise of
Buildprint compatibility. No app mutations were performed during this audit.

Buildprint does not expose separate top-level commands for adding a button or
editing a workflow. Those changes are authored in BubbleScript files and sent
through `apply`. Command parity alone would therefore conceal the real scope:
the supported app definitions and their semantics.

## Command inventory and disposition

The table accounts for all functional command families in `buildprint --help`;
generic `help` is omitted. Subcommands are listed where relevant to editing.

| Command family | Role | Proposed disposition |
| --- | --- | --- |
| `project clone` | Branch snapshot to local BubbleScript workspace | Core: equivalent fresh editor-state read and editable representation; do not require BubbleScript syntax compatibility |
| `project list`, `project info` | Discover linked apps and metadata | Minimal app inspection; a full linked-project directory is optional |
| `sync` | Fetch current snapshot and merge regenerated source | Core freshness/reconciliation; automatic Git merge parity can wait |
| `check [--full] [--json]` | Validate source and explain planned changes | Core: validate supported edits, resolve references, show changes without writing |
| `apply [--json]` | Validate and write workspace changes, regenerate source | Core: bounded write batches, readback verification, receipts and failure reconciliation |
| `branch`, `branch list`, `branch create` | Resolve, inspect and create development branches | Supporting scope: explicit target identity and isolated editing |
| `savepoint create/list/restore` | Native Bubble editor recovery | Supporting scope: recovery required; investigate native savepoints, do not equate local snapshots with native restore |
| `schema` | Search BubbleScript contracts; generated app/name/type declarations | Core equivalent: discover supported properties, types and references; no need to duplicate its entire language |
| `utils generate-ids` | Allocate Buildprint-format IDs | Required capability for creation, preferably internal; verify Bubble uniqueness/ownership rules independently |
| `secret get/set` | API Connector private values | Later, with API Connector editing; not needed for canvas/demo edits |
| `expand` | Expand source templates | Optional authoring convenience; defer |
| `components` / `component` | Discover/install reusable Buildprint components | Exclude catalogue/package system; native Bubble reusable editing stays in scope |
| `versions` / `version` | Buildprint synced history and snapshot restoration | Exclude hosted history parity; keep our own edit receipts and recovery evidence |
| `merge` | Merge Bubble branches | Defer release workflow; initial tool edits isolated branches only |
| `link` | Authenticate to Buildprint | Do not reproduce; own Bubble authentication is a required dependency |
| `login` | Sign into a running Bubble app as an app user | Exclude runtime impersonation/login; this is not editor authentication |
| `data` | Read/write runtime records, including bulk operations | Exclude; data-type/field definitions are a separate app-editing capability |
| `file` | Runtime file manager | Exclude upload/delete management; existing asset references can be edited |
| `logs` | Runtime server logs | Exclude |
| `screenshot` | Run-mode screenshots | Reuse browser verification tools; no command parity needed |
| `plugin`, `plugins` | Plugin-source workspaces and discovery | Exclude plugin authoring/publishing; configuring installed plugin instances and their workflows remains in scope |
| `extension` | Buildprint extensions/custom pages/endpoints | Exclude |
| `migration` | Bubble-to-code migration tooling | Exclude |
| `docs`, `guidelines` | Documentation and agent guidance | Write focused documentation for our supported edits; no documentation-service parity |
| `mcp` | Client integration management | Exclude |
| `report`, `update` | Vendor reporting and CLI maintenance | Exclude parity |

`check` and `apply` can emit JSON; `apply` already validates, so a separate check
need not be a mandatory extra invocation. Our plan/check should still be usable
without a write. Generated `.buildprint/types/{language,app,names}.d.ts` show
that property and reference knowledge is a substantial part of the product,
not merely a transport wrapper.

## Editing capabilities, in priority order

| Priority | Capability | First useful acceptance example |
| --- | --- | --- |
| Foundation | Authenticated editor reads, branch identity, ID/path resolution, plans, preservation of unknown fields, guarded writes, readback and recovery | Rename one existing element; reject a stale expected value; reconcile an ambiguous submission without blindly repeating it |
| First release | Add/update/remove native web elements; text, size, spacing, appearance, ordering and same-owner reparenting | Create a small responsive demo page, edit nested content, move a child, remove only the intended node; fresh editor read matches |
| First release | Page and reusable definitions, reusable instances and inputs | Place two instances and verify references and independently owned state; no accidental edits to unrelated pages |
| First release | Installed plugin element properties, literal/dynamic bindings and conditional overrides | Configure an existing Tiptap/Popover plugin instance using the current plugin schema |
| First release | Custom states, frontend events/actions, conditions and action ordering | Button opens a popup; plugin event updates a state/readout; reusable-owned workflow acts on the correct instance |
| Next | Data types, fields and option sets | Add a small fixture type and bind it without changing runtime records |
| Next | Broader expression and workflow support, backend workflow definitions | Author and read back a disabled backend fixture with checked parameter/action references |
| Next | Shared style definitions, app texts and global expressions | Change a shared definition with its dependents identified in the plan |
| Later | Privacy rules and destructive schema changes | Explicitly test semantics, deletion conventions and recovery before enabling |
| Later | API Connector groups/calls, authentication settings and secrets | Preserve private values, validate references and call schemas, verify persisted definitions |
| Later | Mobile views, global elements, sitemap/page-list settings and broader app settings | Separate acceptance corpus; not a dependency for our web demo editing milestone |

First-release support must name a bounded set of element kinds, property types,
expression nodes and actions. The categories above are not a claim that every
Bubble element or workflow action belongs in version one. Cross-owner moves
and extracting a page subtree into a reusable need separate identity/reference
experiments; do not generalize from same-parent reordering.

## Evidence from our work

- [Overlay runtime audit](overlay-runtime-audit.md): authored a page, Popup,
  Group Focus, references and three element-only workflows through check/apply.
  This is a compact first acceptance scenario for functional UI editing.
- [Responsive layout slice](responsive-layout-vertical-slice.md): savepoint and
  controlled page edits; Buildprint layout provenance preserved dimensions that
  were otherwise lost. Read/modify/write must retain defaults and unknown data.
- [Workflow explanation validation](workflow-explanation-validation.md): new
  page, two disabled workflows, a data type and four fields; observed stale-base
  rejection and sync conflicts. This is a later schema/workflow scenario.
- Local Modern Popover evidence under
  `/Users/rico/dev/bubble-plugins/modern-dropdown/docs/verification/`:
  `2026-09-09-wtf-258-bubble.md` records a 366-change showcase apply;
  `2026-09-10-wtf-258-reusables.md` records seven reusables, native workflows,
  custom states and duplicate-instance verification. Extraction also encountered
  ownership/ID changes and canonicalized workflow conflicts. Use a small
  representative subset first, not the entire showcase as milestone one.
- The bubble-plugin-development skill prescribes branch create, project clone,
  savepoint, apply and real-preview verification for development-app changes.

These are observed examples, not an exhaustive frequency analysis of all prior
agent sessions. The legacy `~/bubble-plugins` path was absent on this machine;
the relevant local projects were found under `~/dev/bubble-plugins`.

## Scope of the known protocol evidence

WTF-271 captured editor-originated create, rename, reorder and undo batches on
`tiptap-plugin`, branch `wtf-271-editor-diff` (`43jvs`). Mutations used
`POST /appeditor/write`, with path/value changes plus history and index entries.
That proves a starting transport shape. It does not yet prove independent CLI
authentication, safe ID allocation, concurrency guarantees, native recovery,
full snapshot round-tripping, arbitrary workflow writing, or plugin schemas.

Recommended completion target: **create and maintain a small native web demo
page with an installed plugin, a reusable, custom state, responsive layout and
frontend workflows entirely through our CLI, with fresh-state verification and
tested failure recovery, without Buildprint.** No full BubbleScript compiler,
runtime data client, hosted history, plugin publisher or deployment system is
required for that target.

## Reproduce this inventory

Read-only sources used: `buildprint --version`, `buildprint --help`, command
help for project/clone, branch, sync, check, apply, savepoint, schema, utils,
secret and expand; and `buildprint guidelines quickstart`, `ui`, `workflows`,
`database`, `api-connector`. These describe installed-version behavior;
unexercised capabilities are documentation evidence, not live verification.
