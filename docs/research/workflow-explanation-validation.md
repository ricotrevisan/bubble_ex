# Workflow explanation verification — issue 91

Verified 2026-09-13. This milestone explains supplied source statically; no
workflows, workflow endpoints, login flows or runtime data operations were used.
No HTML/snapshot work was reopened. Raw real-app inputs and reports stay private.

## Controlled editor evidence

Buildprint project/branch listings reconfirmed `TiptapDev` / `tiptap-plugin` and
`bubble-ex` / `83jop`. The thread browser opened the actual editor successfully.
The saved inventory snapshot has no `NewThing` or `ChangeThing` actions, so a
separate `i91-explain` / `33juy` branch was created from `test` with savepoints.
Only a new `bubbleex-explain-91` page, its two disabled workflows, and the new
`Explanation Task 91` data type were added. The final branch diff confirms no
changes to pre-existing app files. Neither `test`, `live`, `83jop`, nor the
preceding session's workspace was modified.

Buildprint rejected stale-base applies without writing. Sync and reapply
succeeded. One sync conflict contained formatting and explicit empty privacy
rules for the new data type; all four field IDs/types were identical. The editor
projection was retained and Buildprint validation passed. Although apply lists
`settings/app.ts` among affected projection files, the final source diff contains
only the four new fixture files. No application workflow was run.

The actual editor on `33juy` showed:

| Source identity | Editor observation | Explanation check |
| --- | --- | --- |
| `bpomiamh` | Disabled Save click event | Scoped Save element identity, disabled flag, event condition |
| Event condition | Page record's owner is Current User, AND (Current User logged in OR count > 0) | Nested receiver/argument grouping preserved, including parentheses in the condition panel; no inference of “ownership” from a field caption |
| `bpomiami` | Create Explanation Task 91; status Draft, owner Current User, count 0, enabled no | Type, field IDs/captions, dynamic reference and exact literal values |
| `bpomiamj` | Change current page's record; status Done, count 0, enabled no; only when status is Draft | Target and assignments; action condition separate from event condition |
| `bpomiamk` | Change result of step 1; blank status field, owner Current User; disabled, only when no | Earlier action identity, exact empty string retained from source, false condition and disabled flag |
| `bpomiaml` | Second disabled Save event with not-equal, empty/not-empty, <, ≤, ≥, yes/no, logged-out checks | All corresponding operator names and nested boolean groups |
| `bpomiamm` | Create Explanation Task 91 | Additional definition/action accounting; source assigns status Marker |

Fresh read-only Buildprint clones after apply independently retained these
records. Bubble's logged-out operator is `not_logged_in`, as shown by the source
and editor label; a guessed `logged_out` spelling is deliberately unsupported.
The new editor source uses `thing_type`; authorized compact sources use `%tt`.
Two public fixtures contain only the newly authored page/data definitions,
with a minimal User schema stub, not unrelated real-app data. Their names, IDs,
conditions and assignments correspond to the actual editor captures.

Saved screenshots cover the grouped Save event and create/change/previous-step
panels. The second operator workflow's snapshot API failed, but browser DOM
inspection of the actual editor succeeded; its URL and rendered text were saved.
This is recorded as text evidence, not a claimed screenshot. No backend action
labels beyond the previous milestone were verified. Its `[missing: null]`
limitation remains unchanged.

The isolated supplied fixtures contain **2 workflows, 4 actions and 4
conditions**. All six workflow/action descriptions, four conditions and four
data actions are fully supported by the bounded vocabulary. The separate
original controlled input still contains **292 workflows / 323 actions**, plus
**23 history candidates**. Its five conditions remain partial; this milestone
makes no claim that reusable parameter or plugin semantics are fully supported.

## Authorized external payload accounting and coverage

The six saved landing-page payloads from the prior milestone were reused
read-only. No fresh third-party requests, private-page acquisition, workflow
endpoint calls, record lookups or login automation were performed. Their
availability remains partial. BetterLegal's recorded acquisition remains the
public redirect from `betterlegal.bubbleapps.io` to `app2.betterlegal.com`.

An independent Python verifier enumerated source collections, dereferenced raw
workflow/action/explanation/condition pointers and reference candidates, checked
array/map ordering, and compared every workflow/action raw record and source
key/order against the previous reports. Canonical hashes and history candidates
also match. All eight inputs passed. Assignment values are checked as source
subtrees, including falsy values; missing members are not treated as null.

Explanation states below are **fully supported / partial / unresolved /
unavailable**, in that order. Data actions include only recognized `NewThing`
and `ChangeThing`, not every workflow action.

| Saved landing source | Workflows | Actions | Condition states | Data-action states |
| --- | ---: | ---: | --- | --- |
| beta.mocharymethod.com | 38 | 65 | 7 / 4 / 8 / 0 | 0 / 6 / 0 / 0 |
| bubble.io | 502 | 1,155 | 45 / 278 / 104 / 0 | 3 / 89 / 2 / 0 |
| betterlegal.bubbleapps.io | 44 | 83 | 2 / 14 / 10 / 1 | 0 / 3 / 0 / 0 |
| app.voicediq.com | 10 | 19 | 5 / 1 / 0 / 0 | 6 / 0 / 0 / 0 |
| assistra.ai | 164 | 502 | 43 / 153 / 11 / 4 | 19 / 83 / 4 / 0 |
| kroki-pay.bubbleapps.io | 24 | 51 | 1 / 20 / 8 / 0 | 0 / 0 / 0 / 0 |
| **Total** | **782** | **1,875** | **103 / 470 / 141 / 5** | **28 / 181 / 6 / 0** |

Thus **103 of 719 conditions (14.3%)** and **28 of 215 create/change actions
(13.0%)** are fully supported. Partial means useful pieces coexist with missing
or unknown semantics, not nearly correct execution. Unknown searches, plugin
operators, custom states, absent built-in schema fields, unavailable receiver
types and unproven field mutation kinds explain much of the remaining gap.

The exact `Empty` assignment-kind marker is observed in authorized compact
payloads; its set projection is kept separate from nonempty mutation kinds.
The controlled editor verifies ordinary set assignments with an absent marker.
Compact alias tests derive from those observed keys; they are not a claim that
the controlled editor itself emitted a compact payload. Nulls and malformed
constructs are covered by automated source-preservation tests, not invented
editor/runtime observations.

## Reproduction and evidence custody

`mix quality` passes formatting, warnings-as-errors compilation, Credo and the
standard offline test suite. Tests cover both captured controlled fixtures,
compact transformations, grouping, event/action condition scope, literal and
dynamic assignments, false/null/empty/zero, ambiguous and missing references,
unknown nested expressions, metadata/collisions, malformed collections, source
pointer equality and versioned JSON/Markdown. CI also runs the existing fidelity
and fresh-consumer gates before merge.

Private evidence is under `_build/workflow-explanation-evidence/`: fresh
controlled clones, fixture projections, savepoint/apply results, editor text and
screenshots, report-generation and independent verification scripts, complete
reports, summary and check logs. The original acquisition remains read-only at
`/Users/rico/dev/bubbleex-evidence/workflow-inventory-20260913`.
The new evidence backup is
`/Users/rico/dev/bubbleex-evidence/workflow-explanations-20260913`, verified by a
per-file SHA-256 manifest before task completion. It contains no newly acquired
third-party data. Reports are not a credential-redaction boundary and must
remain private. The isolated Bubble branch is retained as disabled editor
evidence; it was not merged into the app's `test` or `live` branches.
