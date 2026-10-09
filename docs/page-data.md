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
| a Repeating Group's data source | `:list` | a search, or a list value (IDs are read by ID); its cells render its template once per item; in another's cell, per outer cell (WTF-520, two levels, below) |
| a reusable-element instance's data source | `:instance` | the reusable element's thing for that instance (`Parent group` inside it); in a repeating group's cell, per cell (WTF-494, below); an instance whose source does not load is not rendered (WTF-522, below) |
| a property a reusable-element instance sets (WTF-493) | `:param` | its value, computed where the instance is, kept under the instance (`This Reusable's <property>` inside it) |
| a reusable element property's default value | `:param` | computed inside the reusable element, for an instance that sets no value |
| a group, popup, repeating group or instance with no data source that a "Display data" / "Display list" step sets (WTF-492) | its kind | what the step showed (`read: :displayed`), read again as the current user; nothing before a step |
| a group, popup, floating group, group focus or repeating group with a type of content, no data source and no step setting it, outside a repeating group's cell (WTF-520) | its kind | nothing, ever (`read: :displayed`) |
| a reusable-element instance with no data source and no step setting it, when every instance of its reusable element (which has a type of content) is one, outside a repeating group's cell, and no step inside it sets its own thing (WTF-520) | `:instance` | nothing, ever (`read: :displayed`): the reusable element's reads of its own thing read nothing |
| a group, popup, floating group, group focus, repeating group, table or reusable-element instance whose conditional states set a data source (WTF-520, WTF-521) | its kind | the value of the last state whose condition is yes, else its own data source, or nothing when it has none (IR `:if`), computed where the element is; outside a repeating group's cell only the winning branch is read (`read: {:switch, ...}`) |
| an input's (Input, Multiline Input) initial content that is an expression, outside a repeating group's cell (WTF-520) | `:input` | its value, its conditional states that set the content applied, computed where the input is: the input's first value |

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
operator over a search inside a repeating group's cell that cannot be
read for every cell together (`:page_data_in_cell`, `kind: query`; see
*Searches in cells* below), dynamic sort fields.

**Display data (WTF-492).** An element a "Display data in a group /
popup" or "Display list in a repeating group" step sets shows what the
step showed until a reset or the page's next load, in place of its own
data source, even when what that source reads changes, and an empty
value shows empty (replay 2026-10-07; `docs/frontend-workflows.md`). The page keeps a thing's
unique ID only (`@bubble_displayed`) and reads it again, as the current
user through Ash, at every read of its data: a workflow never shows
what the user may not read. Its entry in `__bubble__(:data)` says so
(`display: %{page_size: ...}`); one with no source of its own has no
function (`read: :displayed`, `fun: nil`, nothing `blocked`).

