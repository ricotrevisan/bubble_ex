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
page search stating `ignore_empty_constraints: true` drops each
constraint whose value is empty, as Bubble does (WTF-478; any other empty
constraint value matches nothing, see below). A **signed-in** user whose
referenced field is empty (`X = Current User's Workspace` for a user
with no workspace), or whose input is blank, gets every record of the
type the search can read, up to the page size or `:max_items`. A
logged-out visitor does not: a constraint reading the current user (or
one of its fields) matches nothing for them, which is stricter than
Bubble (its temporary user's empty fields would drop the constraint).
Under `privacy: :omit` nothing stops this: there is no policy to fall
back on, and requiring sign-in does not help. Before enabling data access, find such searches
and add policies that limit what each user may read (or generate with
`privacy: :enforced`), make the referenced field required, or set the
search's `ignore_empty_constraints` to false in Bubble where a blank
value should show nothing.

**A search on a field Bubble keeps out of searches is not loaded.** A
privacy rule can list fields the users it applies to may not search by
(non-filterable fields). A page data search whose constraints or sort
name such a field of the searched type is residue
(`:search_field_restricted`, `detail.fields`): Bubble limits it per user,
and under `privacy: :omit` nothing would. With policies (`privacy:
:unverified`), `<App>.Privacy.SearchFields` limits such a read to the
records where the user may search by the field.

## Enforced privacy (WTF-423)

`BubbleEx.Target.Phoenix.render/2` also renders a Project mapped with
`privacy: :enforced` (`BubbleEx.Target.Ash`, "Enforced"): the privacy
rules compiled to Ash policies, and a runtime that passes them an actor
everywhere.

**What is guaranteed**, for page data, frontend and backend workflows,
the workflow API and private files:

* **Reads follow the compiled privacy rules** for the current user, read
  afresh with what the policies read (`<App>.Privacy.load_actor/1`) at
  every page load and event, so a changed role is not served stale. A
  record the user may not view reads as nothing; a hidden field as empty
  (`%Ash.ForbiddenField{}`, shown as empty text); a search runs the
  `:search` action (what the user may find in searches); a read the
  policies refuse outright (logged out, where every rule reads the user)
  shows nothing, as in Bubble. Relationships load through the policies
  too.
* **Stricter than Bubble on empty values**, by decision: where a rule
  compares a value of the user's (logged out, or a user without it) with
  a record's, Bubble may grant when both are empty; the policies deny
  (`actor_empty_denies`, reported as intended differences). Likewise
  (WTF-467) a logged-out user is denied every comparison reading it
  (Bubble's temporary user is unequal to any record's user), `x is no`
  needs a stored no (Bubble reads an empty yes/no as no), and the
  `everyone` rule's grants reach only users no rule lacking them matches
  (Bubble's reach every user).
* **Searches on fields some users may not view are decided per user**
  (WTF-457). In Bubble, viewing a field and constraining a search on it
  are separate permissions: a page search constrained (or sorted) on a
  field the user may not view matches its stored value, an oracle on the
  hidden values (replayed 2026-10-01: a logged-out visitor's `= aaa`
  found the record holding "aaa", `is not empty` found both, `is empty`
  none; Bubble's security dashboard flags such fields as "non-viewable
  but constrainable"). A backend workflow's search reads the field as
  empty instead, and a Data API search matches nothing; only a field the
  user may not constrain on (non-filterable) makes a page search find
  nothing. Field policies do not guard a filter written in code, so the
  generated page loads such a search and `<App>.Privacy.SearchFields`
  matches nothing on a record whose field the user may not view (like
  the Data API): it returns only the records where the user may view
  every field its filter or sort reads, in either polarity (per user and
  record, in the database). A user who may view the field gets Bubble's
  result; one who may not finds fewer records than in Bubble, by the
  owner's decision (stay stricter: `hidden_field_constraint_matches` in
  `BubbleEx.Verify.Difference`, `:ash_policy_hidden_search_stricter_than_bubble`
  per data type). Only a hidden field further along a relationship (a
  normalized list's join, ...) is still residue (`:search_field_hidden`):
  the check would return nothing for everyone.
* **Writes (Rico's option A)**: the generated runtime's writes are allowed
  (the `WorkflowWrite` check: a context flag only the runtime sets), so a
  workflow's own conditions guard them, as in Bubble. **They are not
  checked against the privacy rules**; every generated app warns about it
  (README, file headers, `:ash_writes_not_policy_checked`). Any other
  write (owned code, a form) is forbidden. A list change (add, remove) on
  a field the user may not view fails the step instead of overwriting it.
* **The workflow API's admin token bypasses privacy**, like Bubble, for
  the run and the custom events it triggers (not the jobs it schedules).
  A user's bearer token runs as that user.
* **Private files** can follow Bubble's "view attached files" rule:
  `private: :privacy_rules` serves a file when a record holding it in a
  file field is readable through its `:attachments` action by the user.

**What `<App>.Privacy.SearchFields` guards:** the filter, sort and
distinct of a read through any read action but `:attachments` (by
primary key), written in code or given as `filter_input`/`sort_input`.
It restricts a field of the read resource some users may not view, a
gated relationship and its private `*_for_privacy` twin (by path or
through `exists`), and a derived field or count that reads through one
of them; it returns only the records where the actor may view each
named field, so a record whose field the actor may not view matches
nothing whatever the expression (`is_nil`, `not`, `or` included). A
restricted field further along a relationship path returns nothing for
everyone (the page leaves such a search as `:search_field_hidden`).

**Not guaranteed:** aggregates over hidden fields (`Ash.count`,
`Ash.sum`, a `:count`/`:sum` aggregate or calculation that reads one:
the check sees the read's filter and sort, not what an aggregate or
calculation computes); calculations written in code that read a hidden
field (field policies hide a loaded field's value, not what code
computes from it); owned code that bypasses authorization
(`authorize?: false`, the Repo). The policies are checked by the
privacy matrix against the interpreter's calibrated reading of Bubble,
run against the generated app (`scripts/phoenix_compile_check.sh`): that
is evidence, not a proof.

**Defaults stay off** (the owner's call). With enforced policies,
`data_access: true` and `serve_workflow_api: true` no longer expose every
record to anyone: they expose what Bubble's rules allow, with writes as
Bubble does them. bubble_ex's recommendation is to default both on in
enforced mode once the owner has reviewed the stricter-than-Bubble list
and the workflows users can trigger (writes are theirs to guard);
`private: :privacy_rules` likewise. Until the owner decides, they remain
opt-in.

## Sources

`BubbleEx.PageData.Source`, per page and element of a page or reusable
element (not a mobile view):

| Bubble | `kind` | Generated read |
|--------|--------|----------------|
| a page's "Type of content" | `:page_thing` | the record whose unique ID is the URL path segment after the page name (`/<page>/<id>`, a second route; for `index` it is `/index/<id>` (WTF-454), since a root catch-all would capture owned routes); the segment must look like a Bubble ID (`<digits>x<digits>`), else nothing is read; query parameters cannot select a thing |
| a Group's, Popup's, Floating Group's or Group Focus's data source | `:group` | a search (below), or an Elixir value (`BubbleEx.Target.Elixir`); a thing given as a Bubble ID is read by ID |
| a Repeating Group's data source | `:list` | a search, or a list value (IDs are read by ID); its cells render its template once per item |
| a reusable-element instance's data source | `:instance` | the reusable element's thing for that instance (`Parent group` inside it); in a repeating group's cell, per cell (WTF-494, below) |
| a property a reusable-element instance sets (WTF-493) | `:param` | its value, computed where the instance is, kept under the instance (`This Reusable's <property>` inside it) |
| a reusable element property's default value | `:param` | computed inside the reusable element, for an instance that sets no value |
| a group, popup, repeating group or instance with no data source that a "Display data" / "Display list" step sets (WTF-492) | its kind | what the step showed (`read: :displayed`), read again as the current user; nothing before a step |

A **search** (with its constraints, its sort, optionally under `first
item`, `item #n`, `items until #n` or `count`) is an Ash query: its filter
comes from `BubbleEx.Target.Ash.Expressions.search/3` and is printed in
the page's `Workflows` module; what it reads from the page (an input's
value, a custom state, a URL parameter, a group's thing, the current
user) is computed first and **pinned** into the filter as a value
(`^pin_1`). A value the Ash filter cannot read itself (a field of a
group's thing, whether a value is empty) is computed in Elixir and
pinned too.

Bubble's **random sort** (`sort_field: "_random_sorting"`, WTF-452)
compiles to `sort: [:random]` (`BubbleEx.Target.Ash.Expr`) and is printed
as `|> BubbleData.random_sort()`: the records ordered by
`md5(CAST(<primary key> AS text) || seed)` in the database (the first
column of a composite key only), then limited
by the page size and `:max_items` as any other search, so the list is a
random selection of the search, not its first records shuffled. The seed
is new on every read (the order changes whenever the page reads again,
change notifications included, as Bubble's does on every load);
`config :<app>, <Web>.BubbleData, random_seed: "..."` fixes it, and the
generated `config/test.exs` sets one so tests see a deterministic order.
It reads no field of the record but its key: with enforced policies it
runs through `:search` like any other search (what the user may find),
the search fields check sees the sort, and no field policy is involved
(no `:search_field_hidden`). Any other sort field that maps to no
attribute leaves the search uncompiled (residue).

A search may name **further sort keys** (`additional_sort_fields`):
the list is sorted by the first key, then the next among equal ones, and
so on, in the database (`Ash.Query.sort([{:rank, :asc_nils_last},
{:title, :desc_nils_last}])`: empty values last, as Bubble sorts things). The editor's display names (`*_friendly`) and an unset
dynamic sort field or geographic reference are ignored; a dynamic sort
field (one an expression picks) or a geographic sort is residue
(`:search_option`).

### List operators (WTF-495)

A source's list operators are lowered by
`BubbleEx.Target.Elixir.FrontendWorkflows.Lists` before binding, so the
database sorts and filters lists of things wherever it can:

| Bubble | Generated read |
|--------|----------------|
| a search `:sorted by` (again) | one query sorted by both keys, the outer one first |
| a search `:filtered` | the search with the filter's constraints added: what the filter keeps of the whole search, not of its first page |
| any other list of things `:sorted by` | a query for the list's records (`id in ^ids`), sorted |
| any other list of things `:filtered` | a query for the list's records that meet the constraints, shown in the list's order (`Runtime.intersect/2` with the list second: it follows the second list's order) |
| `:merged with`, `:unique elements`, `:minus list`, `:intersect with`, `:plus item`, `:minus item`, `:items until #`, `:item #`, `:converted to list` | Elixir over the lists (the generated `Bubble.Runtime`); a search under them is a query read first (`query_<n>`) |
| options, texts, numbers or dates `:filtered` | Elixir (`Enum.filter/2`, the constraints per item) |
| texts, numbers or dates `:sorted` | Elixir (`Runtime.sort_values/2`): empty values first ascending, last descending; a stable sort |
| `All <option set>` (an option value of `all values`) | every option of the set |

Every query reads as the current user, bounded by `:max_items`, like any
other search: a merged list reads at most `:max_items` of each search,
then shows one page, so it may show less than Bubble, never more. What
would show more or other than Bubble over such a capped read is residue
(`elixir:capped_list`): its count, its last item, or subtracting it from
a list (`:minus list`). A count of searches of one type merged is one
count query for either's records. A query for a list's records reads
them as the user may view them (the resource's read action, its count
too, `BubbleData.listed/2`), as reading the list's things by ID does; a
search, as the user may find them (`:search`). It reads all of the
list's matches (the list's things' IDs, each once, at most
`:max_listed`, default 10,000, logged past it) unless a page shows them,
and equal sort keys keep the list's order (its position is the last
sort key). A record the list holds that the user may not read is
not shown; with enforced policies, neither is one whose sorted or
filtered field the user may not view (`<App>.Privacy.SearchFields`, as
for searches, WTF-457). A source over queries subscribes to its type's
changes like a search (`read: :query`), and to those of every resource
its queries search (`query_topics`), whatever its own type (a count, a
text).

As Bubble does (replay 2026-10-07, a list of texts `b,a,b,c` and `c,d,a`,
and three things):

* `:unique elements` keeps each item's first occurrence, in order
  (`b|a|c`); `:merged with` keeps the first list's items, then the
  second's not in it, each once (`b|a|c|d`); `:minus list` removes
  duplicates too (`b`); things are the same item when their unique IDs
  are.
* `:intersect with` follows the **second** list's order (`c|a`).
* `:plus item` of an item already listed deduplicates the whole list
  (`b|a|c`, not `b|a|b|c`); of an empty value it **appends** it (empty).
* `:items until #` with an empty number or 0 shows nothing; `:item #`
  with 0, a negative or an empty number is empty.
* Texts, numbers and dates sort with empty values **first ascending**
  and last descending. Things sort with empty values **last in both
  directions** (`Ash.Query.sort` with `:asc_nils_last` /
  `:desc_nils_last`, for searches too: one database sort).
* `:filtered` with an empty constraint value matches nothing when
  `ignore_empty_constraints` is unstated or false, and everything (the
  constraint is dropped) when true.

Still assumed (chosen to show less, never more): a list of things sorted
or filtered shows each thing once (a query finds each record once), and
a sort is stable: equal keys keep the order of what is sorted (a
search's, the database's).

Extended beyond what the replay measured (unverified):

* A search's own sort ("Do a search for" with a sort field) also puts
  empty values last in both directions: the replay measured `:sorted` on
  a list of things, and both are one database sort here.
* `:plus item` (deduplicating, appending an empty value) and `:sorted` by
  value apply to every list: the replay measured lists of texts (and
  `:plus item` of a listed thing); numbers, dates and things follow the
  same rules.

Not lowered yet: sorting a list of options, or any list by a field of its
items (residue `elixir:sort`), a field of each item of a list, a list
operator inside a repeating group's cell (`:page_data_in_cell`, `kind:
query`), dynamic sort fields.

**Display data (WTF-492).** An element a "Display data in a group /
popup" or "Display list in a repeating group" step sets shows what the
step showed until a reset or the page's next load, in place of its own
data source, even when what that source reads changes, and an empty
value shows empty (replay 2026-10-07; `docs/frontend-workflows.md`). The page keeps a thing's
unique ID only (`@bubble_displayed`) and reads it again, as the current
user through Ash, at every read of its data: a workflow never shows
what the user may not read. Its entry in `__bubble__(:data)` says so
(`display: %{page_size: ...}`); one with no source of its own has no
function (`read: :displayed`, `fun: nil`, nothing `blocked`). Only an
element a step that runs sets is listed.

## Reusable element properties (WTF-493)

An instance's properties are page data. Each value it sets in the editor
is a source of the instance's page (or reusable element): a static value
as the property's type (the editor keeps yes/no and numbers as text:
`"true"`, `"1.5"`), an expression computed in the instance's parent's
scope, like the instance's own data source. A property it does not set
takes its default, a source of the reusable element computed inside it
(a default may read the reusable element's thing, its other properties,
its elements), read only for the instances that set no value; with no
default it is empty; a default reading its own property is a cycle
(`:unresolved_reference`). Values are kept under the instance's scope
(`{scope, "param_<id>/<reusable id>"}` in `@bubble_data`, the component's
`bubble_data` attribute: property IDs are unique only within a reusable
element, so keys, relationship loads and input-change reloads name
both), so `This Reusable's <property>` reads the value of the
instance being rendered, in texts, visibility conditions, data sources
(a group whose data source is the property) and workflows, and nested
reusables pass theirs down the same way. A page may read an instance's
property too (`<instance>'s <property>`): the value the instance sets,
or, when it sets none, its default (with no default, see below), which the
page computed in the instance's scope under the same key. The page's
texts and visibility conditions read it when they render, after the
page's data loaded, and only when every value of the property loads
(below) and the instance is outside a repeating group's cell; the page's
own data sources and workflows read only a value the instance sets
(they run before the instance's sources compute its default).

A property with no value (no default, and the instance sets none) reads
as empty in texts, but a visibility condition reading it is not decided
(WTF-505): Bubble's value there is not verified, and an empty value would
decide it wrongly (a panel shown whenever the property differs from
something). Read from where the instance is, or in a reusable element no
instance of which sets it, the conditionals are not lowered (a marker,
counted in `visibility_conditions_unset_property` too) and the element
keeps its fallback visibility. When only some instances set it, the
helper decides for those, and an instance with no value keeps the
fallback: `Bubble.set?/3` checks that the instance's scope has a value
under the property's key, and a value the instance sets (even an empty
one) or a default is always there. The fallback is the page-load
visibility; with privacy: :enforced, an element shown on page load that a
conditional may hide stays hidden, so content a condition hides is never
shown for want of a value.

Visibility conditions and shown values (a text's dynamic content, an
input's placeholder...) may also read a URL parameter read as a single
text (`Get <name> from page URL`, Bubble's default type): the runtime
keeps the URL's query (`@bubble_url`, decoded by Phoenix: text values
only, a repeated key reads its last value, `+` reads as a space, and a
key written `x[]` is not a text value, so it reads as empty; Bubble's
reading of these is a replay question, WTF-387), and a reusable element's
component gets it from its caller (`bubble_url`), at any depth. A URL
parameter of another type (a yes/no, a number, a thing), a list or a
path is not read by either: the condition or the value stays a marker
(the typing reads every URL parameter as text, which would compare or
show it wrongly).

A thing or list of things a property holds is what the parent's
expression read: through Ash, with the current user as the actor, like
every other source (a search is a query, Bubble IDs are read by ID; a
record the user may not view is nothing). Nothing reads around the
policies.

`This Reusable's <property>` is read only when **every** value of it
loads: each instance's (one in a repeating group's cell too, when it is
rendered per cell, WTF-494) and its default.
One that does not (it does not compile, or reads data the page does not
load) leaves the reads residue (`:unavailable_input`,
`element_state:param`) for every instance, never an empty value for some;
the instance is marked `TODO(bubble:<id>) its property param_<id> is not
passed (<reasons>)`.

An instance in a repeating group's cell sets its properties per cell
(below).

Bubble has no workflow action that changes a property (in the private
fixture app, no action names one): properties are read only. A "Display
data" step on an instance sets the instance's own thing (`Parent group`
inside it, WTF-492), not its properties: they stay the values computed in
the parent's scope.

A group inside a repeating group's cell holds a value per cell. A
repeating group or a search inside a cell is residue
(`:page_data_in_cell`): the page would query once per cell.

## Reusable instances in repeating group cells (WTF-494)

A reusable-element instance in a repeating group's cell is rendered once
per cell, in a scope of its own: the cell's thing's
(`<Web>.Bubble.cell_scope/4`: `<scope>-<repeating group>~2<the thing's
unique ID>`, then `-<instance>`; a list of texts or numbers, which has no
unique ID, by the cell's position). A re-sorted list keeps what each
thing's cell held, as "Display data" does in cells (WTF-492). In that
scope:

* its own data source and the properties it sets are computed in the
  cell (`Current cell's X` is that cell's thing); they are sources of the
  instance's surface with `cell` set, kept under the cell's scope like an
  instance's outside a cell, and they need the list loaded;
* its reusable element's sources (groups, lists, defaults, nested
  instances' properties) run in the cell's scope, so a text, a visibility
  conditional or a workflow inside it reads that cell's values;
* its custom states and inputs are the cell's: a cell new to the page
  starts with the defaults and first values, a cell the page already
  showed keeps its own;
* its workflows run in that scope (clicks, input changes, "Display
  data", resets). Its page-load, condition-true and "do every" workflows
  do not run in a cell (a condition would be evaluated in every cell on
  every event): the instance is marked when its reusable element has
  any.

**Read for every cell together, never once per cell.** The loader reads
each source for all the cells at once (`<Web>.BubbleData`):

* a value computed per cell is Elixir on what the page loaded; the
  relationships it reads through a source, a custom state or the current
  user are read again for every cell first (`preloads:` in
  `__bubble__(:data)`), through Ash as the current user, never reused
  from what was loaded before (the current user is loaded with what the
  policies read, without authorization: its relationships are read again
  into a copy for the values, and the actor the policies read is left as
  it is; a read that fails reads as empty, logged, never as the value
  carried it); the relationships the page's bindings read through the value
  are loaded for every cell after, one load per resource;
* a thing given as a unique ID (`BubbleData.records/5`) is read with the
  other cells' IDs, one read per resource;
* a search that reads nothing of the instance or the cell (only the
  current user, the time or the URL, `shared: true`) runs once and is
  shared by every cell;
* a search that reads the instance would run once per cell: a reusable
  element with one (or nesting one, outside its own cells) is not
  rendered per cell. Its instances in cells keep one fixed scope and are
  marked, with their sources (`:page_data_in_cell`, `kind` `"query"`):
  `TODO(bubble:<id>) rendered once for every cell, not per cell`.

A repeating group's first page is at most `:max_items` cells, and the
instances in cells of lists inside those instances are read the same
way, at most `:max_cell_depth` levels down (default 3) and `:max_cells`
scopes in all (default `:max_items` x 10; `config :<app>,
<Web>.BubbleData`): past that the first scopes are kept, the rest show no
data and take no events, logged once per page. An input change re-reads
only what reads the input in every cell; when a list whose cells hold
instances is re-read, the whole page is. When a cell leaves the list
(its thing is gone, filtered out, or no longer readable), what the page
kept for it (custom states, inputs, what "Display data" showed) is
dropped, and its scope takes no event, a paused or scheduled workflow
included. A list of texts or numbers has no unique ID: its cells are
by position, duplicates included; a list holding the same thing twice
gives both cells one scope (they share their states).

An instance inside a runtime container of a cell (not the cell's own
template) keeps one scope and is marked.

**Privacy.** Every read goes through Ash with the current user as the
actor, as anywhere else, the current user's own relationships included
(`enforced_behavior.exs`: a member reads their team's name, not its
secret, in a cell too). The cells are the list's items as the user read
them: a thing the user may not read has no cell, so no instance and no
scope.

**Events.** A page lists the cell scopes it read (`@bubble_cells`) and
accepts a click or an input change only in a scope it renders: the
page's own, an instance's (`__bubble__(:instances)`) or a cell's it
read; any other is ignored, so a browser cannot reach a cell of a thing
the user was not shown, or make up a scope. The scope is never parsed.

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
| `lib/<app>_web/bubble_routes.ex` | generated | a second route per page (`/<page>/:bubble_thing`, `/index/:bubble_thing` for the index page): a page with a type of content reads its thing there, any other ignores it (WTF-466) |
| the resources the pages read | generated | `Ash.Notifier.PubSub` publishing to `<App>.Bubble.Changes` |

Page bindings read the data through `<Web>.Bubble.data/3` (a group's,
page's or instance's thing, keyed by instance scope and element) and
`data/4` (a group in the `n`th cell); a repeating group's template loops
over `Bubble.cells/3`. The relationships a binding reads through a source
(`Parent group's Task's project's name`) are loaded with the data, not
while rendering.

## Security

* **The browser chooses nothing.** A page reads only the sources its
  module lists, with filters fixed in its code, in the scopes it renders
  (a reusable instance in a cell: the cells it read, WTF-494). From the browser come
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
  query (with `privacy: :enforced`, the number of keys read through
  `:search`, at most `:max_count`, default 10,000, past which it shows the
  cap and logs: Ash's count aggregate under-counts with policies that read
  the user).
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
supersede its pending workflow without resetting the shared run budget.

Writes that bypass Ash (raw SQL, `Ash.Seed`, the data loader, a Repo call
in owned code) publish nothing, and since reads are gated on staleness
they are no longer picked up by the next click either: a page shows them
only after something marks its data stale (a notification, a data step or
a state change of its own workflows) or on its next mount. Owned code that
writes around Ash and wants open pages to follow must broadcast the
topics above itself (`<App>.Bubble.Changes`).

A "do every" workflow whose actions change no data, custom state or input
does not re-read either. A source that uses Current date/time directly (a
search constrained by `Current date/time`, a displayed "time ago") is
therefore frozen at its last read; to refresh it on a schedule, have the
"do every" workflow set a custom state the source reads.

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

### Private fixture app (test version), 2026-10-04 (WTF-494)

Reusable instances in repeating group cells. Of the 61 instances in a
cell, 6 are rendered per cell; 53 wait on their list, which the page
does not load yet (list operators such as sort, merge and unique,
searches that do not state `ignore_empty_constraints`, search options),
and 2 on a search of their reusable element that reads the instance.
The 6 render 504 elements (their reusable elements', nested ones
included) with each cell's data, where every cell showed the same empty
instance before.

| | before | after |
|-|------:|------:|
| data sources, total | 3,530 | 3,246 |
| data sources, wired | 2,026 | 2,044 |
| `:page_data_in_cell` residue entries | 531 | 22 |
| instance sources wired | 107 | 113 |
| visibility conditionals rendered | 569 | 607 |
| workflows, native (generated code) | 737 | 750 |
| workflows, wired | 502 | 511 |
| `TODO` markers in the pages | 4,310 | 3,983 |

The total drops because an instance in a cell now lists only the
properties it sets (469 values in cells before, 185 now), as everywhere
else. The 13 newly native workflows read a reusable element's thing that
an instance rendered per cell now gives it.

### Private fixture app (test version), 2026-09-27

Counts only; the snapshot is
`test/support/target/phoenix/counts/private-app.frontend_workflows.json`.

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
state `ignore_empty_constraints` (compiled since WTF-478, below), 112 read a group's thing the
page does not load (mostly a reusable element's own, when no instance
gives it one), 74 read a cell's thing of a list that is not loaded, 62
are in a cell.

## Empty constraint values (WTF-478)

What a search constraint whose value is empty does was replayed against
Bubble (WTF-385, 2026-10-01), and depends on where the search runs
(`BubbleEx.Expression.Env`'s `searches`):

| where | `ignore_empty_constraints` unstated or false | `true` |
|-------|----------------------------------------------|--------|
| a page (its data sources, elements and workflows) | matches nothing, even a record whose field is empty | the constraint is dropped |
| a backend workflow | matches nothing | matches nothing (no effect) |
| a page workflow's server-side action (create, change, delete, bulk change, schedule, …) | matches nothing | matches nothing: **stricter than Bubble** (see below) |

(The Data API drops `equals ""`, `equals null`, `not equal ""` and `text
contains ""`; nothing here generates Data API searches.) Both forms are a
filter of the same search, read with the actor like any other, so privacy
policies and `<App>.Privacy.SearchFields` still apply: a field a dropped
constraint names still decides whether the search is loaded. The
emptiness of a page's value is computed per read (a pinned
`Runtime.empty?/1`). The Current User itself is never empty (a
logged-out visitor is Bubble's temporary user), so `X = Current User`
matches nothing for them rather than being dropped.

**Known difference: server actions are stricter than Bubble.** In a page
workflow's server-side action, Bubble drops an empty constraint when the
search states `ignore_empty_constraints: true`, as a page search does
(replay 2026-10-07: "Delete a list" and "Make changes to a list" on
`field = <empty input>` touched both marker records with `true`, none
unstated or false). Here such a constraint matches nothing whatever the
flag says, on purpose: a delete or bulk change with a blank input never
reaches every record the user can read.

A page's `:filtered` takes the page search's rule (replay 2026-10-07:
unstated or false, an empty value matches nothing; `true` drops the
constraint), whatever default `BubbleEx.PageData.build/3` is given.
Elsewhere a `:filtered` follows its own `ignore_empty_constraints`
(`true` drops, `false` compares), or the caller's default; without
either it is residue, as is a search where it is not known where it runs
(a privacy rule's condition).

## Unverified Bubble behavior and open questions

Answered by the replay of 2026-10-07 and removed from this list:
`:filtered` with an empty constraint value, the list operators,
server actions with an empty input (kept stricter than Bubble, above)
and "Display data" over a group's own source.

* **Matches nothing for operators other than `equals`.** The replay
  tried `equals`; that `>`, `contains`, `in` and the others match
  nothing on an empty value (or are dropped with `true`) is assumed.
* A page's thing is read from the path segment after the page name; a
  slug is not resolved.
* A repeating group shows its first page; later pages ("Show next") are
  not loaded.
* A reusable instance in a repeating group's cell: that Bubble runs its
  page-load workflows once per cell, and its condition-true ones per
  cell, is not replayed (here neither runs in a cell); that two cells of
  the same thing (a list holding it twice) share their custom states is
  this target's choice (WTF-494).
* A property an instance sets to a value that is empty at run time stays
  empty; whether Bubble shows the property's default then is not replayed
  (WTF-387).
