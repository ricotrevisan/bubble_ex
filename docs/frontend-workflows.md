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

# 2. Bound to LiveView: Elixir source, where each value comes from, target residue.
{:ok, spec} =
  BubbleEx.Target.Elixir.FrontendWorkflows.map(lowered, project,
    namespace: "Acme",
    frontend: frontend
  )

# 3. Printed with the pages.
{:ok, files} =
  BubbleEx.Target.Phoenix.render(project,
    name: "Acme",
    frontend: frontend,
    expressions: expressions,
    frontend_workflows: spec
  )
```

`BubbleEx.Workflows.Lowering` holds the step vocabulary shared with the
backend lowering (data operations, custom-event calls and returns, residue
of action types). `BubbleEx.Workflows.Frontend.residue/1` feeds
`BubbleEx.Plan.build/5` (`residue:`).

## What is generated

| File | Kind | What |
|------|------|------|
| `lib/<app>_web/live/<page>_live/workflows.ex` | owned | the page's workflows (WTF-359 Q5) |
| `lib/<app>_web/components/reusables/<name>/workflows.ex` | owned | a reusable element's workflows, when it has workflows, custom states or tracked inputs |
| `lib/<app>_web/bubble_workflows.ex` | generated | the runtime the LiveViews and bodies call |
| `lib/<app>_web/components/bubble.ex` | generated | element steps as JS commands and the page's hook |
| `test/<app>_web/bubble_workflows_test.exs` | owned | one test per native workflow, tagged `bubble: "workflow:<id>"` |

A `Workflows` module starts with `__bubble__/1`: what the page lets a
browser trigger (`:surface`: clicked elements, changed inputs, page-loaded,
condition-true and "do every" workflows, custom states with their defaults,
tracked inputs with their first values), each workflow's metadata
(`:workflows`: its function, its condition, what blocks it, whether it
touches stored data, its callees) and, for a page, the reusable-element
instances it renders (`:instances`, by scope). Then one function per
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
| Create / change / delete things, change the current user | Ash, with the current user as actor (data-access opt-in, below) |
| Trigger a custom event (also from a reusable element) | a call in the same process; its return values are the step's result |
| Schedule a custom event | `Process.send_after` to the page |
| Schedule API workflow | residue (`:backend_workflow`): waits for the backend runtime of WTF-373 |
| Terminate this workflow | ends it (with a custom event's return values) |

### Values

Custom states and input values are kept per reusable-element instance.
Instances are addressed by a scope, the instances' Bubble IDs from the page
down (`<Web>.Bubble.nest/2`); an instance's root carries
`data-bubble-scope`. Page bindings compiled by T5 that read a custom state
or an input value read the page's maps too, so they update when a workflow
sets them.

Anything the generated page does not keep is `:unavailable_input` residue,
never a silent empty value: a page's or a cell's thing, a group's data, a
reusable element's parameters, an element's built-in states (`is visible`,
`is hovered`), other page data, the value of an input the page does not
track (a placeholder, a date input, one whose first value is dynamic).

## Refusing to run, never a partial run

A workflow with any step bubble_ex did not lower is generated whole (the
step is a `TODO(bubble:<id>)` function) and listed in `blocked`; the
runtime refuses it **before its first step**, and refuses every workflow
that calls or schedules it, transitively. The same holds for data access.
A step that fails at run time ends its workflow; the steps before it keep
their effects, as in Bubble.

## Security

* **Event parameters are untrusted.** The page runs only what its static
  lists name: an element it renders, in a scope it renders. Parameters
  never become atoms and never name a workflow, a module or a record.
  Input values are text, numbers or yes/no, never records. Unknown events
  are ignored.
* **Data access is off by default.** The Ash resources are generated with
  `privacy: :omit`: they have **no authorization**. A workflow that reads
  or writes stored data would do so for anyone who can open the page, so
  such workflows (and their callers) refuse to start unless the owner opts
  in: `config :<app>, <Web>.BubbleWorkflows, data_access: true`. Data steps
  pass the current user as the actor with `authorize?: true`, so policies
  the owner adds apply; none are generated.
* **What is not enforced.** A browser can trigger the workflows of any
  element the page lists, whether or not it is visible at the time (Bubble
  does not guarantee that either). Conditions are evaluated on the server.

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
* **Generated code**, `BubbleEx.Target.Elixir.FrontendWorkflows.coverage/1`:
  * *native*: the whole body is generated with no residue, neither the
    lowering's nor the binding's (an IR with no Elixir mapping, a value the
    page does not provide, a step this target does not run yet);
  * *runnable*: native, and every custom event it calls or schedules is
    native too, transitively (the runtime starts only these);
  * *wired*: runnable and triggered by the page (not disabled in the
    editor, and not a custom event, which runs only when called);
  * *client*: native workflows run in the browser.

  Steps are counted the same way. Residue reasons are counted per entry (a
  workflow can have several).

### mm-137 (test version), 2026-09-27

Counts only; the snapshot is
`test/support/target/phoenix/counts/mm-137.frontend_workflows.json`.

| | total | native | runnable | wired |
|-|------:|-------:|---------:|------:|
| workflows, IR level | 2,275 | 1,152 (50.6%) | | |
| workflows, generated code | 2,275 | 635 (27.9%) | 531 (23.3%) | 361 |
| steps, IR level | 3,984 | 2,555 (64.1%) | | |
| steps, generated code | 3,984 | 1,751 (43.9%) | | |

By surface (generated): pages 215/637, reusable elements 420/1,638. 95
native workflows run in the browser; 15 touch stored data (they run only
with the opt-in). 54 workflows are disabled in the editor.

The largest blockers (residue entries, generated code): unavailable inputs
946 (a group's data 448, a reusable element's parameters 319, a cell's
thing 72, untracked input values 47+13, a page's thing 27, built-in element
states 42, page data 16), uncompiled expressions 780, plugin actions 607,
plugin events 258, unsupported actions 222, triggers inside runtime
templates 192, scheduled backend workflows 139 (waiting for WTF-373).
Workflows blocked by one reason only: unavailable inputs 256, plugin
actions 216, uncompiled expressions 125, unsupported actions 98.

The WTF-359 estimate was 30–45% of frontend workflows fully generated; the
measured 27.9% (23.3% runnable) is below it, mostly because group data and
reusable-element parameters are not loaded or passed yet.

## Checks

`scripts/phoenix_compile_check.sh` renders
`test/support/target/phoenix/frontend_workflows.json` (`phoenix_frontend_workflows`)
and its hostile-ID twin (`hostile_workflows`), compiles them with
`--warnings-as-errors`, runs the generated tests, runs the behavior tests of
`test/support/target/phoenix/frontend_workflows_behavior.exs` in the
generated app, and completes the fixture's workflow tasks with `mix
wtf.task complete` (compiles, lint, step_order) and runs their tagged tests
(`scripts/phoenix_compile_check/frontend_workflows.exs`). It formats the
scratch project first: a freshly generated project is not formatter-clean
(HEEx templates, router, runtime config and smoke test of WTF-369/370), so
`lint` would fail for every task until the owner runs `mix format`.