Which elements are listed depends on when their steps may run (WTF-520,
`docs/frontend-workflows.md`, "Display data"): an element only events
set (clicks, input changes, "do every" ticks, the custom events they
call) is listed when the page triggers every one of those events,
whether or not the runtime then runs their workflows, since it shows
nothing before the event, as in Bubble; a popup's "is opened" or "is
closed" workflow counts as the workflows whose steps open or close the
popup, and must be triggered itself (WTF-520: popups are closed as the
page loads); one a step may set as the page loads (a page-load,
condition-true or plugin-event workflow, a custom event one of them
calls, or a popup one of them opens or closes) only when every such
workflow runs whole here; otherwise it is not listed, and what reads it
is not loaded.
An element no step sets, with no data source, shows nothing and is
listed too, so what reads it (a group inside it reading `Parent group's`
field, a search constrained by it, a reusable property's default) loads,
reading an empty value: with `ignore_empty_constraints` a constraint on
it is dropped, as in Bubble.

**Conditional data sources (WTF-520, WTF-521).** A group, popup,
floating group, group focus, repeating group, table or reusable-element
instance may get a data source from its conditional states ("when ...
data source: ..."). Its source is then those states folded in Bubble's
order over a base (the last state whose condition is yes wins, an empty
condition is no, IR `:if`, the last state outermost): the base is the
element's own data source (an instance's thing for an instance), or an
empty value when it has none, as an input's initial content is. Each
state's source replaces the base whole: a repeating group whose own
source is a search with constraints and a sort, and whose condition sets
another search, shows that other search with its own constraints and
sort, never one merged with the base's. A state whose source is another
kind of value than the element holds (another data type, a list in a
group, one thing in a repeating group) cannot be shown in it: residue
(`:uncompiled_expression`, construct `conditional_source_type`; an
untyped side or an empty value is not checked).

Outside a repeating group's cell the source is read as
`read: {:switch, %{cases, else}}`
(`BubbleEx.Target.Elixir.FrontendWorkflows.Data`): the generated function
tests the conditions in order (`data_<element>_when_<n>`, the last state
first) and reads only the winning branch (`data_<element>_then_<n>`), or
the base (`data_<element>_else`). Each branch is a whole read of its own,
a search as an Ash query with its constraints, sort and the element's
page size, or a value; a condition is a value, its searches read first.
The queries go through `BubbleData.read/4`, so one already read in the
same pass (`once/3`) is not read again, and nothing is read for a branch
that does not win. In a repeating group's cell the fold is one value,
computed per cell, as before; a search there is read for every cell
together (*Searches in cells*, below) or is `:page_data_in_cell`.
In a reusable element rendered in cells (one of its instances is in a
repeating group's cell, or it is nested in one that is), a conditional
source with a search that reads the instance's scope would query once
per cell: unless it is read for every cell together (*Searches in
cells*, below), that source is `:page_data_in_cell` residue (`kind` `"query"`),
and so is what reads it, but its instances are still rendered per cell
(WTF-494). A search that reads nothing of the scope is the same query in
every cell, read once. A value over searches read first (WTF-495) in
such a reusable element is held to the same rule (before, it was read
once per cell). A search source of its own that reads the scope still
blocks the per-cell rendering of its instances, as before.

What the source reads is the union of what the base, the conditions and
the branches read: its `inputs`, `reads` and `deps` in
`__bubble__(:data)` list them all, so the loader orders it after all of
them and an input change or a reload of any of them reads it again, the
conditions included (the change may flip which branch wins). Its change
topics are every branch's resources. A condition or branch reading the
element's own value is a cycle (`:unresolved_reference`, `reference:
"data_source"`): as the page loads that value is empty, so the condition
would always decide on nothing. If any part does not load, the element
is not loaded, never shown from its base alone or from part of its
states. When a part does not lower to IR (a state with no condition, a
condition or a source that does not compile, a state of another kind of
value), an element with a source of its own carries
`:unsupported_option` (`options: ["states.data_source"]`) next to the
parts' own residue, one with none only the parts' residue. When the
target cannot bind a part (a search the Ash compiler rejects, a value it
cannot compile, a source it reads that is not loaded, a cycle), the
element carries that target residue only, without the marker. What a
"Display data" or "Display list" step shows wins over the folded source
until a reset, as over any source of the element's own (unverified for a
conditional source, below). Privacy is unchanged: every branch is read
as the current user through Ash, with `data_access` off nothing is read,
and with enforced policies a branch's search is checked like any other
(`:search_field_hidden`, `:search_field_restricted`).

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
(below) and the instance is outside a repeating group's cell. The page's
own data sources and workflows read it too, the default included
(WTF-520, *Across instance boundaries* below).

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

Visibility conditions, shown values (a text's dynamic content, an
input's placeholder...), data sources and workflows also read the page's
URL (`Get data from page URL`), as Bubble reads it (replayed 2026-10-07,
WTF-387; WTF-508). The runtime keeps the URL as written, not Phoenix's
`params` (which keep a repeated key's last value and decode the path):
its query (`@bubble_url`, `<Web>.Bubble.url_query/1`) and its path's
segments (`@bubble_segments`, `<Web>.Bubble.url_segments/2`), and a
reusable element's component gets both from its caller (`bubble_url`,
`bubble_segments`), at any depth.

* **A query parameter** (Bubble's default type, text): `+` and `%20` are
  spaces; a key given more than once reads all its values joined with
  `,` (`?t=a&t=b` reads `a,b`); a key reads as written (`tags[]` is its
  own key, `?tags[]=a&tags[]=b` reads `a,b` for `tags[]`); an empty
  value is empty.
* **Typed** (`<Web>.Bubble.url_value/4`): a number parses `3`, `-2` or
  `3.5` (`abc` is empty); a yes/no is yes for `yes`, `true` or `1` and no
  for `no` or `false`, in any case, and empty for anything else (`0`,
  `y`, empty); a date parses `2026-10-07`, `10/07/2026` (month first),
  `Oct 7, 2026` (with an optional time, as Bubble writes dates into
  URLs), milliseconds since 1970 or ISO 8601 with a time, and one with no
  time is midnight in the app's time zone (`:bubble_time_zone`; Bubble
  uses the browser's).
* **A thing** is read by its unique ID through Ash, with the current user
  as the actor, so the privacy policies apply: an unknown ID, text that
  is not a Bubble ID or a record the user may not view is empty. Only
  data sources and workflows read it (a group whose data source it is,
  then the group's thing); a text or condition reading it directly stays
  a marker.
* **The path's segments** are a list of texts from 1: the Bubble page's
  name (whatever its route here, e.g. a reserved name's `/<name>-page`),
  then the segment after it, the route's `/:bubble_thing` (the index
  page's `/index/<x>`; at `/` there is none). Empty segments and a
  trailing slash are dropped, and nothing is decoded (`a%20b` and `e+f`
  read as written). Item 0 is empty. **The path** alone is the first
  segment after the page's name, as text or a thing.
* **"Is a list"** was not replayed (Buildprint cannot express it): such a
  parameter is not read, and the condition or value stays a marker; so
  does a list of things from the path.
* **Segments after the second.** Bubble serves deeper URLs
  (`/<page>/<a>/<b>`); the generated routes stop at `/<page>/:bubble_thing`
  and answer a deeper URL with not found. A read of path segment 3 or
  later would always be empty, so it does not compile (a marker on a
  page, residue in a data source or workflow).

**Not replayed (assumptions, WTF-387).** These choices are this
generator's, not measured against Bubble:

* a number in another notation (`1e3`) is empty; so is one longer than
  32 characters or past JavaScript's exact integers (2^53), never a value
  a database column would refuse;
* a repeated key with an empty value keeps its place: `t=a&t=` reads
  `a,`;
* the index page at `/` has no path segments (Bubble's index page at the
  bare domain may read its name);
* a bare four-digit date (`2026`) is that year's first day (as
  JavaScript reads it, local midnight here), not milliseconds; five or
  more digits are milliseconds since 1970.

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
repeating group inside a cell is residue (`:page_data_in_cell`, `kind`
`"list"`); a search inside a cell is read for every cell together
(*Searches in cells*, below) or is residue (`kind` `"query"`): the page
never queries once per cell.

### Across instance boundaries (WTF-520)

A data source may read an instance's property from outside the instance
(`<instance>'s <property>`) where the instance sets no value: the
property's default, computed inside the instance's reusable element, in
the instance's scope. A products list whose search is constrained by a
picker instance's default, or a sibling instance whose property is set
to it, reads that default. The loader reads the sources of the page and
of every instance it renders once as one graph, in the order they read
each other, across instance boundaries:

* each source lists what it reads (`deps` in `__bubble__(:data)`:
  `{:data, path, element}`, a value kept `path` instances below the
  scope the source runs in; `{:cell, rg}`, a list for its cells;
  `{:cell_data, group}`, a value per cell), and `<Web>.BubbleData` reads
  it after the sources keeping those values, whichever surface they are
  of: the default before the page's list, the instance's thing and the
  values it sets before the default;
* a default is read after the value an instance may set under its key
  (the default is only for the instances that set none);
* otherwise the order is the listed one: the page's sources, then each
  instance's; a reusable instance in a repeating group's cell reads its
  sources the same way, its nested instances' defaults included, all the
  cells' together (WTF-494).

Only an instance rendered once (not in a repeating group's cell nor
another runtime template) is read from outside, when every value of
the property loads, as `This Reusable's <property>` is. A value the
instance sets that does not load is not replaced by the default: what
reads it is not loaded. A property with no default that the instance
does not set is not read from outside by data sources and workflows
(`element_state:param`), as before.

**Cycles.** A default that reads, through the instance's thing or
properties, what reads it (the page's source reading the default sets
the instance's property the default reads) cannot be ordered: the
source reading the default from outside, in the cycle, is not loaded
(`:unresolved_reference`, `reference: "data_source"`), and neither is
what reads it, as before. The cycle is found with every instance
expanded in its own scope, so two instances of one reusable element
reading each other's defaults are no cycle.

What is marked is a source, not one instance's value of it: a cycle
through two instances of one reusable element (each one's property set
to the other's default, which reads it) marks both instances' values,
and since `This Reusable's <property>` loads only when every value of it
does (WTF-493), the default reading that property is not loaded for any
instance of the reusable element, nor is what reads it, on every page.
Scoping it to the instances in the cycle would need a value per instance
of a source the reusable element computes once; it is not done.

**Fail closed.** Where no source on the page keeps what a source reads
from outside an instance (the instance is not rendered there, or the
source keeping it is dropped there itself), the loader does not run the
source in that scope: it reads nothing, never an empty value in place of
the default (with `ignore_empty_constraints` an empty value would drop
the constraint). This is decided from the page's structure before
reading, not from values: a default that runs and fails (a read that
raises is logged and kept as nothing) gives what reads it an empty
value, as any other source that fails does. Every read still goes through Ash as the current user, with
data access off nothing is read, and a page reads only the sources its
modules list: the order changes, not what is read.

**Queries.** The order changes when each source runs, not how often: a
source reads once per load (and once for all the cells), and `once/3`
shares its queries within a read as before. The order of the page's own
sources and its instances' is computed once per set of modules and kept
(`:persistent_term`, again when a module is recompiled); the order of
the instances in cells, which depends on the lists read, is computed at
each read.

### Instances whose own source does not load (WTF-522)

A reusable element is compiled once for all its instances, so its reads
of its own thing (`Parent group's X` at its top, "Current reusable's
thing", a group or nested instance inside it whose source is that thing,
a workflow reading it) are loaded when some instance gives it a thing:
an instance whose own data source loads (or a step that sets it, or,
when every instance is one, an instance nothing fills, above). An
instance whose own source does not load (it does not compile, a
conditional state of it does not, it reads data the page does not load,
or, in a repeating group's cell, it cannot be read per cell) would
render that component reading nothing: an empty text, an empty list, a
workflow on an empty thing.

Such an instance is residue instead, per instance
(`Data.unloaded_instances/3`, `Spec.unloaded/2`), when its reusable
element reads its own thing at all: one of its expressions (a data
source, a text or attribute, a visibility condition, a workflow, a
nested instance's source or property) reads it, as compiled to IR
(`BubbleEx.PageData`'s `self_reads`). An instance of a reusable element
that never reads it renders whatever its source: nothing in it would
read the missing thing. The instance is rendered as a sized placeholder
carrying its `TODO(bubble:<id>)` markers (`not rendered: its data source
does not load, and its reusable element reads the thing it gives (Parent
group)`, and `its data source is not loaded (<reasons>)`), as an element
the page cannot render, and counted in the frontend report's
`placeholder`. Its sibling instances render and load as before.

Its scope is not rendered: it is left out of `__bubble__(:instances)`
(and, in a repeating group's cell, of `__bubble__(:cells)`), so the
loader reads none of its reusable element's sources there, the page
accepts no click or input change in it, and no page-load, condition or
"do every" workflow of its reusable element runs in it; nor does any of
its nested instances. Nothing inside it can be reached from outside
either:

* a property default read through it (`<instance>'s <property>`,
  WTF-520) is not loaded: the sources and workflows reading it are
  `:unavailable_input` (`element_state:param`), the page's texts markers;
* its custom states read by its page are not kept (their defaults have
  no scope to live in): a text is a marker, a visibility condition is not
  lowered and keeps its page-load visibility;
* a page step calling its custom event, or a "Display data" step into
  it, is `:target_not_rendered`. Showing data in it is not taken as
  filling it: before the step it would still show its own source, which
  does not load.

The binding runs in passes: an instance found unloaded in one pass stays
unloaded in the next (the page data is bound again only when a source
reads a value kept under a newly unloaded instance, a default or a
custom state; sources only lose, never gain, so the passes end). An
instance may so stay unloaded after a later pass finds its reusable
element no longer a root (its other instances lost their sources too):
it is then residue where the marked component would have done, never
rendered reading nothing.

When no instance gives the reusable element a thing, nothing changes:
its reads of its own thing are marked in the component itself, and
every instance renders it with those markers. The values the instance
sets for its properties are still computed and still count for `This
Reusable's <property>` (every value must load, WTF-493), as before; and
an instance in a repeating group's cell still counts its reusable
element as rendered in cells (WTF-494, `:page_data_in_cell`), since the
cell residue can be what leaves it unloaded in the first place.

## Inputs whose initial content is page data (WTF-520)

An input's initial content may read data: a field of its group's thing,
the current user's, another source's. Before, the page tracked only
inputs with a static first value; one with an expression showed it but
was not tracked, so every data source, condition and workflow reading
the input's value was not loaded (`:unavailable_input`,
`element_state:get_data`), however simple the search.

Such an initial content is now a source of the input (`:input`), computed
where the input is (`Parent group` is the input's group) with the
conditional states that set the content folded in Bubble's order (the
last state whose condition is yes wins; an empty condition is no: IR
`:if`). When it loads, the page tracks the input:

* its first value is `:data` (`__bubble__(:surface).inputs`, `{type,
  :data}`): until the user changes it, the input holds the value the page
  computed (`<Web>.BubbleWorkflows.input/3` and `<Web>.Bubble.input/5`
  read it from `@bubble_data`), and it follows that value when the data is
  read again (a change notification, a write), as an input's initial
  content does in Bubble;
* what reads the input (a search's constraint, a value) is read after its
  initial content (`reads` names the input) and again when it changes;
* the user's value wins from the first change on, whatever the data does;
  a value sent back unchanged (a blur with no typing, a form recovered on
  reconnect, the text shown before the data changed under a focused
  input), compared as the input shows it (a number by value, a text as
  text, empty as empty), keeps `:data` and runs no "An input's value is
  changed" workflow; a reset ("Reset a group", "Reset inputs") puts back
  `:data`, so the input shows its initial content again;
* with data access off the page loads nothing, so the input starts empty
  (not `:data`): the input, texts, conditions and workflows all read the
  same empty value.

An initial content that does not load (it does not compile, or reads a
source that is not loaded) leaves the input as before: not tracked, its
binding shown, what reads it not loaded; its source is left out of
`__bubble__(:data)`. A static initial content with conditional states
that set the content is not lowered yet (the static value is the first
value, as before), and neither is an input in a repeating group's cell, a
Dropdown's or a Checkbox's.

## Reusable instances in repeating group cells (WTF-494)

A reusable-element instance in a repeating group's cell is rendered once
per cell, in a scope of its own: the cell's thing's
(`<Web>.Bubble.cell_scope/5`: `<scope>-<repeating group>~2<the thing's
unique ID>`, then `-<instance>`; a list of options by the option's value
and its occurrence, `~4<value>[~5<n>]`, WTF-520; a list of texts or
numbers, which has no unique ID, by the cell's position). A re-sorted list keeps what each
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
* a search that reads the instance is read for every cell together
  (*Searches in cells*, below); one that cannot be would run once per
  cell: a reusable element with one (or nesting one, outside its own
  cells) is not rendered per cell. Its instances in cells keep one fixed scope and are
  marked, with their sources (`:page_data_in_cell`, `kind` `"query"`):
  `TODO(bubble:<id>) rendered once for every cell, not per cell`. When
  another instance gives the reusable element its thing, such an
  instance's own source is not loaded while the reads are: it is not
  rendered at all (WTF-522, above).

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
gives both cells one scope (they share their states). A list of options
keys each cell by its option and its occurrence (the second of two equal
options has a scope of its own).

An instance inside a runtime container of a cell (not the cell's own
template) keeps one scope and is marked.

**Privacy.** Every read goes through Ash with the current user as the
actor, as anywhere else, the current user's own relationships included
(`enforced_behavior.exs`: a member reads their team's name, not its
secret, in a cell too). The cells are the list's items as the user read
them: a thing the user may not read has no cell, so no instance and no
scope.

**Events.** A page lists the cell scopes it read (`@bubble_cells`; and
for its own elements in cells, `@bubble_page_cells`, WTF-520) and
accepts a click or an input change only in a scope it renders: the
page's own, an instance's (`__bubble__(:instances)`) or a cell's it
read; any other is ignored, so a browser cannot reach a cell of a thing
the user was not shown, or make up a scope. The scope is never parsed.

Sources are loaded in the order they read each other, across instance
boundaries (WTF-520, above); a source that
reads one that is not loaded is not loaded either (`:unavailable_input`,
`inputs: ["data_source"]`), and sources reading each other in a cycle
are `:unresolved_reference`.

## Searches in cells (WTF-520)

A search a repeating group's cells read with the cell's thing ("Search
for orders where customer = Current cell's customer", its `:count`, its
first item, `:items until #n`, a cell's own list `:filtered`), whether in
a group of the cell, a reusable instance's property or source there, or
inside a reusable element rendered per cell (reading its own thing), is
read for every cell together: **one query per round of cells, never one
per cell.**

**Which searches.** `BubbleEx.Target.Elixir.FrontendWorkflows.Data`
binds the search as anywhere else, then batches it (`cell_batch/2`) when
its constraints are a conjunction whose parts that differ from cell to
cell are:

* a **key**: the searched record's own attribute equal to a thing's
  unique ID read from the cell (`customer = Current cell's customer`, a
  group's thing in the cell, the instance's thing or property), or its
  unique ID in a list the cell holds (the records of `Current cell's
  customer's orders :filtered`, WTF-495);
* such a key under a constraint dropped when its value is empty
  (`ignore_empty_constraints`): it holds only in the cells whose value is
  not empty;
* anything else reading only yes/no values (whether a value is empty):
  the cells are grouped by them, one query per group.

Constraints that read nothing of the cell (the current user, a page
input, a constant) are the same in every cell. A search reading another
batched search's records (a cell's list `:filtered`, then `:sorted`) is
batched too, read in the round after it. Anything else that differs
from cell to cell (an ordering or a text comparison with the cell's
value, a key under `or` or `not`, a field of a related record, more
than three keys, Bubble's random sort) stays residue (`:page_data_in_cell`, `kind` `"query"`), as
before.

**How it is read.** The source's entry in `__bubble__(:data)` says
`cell_reads: true`; each batched search is printed as
`BubbleData.cell_read/4`, with the cell's own query and the query of
every cell at once (each key `attribute in ^values`; with two or three
keys, also the cells' own combinations of their values, so no record of
one cell's first key and another's second is read). The loader runs the
source in every cell first, collecting each cell's search (reading
nothing for it), reads the batches into the read pass, collects again
while a search reading those records appears (at most `:max_cell_rounds`
rounds, default 4; past it, what the next round collects is still read
together once, and what a later one would collect reads its own queries,
logged), then runs the source again: each cell finds its records there (`once/3`), and reads its
own query only if nothing collected it. Each cell gets the records whose
attributes equal its keys, in the search's order:

| what the cell takes | the batched read |
|---|---|
| `:count` | the keys of the matching records (`select`), counted per cell; past `:max_batched` (default 10,000) records in all, each cell's count is read on its own (logged) |
| `:first item` | the first record per key, in the search's order (`DISTINCT ON` the keys) |
| a list (its page size), `:items until #n`, `item #n` | the records sorted by the search, at most the sum of the cells' needs plus one: every record read is some cell's, so a read reaching that limit settles at least one cell; a cell with fewer than it needs may have lost records to the others, and the cells left are read again together with the limit doubled, at most `:max_cell_rounds` rounds; past them, or when a round settles none, they read their own queries (logged) |
| the records a cell's list holds | all of every cell's at once (no more than their IDs, not sorted by their position in the union), each cell's in its own list's order among equal sort keys |

A per-cell limit is never a global `LIMIT`. The doubled limit never passes
`:max_batched` (plus one), and a search whose cells have more key
combinations than `:max_batched` in all is read in chunks of cells of at
most `:max_batched` combinations, one query each (logged): about
combinations / `:max_batched` queries, never one per cell (a single cell
with more combinations than that reads its own query).
The arrays of values are bound as query parameters, so the SQL text is
the same whatever the cells. A window function
(`row_number() OVER (PARTITION BY ...)`) would read each cell's page in
one query, but Ash's filters cannot express it, and raw SQL around the
read would rank records the policies hide: a heavy cell costs rounds
instead. A batched read that fails leaves every cell of it empty
(logged), as each cell's own read would. Every search collected is
settled in the read pass (read together, or alone), so a later round
never collects it again. Ties in a sort (records with
equal sort keys) come in the database's order, as for a single search. A
cell whose key value is empty reads its own query (cells alike share it).

**Privacy.** The batched query is the same search, with the same
constraints and sort, read once as the current user through Ash: the
same action (`:search`, or `:read` for a list's records), the same
policies and, with enforced privacy, the same `<App>.Privacy.SearchFields`
check (it sees the keys' fields in the filter). A field hidden from
searches (`:search_field_restricted`, WTF-457) or hidden along a path
(`:search_field_hidden`) stays refused, as for any search. With data
access off nothing is read.

**Not yet:** a key on a value other than a unique ID (a text or a number
read from the cell). A repeating group inside a cell is read per outer
cell (below), its list batched like any other search in a cell.

## Repeating groups in a repeating group's cell (WTF-520)

A repeating group in another's cell (customers, each with a list of its
orders) is rendered once per outer cell, **two levels deep**: the outer
repeating group outside any cell of its page or reusable element, the
inner one in its cell's template (in a group there, not inside another
runtime container such as a table or a plugin's). Which repeating groups
qualify is decided from the page's structure
(`FrontendWorkflows`' `nested_lists`, inner => outer); any other
repeating group in a cell (a third level, one in a table's row) is
residue as before (`:page_data_in_cell`, `kind` `"list"`), and so is
what its cells read.

**Its list** is a value per outer cell, as a group's there: "Search for
orders where customer = Parent group's customer" is a search keyed on
the outer cell (batched, *Searches in cells* above: one query per round
of outer cells, each outer cell's page of records), "Parent group's
customer's orders" a value read from the outer cell's thing (the
records it holds read by ID for every outer cell at once), and a search
that reads nothing of the cell is read once. It is kept per outer cell
(`{scope, inner, outer index}`), so the outer cell reads it too
(`<inner>'s list of orders :count`, `{:cell_data, inner}`). It needs the
outer list loaded, whatever it reads. A repeating group's own
properties (its data source, its conditions) are evaluated in its
parent's context, as any element's: "Current cell's" there is the outer
cell (`BubbleEx.Expression.Typing`; before, it named the repeating group
itself and its source stayed unloaded), and "Parent group's" the group
holding it.

Which repeating groups are nested is one rule, the page's structure
(`data_index.nested_lists`, `Spec.nested_list?/2`), read alike by the
loader, the bindings (`Spec.data_read/4`) and the page's markup: a
repeating group in a table of the cell, or in another runtime container
there, is a marked runtime container, never an empty loop.

**Its cells** have a scope of their own, the outer cell's
(`<Web>.Bubble.cell_scope/5` of the outer list and its thing): a group in
an inner cell is kept under `{outer cell's scope, group, inner index}`,
a reusable instance in it under `<outer cell's scope>-<inner>~2<thing>-<instance>`
(by the things' unique IDs, so a re-sorted list keeps what each cell
held). In an inner cell:

* `Current cell's X` is the inner cell's thing (`{:cell, inner}`), its
  index the inner index;
* a group of the inner cell (`Parent group's X` there) is that inner
  cell's (`{:cell_data, group}`);
* the outer cell's thing and index, and a group (or another inner list)
  of the outer cell, are the outer cell's (`{:outer_cell, outer}`,
  `{:outer_cell_index, outer}`, `{:outer_cell_data, group}`);
* the page's own data, custom states and inputs are the page's, as
  anywhere in a cell.

Elements, texts and visibility conditions read these where the inner
cell renders (`Bubble.cells/4` loops over the inner list of the outer
cell's index); a reusable instance there is rendered per inner cell
(WTF-494), its workflows run in its scope, and the page's own clicks and
input changes in an inner cell run in that inner cell (WTF-520,
`docs/frontend-workflows.md`), with the outer cell's thing and groups.

**Read for every inner cell of every outer cell together.** The loader
runs each source of the inner cells once for all of them
(`<Web>.BubbleData`, a source's `outer` in `__bubble__(:data)`): what a
value reads through the inner cell's thing (`cell_loads`), the outer
cell's (`outer_loads`) or a group of either (`preloads`) is loaded for
all of them first, and a search reading the inner cell is batched across
every inner cell of every outer cell: **one query per round, never one
per outer cell nor per inner cell.** A page of customers and their orders
with each order's item count reads the customers once, the orders once
and the items once, whatever the number of customers and orders
(`nested_lists_behavior.exs` counts the queries, in both privacy modes).
The instances in inner cells are listed as `{{outer, inner}, [...]}` in
`__bubble__(:cells)` and read in the same rounds as those in outer cells.

**Bounds.** An inner list shows its own page (its rows times its
columns, at most `:max_items`) in each outer cell, and the outer list at
most `:max_items` cells, so a scope (the page, or each reusable instance
rendering such lists) holds at most `:max_items` x `:max_items` inner
cells: the cap is per scope, not per page. The batched searches keep
their `:max_batched` (in chunks past it) and `:max_cell_rounds` caps, and
the instances in inner cells count towards `:max_cells`.

**Failures.** A batched read that fails at run time leaves every cell it
covers empty (logged), as in *Searches in cells*: an inner list or an
inner cell's value shows nothing, never another cell's records.

**Privacy and events.** Every read goes through Ash as the current user,
as anywhere else: an outer cell is a thing the user read, an inner cell
one of its inner list the user read, so a thing the user may not read
has no cell and no scope. The page lists the scopes it read
(`@bubble_cells`, `put_cells/2`) and accepts an event only in one of
them (`BubbleWorkflows.surface/3`): a scope naming an order under
another customer's cell, a made-up order, or an order the user may not
read is ignored. The scope is never parsed. A reusable instance in an
inner cell whose own source does not load while its reusable element
reads its thing is not rendered there, per instance (WTF-522). With
data access off, nothing is read and no inner cell exists.

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
  input values, custom states and the URL's parameters and path
  segments, pinned into filters as values, and things' unique IDs from
  the URL (the page's thing, a thing parameter), which must look like a
  Bubble ID and are read through Ash like any other record, as the
  current user. No event or URL names a resource, a field, a record, a
  query or a data function; nothing from the browser becomes an atom
  (the behavior test checks the atom table).
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
  start, as before;
* a reusable instance whose own source is not loaded, while its reusable
  element's reads of its own thing are, is not rendered: a placeholder
  with its markers, and no scope (WTF-522, above).

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

### Private fixture app (test version), 2026-10-10, clicks and input changes in cells of option lists (WTF-520)

Cells of a list of options are keyed by their option and its occurrence
(`docs/frontend-workflows.md`), no longer by position, so their clicks
and input changes are wired per cell. Of the 41 workflows left unwired
in lists keyed by position, the 39 in lists of options are wired now: 29
run whole (native), 10 are refused by the runtime with the notice, for
their own residue. The 2 in lists of texts stay residue.

| | before | after |
|-|------:|------:|
| workflows native / wired | 850 / 577 | 879 / 606 |
| native steps | 2,487 | 2,523 |
| `:trigger_in_runtime_template` (residue entries, workflows) | 111 | 72 |
| `:unavailable_input` (residue entries, workflows) | 395 | 350 |

No data source moved (the page data counts are unchanged).

### Private fixture app (test version), 2026-10-09, clicks and input changes in cells (WTF-520)

The page's own clicks and input changes in repeating group cells
(`docs/frontend-workflows.md`). Of the 194 workflows whose trigger was in
a runtime template, 83 are now wired per cell; 35 of them run whole, the
others are refused by the runtime with the notice, for their own residue
(mostly uncompiled expressions and plugin actions). The 111 left: 65 in
a list the page does not load (34 lists whose own source does not
compile or reads what the page does not load), 41 in lists of options
(39) or texts (2), whose cells are keyed by position, 3 in a table's
row, 2 in a nested list that does not load.

| | before | after |
|-|------:|------:|
| workflows native / wired | 814 / 541 | 850 / 577 |
| native steps | 2,419 | 2,487 |
| `:trigger_in_runtime_template` (residue entries, workflows) | 194 | 111 |
| `:unavailable_input` (residue entries, workflows) | 479 | 395 |
| data sources wired / total | 2,752 / 3,356 | 2,774 / 3,361 |
| read as what steps showed | 133 | 136 |
| `:unavailable_input` (sources) | 434 | 417 |

Sources: 3 groups set only by those clicks (each by one that runs whole)
are now page data (empty until the click), and 2 inputs whose initial
content reads one of them are tracked; 17 sources that read them load
(13 groups outside cells, 3 in cells, 1 list). No other workflow or
source moved.

### Private fixture app (test version), 2026-10-09, nested repeating groups (WTF-520)

Of the 16 repeating groups in another's cell (all `:page_data_in_cell`,
`kind` `"list"`, before), by their list's source:

| inner list's source | roots | load now |
|---|--:|--:|
| a value read from the outer cell (a field of its group's list, another inner list of the cell, a list filtered by the cell's group, an option set's values) | 9 | 3 |
| a search keyed on the outer cell | 4 | 2 |
| something else (a search reading nothing of the cell, conditional sources over searches) | 3 | 2 |

One source moved the other way, from `:unavailable_input` to
`:page_data_in_cell` (`kind` `"query"`): a group of an outer cell whose
search reads the cell's inner list (`<inner>'s list of things`), which
did not load before. The inner list now loads, so the search is bound,
and it cannot be batched (its key is not one of the shapes above): it
shows the next thing blocking it. It is the only such move, compared
source by source; the 2 `:page_data_in_cell` (`kind` `"list"`) entries
among the inner cells' sources are third-level lists, residue before and
after. Resolving "Current cell's" in a repeating group's own properties
from its parent moved no count here.

The 9 left: 2 are a third level (their outer list is itself in a cell),
3 have an outer list that does not load, 2 read another list of the cell
that does not load, and 2 now show the Elixir value they do not compile
(a path through a list, a field of an intersection). The sources in the
inner lists' cells (46) were all a cascade of their list: 14 now load
(6 groups, 3 reusable instances, 5 of their properties), and 2 groups of
outer cells reading an inner list load with it.

| | before | after |
|-|------:|------:|
| data sources, wired | 2,729 | 2,752 |
| groups / instances / lists / properties wired | 1,351 / 170 / 166 / 1,010 | 1,359 / 173 / 173 / 1,015 |
| read as a query / a value | 170 / 2,346 | 174 / 2,365 |
| `:page_data_in_cell` residue entries (sources) | 20 | 8 |
| `:unavailable_input` residue entries (sources) | 447 | 434 |
| `:uncompiled_expression` residue entries (sources) | 167 | 169 |
| workflows, native / wired | 814 / 541 | 814 / 541 |

### Private fixture app (test version), 2026-10-09, searches in cells (WTF-520)

Of 67 sources that were `:page_data_in_cell` residue because a search
read the cell (or a reusable element's scope rendered per cell), 51 now
load, 13 now show what else they read that is not loaded (an input or a
group's thing set at run time, a list not loaded, a field of a merged
list), and 3 stay: a comparison other than equality with the cell, or a
search the batch cannot key. Six reusable instances in cells that were
rendered once for every cell are now rendered per cell; 6 sources reading
those load with them. One of those reusable elements has a property one
of whose values (in a cell) does not load: `This Reusable's <property>`
loads only when every value does (WTF-493), so 2 sources and 5 workflows
reading it no longer load (fail closed).

| | before | after |
|-|------:|------:|
| data sources, wired | 2,674 | 2,729 |
| groups wired | 1,323 | 1,351 |
| instance sources wired | 165 | 170 |
| lists wired | 165 | 166 |
| property values wired | 989 | 1,010 |
| read as a query / a switch / a value | 155 / 71 / 2,313 | 170 / 78 / 2,346 |
| `:page_data_in_cell` residue entries (sources) | 84 | 20 |
| `:unavailable_input` residue entries (sources) | 439 | 447 |
| `:uncompiled_expression` residue entries (sources) | 166 | 167 |
| workflows, native / wired | 812 / 540 | 814 / 541 |
| steps, native | 2,420 | 2,419 |

The repeating group's own `cell_thing` readers (49 sources) are all a
cascade of their list not loading: 14 lists are repeating groups in a
cell (`:page_data_in_cell`, `kind` `"list"`), the others' sources do not
compile (a plugin element's state, a regular expression, a dynamic sort
field, an unknown source).

### Private fixture app (test version), 2026-10-09, instances whose own source does not load (WTF-522)

37 instances of 13 reusable elements are no longer rendered (23 of them
in a repeating group's cell, 14 outside): each one's own source did not
load while another instance gave its reusable element a thing. Their
reasons: `:unavailable_input` 34, `:uncompiled_expression` 2,
`:unsupported_option` 2, `:page_data_in_cell` 1 (one instance may have
several). Every one of the 13 reusable elements has data sources reading
its own thing, so none was marked for nothing.

The page data counts do not move: those instances' sources were residue
already, and so were the sources reading them. What moves is what ran in
them:

| | before | after |
|-|------:|------:|
| steps calling a reusable instance's custom event, native | 127 | 123 |
| `:target_not_rendered` residue entries (steps) | 2 | 6 |
| `:unavailable_input` residue entries (workflows) | 475 | 476 |
| workflows, native (generated code) | 814 | 812 |
| workflows, wired | 542 | 540 |
| frontend report: elements printed natively / as placeholders | 5,841 / 1,297 | 5,827 / 1,311 |
| frontend report: markers | 2,910 | 2,946 |

Four page steps called a custom event in one of those instances (it
would have run on an empty thing) and are residue now, which leaves two
click workflows not native; one more step read a value kept in one.
The 14 instances outside cells are placeholders in the page now, the 23
in cells placeholders in their cell's template.

### Private fixture app (test version), 2026-10-09, popup events and instances nothing fills (WTF-520)

Groups set only at run time (`element_state:get_group_data` read by a
source, the top cause left: 51 sources reading 31 groups, about 116
sources unblocked if every one loaded). Grouped by what sets the group
(sources reading it directly, then those unblocked with what reads them,
each group alone):

| what sets the group | groups | direct | with readers |
|-|------:|------:|------:|
| custom events a JavaScript-to-Bubble plugin event calls | 15 | 20 | 55 |
| those, and a click in a repeating group's cell (or the icon plugin's) | 2 | 8 | 25 |
| a click in a repeating group's cell (not wired yet) | 3 | 4 | 14 |
| an icon plugin's "clicked" event | 1 | 5 | 6 |
| nothing, in a repeating group's cell | 2 | 5 | 5 |
| its own source, which does not lower (an accessor) | 4 | 4 | 4 |
| a reusable element whose instances nothing fills | 3 | 2 | 2 |
| a condition-true workflow the runtime refuses | 1 | 1 | 2 |
| a popup opened or closed | 0 | 0 | 0 |

The rows overlap (one source may read several groups). Only the
reusable elements whose every instance nothing fills load here (this
section's rule above); a popup's events set none of these groups in this
app, but 5 of its 6 popup event workflows are now wired (the sixth is a
reusable element that is itself a popup). Custom events called from a
JavaScript-to-Bubble plugin event stay unloaded (it may fire whenever
JavaScript calls it, as the page loads included); a refused
condition-true workflow may set its group as the page loads, so that
one stays too.

| | before | after |
|-|------:|------:|
| data sources, total | 3,342 | 3,356 |
| data sources, wired | 2,658 | 2,674 |
| groups wired | 1,321 | 1,323 |
| instance sources (total / wired) | 200 / 151 | 214 / 165 |
| elements read as what steps showed (`read: :displayed`) | 119 | 133 |
| `:unavailable_input` residue entries (sources) | 441 | 439 |
| sources reading a group set only at run time | 51 | 49 |
| workflows, native (generated code) | 809 | 814 |
| workflows, wired | 538 | 542 |
| `:unsupported_event` residue entries (workflows) | 16 | 11 |

The total grows by the 14 instances now read as empty (all wired); the
two groups are read through the reusable elements they feed.

### Private fixture app (test version), 2026-10-08, conditional sources over own ones (WTF-521)

The 101 elements with a data source of their own (or instances with
none) whose conditions set another, residue until now (*Conditional data
sources*, above), fold their states over their own source. Before, they
and what reads them kept 173 sources from loading.

| | before | after |
|-|------:|------:|
| data sources, total | 3,342 | 3,342 |
| data sources, wired | 2,534 | 2,634 |
| groups wired | 1,267 | 1,305 |
| lists wired | 130 | 160 |
| instance sources wired | 140 | 151 |
| property values wired | 965 | 986 |
| read as a switch (`read: {:switch, ...}`) | 0 | 68 |
| `:unsupported_option` residue entries (sources) | 101 | 26 |
| `:uncompiled_expression` residue entries (sources) | 135 | 171 |
| `:page_data_in_cell` residue entries (sources) | 59 | 83 |
| `:unavailable_input` residue entries (sources) | 520 | 461 |
| `:unresolved_reference` residue entries (sources) | 0 | 2 |
| data sources, native (IR) | 3,034 | 3,109 |
| workflows, wired | 532 | 536 |
| steps, native | 2,411 | 2,422 |

How the wired sources move (+100): of the 101, 53 bind and 68 sources
reading them load with them (+121). Of those, 5 conditional sources are
in reusable elements rendered in repeating group cells and search with
the instance: they are `:page_data_in_cell` residue, and 10 sources
reading them do not load either (-15); their instances are still
rendered per cell. 6 values over a search read first, in such reusable
elements and searching with the instance, were read once per cell; they
are now `:page_data_in_cell` residue too (-6). Of the 101, 26 stay
residue because a state's condition or source does not lower to IR (no
state has a source of another kind of value), and 22 because the target
cannot bind a part (a search the Ash compiler rejects, a value it cannot
compile, a source it reads that does not load, a list in a cell). The 2
`:unresolved_reference` entries are a conditional source and a property
default reading each other in a cycle; no condition reads its own
element here. The 68 switches also include the elements with no source
of their own that were folded before (read as a value then).

### Private fixture app (test version), 2026-10-08, elements no data source fills (WTF-520)

Groups, popups and repeating groups with no data source of their own
(*Display data* and *Conditional data sources*, above). Before, 79
sources were not loaded because they read such an element. Grouped by
what fills the element (sources reading it directly, then with what
reads them):

| what fills the element | direct | with readers |
|-|------:|------:|
| a custom event a plugin's event calls | 18 | 61 |
| nothing (no step, no source) | 28 | 42 |
| its conditional states | 11 | 32 |
| only events, whose workflows the runtime refuses | 7 | 29 |
| a condition-true workflow that is not lowered | 1 | 9 |
| a page-load step | 0 | 0 |

The first and the last but one stay unloaded (they may be set as the
page loads); the others load. Separately, 101 elements with a data
source of their own whose conditions set another one are now residue
(WTF-521): they were loaded from their own source alone, which could
show the wrong data.

| | before | after |
|-|------:|------:|
| data sources, total | 3,211 | 3,342 |
| data sources, wired | 2,566 | 2,534 |
| groups wired | 1,220 | 1,267 |
| lists wired | 170 | 130 |
| instance sources wired | 154 | 140 |
| property values wired | 993 | 965 |
| inputs wired | 27 | 30 |
| elements read as what steps showed (`read: :displayed`) | 23 | 119 |
| `:unavailable_input` residue entries (sources) | 440 | 520 |
| `:unsupported_option` residue entries (sources) | 0 | 101 |
| workflows, native (generated code) | 818 | 800 |
| workflows, wired | 547 | 532 |
| steps, native | 2,429 | 2,411 |

How the wired sources move, step by step: the elements no step fills,
those only triggered events fill and the conditional sources of
elements with no source of their own load (2,566 to 2,737, the total
growing by the elements now read as empty and the conditional sources);
elements a plugin's event, a popup opened or closed, or an event the
page does not trigger (a click in a repeating group's cell) may set are
no longer loaded, nor what reads them, among them 13 that were before
(to 2,707); the 101 elements whose conditions replace their own source,
and what reads them, are no longer loaded (to 2,534). The total grows by
131: the elements now read as empty until a step sets them, the 32
conditional sources (5 do not compile), an instance whose conditions
set its source (residue) and 3 inputs whose initial content now loads.
The workflows reading what is no longer loaded are no longer native.

### Private fixture app (test version), 2026-10-08, across instance boundaries (WTF-520)

Data sources reading an instance's property default from outside the
instance (*Across instance boundaries*, above). 43 sources read one
directly; the rest load because what they read now does (lists filtered
by such a source, the instances in their cells and the properties those
set, groups reading those). No cycle through an instance's boundary was
found.

| | before | after |
|-|------:|------:|
| data sources, total | 3,210 | 3,211 |
| data sources, wired | 2,365 | 2,566 |
| groups wired | 1,122 | 1,220 |
| lists wired | 143 | 170 |
| instance sources wired | 131 | 154 |
| property values wired | 941 | 993 |
| `:unavailable_input` residue entries (sources) | 643 | 440 |
| `:page_data_in_cell` residue entries (sources) | 70 | 71 |
| workflows, native (generated code) | 794 | 818 |
| workflows, wired | 529 | 547 |
| steps, native | 2,380 | 2,429 |

The total grows by one input whose initial content now loads (it is
tracked, WTF-520 above). One more instance in a cell is marked
`:page_data_in_cell`: its list now loads, and its reusable element
searches with its instance. Workflows read instance defaults too, and
the sources that now load.

### Private fixture app (test version), 2026-10-08 (WTF-520)

Inputs whose initial content is page data, and cleared dynamic sort
fields. Of 49 inputs whose initial content is an expression, 48 lower
and 26 are tracked (the others are placeholders, in a runtime template,
or read a source that is not loaded). Two searches whose dynamic sort
field was an empty text now compile.

| | before | after |
|-|------:|------:|
| data sources, total | 3,184 | 3,210 |
| data sources, wired | 2,321 | 2,365 |
| lists wired | 139 | 143 |
| instance sources wired | 127 | 131 |
| property values wired | 931 | 941 |
| `:unavailable_input` residue entries (sources) | 658 | 643 |
| workflows, native (generated code) | 790 | 794 |
| workflows, wired | 525 | 529 |
| "An input's value is changed" workflows, native | 2 | 6 |
| steps, native | 2,371 | 2,380 |

The total grows by the 26 inputs' sources; 18 more sources load besides
them (lists filtered by such an input, the instances in their cells and
the properties those set).

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

## Empty texts and case-insensitive texts (WTF-514, WTF-515)

**An empty text is empty.** Bubble has no empty text apart from an empty
value, so pages and workflows compare `""` as empty: `is` and `is not`
(conditions, visibility conditionals, `Only when`, anything compiled by
`BubbleEx.Target.Elixir`) read each side that may be text or empty
through the runtime's `unhidden/1`, which maps `""` (and a field the user
may not view) to nil. A path segment that is not there (nil, a bare
`/home`) therefore equals a value set to an empty text, and `?q=` equals
a missing `q`. `is empty` already counted `""` as empty;
`Bubble.Runtime.id/1` gives no ID for `""` in expressions on pages
(workflow writes are unchanged: `Workflows.Runtime.id/1` passes `""`
through). Numbers, yes/no values and dates are unchanged (`0`
is not empty), as is the current user's guard: a comparison with an
empty value read from the current user is false in either polarity.
This is inferred from Bubble's data model, not replayed.

**The generated privacy policies keep the stricter rule** (owner
decision, 2026-09-29): there `""` and NULL stay apart
(`is_not_distinct_from`), and an empty actor-side value matches nothing,
an empty field included (`BubbleEx.Target.Ash.ExpressionsTest` pins
this).

**A case-insensitive text is its text.** The generated User's email is
an `Ash.CiString`. The runtime reads it as its text wherever a value is
used as text: shown (`text/1`, `display/1`, an input's initial value),
compared (`unhidden/1`, `contains` on a list of texts, ordering and
`:sorted`), as a list item (`list_key/1`: `:unique elements`, `:merged
with`, `:minus item`, …), given to a text operator,
sent as a URL parameter or path segment, written by a backend workflow
or returned by it. Before, `text/1` showed its debug output
(`#Ash.CiString<...>`), and `is` never matched it.

## Unverified Bubble behavior and open questions

Answered by the replay of 2026-10-07 and removed from this list:
`:filtered` with an empty constraint value, the list operators,
server actions with an empty input (kept stricter than Bubble, above)
and "Display data" over a group's own source.

* **An empty text is empty** (WTF-514, above): that Bubble compares
  `""` as equal to an empty value in `is` / `is not` is inferred from
  its data model (it stores no empty texts), not replayed. A condition
  and the equivalent server search can disagree: in memory `is` treats
  `""` as empty, but a search with the same constraint still compiles to
  `== ""` (`BubbleEx.Target.Ash.Expressions`).
* **Matches nothing for operators other than `equals`.** The replay
  tried `equals`; that `>`, `contains`, `in` and the others match
  nothing on an empty value (or are dropped with `true`) is assumed.
* **Keyword searches** (`contains keyword(s)`, WTF-520): compiled with a
  conservative reading, every whitespace-separated word of the input a
  case-insensitive substring of the field (`ILIKE ALL` over bound
  patterns, `\`, `%` and `_` matching themselves), an input of spaces
  only matching nothing. The words are computed in Elixir
  (`BubbleEx.Target.Keywords`), never split per row, and capped: only
  the first 32 words of the first 256 characters count, so a long input
  costs the database no more than a short one (a later word is ignored,
  which can only widen the result). The in-memory match
  (`Bubble.Runtime.text_contains_words?/2`, for conditions and lists of
  texts) uses the same words, so a search and a condition agree. What
  Bubble does needs a replay: whole words or substrings, every word or
  any, stemming, a minimum word length, punctuation as a separator, an
  input of spaces only, whether a non-breaking space separates words
  (here it does), whether it caps the input, and case folding beyond
  ASCII (`ß`, a final sigma, a locale's rules: PostgreSQL's `ILIKE` and
  Elixir's `String.downcase/1` may differ there too).
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
* An input whose initial content is page data (WTF-520, above) follows it
  until the user changes the input, and a reset brings it back; that
  Bubble re-evaluates the initial content after the page loaded (when the
  data it reads changes) is assumed, not replayed. A user's change always
  wins over it.
* An instance's property read from outside the instance by a data
  source or a workflow (WTF-520, above) is its default where the
  instance sets none, computed before what reads it. That Bubble's page
  searches see the default (not an empty value) when the page loads is
  assumed from what its texts show, not replayed; so is the order of a
  default and a search over it when the default changes later. The
  conservative reading is kept: a default that cannot be computed first
  (a cycle, an instance not rendered once) is not read, never read as
  empty.
* A property an instance sets to a value that is empty at run time does
  not fall back to the default when read from outside the instance
  either (WTF-520): the value set wins, empty or not (as above).
* A group, popup or repeating group with no data source that no step
  sets shows nothing (WTF-520): inferred from Bubble's data model, not
  replayed.
* **Conditions over the base** (WTF-520, WTF-521): an element's
  conditional states that set a data source are folded in the order an
  input's content states are, over its own data source (or empty): the
  last state whose condition is yes wins, and its source replaces the
  base whole (a search is not merged with the base's constraints or
  sort). Assumed from how Bubble applies other conditional properties,
  not replayed for data sources.
* **A Display step over a conditional source** (WTF-520, WTF-521): what
  a "Display data" or "Display list" step shows is taken to win over a
  folded source until a reset, even when a condition later flips, as it
  does over a source of the element's own (replayed for that, not for a
  conditional one).
* Elements a plugin's event or "User is logged in / out" may set are
  taken to be set as the page loads (conservative, see
  `docs/frontend-workflows.md`).
* **Popup events** (WTF-520): a popup's "is opened" workflow is taken to
  run only after a step opens the closed popup (never as the page
  loads), and its "is closed" one after a step or Escape closes it; what
  they set is empty until then. Not replayed: whether showing an open
  popup fires it again (here it does not), whether a popup's conditions
  open it (here what its workflows set stays unloaded), and the order of
  the popup's workflow and the rest of the workflow that opened it (here
  the popup's runs after it). See `docs/frontend-workflows.md`.
* A search's dynamic sort field that is an empty text (the editor keeps
  `{"entries": {"1": ""}}` once it is cleared) is taken to name no field
  (WTF-520): next to a static sort field, that field sorts; with the sort
  field set to Dynamic (`_dynamic_sort_field`) and the field cleared, the
  search is not sorted. A dynamic sort field that is not empty is still
  not compiled, whatever the sort field.
