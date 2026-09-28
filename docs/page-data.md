# Page data (WTF-420)

The generated pages load the data the Bubble page shows: a page's "Type
of content" (its thing, from the URL), and the data sources of its
groups, repeating groups and reusable-element instances. Text and image
bindings that read that data are rendered from it, and workflows read it
too. It follows the three layers of the frontend workflows
(`docs/frontend-workflows.md`):

```elixir
{:ok, model} = BubbleEx.Model.build(app)

# 1. Stack-neutral: one source per page thing and data source, values as
#    Expression IR, residue.
{:ok, page_data} = BubbleEx.PageData.build(app, model)

# 2. Bound to Ash and LiveView with the frontend workflows.
{:ok, spec} =
  BubbleEx.Target.Elixir.FrontendWorkflows.map(lowered, project,
    namespace: "Acme",
    frontend: frontend,
    backend: workflows,
    page_data: page_data
  )

# 3. Printed with the pages (unchanged call).
{:ok, files} = BubbleEx.Target.Phoenix.render(project, frontend_workflows: spec, ...)
```

**Loading is off by default.** Pages load data only with the frontend
workflows' opt-in, `config :<app>, <Web>.BubbleWorkflows, data_access:
true` (owner decision, 2026-09-27): the resources are generated with
`privacy: :omit`, so no resource has an authorizer and every read would
return every record to anyone who can open the page. Until privacy
policies are generated, turning it on is the owner's call. **Do not enable it on
public pages without first adding and testing authorization policies**; passing
`authorize?: true` alone does not enforce privacy.

**A search that ignores empty constraints can return every record.** A
search stating `ignore_empty_constraints: true` drops each constraint
whose value is empty, as Bubble does. For a logged-out visitor `Current
User` is empty, so a constraint `X = Current User` (the usual "my
records" search) is dropped and the search returns every record of the
type, up to the page size or `:max_items`. Under `privacy: :omit`
nothing stops this: there is no policy to fall back on. Before enabling
data access, find such searches on pages a logged-out visitor can open
(or that a signed-out session can reach), and either require a signed-in
user there or add policies.

## Sources

`BubbleEx.PageData.Source`, per page and element of a page or reusable
element (not a mobile view):

| Bubble | `kind` | Generated read |
|--------|--------|----------------|
| a page's "Type of content" | `:page_thing` | the record whose unique ID is the URL path segment after the page name (`/<page>/<id>`, a second route except for `index`, where a root catch-all would capture owned routes); the segment must look like a Bubble ID (`<digits>x<digits>`), else nothing is read; query parameters cannot select a thing |
| a Group's, Popup's, Floating Group's or Group Focus's data source | `:group` | a search (below), or an Elixir value (`BubbleEx.Target.Elixir`); a thing given as a Bubble ID is read by ID |
| a Repeating Group's data source | `:list` | a search, or a list value (IDs are read by ID); its cells render its template once per item |
| a reusable-element instance's data source | `:instance` | the reusable element's thing for that instance (`Parent group` inside it) |

A **search** (with its constraints, its sort, optionally under `first
item`, `item #n`, `items until #n` or `count`) is an Ash query: its filter
comes from `BubbleEx.Target.Ash.Expressions.search/3` and is printed in
the page's `Workflows` module; what it reads from the page (an input's
value, a custom state, a URL parameter, a group's thing, the current
user) is computed first and **pinned** into the filter as a value
(`^pin_1`). A value the Ash filter cannot read itself (a field of a
group's thing, whether a value is empty) is computed in Elixir and
pinned too.

A group inside a repeating group's cell holds a value per cell. A
repeating group, a reusable instance or a search inside a cell is residue
(`:page_data_in_cell`): the page would query once per cell.

Sources are loaded in the order they read each other; a source that
reads one that is not loaded is not loaded either (`:unavailable_input`,
`inputs: ["data_source"]`), and sources reading each other in a cycle
are `:unresolved_reference`.

## What is generated

| File | Kind | What |
|------|------|------|
| `lib/<app>_web/live/<page>_live/workflows.ex` | owned | `__bubble__(:data)` (the sources, in order, with what blocks the ones not loaded) and one `data_<element>_<hash>/1` per source, marked `# bubble:data <id>` |
| `lib/<app>_web/components/reusables/<name>/workflows.ex` | owned | the same for a reusable element with data sources |
| `lib/<app>_web/bubble_data.ex` | generated | the loader: runs the sources, keeps them in `@bubble_data`, subscribes to changes |
| `lib/<app>/bubble/changes.ex` | generated | the change broadcaster the resources publish through |
| `lib/<app>_web/bubble_routes.ex` | generated | a second route per page with a type of content (`/<page>/:bubble_thing`) |
| the resources the pages read | generated | `Ash.Notifier.PubSub` publishing to `<App>.Bubble.Changes` |

Page bindings read the data through `<Web>.Bubble.data/3` (a group's,
page's or instance's thing, keyed by instance scope and element) and
`data/4` (a group in the `n`th cell); a repeating group's template loops
over `Bubble.cells/3`. The relationships a binding reads through a source
(`Parent group's Task's project's name`) are loaded with the data, not
while rendering.

## Security

* **The browser chooses nothing.** A page reads only the sources its
  module lists, with filters fixed in its code. From the browser come
  input values, custom states and URL parameters, pinned into filters as
  values, and the page thing's unique ID from the URL path, which must
  look like a Bubble ID and is read through Ash like any other record. No
  event names a resource, a record, a query or a data function; nothing
  from the browser becomes an atom (the behavior test checks the atom
  table).
* **Every read goes through Ash** with the current user as the actor and
  `authorize?: true` (which authorizes nothing until policies exist).
* **The opt-in is checked on every load path**: `<Web>.BubbleData.load/2`
  (mount, URL changes, events, change notifications) reads nothing with
  data access off, and relationship loads go through
  `<Web>.BubbleWorkflows.load/3`, which refuses on its own. Workflows that
  read the page's data are data workflows: they refuse to start without
  the opt-in, as those that read or write stored data.
* **Bounded.** A repeating group reads its first page (rows × columns);
  any list, with no page size or a larger one, stops at `:max_items`
  (`config :<app>, <Web>.BubbleData, max_items: 100`); a list of IDs is
  read by ID, at most as many; relationships loaded for page bindings
  batch across rows, and a record's related list reads at most
  `:max_items`, capped at 100 (`<Web>.BubbleData.related_cap/0`), in all
  when lists nest (two levels read at most 10 × 10); `count` is a count
  query.
* **Generated text is escaped**: Bubble IDs and app text in generated code
  are `inspect/1`ed without limits (quotes, `#{`, braces escaped); the
  `hostile_page_data` compile-check fixture renames every ID.

## Reactivity

The resources the pages read publish their changes through
`Ash.Notifier.PubSub` to `<App>.Bubble.Changes`: every create, update or
delete of a type on `bubble:<Type>`, every update or delete of a record
also on `bubble:<Type>:<id>`. A connected page subscribes to the type of
each search it ran, each record it holds, and the related records its
bindings preload. Notifications are coalesced into a re-read. Only the
topic travels, never the record: the page reads again with its own actor.
The page reads again only when its data is **stale** (`@bubble_data_stale`):
a change notification of a topic it subscribes to, a data step of its
workflows (create, change, delete, and schedules, through
`<Web>.BubbleWorkflows.backend/2`), or a custom state or input value its
workflows changed (either may be a search constraint). Stale data is read
again before the next workflow of an event (so a preceding write is
visible) and before data-driven conditions settle; every read clears the
flag. An event that changes none of these reads nothing: a click whose
workflows neither write nor change a state or input, a "do every" tick, a
scheduled custom event (a self-scheduling one no longer reads per round).
A page-load workflow runs on the data `handle_params` loaded (one read on
a connected mount). Every read also takes the change notifications already
delivered to the page (each is sent after its write committed, so the
read sees it): a workflow's own write and its notification cost one read,
not two; a write in owned code that goes through Ash counts too.
Input changes defer the workflows, re-read and condition evaluation
for 150 ms after the last keystroke; repeated changes to the same input
supersede its pending workflow without resetting the shared run budget. Writes that
bypass Ash (raw SQL, `Ash.Seed`, the loader) publish nothing.

## Residue fails loudly

Nothing is dropped silently:

* a source that is not loaded is a `:page_data_residue` diagnostic and a
  `TODO(bubble:<id>) its data source is not loaded (<reasons>)` marker on
  its element; its entry in `__bubble__(:data)` has no function and lists
  what `blocked` it;
* a binding that reads page data the page does not load is not rendered
  as an empty value but as a `TODO(bubble:<id>) <slot>: reads page data
  that is not loaded (<kind>)` marker (counted in `bindings_marked`);
* a workflow that reads it is `:unavailable_input` residue and refuses to
  start, as before.

## Coverage metrics

Both count page and reusable-element sources (a page with a type of
content, and every group, repeating group or reusable instance with a
data source; not mobile views, dropdown choices or plugin elements):

* **IR level**, `BubbleEx.PageData.coverage/1`: a source is *native* when
  it lowers with no residue: a page's thing of a data type, or a data
  source that compiles to Expression IR.
* **Generated code**, `BubbleEx.Target.Elixir.FrontendWorkflows.data_coverage/1`:
  a source is *wired* when the generated page loads it: native, bound to
  an Ash query, a URL read or an Elixir value with no target residue (an
  input the page does not provide, a source in a cell, a filter the Ash
  compiler rejects), and every source it reads is wired too.

The frontend workflow metrics (`docs/frontend-workflows.md`, *native*
and *wired* workflows) also move: a workflow reading a page's thing, a
group's or instance's thing or a repeating group's list is no longer
`:unavailable_input` when the page loads it.

### mm-137 (test version), 2026-09-27

Counts only; the snapshot is
`test/support/target/phoenix/counts/mm-137.frontend_workflows.json`.

| | before | after |
|-|------:|------:|
| workflows, native (whole body and callees) | 531 (23.3%) | 553 (24.3%) |
| workflows, wired (triggered by the page) | 361 (15.9%) | 380 (16.7%) |
| workflows, native own body | 648 (28.5%) | 702 (30.9%) |
| steps, native (generated code) | 1,795 (45.1%) | 1,877 (47.1%) |
| `:unavailable_input` residue entries | 1,027 | 858 |
| data sources, native (IR level) | – | 1,768 of 1,980 (89.3%) |
| data sources, wired (loaded) | 0 | 805 of 1,980 (40.7%) |

Wired sources by kind: groups 707/1,548, instances 59/195, lists 36/234,
page things 3/3; by read: 798 Elixir values, 4 queries, 3 URL things. The
largest blockers: 472 sources read a source that is not loaded, 160 read
a reusable element's parameters (not passed yet), 149 searches do not
state `ignore_empty_constraints` (below), 112 read a group's thing the
page does not load (mostly a reusable element's own, when no instance
gives it one), 74 read a cell's thing of a list that is not loaded, 62
are in a cell.

## Unverified Bubble behavior and open questions

* **`ignore_empty_constraints`.** Most searches do not state it, and
  Bubble's default is not verified; **do not set a global default merely to
  increase coverage**: verify the app's ignore-empty behavior first.
  Such a search with a constraint whose value may be empty is residue
  (149 on mm-137, and every source reading them). `BubbleEx.PageData.build/3` takes the default
  (`ignore_empty_constraints:`); it is left unset until replay (WTF-358)
  or the owner decides.
* A page's thing is read from the path segment after the page name; a
  slug is not resolved.
* A repeating group shows its first page; later pages ("Show next") are
  not loaded.
* Reusable-element parameters are not passed to components as data yet.
