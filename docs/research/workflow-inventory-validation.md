# Workflow inventory milestone verification

Verified 2026-09-13 in the isolated `feat/workflow-inventory` worktree. This is
static inventory validation, not execution validation or a Bubble runtime claim.
No controlled app edits, workflow executions, third-party workflow requests,
private-page exploration or HTML export changes were made.

## Controlled app and editor

Buildprint's current project and branch listings confirmed `tiptap-plugin`
(`TiptapDev`) and `83jop` (`bubble-ex`). A fresh read-only clone was taken. The
clone's SQLite `snapshot_roots` were assembled into supplied app data by merging
section records and replacing records with the same editor ID; the original
snapshot and assembly inputs remain private. This is exported editor structure,
not an assertion that every backend definition is available in public assets.

The thread's browser preview opened the actual Bubble editor on that branch.
Its version control displayed `Main / bubble-ex`; property panels displayed
`View only access`. Native computer-use surfaces failed initially, but the
thread browser provided usable editor access. No access blocker is being claimed.

| Editor observation | Inventory comparison |
| --- | --- |
| `index`: 2 workflows | 2 workflow definitions; collection `length` metadata excluded and retained separately |
| `bTHEe0`: Button Go to demo doc is clicked → Step 1 Go to page tiptap-demo | `ButtonClicked`, `ChangePage`; destination reference resolves to the supplied page |
| `bubbleex-overlay-boundaries`: 3 workflows | Exactly 3 definitions |
| `bpavsdwc`: Open Popup → Show Overlay__Popup | `ButtonClicked`, `ShowElement`, matching source element IDs |
| `bpcpmnmu`: Close Popup → Hide Overlay__Popup | `ButtonClicked`, `HideElement`, matching source element IDs |
| `bpbccsjz`: Open Focus → Toggle Overlay__Group_Focus | `ButtonClicked`, `ToggleElement`, matching source element IDs |
| `editor collab reuse`: 49 workflows | Exactly 49 definitions in that reusable |
| `bTKFs`: Page is loaded, only when This CustomDefinition's enableCollab? is yes | `PageLoaded`; complete chained `ThisElement`/parameter/`is_true` condition retained as unresolved |
| `bTKFs` steps: generate auth token (testing), Set states jwt..., Show Tiptap A | Ordered plugin action, `SetCustomState`, `ShowElement`; prior-step and reusable-self references retained; plugin semantics unsupported |
| Backend editor: 1 workflow, `bpyerffv`, 2 steps | One `APIEvent` definition, 2 action entries |

**Backend UI limitation:** both backend step labels showed `[missing: null]` in
the editor. The source snapshot contains a plugin action followed by
`APIReturnData`, and the inventory retains both. The editor confirms existence
and step count, but does **not** validate those missing action labels. Nothing
was executed to work around this limitation.

The controlled payload contains 292 workflow collection entries and 323 action
entries. It also contains 23 typed action-bearing change-history records; these
are retained under `unclassified_definitions`, not counted as active workflows.
Absent workflow fields on other owners remain unavailable rather than inferred
empty. This explains the overall `partial` availability.

## Authorized external landing pages

Each authorized landing URL was fetched as HTML through BubbleEx.HTTP, followed
by its advertised dynamic bundle. BubbleEx.Apps.Parser decoded the supplied data;
JavaScript was not evaluated. No additional page hydration, login, workflow
endpoint call, or sample-record enrichment was used. BetterLegal followed its
existing public landing redirect to `app2.betterlegal.com`.

An independent Python walk enumerated collection entries, excluding and
accounting separately for nonnegative integer `length` metadata. It compared the
complete expected path→raw-value mapping against each JSON report, dereferenced
every workflow/action/condition/reference pointer, checked resolved target paths,
and checked report entry counts. All comparisons passed.

| Authorized landing page | Workflows | Actions | Preserved conditions | Reference records | Availability |
| --- | ---: | ---: | ---: | ---: | --- |
| beta.mocharymethod.com | 38 | 65 | 19 | 99 | partial |
| bubble.io | 502 | 1,155 | 427 | 2,231 | partial |
| betterlegal.bubbleapps.io | 44 | 83 | 27 | 133 | partial |
| app.voicediq.com | 10 | 19 | 6 | 22 | partial |
| assistra.ai | 164 | 502 | 211 | 684 | partial |
| kroki-pay.bubbleapps.io | 24 | 51 | 29 | 88 | partial |
| **Total** | **782** | **1,875** | **719** | **3,257** | |

Counts describe those captured payloads only. They do not establish each app's
complete workflow count. Public payloads have unavailable scopes and absent
backend definitions. Unsupported plugin types, unresolved conditions, unknown
properties and missing references are reported without guessing their meaning.
The initially observed scalar collection members in these captures were `length`
metadata, not malformed workflow definitions; automated synthetic tests cover
actual malformed definitions.

## Reproducible checks and private evidence

`test/bubble_ex/workflows_test.exs` covers page/reusable/backend definitions,
compact aliases, complex and literal conditions, numeric and unresolved order,
missing/malformed data, duplicate and missing references, source-pointer equality,
null preservation, metadata, unknown definitions, safe Markdown fences and output
write errors. AppTree tests check inclusion of the new reports. The standard
quality gate runs formatting, warnings-as-errors compilation, Credo and offline
ExUnit tests. CI additionally runs its existing fidelity and fresh-consumer gates.

Private evidence lives under `_build/workflow-evidence/` in the session worktree:
`controlled/` (fresh clone), `controlled-assembled.json`, `external/`, `reports/`,
`summary.json`, `verification.json`, `verify.py`, and `editor-*.json` screenshot
and visible-text records. Acquisition and export scripts are retained alongside
those inputs. This directory is ignored; raw sources, real-app reports and
credentials are not committed. A verified backup outside the worktree is made
at task completion. Only this aggregate, non-sensitive verification record is
published.
