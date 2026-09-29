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
| An element is clicked | `phx-click` (plus Enter and `role="button"` on an element that is not a control) |
| An input's value is changed | the input in its own `<form phx-change>` (`display: contents`) |
| Page is loaded | a message after the connected mount (the mount itself loads nothing) |
| Do when condition is true | re-evaluated after every event; runs when it becomes true (`every time`), or once per page load |
| A custom event | a function; called, or scheduled with `Process.send_after` |
| Do every N seconds | `:timer.send_interval` (a constant interval only) |
| Popup opened/closed, user logged in/out, plugin events | residue |

### Steps

| Bubble | Generated |
|--------|-----------|
| Show / Hide / Toggle, Set focus, Scroll to | `<Web>.Bubble` JS commands (browser) or `bubble:exec` operations pushed to the page's hook (server) |
| Set state(s) | the page's state map, per instance |
| Reset relevant inputs, Reset a group | the page's input map back to first values, and the browser's inputs |
| Go to page | `push_patch` (same page) or `push_navigate`, URL parameters as text |
| Open an external website | `redirect(external:)` or a new tab, http(s) or a site path only |
| Refresh the page, Log out | `redirect` |
| Create / change / delete things, change the current user | the backend workflow runtime's data steps (`<Module>.Workflows.Runtime`, WTF-373), with the current user as actor (data-access opt-in, below) |
| Trigger a custom event (also from a reusable element) | a call in the same process, counted in the backend runtime's call budget; its return values are the step's result |
| Schedule a custom event | `Process.send_after` to the page |
| Schedule API workflow (on a list) | the backend runtime's `schedule/5` (`schedule_list/7`): an Oban job, from the event's job budget (data-access opt-in); without the backend spec, `:backend_workflow` residue |
| Terminate this workflow | ends it (with a custom event's return values) |

### Values

Custom states and input values are kept per reusable-element instance.
Instances are addressed by a scope, the instances' Bubble IDs from the page
down (`<Web>.Bubble.nest/2`); an instance's root carries
`data-bubble-scope`. Page bindings compiled by T5 that read a custom state
or an input value read the page's maps too, so they update when a workflow
sets them.

With `page_data:` (WTF-420, `docs/page-data.md`), the page's thing, a
group's or reusable instance's thing and a repeating group's list are
what the page loads, and workflows read them; a workflow that does is a
data workflow (it runs only with the data-access opt-in).

Anything the generated page does not keep is `:unavailable_input` residue,
never a silent empty value: data the page does not load, a cell's thing
(workflows in a cell's template are not wired yet), a reusable element's
parameters, an element's built-in states (`is visible`, `is hovered`),
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

## Security

* **Event parameters are untrusted.** The page runs only what its static
  lists name: an element it renders, in a scope it renders. Parameters
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

## Unverified Bubble behavior

To confirm by replay (WTF-358): "Reset relevant inputs" resets the inputs
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
