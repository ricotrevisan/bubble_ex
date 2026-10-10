# Frontend workflows (WTF-372)

Page and reusable-element workflows become LiveView event handling: T6 of
the WTF-359 plan. The pipeline has three layers, like the backend workflows
of WTF-373:

```elixir
{:ok, model} = BubbleEx.Model.build(app)
{:ok, index} = BubbleEx.Index.build(app, model: model)
{:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
{:ok, frontend} = BubbleEx.Frontend.normalize(app)

# 1. Stack-neutral: events and steps, values as Expression IR, residue.
{:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)

# The backend workflows (WTF-373): the frontend's data steps and schedules
# run on their runtime.
{:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
{:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Acme")

# 2. Bound to LiveView: Elixir source, where each value comes from, target residue.
{:ok, spec} =
  BubbleEx.Target.Elixir.FrontendWorkflows.map(lowered, project,
    namespace: "Acme",
    frontend: frontend,
    backend: workflows
  )

# 3. Printed with the pages (and the backend workflows, required).
{:ok, files} =
  BubbleEx.Target.Phoenix.render(project,
    name: "Acme",
    frontend: frontend,
    expressions: expressions,
    workflows: workflows,
    frontend_workflows: spec
  )
```

`BubbleEx.Workflows.Lowering` is the step vocabulary both lowerings share:
the data operations, custom-event calls and returns, parameters, the value
structs (`Lowering.Expr`, `.Change`, `.Param`, `.Return`) and the residue of
action types; `BubbleEx.Workflows.Backend` uses it too.
`BubbleEx.Workflows.Frontend.residue/1` feeds `BubbleEx.Plan.build/5`
(`residue:`).

## What is generated

| File | Kind | What |
|------|------|------|
| `lib/<app>_web/live/<page>_live/workflows.ex` | owned | the page's workflows (WTF-359 Q5) |
| `lib/<app>_web/components/reusables/<name>/workflows.ex` | owned | a reusable element's workflows, when it has workflows, custom states or tracked inputs |
| `lib/<app>_web/bubble_workflows.ex` | generated | the runtime the LiveViews and bodies call |
| `lib/<app>_web/components/bubble.ex` | generated | element steps as JS commands and the page's hook |
| `test/<app>_web/bubble_frontend_workflows_test.exs` | owned | one smoke test per native workflow, tagged `bubble_smoke: "workflow:<id>"` |

A `Workflows` module starts with `__bubble__/1`: what the page lets a
browser trigger (`:surface`: clicked elements, changed inputs, page-loaded,
condition-true and "do every" workflows, custom states with their defaults,
tracked inputs with their first values), each workflow's metadata
(`:workflows`: its function, its condition, what blocks it, whether it
touches stored data) and, for a page, the reusable-element instances it
renders (`:instances`, by scope). Then one function per
workflow, marked `# bubble:workflow <id>`, with one private function per
step marked `# bubble:step N <type>` (the plan's `step_order`).

A clicked workflow whose steps only show, hide, toggle, focus or scroll to
elements, with no condition, runs in the browser: its function returns
`Phoenix.LiveView.JS` commands and the element's `phx-click` calls it.
Every other workflow runs on the server, in the LiveView process: the
element's `phx-click` sends the page's own `bubble:click` event, an
input's own form sends `bubble:change`, and the page runs the workflows it
lists for that element.

### Events

| Bubble | LiveView |
|--------|----------|
| An element is clicked | `phx-click` (plus Enter and `role="button"` on an element that is not a control); in a repeating group's cell, with the cell's scope (below) |
| An input's value is changed | the input in its own `<form phx-change>` (`display: contents`); in a repeating group's cell, one per cell, its value kept per cell (below) |
| Page is loaded | a message after the connected mount (the mount itself loads nothing) |
| Do when condition is true | re-evaluated after every event; runs when it becomes true (`every time`), or once per page load |
| A custom event | a function; called, or scheduled with `Process.send_after` |
| Do every N seconds | `:timer.send_interval` (a constant interval only) |
| A popup is opened / closed | the page's hook reports a Popup it opened or closed (`bubble:popup`, below) |
| User logged in/out, plugin events | residue |

**Clicks and input changes in a repeating group's cell (WTF-520).** The
page's own elements in a repeating group's cell take their clicks and
input changes per cell: in a repeating group the page renders per cell
(outside any runtime container, or rendered per cell of another, two
levels, `docs/page-data.md`) whose list loads and is a list of things
or of options (a list of texts, numbers or dates has cells by position
only, which a stale page could make name another item: its events stay
residue), the element in the cell's
template, not inside another runtime container there (a table, a
plugin's container, a third level) nor inside a reusable instance (its
elements are its reusable element's). They are listed apart in
`__bubble__(:surface)` (`cell_clicks`, `cell_changes`, `cell_inputs`:
element => `{repeating group, ...}`; `cell_lists`, the repeating groups
with their outer one). The element's event carries the cell's scope, the
format a reusable instance in a cell uses without the instance
(`<Web>.Bubble.cell_scope/5`: `<scope>-<repeating group>~2<the thing's
unique ID>`; an inner cell's under the outer cell's scope). A cell of a
list of options is keyed by its option instead (option values are
stable and unique within their set): `~4<value>`, the value escaped as
an ID is, for an option the list holds once; for one it holds `c` times,
`~4<value>~5<n>~6<c>` (`n` its occurrence, counted from the list's start,
`<Web>.Bubble.keyed_cells/3`). The list is a list of options only when
both the repeating group's type of content and what its data source
computes are that option set: an option-typed list whose source computes
texts keeps cells by position (and its events residue), so no user text
reaches a scope. A list reordered under a stale page keeps each option's
scope. When the number of equal options changes (one of two removed, a
second added), every cell of that value gets a new scope: its inputs'
values and what "Display data" showed in its groups are dropped (a
reusable instance in it starts over, custom states included), and an
event naming an old scope is ignored, never moved to the cell left. An
event in either of two equal options binds that value; their inputs'
values and "Display data" in their groups are each cell's own while the
count holds. "Display data" in a group of a cell is kept by the thing's
unique ID in a list of things (a re-sorted list keeps it) and by the
cell's scope in a list of options. The page
keeps the cells it read last, by scope, from the lists it read as the
current user (`@bubble_page_cells`, `BubbleWorkflows.put_page_cells/2`,
after every read of its data), and accepts the event only for one of
them and an element listed for that cell's repeating group; the scope is
looked up, never parsed. The workflow runs in its surface's scope (the
page's, or the reusable instance's) with the cell's thing and index, a
group of the cell, and in an inner cell the outer cell's thing, index and
groups, all as the page read them: nothing the browser sends becomes the
cell's thing. The cell is looked up again before each workflow of the
event, after the page's data is read again (a preceding write), so a
cell that left the list runs nothing. An input in a cell keeps its value
per cell, under the cell's scope, starting with its static first value
when the cell is new to the page (an input whose first value is dynamic
is not tracked in a cell, and its change workflows are
`:unavailable_input`); "This input's value" in a workflow of the same
cell, and a text of the same cell, read that cell's value. A cell that
leaves the list drops its inputs' values. A paused workflow of a cell
resumes in it only while the page still shows it, checked again after the
page reads its data. A click, an input's workflows or the rest of a
paused workflow whose cell is gone are dropped silently (logged, no
notice). "Reset relevant inputs" with no element resets the cells'
inputs too; a reset group or popup does not reset the inputs of the
cells inside it (only the inputs it holds directly). A click whose steps
only show, hide, toggle, focus or scroll to the surface's elements runs
in the browser, as anywhere. Page-load, condition-true and "do every"
workflows have no cell. Anything else in a cell (a table's row, a third
level, a list that does not load) stays `:trigger_in_runtime_template`
residue.

**Popup opened or closed (WTF-520).** The page's hook opens and closes
overlays; when a Popup whose "is opened" or "is closed" workflows the
page runs (`data-bubble-events`, listed as `popups` in
`__bubble__(:surface)`) actually opens or closes, by a step in the
browser or sent by the server, or Escape, it sends
`bubble:popup` (the instance scope, the Popup's Bubble ID, `opened` or
`closed`). Opening an open Popup, or closing a closed one, reports
nothing. A report the user caused (a step in the browser, Escape) runs
the listed workflows like a click's: a root run, and a refused one shows
the notice. One a server-side step caused runs on that run's budgets,
one link further down its chain, as a scheduled custom event: the page
expects it when it sends the step (`{scope, element, event}`, an equal
share of what the run left), and the browser's report carries no budget,
so Popups opening each other through the server end on the run's
budgets and `:max_chain`. An expected report that never comes (the
Popup was already open) is taken by the next report of that event. A
reconnect forgets what was expected; the browser keeps its open Popups
open without reporting them again. Wired only on a Popup of the
workflow's own page or reusable element that the page renders, outside a
repeating group's cell; a reusable element that is itself a popup, or
another element, is `:unsupported_event` residue.

### Steps

| Bubble | Generated |
|--------|-----------|
| Show / Hide / Toggle, Set focus, Scroll to | `<Web>.Bubble` JS commands (browser) or `bubble:exec` operations pushed to the page's hook (server) |
| Set state(s) | the page's state map, per instance |
| Reset relevant inputs, Reset a group | the page's input map back to first values, and the browser's inputs; a reset group or popup also forgets what "Display data" showed in it and in the elements inside it, a reset reusable-element instance everything shown in its scope (WTF-492) |
| Display data in a group / popup, Display list in a repeating group | the element's data, kept by the page per instance (per cell in a repeating group's cell) until a reset or the page's next load, in place of its own data source, whatever that source reads meanwhile; an empty value shows empty (replay 2026-10-07); a thing is kept as its unique ID and read again as the current user (WTF-492, below) |
| Go to page | `push_patch` (same page) or `push_navigate`, URL parameters as text as Bubble writes them (replay 2026-10-07: a date as its display text, `Oct 7, 2026 12:00 am`, in the app's `:bubble_time_zone`; a number `3`; a yes/no `yes`; a thing parameter empty, so left out); the target is a page of the app or Bubble's `Current page`, anything else (an unknown or deleted page's ID, an empty one, a path, other text) is `:unresolved_reference` residue and the workflow refuses to run, never a navigation elsewhere (WTF-429); its data to send, to a page with a type of content whose thing the page loads (`docs/page-data.md`), is the thing's unique ID as the path segment after the page's (`/<page>/<unique id>`, WTF-378; `/index/<unique id>` for the index page, WTF-454); to a page with no type of content (WTF-466, replay-verified) it is appended all the same, as Bubble does: a thing's unique ID or the value (text, a number, a boolean, a date) as text, percent-encoded as one segment (`/<page>/x`; none when empty, `.` or `..`, another kind of value, a list included, or over 2000 encoded bytes, logged), which the page ignores (a list sends no segment to any page: see "Known differences");  to the current page it replaces that segment of the page's URL (a page's workflow: known at generation; a reusable element's: decided at run time, as text when the page takes no thing); every page's route takes the segment; the page's own path is its route's, without the segment the router took (never a query parameter), and the index page's is `/` |
| Open an external website | `redirect(external:)` or a new tab, http(s) or a site path only |
| Refresh the page, Log out | `redirect` |
| Create / change / delete things, change the current user | the backend workflow runtime's data steps (`<Module>.Workflows.Runtime`, WTF-373), with the current user as actor (data-access opt-in, below) |
| Trigger a custom event (also from a reusable element) | a call in the same process, counted in the backend runtime's call budget; its return values are the step's result |
| Schedule a custom event | `Process.send_after` to the page |
| Schedule API workflow (on a list) | the backend runtime's `schedule/5` (`schedule_list/7`): an Oban job, from the event's job budget (data-access opt-in); without the backend spec, `:backend_workflow` residue |
| Terminate this workflow | ends it (with a custom event's return values) |
| Add a pause before next action | ends the event; the rest of the workflow (and of the custom events waiting on it) runs after the pause in a `Process.send_after` message to the page (WTF-451, below) |

### Values

Custom states and input values are kept per reusable-element instance.
Instances are addressed by a scope, the instances' Bubble IDs from the page
down (`<Web>.Bubble.nest/2`); an instance's root carries
`data-bubble-scope`. An instance in a repeating group's cell (WTF-494) has
a scope per cell, the cell's thing's (`<Web>.Bubble.cell_scope/5`): its
workflows run there, with that cell's states, inputs and data
(`docs/page-data.md`); its page-load, condition-true and "do every"
workflows do not run in a cell. Page bindings compiled by T5 that read a custom state
or an input value read the page's maps too, so they update when a workflow
sets them.

With `page_data:` (WTF-420, `docs/page-data.md`), the page's thing, a
group's or reusable instance's thing, a repeating group's list and a
reusable element's properties (WTF-493) are what the page loads, and
workflows read them; a workflow that does is a data workflow (it runs
only with the data-access opt-in). Bubble has no action that changes a
reusable element's property: workflows only read it.

### Navigation and JSON-safe text (WTF-500)

Each workflow of an event applies its navigation when it ends. The first
page-leaving navigation of an event ("Go to page" to another page, a
reload, "Open an external website", "Log out") wins, from a later step
of the same workflow or from another workflow on the same trigger: the
page is gone once it runs. A same-page navigation (a URL parameter of the
current page) never blocks: any later navigation replaces it, so a
workflow that only changes a parameter can never skip another one's
"Log out". **Bubble does not guarantee the order of workflows on the same
trigger**, and the generated runtime does not either; with this rule the
outcome of a page-leaving and a same-page navigation does not depend on
it.

`:formatted as JSON-safe` is text on pages, as typed: a yes/no is `"true"`
or `"false"`, a number its text and a date ISO 8601, so comparing it with a
text (`Admin? :formatted as JSON-safe is "true"`) holds as in Bubble.
**API calls are not lowered yet** (plugin and API Connector actions are
residue). When they are, a request body must insert a value's raw JSON
(`true`, `3`, a quoted and escaped string), never this text form: the
runtime's `json_encode/1` (`TODO(bubble:api-body)`) must not be reused
for bodies as is.

### Display data (WTF-492)

"Display data in a group / popup" sets what a group, popup, floating
group, group focus, reusable-element instance (its reusable element's
thing) or the reusable element itself (seen from inside) shows; "Display
list in a repeating group" sets a repeating group's list. The lowering's
`:display_data` / `:display_list` step names the element, the value and
the repeating group whose cell holds the element; another kind of
element is `:unsupported_option` residue (`element_id`).

The page keeps what was shown in `@bubble_displayed`, keyed by
`{scope, element}` (in a cell, plus `{:cell, <the cell's thing's unique
ID>}`, so a re-sorted list keeps what each thing's cell showed):
`{resource, list?, value}` where a thing (or list of things) is its
unique ID only: a record of the element's type, or a text shaped like a
Bubble ID; a record of another type, a crafted text or a number is
dropped. A list keeps at most its repeating group's page size (capped by
`:max_items`). The workflow's later steps read the element's new data at
once (read the same way, as the current user, into the run's context).
Every read of the page's data reads it again through Ash
as the current user (`<Web>.BubbleData`), with the relationships the
page's bindings read through it, and follows its records' change
notifications. So a workflow never shows what the user may not read:
with `privacy: :enforced`, a record the user may not view shows nothing
and a hidden field is empty, whatever the workflow read it as (a custom
event ignoring privacy rules included). Any other value (text, a
number, a date) is kept as it is, never a record.

The element becomes page data (`docs/page-data.md`): with no data
source of its own, a source that reads only what a step showed
(`read: :displayed`, nothing before); with one, the step's value wins
over it until a reset. When the page keeps it depends on when its steps
may run (WTF-520):

* **Only on events.** Every workflow that may start a step on the
  element is a click, an input change or a "do every" tick (directly,
  or through the custom events it calls or schedules), and the page
  triggers every one of them (`Spec.wired?/1`): before the event the
  element shows nothing, as in Bubble, so the page keeps it whether or
  not the runtime then runs those workflows. A triggered workflow the
  runtime refuses never sets it (a click or an input change shows the
  refusal notice; a "do every" tick is refused silently, logged); what
  reads the element reads it empty, as Bubble's page does before the
  event. A click or an input change in a repeating group's cell is such
  an event when the page wires it per cell (WTF-520, above) and the
  runtime runs it whole: a detail group outside the list that a row's
  click sets ("Display data in bDetail: Current cell's product",
  master-detail) is page data, empty until the click. One the runtime
  refuses would never set it, so the element stays unloaded, loudly (a
  page-level click the runtime refuses still counts, as before). An event the page never triggers (a click in a
  table's row or a third level, `:trigger_in_runtime_template`) would
  leave it empty where Bubble shows data: the element stays unloaded.
  A custom event nothing calls never runs: it sets nothing.
* **Popups opened or closed (WTF-520).** Popups are closed as the page
  loads. A popup's "is opened" workflow is started by the workflows whose
  steps show or toggle the popup, its "is closed" one by those that hide
  or toggle it and by the user (Escape, unless the popup prevents it),
  through the custom events that call them too; the popup's own workflow
  must be triggered by the page (wired). When only events open it, its
  workflow counts as an event; when a page-load workflow (or another that
  may run as the page loads) opens it, as one that runs as the page
  loads, and it must run whole too. A popup whose conditions set its visibility
  may be opened by them, which the page does not follow, and so may one
  an action this target does not lower names (an animation, a plugin's
  action): what its workflows set stays unloaded. When a workflow that
  opens (closes) the popup, or one calling it, shows data in an element
  the popup's "is opened" ("is closed") workflow resets (it or a group
  around it, the popup included) or shows data in too, that element is
  unloaded: which runs last is not replayed.
* **As the page loads.** A step in a page-load or condition-true
  workflow, one whose event this target does not lower or wire (a
  plugin's event, "User is logged in / out", which may fire as the page
  loads, or right after), or a custom event any of those calls or
  schedules: the page keeps the
  element only when every such workflow runs whole here and is
  triggered (native and wired). Otherwise the element stays unloaded
  and what reads it is a `TODO` marker: the page cannot show what
  Bubble would set as it loads. A page-load step that runs sets the
  element right after the connected mount's read, and the page reads
  what depends on it again (one more read of the page's data).
* **No step at all.** A group, popup, floating group, group focus or
  repeating group with a type of content, no data source and no step
  setting it, outside a repeating group's cell, shows nothing, ever:
  it is page data too (`read: :displayed`), so what reads it loads.

In a repeating group's cell, only a group from a workflow of the same
cell (per cell, kept by the cell's thing; in an inner cell, in the outer
cell's scope, WTF-520); a list or an instance there, or a cell's group
from outside the cell, is `:page_data_in_cell` residue (`kind`
`"list"`, `"instance"`, `"display"`). An element whose
conditions set a data source has that source folded over its own, or
over the empty one when it has none (`docs/page-data.md`, WTF-521).

Anything the generated page does not keep is `:unavailable_input` residue,
never a silent empty value: data the page does not load, a cell's thing
outside the cell's own clicks and input changes, a reusable element's
property some instance's value of which is not loaded, an element's built-in states (`is visible`, `is hovered`),
other page data, the value of an input the page does not track (a
placeholder, a date input, one whose first value is dynamic).

## Refusing to run, never a partial run

A workflow with any step bubble_ex did not lower is generated whole (the
step is a `TODO(bubble:<id>)` function); its `blocked` list, as the
backend's `blocked_by`, names its own residue subjects and the blocked (or
unknown) workflows it calls or schedules directly (custom events, backend
workflows), computed transitively at generation. The runtime refuses a
workflow with a non-empty `blocked` **before its first step**. The same
holds for data access, which is transitive through custom events. A step
that fails at run time ends its workflow; the steps before it keep their
effects, as in Bubble.

## Pauses (WTF-451)

"Add a pause before next action" never blocks the LiveView process. The
pause step ends the event: what the steps before it did applies to the
page (states, inputs, element steps), and the page sends itself a
message after the pause (`Process.send_after/3`) carrying what is left:
the paused workflow from the step after the pause and, innermost first,
every workflow waiting on it through "Trigger a custom event" (the call
step gets the custom event's return values when it ends). The rest keeps
the workflow's arguments, step results and start time ("Current
date/time"); it reads the page's states, inputs and data as they are
then.

* **Capped.** A pause lasts at most `:max_pause_ms` (`config :<app>,
  <Web>.BubbleWorkflows`, default 60_000 ms); an empty or negative length
  is no pause.
* **Budgets and chains.** A pause costs one call of the run's call budget
  and the rest continues the run's budgets one link further down the
  chain, as a scheduled custom event does: a pause at `:max_chain` fails
  its step, so a workflow that pauses in a loop (through a condition or a
  schedule) ends.
* **Held by the page.** A page holds at most `:max_pending` (default
  100) paused workflows and scheduled custom events at once; beyond that
  the new ones are dropped, logged, and the page shows the refusal notice
  (below). A resumed or scheduled run's budget never exceeds a root run's.
* **The page must still be there.** Paused work lives in the LiveView
  process: going to another page, closing it or a reconnect (a new
  process) drops it. A malformed message, one for a surface the page does
  not render, or one without a well-formed budget is ignored and logged.

## A refused click shows a notice (WTF-453)

When a click or an input change asks for a workflow the runtime refuses
before its first step (not lowered, or data access off), the page shows a
short notice, "This action isn't available yet.", in a polite live region
(`#bubble-notice`, `role="status"`, set as text by the page's hook from a
`bubble:notice` event). It never names the workflow, the reason or any
ID: those stay in the server log (`[error] bubble workflow ... is not
lowered`). Page-load, condition-true, "do every" and scheduled workflows
are refused silently (logged), as they would show it on their own.

## Security

* **Event parameters are untrusted.** The page runs only what its static
  lists name: an element it renders (a Popup's listed opened or closed
  event, WTF-520), in a scope it renders (an
  instance in a repeating group's cell: one of the cell scopes the page
  read as the current user, WTF-494, never one the browser made up; the
  page's own element in a cell: one of the cells it read, WTF-520, its
  thing bound from what the page read). Parameters
  never become atoms and never name a workflow, a module or a record.
  Input values are text, numbers or yes/no, never records. Unknown events
  are ignored.
* **Data access is off by default.** The Ash resources are generated with
  `privacy: :omit`: **no resource has an authorizer**, so nothing is
  authorized. A workflow that reads or writes stored data, or schedules a
  backend workflow, would do so for anyone who can open the page, on any
  record, so such workflows (and their callers) refuse to start unless the
  owner opts in: `config :<app>, <Web>.BubbleWorkflows, data_access: true`
  (the backend's workflow API is off by default the same way). They run
  on the backend runtime with the current user as actor and `authorize?:
  true`, which authorizes nothing until the owner adds policies.
  Rendered with `privacy: :enforced` (WTF-423) the policies are there:
  the actor is the current user read afresh with what the policies read
  at every event, reads follow the privacy rules, and the runtime's writes
  are allowed (the workflow's conditions guard them, as in Bubble; they
  are not checked against the privacy rules). See `docs/page-data.md`,
  "Enforced privacy", for what that guarantees and the opt-in defaults.
* **Budgets fail closed.** A browser event is a root run of the backend
  runtime (`Runtime.root/2`): its job budget (`:max_jobs`) bounds the jobs
  its schedules and trigger-firing writes cause, and its call budget
  (`:max_calls`) the custom events it triggers, frontend ones included. A
  scheduled custom event costs one call and continues the budgets of the
  run that scheduled it (shared among everything that run scheduled), and
  a chain of them stops at `:max_chain`: a delay-0 self-schedule ends.
  The condition-true workflows an event's effects fire run within that
  event's budgets and chain, never fresh ones (WTF-421), so a loop through
  a condition ("when flip is yes: set flip to no; schedule re-arm", where
  re-arm sets flip back) ends too; what an event schedules is sent when
  it (and the condition-true runs it fired) ends, sharing what it left.
* **What is not enforced.** Visibility is not part of the click
  allowlist (a browser can trigger any listed element's workflows, visible
  or not); server-side "Only when" conditions are.
* **Inputs are capped.** A value above `:max_input_bytes` (default
  100 KB) is ignored, and the scaffold's LiveView socket takes frames of at
  most 1 MB.
* **Data access fails closed twice.** A workflow is flagged as a data
  workflow when any value, condition or step condition loads a
  relationship, or it writes or schedules; independently, the runtime's
  `load/3` and data steps read and write nothing with data access off.

## The overlay runtime (fixes latent T5 issues)

Show and hide go through one hook per page (`<Web>.Bubble.runtime/1`),
which sets and removes `hidden` with LiveView's JS commands, so a later
render keeps an overlay open:

* opening an overlay that is already open does nothing, so its opener is
  remembered once (T5 saved the focus a second time);
* element steps address one instance (`scope`), not every instance of a
  reusable element's overlay;
* a modal Popup gives the focus back to its opener; if the opener is hidden
  by then (inside a Group Focus the Popup closed), the focus goes to what
  opened that Group Focus, else it is released.

Elements that are not overlays follow Bubble's rule for a step against
their visibility conditions (WTF-509, replay 2026-10-07): a show, hide or
toggle step holds until one of the element's conditions changes the
visibility the conditions give it; then the condition wins and the step
is dropped. The page renders that visibility as `data-bubble-visible`
next to `hidden`; the hook compares it across renders (steps of the same
event run after the render they follow, so a step after "Set state"
wins). Replay, on a synthetic page with a custom state `s` (no on load)
and three texts, T1 visible on load with "when s is yes: visible" (the
same as on load), T2 hidden on load with "when s is yes: visible", T3
visible on load with "when s is yes: hidden" (shown, hidden, shown on
load):

* hide T1: hidden hidden shown; s yes: hidden shown hidden; s no:
  hidden hidden shown
* s yes: shown shown hidden; hide T1: hidden shown hidden; s no: hidden
  hidden shown; s yes: hidden shown hidden
* s yes: shown shown hidden; hide T2: shown hidden hidden; s no: shown
  hidden shown; s yes: shown shown hidden
* s yes: shown shown hidden; show T3: shown shown shown; s no: shown
  hidden shown; s yes: shown shown hidden

A hide of T1 holds through every change (its condition never changes
its visibility); a step on an element with no conditions holds until the
page reloads. A LiveView reconnect mounts the page again (custom states
and inputs start over); its render is compared with the last one like
any other.

## Known differences from Bubble

* **"Go to page" with a list as the data to send.** Bubble sends the
  literal segment `[object%20Object]` for a list of things or of texts
  (replay 2026-10-07), which no page reads. Here a list sends no path
  segment, to any page.
* **Server-side actions with an empty constraint value** are stricter
  than Bubble: see `docs/page-data.md`, "Empty constraint values".

## Unverified Bubble behavior

Answered by the replay of 2026-10-07 and removed from this list: what
"Go to page" sends for a list (above), and "Display data" over a group's
own source (it wins until a reset, whatever its source reads), with an
empty value (it shows empty) and under a reset parent (a nested group
with no source is cleared, one with its own source shows it again).

Extended beyond what the replay measured (unverified): `text/1` writes a
date as its display text wherever it is used, not only in "Go to page"
URL parameters and API workflow responses (measured): a date sent as
the data to a page with no type of content (the path segment), a date
inside a dynamic text a page workflow writes (a custom state, a field),
and a value a workflow sends to an API call take the same display text;
a backend workflow's in UTC.

**A show or hide step, then "Set state" in the same workflow.** The
replay measured a state change and a step in separate workflows. Here a
step runs after the render of the event it belongs to, so it wins over a
condition change made in the same workflow whatever their order: "hide,
then set state" keeps the element hidden even when the new state changes
the visibility its conditions give it. Bubble may apply the steps in
order (the condition winning there); not replayed.

**When display steps may run (WTF-520).** That a group or repeating
group only clicks, input changes, "do every" ticks or the custom events
they call set shows nothing before them is Bubble's documented
behavior; that a "do every" workflow first runs after its interval, not
as the page loads, is assumed. Plugin events and "User is logged in /
out" are taken to possibly fire as the page loads (the conservative
reading): an element they set, directly or through a custom event, stays
unloaded until they run here.

**Popup events (WTF-520), not replayed:** that "A popup is opened" fires
only when a step (or the user) opens a closed popup, never as the page
loads, and "A popup is closed" only when an open one closes (Escape or
a step); that showing an open popup, or hiding a closed
one, fires nothing (here it reports nothing); that a popup's conditions
may open it (here what its workflows set then stays unloaded); and when
the popup's workflow runs relative to the rest of the workflow whose
step opened it (here after it, and after the page re-rendered: a later
step of that workflow does not see what the popup's workflow set, and
what the popup's workflow resets or shows wins over what that workflow
showed: such elements are not loaded until a replay says which wins).

To confirm by replay (WTF-358): what "Go to page" appends when the data
sent to a page with no type of content is a value
over 2000 encoded bytes (here none, logged); the URL Bubble gives
the index page with data sent to it (`/index/<unique id>` here); that a
workflow calling a custom event waits for the custom event's pauses;
a reset reusable-element instance forgets everything
shown in it, but not what was shown inside the reusable-element
instances within a reset group (to replay, WTF-387); a repeating group a
"Display list" sets shows one page of the list (its rows × columns);
"Reset relevant inputs" resets the inputs
of the triggering element's container; a condition-true workflow whose "run
this" is unset runs once per page load; a condition that is true when the
page loads fires; "Go to page" lets the workflow finish before the page
changes; workflows triggered together run one after the other (in Bubble ID
order); a click runs only the innermost clickable element's workflows
(Bubble also runs those of a clickable element around it).

## Coverage metric

Two measures, both counting page and reusable-element workflows (not
mobile views):

* **IR level**, `BubbleEx.Workflows.Frontend.coverage/1`: a workflow is
  *native* when it has no residue at all: its event and every step have a
  lowering and every value compiles to Expression IR.
* **Generated code**, `BubbleEx.Target.Elixir.FrontendWorkflows.coverage/1`,
  the backend's metric (`BubbleEx.Target.Ash.Workflows.Spec.coverage/1`)
  plus what pages add:
  * *native*: the whole body is generated with no residue, neither the
    lowering's nor the binding's (an IR with no Elixir mapping, a value the
    page does not provide, a step this target does not run yet), and so is
    every workflow it calls or schedules, transitively: the runtime starts
    only these;
  * *native own body*: the body alone, callees aside;
  * *wired*: native and triggered by the page (not disabled in the
    editor, and not a custom event, which runs only when called);
  * *client*: native workflows run in the browser.

  Steps are counted the same way. Residue reasons are counted per entry (a
  workflow can have several).

### Private fixture app (test version), 2026-10-04

With "Display data" lowered (WTF-492): 55 of the 77 "Display data"
steps (79 with mobile views, not counted) are generated (35 in workflows
the runtime starts; the rest wait on other steps), up from none; the 30
"Display list" steps lower but none compiles yet (searches, list
operators, untyped step results in their values). Generated code: 622 →
692 native workflows, 430 → 466 wired, 2,007 → 2,085 native steps;
`unsupported_action` residue entries 175 → 68. Page data: 943 → 1,016
of 2,017 → 2,037 sources wired (20 elements set only by a step, 14 with
a source of their own a step overrides, 53 sources reading them wired),
and the elements inside wired page data 4,308 → 4,569 (elements inside
unloaded data only 1,486 → 1,294).

### Private fixture app (test version), 2026-09-30

With pauses lowered (WTF-451): 47 of its 48 "Add a pause" steps are
native (one has an uncompiled length); generated code 569 → 582 native
workflows, 395 → 403 wired, 1,917 → 1,964 native steps (IR level:
1,196 → 1,207 native workflows). Data sent to the current or index page
(WTF-454) changes nothing there: all its data-to-send steps target
another page. The snapshot below is the earlier one.

### Private fixture app (test version), 2026-09-27

With page data (WTF-420): 553 native (24.3%), 380 wired (16.7%), 702 own
body, 1,877 native steps, 858 unavailable inputs; see
`docs/page-data.md` for the before/after table. The counts below are
before it (WTF-372).

Counts only; the snapshot is
`test/support/target/phoenix/counts/private-app.frontend_workflows.json`.

| | total | native (own body) | native | wired |
|-|------:|------:|-------:|------:|
| workflows, IR level | 2,275 | 1,152 (50.6%) | | |
| workflows, generated code | 2,275 | 648 (28.5%) | 531 (23.3%) | 361 (15.9%) |
| steps, IR level | 3,984 | 2,555 (64.1%) | | |
| steps, generated code | 3,984 | 1,795 (45.1%) | | |

*Native* here is the backend's definition (the workflow and everything it
calls or schedules generated whole): 531 workflows start. *Wired* is what
a page actually triggers: 361 (15.9%); the rest of the native ones are
custom events (run when called) or disabled in the editor. By surface
(native): pages 170/637, reusable elements 361/1,638. 95 native workflows
run in the browser; 14 touch stored data or schedule backend workflows
(they run only with the opt-in). 54 workflows are disabled in the editor.
44 "Schedule API workflow" steps are generated on the backend runtime.

The largest blockers (residue entries, generated code): unavailable inputs
1,027 (mostly a group's data and a reusable element's parameters, then a
cell's thing, untracked input values, a page's thing, built-in element
states and page data), uncompiled expressions 783, plugin actions 607,
plugin events 258, unsupported actions 222, triggers inside runtime
templates 192.

The WTF-359 estimate was 30–45% of frontend workflows fully generated; the
measured 23.3% native (28.5% for the body alone) is below it, mostly
because group data and reusable-element parameters are not loaded or
passed yet.

## Checks

`scripts/phoenix_compile_check.sh` renders
`test/support/target/phoenix/frontend_workflows.json` (`phoenix_frontend_workflows`)
and its hostile-ID twin (`hostile_workflows`), compiles them with
`--warnings-as-errors`, runs the generated tests, runs the behavior tests of
`test/support/target/phoenix/frontend_workflows_behavior.exs` in the
generated app, and completes the fixture's workflow tasks with `mix
wtf.task complete` (compiles, lint, step_order) and runs their smoke tests
by tag (`mix test --only bubble_smoke:workflow:<id>`,
`scripts/phoenix_compile_check/frontend_workflows.exs`). Frontend workflow
tasks have no `unit_test` criterion; the smoke tests, which cannot fail on
behavior, would not satisfy one. It formats the
scratch project first: a freshly generated project is not formatter-clean
(HEEx templates, router, runtime config and smoke test of WTF-369/370), so
`lint` would fail for every task until the owner runs `mix format`.

The page hook's popup reports (WTF-520) run in the pinned browser with
the fidelity checks (`mix test --only fidelity`,
`test/support/fidelity/popup-events.mjs`): a step, Escape, toggle,
showing an open popup, a popup in a reusable instance and a server-side
step.
