# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Fixed

- **A thing held by an element compared with a reference field** (found
  on the page WTF-505 started from). `is`, `is not` and `contains` compare
  things by ID, and a field path reads its reference's `_id` attribute.
  Any other thing (an element's thing, a reusable property, a custom
  state, a search's first item) was compared as the loaded record. A
  record never equals an ID, so `<property> is not <a thing's reference
  field>` was always true, and a panel shown by it always covered the
  view even though the property's default was read correctly. Those
  operands now go through the runtime's new `id/1` (a record's `id`; an
  ID stays itself; empty or a field the user may not view, nil). The same
  compiled comparisons guard workflows: an "Only when" on a workflow or a
  step, including write guards under option A, was accidentally always
  false (`is`, `contains`) or always true (`is not`) on such operands, and
  now matches Bubble. An existing app's owned `Bubble.Runtime` needs `id/1`
  added from the template. On the private fixture app (counts only), 75
  compiled comparisons go through it, 13 of them in visibility helpers.

- **A visibility condition reading a reusable property with no value is
  not decided as if it were empty** (WTF-505). A condition reading a
  reusable element's property that has no default and that the instance
  does not set read it as empty, so a panel shown whenever the property
  differs from something was always shown. Bubble's value there is not
  verified yet. A property with a default still reads the default
  (WTF-503). Read from where the instance is, or in a reusable element
  that no instance sets it in, the conditionals are now not lowered (a
  marker; the element keeps its page-load visibility). When only some
  instances set it, the helper decides for those and the others keep the
  page-load visibility (`Bubble.set?/3` tells them apart by scope). With
  privacy: :enforced, an element shown on page load that a conditional may
  hide stays hidden instead. The frontend report counts these conditionals
  as `visibility_conditions_unset_property`. On the private fixture app
  (counts only), 40 conditionals read such a property: 5 are now marked
  (conditionals not lowered went from 821 to 826), and 35 are decided
  only where the property is set. None is hidden by the privacy rule. The
  panel that started this reads a property with a default, so this
  change doesn't affect it; the comparison fix above does.

- **Signed-in panels hidden by what the page already had** (WTF-476
  follow-up). Measured on the private fixture app's five signed-in pages
  (their reusables included), counts only: of the elements that render
  hidden or empty, the two largest tractable root causes were:
  - **A reusable instance's property read from outside the instance,
    when the instance keeps its default.** A page's text or visibility
    condition reading `<instance>'s <property>` was page data only when
    the instance set the property; the default, which the page already
    computes in the instance's scope under the same key, was not read,
    so the condition stayed a marker and the panel stayed hidden. Pages
    now read it (`FrontendWorkflows.Spec.instance_property/4`), only when
    every value of the property loads and the instance is outside a
    repeating group's cell; data sources and workflows still read only a
    value the instance sets (they run before the default is computed).
  - **URL parameters in visibility conditions and shown values.** A
    condition reading `Get <name> from page URL` (text) did not compile
    for pages, and a text showing one read an assign nothing set (always
    empty), though the runtime keeps the URL's query. Both now read
    `@bubble_url`, passed down to reusable components (at any depth) as
    `bubble_url`. A URL parameter read as another type (yes/no, number,
    thing), as a list, or a path does not compile in either (a marker,
    shown empty), since the typing reads every URL parameter as text.

  Counted statically over the 10,163 elements of the four page modules
  behind the five routes, the elements that can show content went from
  3,405 to 4,378 (hidden 6,458 to 5,391); signed in on synthetic data,
  the visible elements went from 89 to 100 on one page and from 6 to 40
  on another, the rest unchanged. The largest remaining root cause is a
  URL's path segments read as a list (`path_segment`), whose Bubble
  semantics are not yet replayed; it stays untyped.

- **Generated pages no longer crash on a value's shape** (WTF-500). On
  the private fixture app, signed in, four pages crashed their LiveViews
  (26 crashes in one scan's server log) and 16 page data sources failed.
  Five root causes:
  - **Option-set list attributes** are stored by Bubble's editor as an
    object keyed by position (`%{"0" => "open", "1" => "done"}`), and the
    enum's `@attributes` kept it as supplied, so `length/1`, `Enum` and
    `label/1` raised on it. A list attribute is now a list in Bubble's
    order (`Target.Ash`; positions sort as numbers); an array is kept and
    a single value is a list of it. The enum's lookups are total:
    `attributes/1` of a value that is not one of the set's (empty, stale,
    any other shape) has every attribute empty, and `label/1` is nil, as
    an empty option in Bubble (it raised `KeyError` and
    `FunctionClauseError`).
  - **A field the user may not view** (`%Ash.ForbiddenField{}`) is truthy,
    so `x || []` kept it and `Enum` raised, and it passed where an empty
    value failed. A hidden field now reads exactly as empty: every list
    the compiled code reads (`count`, `:first item`, `contains`,
    `:filtered`, a list of options or files) goes through the runtime's
    `as_list/1`; the current user's operands are checked with `empty?/1`
    (it was `not in [nil, "", []]`); an ordering's negation requires both
    sides non-empty (`empty?/1`, it was `not is_nil/1`); `is` and `is not`
    between two values that may be empty compare through the new
    `unhidden/1` (a hidden field `is not` an empty value was true). The
    runtime treats it as empty with or without generated policies.
  - **A field of a list of things** (a search read first, then a field of
    each item, then `:sorted`) was `get_in/2` on the list (`BadMapError`).
    It is now each item's: one list of their values, empty ones dropped.
  - **`:formatted as JSON-safe`** returned a yes/no or a number unchanged,
    so a guard such as `Admin? :formatted as JSON-safe is not "true"` held
    for every admin (`true != "true"`) and sent them away. It is text, as
    the compiler types it: `"true"`/`"false"`, a number or date's machine
    text. API calls are not lowered yet; their request bodies must insert
    raw JSON, not this text (`TODO(bubble:api-body)`,
    `docs/frontend-workflows.md`).
  - **Two navigations of one event** (two page-load workflows, each with
    a "Go to page") raised "socket already prepared to redirect": each
    workflow applies to the page as it ends. The first page-leaving
    navigation (another page, a reload, a URL, "Log out") wins, from a
    later step or a later workflow; a same-page one (a URL parameter)
    never blocks and is replaced by any later navigation, so changing a
    parameter can never skip a "Log out". Bubble does not guarantee the
    order of workflows on one trigger; the outcome no longer depends on it.

  The slice seed (`scripts/vertical_slice/seed.exs`) also keeps each
  index one coherent world: a reference to another type points at the same
  index (user 1's membership is membership 1, whose member is user 1), and
  only one to its own type at the next record. It pointed every reference
  at the next record, so the signed-in user's own records belonged to
  another user. A new fixture, `phoenix_shapes`
  (`test/support/target/phoenix/shapes.json`, invented names and data),
  reproduces each crash and navigation case in a generated app, with
  privacy `:omit` and `:enforced` (`shapes_behavior.exs`). On the private
  fixture app (synthetic data, localhost), 29 pages signed in and signed
  out: 0 LiveView crashes and 0 page data failures; generator counts
  unchanged.

- **Owners without bubble_ex can upgrade their index snapshots**
  (WTF-499). A project downloaded as a ZIP has no bubble_ex dependency,
  so `mix bubble.concurrent_index_snapshots` was out of reach and the
  next `mix ash.codegen` dropped and rebuilt every index hint. Every
  generated project now ships the upgrader as a generated file,
  `priv/bubble/concurrent_index_snapshots.exs`: `mix run --no-start
  priv/bubble/concurrent_index_snapshots.exs [--dry-run]` from the
  project root. Its code is
  `BubbleEx.Target.Phoenix.IndexSnapshots.Upgrader`'s source byte for
  byte (Elixir and Jason only), the same code the task runs, so the two
  cannot drift; same rules, atomic writes, skips and exit status. The
  README's "Regenerating and migrations" names the command and what
  skipping it costs; the stale-snapshot warnings name it too.
  `scripts/phoenix_compile_check/index_snapshots.sh` runs the script in
  the rendered project (old snapshots, then no changes from `mix
  ash.codegen`), then the task, then a skipped snapshot failing the script.

- **"Go to page" to an unknown page no longer goes to the current page**
  (WTF-429). Lowering took any target with whitespace for "Current
  page", so a page ID with a space or newline (hostile, or not a Bubble
  ID at all) became a navigation to the page the user was on, even when
  a page had that ID. Only Bubble's exact `Current page` is the current
  page now; a page of the app is that page; anything else (an unknown or
  deleted page's ID, an empty one, a path, other text, unicode included)
  is `:unresolved_reference` residue with a `frontend_workflow_residue`
  diagnostic, so the workflow refuses to run. Private fixture counts are
  unchanged: no target there has a space but `Current page`.

### Changed

- **Bubble behaviours measured by the replay of 2026-10-07** (WTF-509;
  counts and synthetic values only, WTF-387). Each answered question
  leaves the docs' "Unverified Bubble behavior" lists.
  - **`extract day` is the weekday**, 0 = Sunday, and `extract date` the
    day of the month, both in the time zone used. The
    `date_part_unit:day` approximation warning is gone.
  - **Values leaving the page** (replaces #177's ISO 8601 machine text).
    `Runtime.text/1` writes a date as Bubble's display text
    (`Oct 7, 2026 12:00 am`, in `:bubble_time_zone`), as Bubble's "Go to
    page" URL parameters do; a number is `3`, a yes/no `yes`, and a
    thing URL parameter is empty (left out). API workflow responses
    ("Return data", `Workflows.Runtime.response/1`) write dates as unix
    milliseconds; a date converted to text on the server (backend
    workflow expressions, compiled with the new `:utc` option to
    `utc_text/1`; returned plain text) is that display text in UTC. Job
    arguments keep ISO 8601. `formatted as` `iso_date` is unchanged.
  - **List operators** (#198's guesses, corrected): `:intersect with`
    follows the second list's order; `:plus item` deduplicates the whole
    list and appends an empty value; `:sorted` on texts, numbers or dates
    now compiles (`Runtime.sort_values/2`, empty values first ascending,
    last descending; it was silently left unsorted); things sort with
    empty values last in both directions (`:asc_nils_last` /
    `:desc_nils_last`, searches included); a page's `:filtered` with
    `ignore_empty_constraints: false` matches nothing on an empty value,
    like unstated (it compared).
  - **Display data** (#195): checked, unchanged; new tests for an input
    change under a displayed group, an empty value and a parent reset
    restoring a nested group's own source.
  - **Known differences, kept on purpose:** "Go to page" with a list
    sends no path segment (Bubble sends `[object%20Object]`); a page
    workflow's server-side action matches nothing on an empty
    constraint value even with `ignore_empty_constraints: true` (Bubble
    drops the constraint, so a delete with an empty input touches every
    record).

- **List operators of page data load** (WTF-495, part of WTF-476).
  Repeating group lists (and groups, properties) using `:sorted by`,
  `:filtered`, `:merged with`, `:unique elements` and the other list
  operators were `:uncompiled_expression` residue, so 53 of 61 instances
  in cells waited on lists the page did not load. Now
  (`Target.Elixir.FrontendWorkflows.Lists`): a sorted search sorted
  again, and a search's further sort keys (`additional_sort_fields`), are
  one query sorted by several keys; a filtered search is the search with
  the filter's constraints; sorting or filtering any other list of
  things is a query for its records (`id in ^ids`, read as the user may
  view them, `BubbleData.listed/1`; filtered keeps the list's order);
  searches under other operators are queries read first (`query_<n>`),
  combined in Elixir by new runtime functions (`merge/2`, `unique/1`,
  `minus_list/2`, `intersect/2`, `plus_item/2`, `minus_item/2`,
  `limit/2`, `item_at/2`, `as_list/1`; an existing app's owned
  `Bubble.Runtime` needs them added from the template). Options, texts
  and numbers are filtered in Elixir; `All <option set>` (option value
  `all values`) is every option. Every read is an Ash query as the
  actor, bounded by `:max_items`; what a capped read would overstate
  (its count, its last item, or subtracting it) is residue
  (`elixir:capped_list`), and a count of merged searches of one type is
  one count query. A list's records read in the database are all its
  matches (at most `:max_listed`, default 10,000), in its order among
  equal sort keys, through the view action (counts too). A value over
  queries follows the changes of every resource they search
  (`query_topics`). A page's `:filtered` that does not
  state `ignore_empty_constraints` matches nothing on an empty value, as
  a page search does (not replayed; questions on WTF-387). The editor's
  `*_friendly` keys and unset dynamic sort fields no longer block a
  search. Structural coverage no longer counts a self-scheduling
  workflow blocked by a residue callee as uncovered. On the private
  fixture app (against main with instances in cells, WTF-494): data
  sources loaded 2,044 → 2,337 (lists 84 → 139 of 238, instances 113 →
  126), elements without data 1,917 → 1,496, instances in cells
  rendered per cell 6 → 17 of 61; frontend workflows native 750 → 805,
  wired 511 → 536; backend workflows native own body 142 → 155.

- **Reusable instances in repeating group cells are rendered per cell**
  (WTF-494, part of WTF-476). An instance in a cell rendered with one scope
  for every cell, so its thing, its properties, what "Display data"
  showed in it and its reusable element's sources were all unresolved
  and marked (`:page_data_in_cell`). Each cell's instance now has a scope
  of its own, keyed by the cell's thing's unique ID
  (`<Web>.Bubble.cell_scope/4`), not its position: its data source and
  the properties it sets are computed in the cell (an instance lists only
  the properties it sets, as elsewhere), its reusable element's sources,
  custom states, inputs, texts, visibility conditionals and workflows
  ("Display data" included) are that cell's. The loader reads each source
  for every cell together: relationships load once per resource, unique
  IDs are read at once, and a search that reads nothing of the instance
  runs once (`shared`, `preloads` in `__bubble__(:data)`); a reusable
  element with a search reading its instance would query once per cell,
  so its instances in cells stay one scope and are marked. The page
  lists the cell scopes it read as the current user (`__bubble__(:cells)`,
  `@bubble_cells`) and ignores an event in any other, so a browser cannot
  reach the cell of a thing the user was not shown. Page-load,
  condition-true and "do every" workflows do not run in a cell (marked).
  Values read the current user's relationships again as the user, never
  from the actor the policies load without authorization (a batch reuses
  only the very records it read, with the paths it read through each);
  a relationship load that fails (`Workflows.Runtime.load/3`,
  `load_page/5`) now fails closed and is logged: the relationships asked
  for read as empty instead of as the value carried them; a cell that
  leaves the list drops what the page kept for it and takes no event
  (scheduled and paused workflows included); `:max_cells` and
  `:max_cell_depth` (`<Web>.BubbleData`) bound the scopes, the first
  ones kept, logged once. `scripts/phoenix_compile_check.sh` reads
  Elixir 1.20's test summary (`Result: ...`) and `refute` failures, and
  CI's 1.20 job checks `phoenix_enforced`.
  Behavior tests in both privacy modes (`reusable_params_behavior.exs`:
  per-cell values, workflows, crafted scopes, an input change, as many
  queries for three cells as for one; `enforced_behavior.exs`: a hidden
  task has no cell and its scope runs nothing). On the private fixture
  app: 6 of its 61 instances in cells are rendered per cell (504
  elements with each cell's data; 53 wait on a list the page does not
  load yet, 2 on a per-instance search), `:page_data_in_cell` residue
  531 → 22, sources wired 2,026 → 2,044, visibility conditionals
  rendered 569 → 607, native workflows 737 → 750.
- **Reusable element properties are passed down** (WTF-493, part of
  WTF-476). `This Reusable's <property>` was `:unavailable_input`
  residue everywhere, so data sources, texts, visibility conditionals
  and workflows reading one were not loaded or rendered. Each value an
  instance sets is now a page data source (`BubbleEx.PageData` kind
  `:param`): a static value as the property's type, an expression
  computed where the instance is; a property it does not set takes its
  default, computed inside the reusable element, or is empty. Values are
  kept under the instance's scope in `@bubble_data`, so the reads resolve
  per instance, nested reusables included; things are read through Ash
  with the actor like any other source. A property is read only when
  every instance's value of it (outside a repeating group's cell) loads;
  an instance in a cell is marked for every property it declares
  (`:page_data_in_cell`). Keys name the reusable element and the property
  (`param_<id>/<reusable id>`: property IDs are unique only within a
  reusable element). A "Display data" step into an instance sets its own
  thing, never its properties. Bubble has no action that changes a
  property. On the private fixture app (against main with Display data):
  data sources loaded 1,016 → 1,217 (those blocked on a property 177 →
  42), elements under a source that is not loaded 2,373 → 1,918,
  visibility conditionals rendered 344 → 569, compiled bindings 455 →
  483, native page workflows 692 → 737.
- **Generated pages render visibility conditionals** (WTF-477). An
  element's conditional states that set `is_visible` were kept by the
  normalizer but never compiled, rendered or counted, so an element not
  visible on page load that a conditional shows (a "Sign in" group shown
  when logged out) never appeared. `Target.Elixir.Frontend.compile/5`
  now compiles them (the element's environment, the same inputs and page
  data path as its dynamic text) into one yes/no expression folding the
  states in Bubble's order (the last true state wins; none keeps the
  visibility on page load), and the page renders `hidden={!visible_<id>(...)}`.
  An element not visible on page load now has the `hidden` attribute
  instead of a `hidden` class (`[data-bubble-id][hidden]` hides it), so a
  workflow's show, hide or toggle step changes it too; a step on an
  element is now kept even when it changes nothing at that moment, so,
  as Bubble documents ("Actions take precedence over conditions which
  take precedence on the default setting"), it decides from then on
  until the page reloads. A visibility conditional that does not compile
  (no IR or Elixir, a non-literal visibility, an input no page supplies
  such as a URL parameter or the page width, an overlay's) or reads what
  this page does not keep keeps the visibility on page load with a
  `TODO(bubble:<id>)` marker; the first kind is new
  `:element_condition` plan residue (`Target.Elixir.Frontend.residue/2`).
  The frontend report counts `visibility_conditions_compiled`,
  `visibility_conditions_marked` and `conditions_other_properties`
  (states setting colors, text and other properties, not lowered yet).
  The relationships a condition reads load with the page's data (as a
  dynamic text's do), and a condition helper raises rather than decide
  on one that was not loaded. With workflows, conditions read the current
  user from `@bubble_viewer`: `<Web>.BubbleWorkflows.refresh_viewer/1`
  reads it afresh at mount, page load and every event (a changed role
  takes effect), as the user themself, so with `privacy: :enforced` a
  field they may not view reads as empty. Repeating group cells carry
  their item's DOM ID (`<Web>.Bubble.cell_id/4`), so a kept step follows
  its item. The compact payload's `"%s"` states are conditionals too,
  except the ones lowered as breakpoint rules.
  `scripts/visibility_browser_check.sh` drives the steps in Chrome
  (browserq; not in CI).

- **Index hints build concurrently** (WTF-418). `Target.Ash` declares
  every custom index `concurrently: true`, so `mix ash.codegen` writes the
  indexes it adds as a migration of their own (index additions only),
  `CREATE INDEX CONCURRENTLY` with `@disable_ddl_transaction true` and
  `@disable_migration_lock true`, after the transactional migration with
  the tables and columns. An index a re-publish adds to a loaded table no
  longer locks its writes while it builds. `scripts/ash_compile_check.sh`
  checks the generated migrations (`index_migrations.exs`) and runs them.
  **Existing projects:** their resource snapshots record the old index
  hints as not concurrent, and AshPostgres compares the flag, so a plain
  `mix ash.codegen` would drop every hint index and build it again. After
  regenerating, and before `mix ash.codegen`, run once from a bubble_ex
  checkout `mix bubble.concurrent_index_snapshots --root
  /path/to/project` (try `--dry-run` first): in each table's latest
  snapshot it records the generated resources' custom indexes as
  concurrent (only those whose table, name, fields and method match;
  never an identity, a unique index or an index of the owner's, nor
  older, `_dev` or tenant snapshots; running it again changes nothing),
  so codegen sees no change for them and the database keeps its indexes.
  It tolerates whitespace-only differences from AshPostgres' layout
  (keeping a trailing newline), writes each file atomically, warns about
  a symbolically linked snapshot directory and `_dev` snapshots, and
  exits non-zero when it must skip a snapshot (other key order, invalid
  JSON: fix it by hand) or when the resources were not regenerated yet. `check_manifest/3` lists the snapshots that
  still need it (`index_snapshots_stale`); the task CLI's
  `generated_unchanged` check warns about them, and `mix wtf.verify`'s
  failing `migrations_in_sync` says to run it. One index is dropped
  either way: `user_email_index`, when a project had the email hint
  below, goes once in the transactional migration (a plain, brief
  `DROP INDEX`). If a concurrent build fails, PostgreSQL leaves an
  `INVALID` index: `DROP INDEX CONCURRENTLY <name>;` and migrate again;
  the generated README says so.
- **A stale SAT solver build after switching to `privacy: :enforced`
  is explained** (WTF-460). Regenerating an `:omit` project with
  `:enforced` adds `picosat_elixir`; `mix deps.get` marks crux (its
  parent, which picks the solver at compile time) to rebuild in every
  `_build/<env>`, but Mix 1.19+ marks it by removing
  `.mix/compile.elixir_scm` while Mix 1.18 and older read
  `.mix/compile.fetch`. So with mixed Mix versions, in either direction
  (`deps.get` under 1.19+ and a build directory last built by 1.18, as
  in the WTF-378 slice's test env, or the reverse), crux is not
  rebuilt and Ash fails with `No SAT solver available, although one was
  loaded`. One Elixir version (1.18, 1.19 or 1.20) rebuilds it
  correctly. The task CLI's and `wtf.verify`'s mix checks now append the
  fix to their failure (`MIX_ENV=<env> mix deps.compile crux --force`),
  and the generated README says so in both privacy sections.
- **No duplicate index on the User's email** (WTF-418).
  `Target.Phoenix` gives the email a unique identity (citext); an
  `email equals` search hint's btree index over the email alone
  duplicated its unique index and is no longer created. Wider indexes
  starting with the email are kept, and `Target.Ash` alone (no identity)
  still creates it.

- **Bubble page images move out of `priv/static`** (WTF-455). Stored
  images (`asset_store:`, the exporter's `assets:`) are generated as
  `priv/bubble_images/<sha256>.<ext>` (was
  `priv/static/images/bubble/`), and `.wtf/assets.json` says so; their
  URLs stay `/images/bubble/<sha256>.<ext>`. New endpoints serve that
  route from `priv/bubble_images` with `nosniff` and the sandbox CSP.
  Under `priv/static`, the main `Plug.Static` (`only: ~w(... images
  ...)`, gzip in production) could also reach them through another
  spelling of the path (`/images/bubbl%65/...`, `/images/%62ubble/...`,
  case variants on case-insensitive filesystems) or a `.gz` without its
  raw file, and serve them without the policy; nothing outside the
  sandboxed plug can now. **Existing projects:** the endpoint is owned,
  so change its `/images/bubble` plug to `from: {:my_app,
  "priv/bubble_images"}`. Regenerating with the asset store (from `mix
  bubble.fetch_assets`) writes the images to the new place, and the
  manifest check lists the old `priv/static/images/bubble/*` files as
  `stale`: remove them. Until both are done, `check_manifest/3` reports
  `images_unserved`: the images, when the endpoint's uncommented source
  does not name `priv/bubble_images` (the manifest records them under a
  new `images` entry), and any file left under
  `priv/static/images/bubble/`. The scaffolded
  `test/<app>_web/bubble_images_test.exs` fails on both too, saying how
  to fix the endpoint.
- **The task CLI's `generated_unchanged` check reports what the owned
  files leave undone** (WTF-455): besides hand-edited and missing
  generated files, it now fails on `unrouted` pages,
  `extensions_unlisted` and `images_unserved` from `check_manifest/3`,
  which it used to pass silently.
- **Scaffold docs: `mix wtf.task` runs from bubble_ex** (WTF-455). The
  generated project does not depend on bubble_ex; its README now shows
  `mix wtf.task audit --root /path/to/this/project` from a bubble_ex
  checkout.

- **`x is not no` reads an empty yes/no as no, as Bubble does** (WTF-471).
  Between yes/no values (not conditions: fields, parameters, option
  attributes, ...; "stored" below), at least one stored, `is not` now
  treats an empty stored value as no, in the Ash policies and in page and
  workflow conditions alike (`Target.Elixir`), and never yields NULL: `x
  is not no` compiles to `is_not_distinct_from(x, true)` (was
  `is_distinct_from(x, false)`, which granted on an empty x), and `x is
  not y` between two stored values holds when exactly one is yes. These
  only narrow: each holds in a subset of the cases it held before. `x is
  no` and `x is y` are unchanged: they stay stricter than Bubble on an
  empty value by the owner's decision (`Verify.Difference`,
  `empty_yes_no_is_no`). A condition compared with another yes/no as a
  value (`(x is not no) is (x is no)`) is now expanded into each side's
  own polarities, as conditions reading the user already were, and a
  condition used as any other value is strictly yes or no (`if(c, true,
  false)`; never nil in Elixir), so an empty operand can no longer match
  through NULL = NULL. That removes such matches (the old form was wider
  than Bubble). In page and workflow conditions it can also match where
  the old form did not: a condition whose negation holds on an empty
  value compared with another yes/no, which is Bubble's reading.
  In the Ash policies only, such a comparison (neither side reading the
  user) also requires the record values a condition reads to be
  non-empty on its negative side, so the policies never grant where the
  previous ones denied (a negation holding on an empty value, `doesn't
  contain` on an empty list or an empty text, rests on uncalibrated
  semantics): a new intended difference,
  `compared_condition_guards_record_values` (`Verify.Difference`,
  `Assumptions`), listed per rule. Page and workflow conditions follow
  Bubble there; the shared expectation table holds their reading as
  `expected_elixir` where it differs. The interpreter reads the same way,
  so the matrix sees these cases agree or as intended differences; the
  `:ash_policy_empty_yes_no_wider_than_bubble` warning and
  `Difference.empty_yes_no_wider?/1` are removed.

- **Privacy interpreter: four calibration flags flipped to Bubble's
  reading** (WTF-467). The 2026-10-01 replay of WTF-385 refuted
  `everyone_guards_record_values` and `logged_out_user_is_empty` (a
  logged-out user is Bubble's temporary user), and leaned flipped on
  `everyone_exclusive` (Bubble's `everyone` rule reaches every user, on
  top of the other rules; only 2 ops tell it apart from dropping the
  guard, both for it) and, for the second run, `empty_yes_no_is_no` (an
  empty yes/no reads as no). Flipping them raises the
  run's agreement from 94.7% to 97.3% (1,354 of 1,392 ops); none breaks
  an agreeing op. `Assumptions.evidence/0` records the run per flag.
  **The generated policies do not change**: each flip would widen them,
  so they keep the stricter reading and `Verify.Difference` lists the
  four as intended differences (`policy/0`, per-case `flags` now naming
  only the flags responsible, or the minimal set that explains the case).
  `ResourcePrivacy.stricter_rules` and `:ash_policy_stricter_than_bubble`
  cover rules whose yes/no tests are stricter on an empty value (`is
  no`), and list `"everyone"` only where its grants (view, search,
  fields, attachments, Data API) are narrowed (some rule lacks what it
  grants), no longer for every type whose rules read the user; the new
  `ResourcePrivacy.stricter_flags` and the structural list name each
  entry's own flags. Because the Project changes, a regenerated app's
  `.wtf/generated.json` records a new `project_sha256` (no generated
  source changes). The matrix seeks the `everyone` rule's witnesses under
  the target's exclusive reach; under Bubble's, rules granting what the
  `everyone` rule grants anyway are masked. (`x is not no` on an empty
  yes/no, less strict than Bubble at first, is closed by WTF-471 below.)

- **"Go to page" sends data to a page with no type of content** (WTF-466).
  A replay showed that Bubble appends the data as a path segment and the
  page loads: text `x` goes to `/page/x` (URL parameters kept), a thing to
  `/page/<unique id>`, no data to `/page`. Such steps are now lowered
  (`Step.args.untyped?`) and run: the generated `navigate/7` takes
  `{:segment, value}` and appends a record's unique ID or the value (text,
  a number, a boolean, a date) as text, percent-encoded as one segment
  (never a `/`, `?`, `#`, backslash or `%` of its own; `.` and `..`, any
  other kind of value, a list included, and a segment over 2000 encoded
  bytes, logged, send nothing). Every page's route now takes that segment
  (`/<page>/:bubble_thing`, `/index/:bubble_thing` for the index page); a
  page that does not read its thing ignores it, and no other page is
  routed at `/index` (a page named so goes to `/index-page`). A
  reusable element sending data to a current page that takes no thing
  appends it the same way instead of failing. `:data_to_send_untyped_page`
  is no longer produced (still decoded).
- **Scan artifacts are compact JSON** (WTF-469). `PayloadFile.with_file/3`
  (and so `Trufflehog.scan/2`) writes maps without pretty-printing. For a
  3 MiB app the pretty iodata was ~290 MiB and OOM-killed a 1.5 GiB scan
  worker; it now peaks at ~141 MiB above baseline. TruffleHog finds the same
  keys or more (newlines no longer split a key from its context), but a
  finding's `SourceMetadata` line is now always 1, and `max_input_bytes`
  counts the smaller compact size.
- **Images on other hosts stay linked, as in Bubble** (WTF-465). An image
  a Bubble app hotlinks from a host other than Bubble's storage is never
  fetched, proxied or dropped: the page links its original URL (an
  `http://` one over HTTPS) with `loading="lazy"` and
  `referrerpolicy="no-referrer"`, a reusable element's image too when an
  instance passes one. It is no longer a `TODO(bubble:<id>)` marker:
  `.wtf/assets.json` lists it as `external` with `"handling": "linked"` (a
  note, not a reason to fix), and `frontend_report/2`'s `assets_external`
  is informational. New routers send
  `img-src 'self' data: blob: https:` with Phoenix's default policy; the
  sandbox policy on `/images/bubble` is unchanged. An `http://` URL on a
  port other than 80 is dropped (no HTTPS equivalent); a loopback or
  private host stays linked, with a manifest note. The vertical slice's
  drive counts the blocked image requests for exactly those URLs (never
  Bubble's storage) as `external_images_expected`, so `blocked_requests`
  lists only unexpected ones.

### Added

- **"Display data" and "Display list" steps** (WTF-492, part of WTF-476).
  Groups, popups, floating groups, group focuses and reusable-element
  instances that read data a workflow sends them were empty: every
  `DisplayGroupData` and `DisplayListData` step was `unsupported_action`.
  `Workflows.Frontend` lowers them to `:display_data` / `:display_list`
  (`element`, `value`, `cell`); `Target.Elixir.FrontendWorkflows` binds
  them to a per-instance page state (`@bubble_displayed`, per cell in a
  repeating group's cell) and makes each element they set page data:
  with no data source of its own it is a source that reads what the step
  showed (`read: :displayed`), with one the step's value wins until a
  reset. "Reset group / popup" forgets what was shown in the group and
  the elements inside it (an instance: everything in its scope). Later
  steps of the workflow read the new data at once; a list keeps its
  repeating group's page size; in a cell it is kept by the cell's thing.
  **The page keeps a thing's unique ID only** (a record of another type,
  a crafted text or a number is dropped) and `<Web>.BubbleData` reads it
  again through Ash as the current user at every read, so a workflow can
  never put into a group what the user may not read (with `privacy:
  :enforced`, what the policies hide stays hidden; tested to fail
  without them). An element is page data only when a step that runs
  (its workflow generated whole) sets it; otherwise it stays unloaded,
  loudly. Private fixture app (counts only): 55 of 77 "Display data"
  steps lowered in generated code (35 in workflows the runtime starts),
  data sources wired 943 → 1,016 of 2,037 (20 elements set only by a
  step, 53 sources reading them), elements inside wired data 4,308 →
  4,569, native workflows 622 → 692. "Display list" steps lower but none
  of the 30 compiles yet (searches, list operators in their values).

- **Enforced privacy: searches on fields some users may not view are
  decided per user** (WTF-457). With `privacy: :enforced`, a page search
  whose constraints or sort read a field of the searched type that some
  users may not view (or follow a gated relationship) is no longer
  refused at generation (`:search_field_hidden`): it is loaded, and
  `<App>.Privacy.SearchFields` now also restricts such fields
  (`ResourcePrivacy.view_search_fields`: the fields, the gated
  relationships and their private `*_for_privacy` twins, and the derived
  fields and counts reading through them), returning only the records where
  the actor may view every field the read's filter or sort names (a
  record whose field the actor may not view matches nothing, in either
  polarity). A Bubble page search matches the stored value (an oracle on
  hidden values: the 2026-10-01 replay; a backend workflow's search reads
  the field as empty, a Data API search matches nothing): the generated
  app is stricter by the owner's decision, recorded as the known difference
  `hidden_field_constraint_matches` (`BubbleEx.Verify.Difference`, scope
  `:search_constraints`; `Difference.flags/1`; evidence status
  `:documented` in `Assumptions.evidence/0`) and reported per data type
  (`:ash_policy_hidden_search_stricter_than_bubble`). Only a hidden field
  further along a relationship path stays residue. On a private app, page
  data wired under enforced privacy goes from 802 to 817 of 2017 sources,
  the same as `:omit`.

- **Vertical slice: enforced privacy and a chosen persona** (WTF-378
  re-run). `scripts/vertical_slice/run.sh` takes `SLICE_PRIVACY=enforced`
  (the Ash target's `privacy: :enforced`, recorded in `slice.json` and
  `seed.json`) and `SLICE_PERSONA=<n>` (the synthetic user signed in).
  The browser drive records each visit's load and settle times and
  layout counts (elements with no area, past the right edge, wired
  elements covered), and signs in only with a magic link that arrived
  after its request, so repeated drives of one server no longer use a
  spent link. The sender's job is unique per email for 60 s, so a
  request within a minute of an earlier one is dropped; with no new link
  61 s after its request, the drive asks once more and keeps polling.
- **Bubble's date and number formats in generated pages** (WTF-456).
  `:formatted as` a date renders Bubble's patterns (named formats and
  custom ones: `mmm d, yyyy`, `h:MM tt`, `dS`, `'yy`, quoted text, `Z`,
  ISO dates) in the expression's time zone (static or dynamic) or the
  app's (`config :<app>, :bubble_time_zone`, default UTC; Bubble uses the
  browser's), instead of a raw ISO timestamp; a date shown without a
  format uses Bubble's default on pages (the runtime's new `display/1`;
  `text/1`, which URLs, navigate parameters and API responses read, keeps
  ISO 8601 in UTC with milliseconds, and prints numbers as JavaScript
  does). A calendar day shows
  as the day; local times a clock change skips or repeats resolve as in
  JavaScript, and rounding down within a repeated hour stays in it (tested
  with `tz`, a test-only dependency). `:formatted as` a number renders decimals,
  thousands separators, currency and percentages; `rounded down to` and
  `extract` work on calendar units in a zone, and `+(months)`/`+(years)`
  step on the calendar. A format the runtime only approximates (`ZZ`,
  unquoted letters, an unknown unit or number setting) still compiles,
  with an `:elixir_format_approximated` warning that the compile report
  counts in its own `approximated` section and the page marks with a
  `TODO(bubble:<id>)` comment; so does `extract day` (kept as the day of
  the month; Bubble may mean the weekday, a replay question). The
  vertical slice's driver counts raw ISO timestamps on each page.
  Assumptions until a replay calibrates them: the default format
  (`mmm d, yyyy h:MM tt`), weeks from Sunday, 2 decimals for a currency
  without a setting.

- **Four gaps of the vertical slice** (WTF-450, WTF-451, WTF-453,
  WTF-454).
  * "Add a pause before next action" lowers to a `:pause` step. The
    generated runtime ends the event there and runs the rest of the
    workflow, and of the custom events waiting on it, in a message the page
    sends itself (`Process.send_after/3`), never blocking the LiveView. A
    pause is capped by `:max_pause_ms` (default 60 s), costs one call and
    continues the run's budgets one link down the chain. A page holds at
    most `:max_pending` (default 100) paused and scheduled workflows;
    malformed resume messages are ignored and budgets capped at a root
    run's. A reconnect drops paused work.
  * A refused click or input change (not lowered, data access off) shows
    "This action isn't available yet." in a polite live region of the
    page's hook, as text; the workflow, reason and IDs stay in the log.
  * "Go to page" data sent to the current page replaces the thing's
    segment of the page's URL (a reusable element's is checked at run
    time: the step fails on a page that takes no thing); to the index
    page it goes to `/index/<unique id>`, a new route of a typed index
    page. The page's own path comes from the router's path parameters, so a
    `bubble_thing` query parameter never shortens it
    (`test/support/target/phoenix/index_thing.json` boots the route). Both use the unique-ID check of `navigate/7`.
  * A Text whose dynamic content has BBCode in its own literal text
    renders `[b]`, `[i]`, `[u]` and `[s]` through the generated
    `<Web>.Bubble.bbcode/1`, the values escaped; BBCode or HTML in data
    shows as typed, other tags stay text with a marker.

- **Bubble's random sort in page data searches** (WTF-452). A search
  sorted by `_random_sorting` compiles (`BubbleEx.Target.Ash.Expressions.search/3`:
  `sort: [:random]`) and loads: `BubbleData.random_sort/1` orders by the
  MD5 of the primary key and a per-read seed in the database, before the
  page size and `:max_items` limit; `:random_seed` (set in the generated
  `config/test.exs`) makes it deterministic. Other unmapped sort fields
  stay residue. See `docs/page-data.md`.

- **`mix wtf.task` runs a run's tagged tests in one `mix test`** (WTF-449).
  `complete` and `audit` gather every subject their tasks' criteria test
  (`BubbleEx.Target.Phoenix.Checks.prefetch/3`) and run them together, an
  `--only bubble:<S>` filter each, with `BubbleEx.Tasks.TestResults` as a
  second ExUnit formatter (loaded at boot through `ERL_AFLAGS`) recording
  each test's tag and outcome: each subject still needs its own passing
  test and no failure. The summary line is never parsed; a run that fails
  before its suite finishes fails every subject; when the formatter does
  not load, each subject runs alone as before. The test database rules of
  WTF-448 are unchanged. `complete generate:api_clients` took 20.4 s
  before and 3.7 s after on `phoenix_api_clients`, and 2,587 s (43 min)
  before and 14 to 16 s after on the private fixture app (199 calls).

- **Static page assets are the app's own** (WTF-447). Generated pages no
  longer point at Bubble's storage. `mix bubble.fetch_assets`
  (`BubbleEx.Frontend.StaticAssets.fetch/3`) is the separate, explicit
  download step: only Bubble's storage hosts (`BubbleEx.Load.Files.bubble?/2`,
  checked on every redirect) and, with `--app-url`, the app's icon
  libraries, through the frontend exporter's fetcher (public destinations,
  5 redirects, size cap, deadline); no URL with credentials is requested;
  bytes must be PNG, JPEG, GIF or WebP by their magic bytes, or an SVG,
  kept only after `BubbleEx.Frontend.SvgSanitizer` rebuilds it from an
  allowlist; content-addressed store with an `index.json`, checked again
  when read. `BubbleEx.Target.Phoenix.render/2` takes it as `asset_store:`
  and stays offline: stored images are served from
  `priv/static/images/bubble/<sha256>.<ext>` (icons inlined), a Bubble image
  not downloaded renders without a source, images on other hosts keep
  their URL; each is marked in the template and listed in the generated
  `.wtf/assets.json` (URL, status, SHA-256, content type, size). A reusable
  instance's image goes through the same rules. New endpoints serve
  `/images/bubble` with `nosniff` and a sandbox CSP.
  `scripts/phoenix_compile_check.sh` renders `phoenix_static_assets` with
  its committed store.

- **Enforced privacy policies in the generated app** (WTF-423).
  `BubbleEx.Target.Phoenix.render/2` renders `privacy: :enforced` Projects
  (Target.Ash's policies plus the write policy of option A): PicoSAT is
  pinned; the User bypasses its policies and field policies for
  AshAuthentication's own interactions (marked
  `scaffold:ash_authentication`); page data, frontend and backend
  workflows, the workflow API and jobs read with the current user loaded
  afresh by `Privacy.load_actor/1`; searches use `:search`, a refused read
  shows nothing and a hidden field reads as empty; a page count reads the
  keys through `:search` (at most `:max_count`: Ash's count aggregate
  under-counts with policies that read the actor); a page search whose
  constraints or sort read a field some users may not view is residue
  (`:search_field_hidden`); the workflow API's
  admin token bypasses privacy for its run; private files can follow
  "view attached files" (`private: :privacy_rules`, lookup marked
  `scaffold:private_file_holders`); README and file headers warn that
  writes are not policy-checked. The `data_access`, `serve_workflow_api`
  and private-file switches stay off by default (`docs/page-data.md`,
  "Enforced privacy", recommends turning them on in enforced mode after
  review). An `:omit` render is unchanged byte for byte.
  `scripts/phoenix_compile_check.sh` renders the fixtures with privacy
  rules, pages and workflows enforced, runs the generated privacy matrix
  against the app (and the private app), and runs
  `test/support/target/phoenix/enforced_behavior.exs`, which must pass
  enforced and fail, every test, against the `:omit` render.

- **`privacy: :enforced` in Target.Ash** (WTF-423). `BubbleEx.Target.Ash.map/3`
  takes `privacy: :enforced`: the policies of `:unverified` (reads follow
  the compiled Bubble rules; stricter than Bubble on empty user-side
  values, `actor_empty_denies`), plus Rico's write policy (option A):
  `policy action(:create | :update | :destroy)` authorizing
  `<Namespace>.Privacy.WorkflowWrite`, a check that passes only for writes
  marked `%{private: %{bubble_workflow_write: true}}` (the generated workflow
  runtime's); any other write is forbidden. Every such project carries
  `:ash_writes_not_policy_checked` (writes are not checked against the
  privacy rules) instead of `:ash_policies_unverified`, and the rendered
  source says so. Types with file fields get a keyed `:attachments` read
  action guarded by "view attached files". `Privacy.mode/0` returns
  `:enforced`; PicoSAT is pinned as with `:unverified`. `Target.Ash.Source`'s
  `extend:` takes `policy_bypasses: [{check, purpose}]`: marked bypasses
  a renderer puts first (policies and field policies, private fields then
  `:include`d). `MatrixTests.render/3` accepts `:enforced` projects.

- **Vertical slice script** (`scripts/vertical_slice/`, WTF-378): takes one
  page of an app end to end and records what works. `run.sh EXPORT
  DECISIONS SLUG [PAGE]` picks the median page (`pages.exs`: own elements
  plus those of the reusables it renders, workflows and data sources, each
  as a percentile rank; the page closest to the median on all three, with
  at least one workflow and one data source), renders the project with the
  owner's decisions (`privacy: :omit`, the plan, the determinism result,
  the generation-time structural summary), compiles it with
  `--warnings-as-errors`, generates and checks its migrations, migrates a
  throwaway PostgreSQL (the script's own labelled docker container on
  127.0.0.1:`$SLICE_DB_PORT`, required and never 5432, checked with
  `docker port` and `pg_isready`; `slice_` databases only, for dev and
  test), loads synthetic records for every data
  type through the data loader (`seed.exs`), serves it with the data-access
  opt-in and every API client of the rendered Spec pointed at a closed
  local port (a client module it cannot account for stops the run), drives
  the page in the pinned Chromium (`drive.mjs`: signed out, a magic-link
  sign-in from the local mailbox, then every wired element, with the
  server log lines each click caused; no host resolves but 127.0.0.1,
  other origins' requests and WebSockets are aborted, service workers are
  blocked), then
  runs `mix wtf.task` and `mix wtf.verify structural`. Output stays in
  `$SLICE_ROOT/<slug>` (0700); the server and the database are removed on
  exit. The generated `navigate/7` trims the page path's trailing slash
  before the thing's segment (never `//<id>`) and takes only a value shaped
  like a Bubble ID.
- **"Go to page" sends its data** (WTF-378). The data to send of a "Go to
  page" step to a page with a type of content is lowered (`Step.args.thing`)
  and bound: the generated `navigate/7` puts the thing's unique ID as the
  path segment the page reads its thing from (`/<page>/<unique id>`), when
  that page loads its thing; otherwise, and to the current or the index
  page, it stays `:unsupported_option` residue. A data to send to a page
  with no type of content is residue of its own reason,
  `:data_to_send_untyped_page` (`detail.page`): what Bubble does with it is
  unverified, so replay (WTF-358) can find these steps; it is never dropped
  silently. On the private fixture app the 70 `data_to_send` entries
  become 35 lowered steps and 35 `data_to_send_untyped_page` entries:
  native frontend workflows 563 to 569, wired 390 to 395.
- **Non-filterable fields in privacy rules.** `BubbleEx.Privacy.Permissions`
  reads Bubble's `non_filterable_fields` (fields users matching a rule may
  not search by) as `non_filterable_fields`, so it is no longer an
  `unknown_permission`. With `privacy: :unverified`, `BubbleEx.Target.Ash`
  records per field who may search by it (`ResourcePrivacy.search_fields`:
  a rule they match grants `search_for` and does not list it, with the
  usual union and everyone-rule negation) and guards every `:read` and
  `:search` from which such a field is reachable with the new filter check
  `<namespace>.Privacy.SearchFields`: a filter or sort naming the field
  (input or code) returns only the records where the actor may search by
  it, and one naming a restricted field further along a relationship
  returns nothing. Aggregates over such a field are not guarded
  (`:ash_policy_search_fields_restricted`). A page data search constrained
  or sorted on such a field is residue (`:search_field_restricted`). The
  privacy interpreter reports the fields a persona may search by
  (`Access.filterable`) and constrained searches (`Interpreter.search/5`,
  assumption `non_filterable_constraint_excludes`); the privacy matrix adds
  a search constrained on each such field (the `search` op's new optional
  `constrain` member), which the generated matrix tests run as
  `filter_input` and the replay recorder as `is empty` plus `is not empty`.
- **`defaulting to` in the Ash and Elixir backends.** `x defaulting to d`
  (`:fallback`) compiles to `Ash.Expr` as `if(<x is empty>, d, x)`, with
  Bubble's emptiness (nil, `""`, `[]`, a reference whose record is gone),
  and so do field chains over it (`(x defaulting to d)'s a`) in both
  backends; `(x defaulting to d) is empty` is both empty. The interpreter
  treats a dangling reference as empty there too (`dangling_ref_is_empty`),
  and the actor guards cover a default read from the current user.

- **Buildprint v5 workspaces** (`BubbleEx.Buildprint.V5`). Buildprint
  retired its v4 JSON export; a v5 workspace (`buildprint project clone`)
  keeps Bubble's raw app JSON in `.buildprint/index.sqlite`.
  `BubbleEx.Buildprint.V5.load/2` opens that index read-only and immutable,
  checks `formatVersion`/`schemaVersion` (and the manifest version) against
  an allowlist (`:unknown_format` otherwise), refuses an index with a
  pending write-ahead log or journal (which an immutable open would ignore)
  or over `:max_index_bytes` (default 512 MB), verifies every row's content
  hash against the manifest (unique root keys, each listed once), applies
  the fragment rows onto the preamble (each definition a fragment holds
  replaces the preamble's stub whole; a fragment writes only the sections
  its root path owns),
  drops Buildprint's own members (`__bp_*`, `_index`) and every setting
  but `client_safe`, and returns the app in the shape `BubbleEx.Model`
  reads. It compares the loaded data types, fields, option sets, pages, API
  calls and workflows with the index's `symbols` table
  (`:buildprint_count_mismatch`) and reports stubs no fragment completes,
  ignored or overlapping fragments, redacted secret handles and the
  manifest's snapshot hash, which is not reproducible from the rows
  (`:buildprint_snapshot_unverified`); diagnostics hold counts only. SQLite
  comes from `exqlite`, an **optional** dependency: without it `load/2`
  returns the new `:dependency_missing` error kind (after adding it, run
  `mix deps.compile bubble_ex --force`). The private-fixture
  loader (`BUBBLE_EX_PRIVATE_EXPORT`) detects v5 workspaces and still reads
  split (v4) export directories and `.bubble` files.

- **Structural bypass inventory hardened** (WTF-424). A workflow body is
  now the function the generated name map binds it to, in its scaffolded
  file (`Structural.Bypasses.bodies/3`:
  `<App>.Workflows.<Folder>.Bodies.<action>/2` in
  `lib/<app>/workflows/<folder>/bodies.ex`, and its step and condition
  helpers), read from the Spec at generation and from
  `.wtf/workflows.json` in the owner's repository: a hand-written
  `# bubble:workflow` comment, a `defmodule` name forged through an
  alias, or the body module defined in another file (`:body_module`, a
  site) is no body. `decision:<key>` markers count only for a privacy
  exception: an active, accepted `parity_exception` whose `checks`
  include a privacy check, authored by an owner listed in
  `Structural.project/2`'s new `:owners` option (trusted list; its anchor
  is WTF-411), and only inside the module or function its `scope` names
  (module names resolved as Elixir does; code in a `quote` is in no
  scope); any other decision (an owner's drop of a symbol included)
  authorizes no bypass. Pipes are rewritten as plain calls before
  matching, and modules are read from aliases (with any options),
  `:"Elixir.X"` atoms, `__MODULE__` and module attributes, with aliases
  (`alias` and `require ..., as:`) and attributes scoped to their block as
  Elixir scopes them. New sites:
  Repo and `Ecto.Adapters.SQL` calls through an alias, an `import`,
  `apply/3`, `:erlang.apply/3`, `Function.capture/3`, `defdelegate`, an
  attribute or an unreadable module (`:repo_unverifiable`); every module
  defined with `use Ecto.Repo` / `use AshPostgres.Repo` is a Repo whatever
  its name, and each such definition but the generated app's Repo is a
  site; `Runtime.start/4`
  through an alias, an attribute, `apply/3` or `import`; `put_in` /
  `update_in` of an `:authorize?` path and `false` under a runtime key
  (`put_in`, `Keyword.put/3`, `Map.put/3`, `[{k, false}]` and
  `%{k => false}` literals); always-true policies with an always-true
  `authorize_if` (`:policy_always`: `always()`, `Builtins.always()`,
  `expr(true)`, lists); owned `use Ash.Resource` without
  `Ash.Policy.Authorizer` (`:unauthorized_resource`; generated resources
  stay hash-checked, `__using__` wrappers' `unquote`d options are their
  callers'); `Ash.Seed` and `Ash.DataLayer` / `AshPostgres.DataLayer` reads
  and writes (`:data_layer_call`); `Code.eval_*`, `Module.eval_quoted`,
  `EEx.eval_*` and `EEx.compile_*` (`:code_eval`); in a `quote` (what
  `__using__` injects), an `alias`, `require ..., as:` or `use` of a Repo,
  Runtime or data layer module, and every quoted `use Ecto.Repo` (the
  app's Repo included; modules using such a wrapper are Repos); an
  `alias` or `require ..., as:` nested in an expression or another
  macro's block (`:nested_alias`, it binds after its statement as in
  Elixir). The `not_run`
  "bypass_inventory (not seen)" text lists only what remains.
- **LiveView patch releases** (WTF-425). bubble_ex requires
  `phoenix_live_view ~> 1.2.12` (was `== 1.2.12`), so apps using it can
  take patch and security releases. `Target.Phoenix.render/2` checks the
  loaded LiveView against the generator's pin
  (`Target.Phoenix.Formatter.live_view_version/0`, still `==` in the
  generated `mix.exs`): another patch warns once (rendered HEEx may
  format differently) and is recorded in the manifest
  (`inputs.phoenix_live_view`), another minor or major version is
  refused.
  `.ex` formatting follows the running Elixir version, which no pin
  covers.
- **Owner drop decisions** (WTF-422). An owner can deliberately leave a
  page, data type, field, option set or workflow out of the migration
  with a `BubbleEx.Decision` of the new kind `:drop`: keyed to the symbol
  (`drop:<hash of the symbol ID>`), with a required rationale, its
  subject's kind in `params.symbol` and a `basis.basis_sha256` over the
  symbol (`Decision.drop/4` builds one from the index;
  `Decision.Drop.impact/2` lists what it would break, for an impact
  preview). `Decision.resolve/3` makes a drop `:stale` when its symbol
  changed or cannot be dropped (the User type, built-in fields, mobile
  views), `:orphaned` when it is gone, and marks an active drop of a data
  type or option set that a kept field still references with
  `:dangling_references`. **Fail-safe default: a dangling reference
  blocks** (`Resolved.blocking/1`, and an `:ash_drop_dangling_reference`
  error in the Project) until the field is dropped too or the owner lists
  it in the drop's `params.dangling` (it then keeps its Bubble IDs as
  strings, with no relationship, and no generated expression reads it: a
  privacy rule testing it, empty, not empty or compared, denies, and a
  workflow condition on it is residue, so stale IDs never grant access).
  Only the owner's drop applies: an accepted drop by another author
  resolves `:stale` with `:author_not_owner` (blocking); anyone may
  withdraw one. A dangling entry that does not reference the dropped
  symbol makes the drop `:stale` (`:params_invalid`); a dropped page's or
  workflow's contents are part of its basis; an owner's finding decision
  or rename about a dropped symbol is `:conflicts_with_drop` (blocking,
  applies nothing). Generators omit what is dropped:
  `Target.Ash` drops the type with its fields and every relationship to
  it (`:ash_dropped_omitted`), and a privacy rule reading a dropped field
  compiles to deny (`:ash_policy_reads_dropped`: dropping never widens
  access); the Phoenix target neither routes nor renders a dropped page;
  the workflow bindings omit dropped workflows and make every step that
  calls, schedules or navigates to what was dropped `:uses_dropped`
  residue, so its workflow refuses to run. `BubbleEx.Plan` closes one
  `:drop` task per drop (`drop:<symbol id>`, subjects everything it
  removes), gives kept symbols using a removed one `:uses_dropped`
  residue and a `:decision` edge to it; structural verification counts
  the removed symbols in the `decision` bucket (`owner_drop`), and a drop
  never authorizes a `decision:<key>` bypass marker. The loader skips
  dropped types and fields and reports them as counts only
  (`:load_type_dropped`, `:load_dropped_field_data`: no sample IDs, no
  values). Stale or forged drops (a key, parameters or basis that do not
  match, or a symbol that changed) are refused by `Target.Ash.map/3`
  (which requires `index:` with a drop) and `Plan.build/5`. The capability probe's contract
  holds: a drop whose subject is missing gets "subject is not in the
  Model".

- **V5 calibration applied: Bubble semantics vs. the target policy**
  (WTF-426). The privacy interpreter's defaults are now Bubble's reading
  as calibrated: `actor_empty_denies` is `false` (Bubble treats an empty
  user-side value, logged out or missing, as equal to an empty record
  value). `Interpreter.Assumptions.target/0` (and `Interpreter.target/1`)
  keep the compiler's fail-safe reading, which the generated Ash policies
  implement and which stays stricter by the owner's decision.
  `Assumptions.evidence/0` records each flag's calibration verdict (the
  leaning flags are not flipped; `unsettled/0` lists the flags that need
  more samples, and the privacy matrix now looks for up to three
  witnesses per type for each). `BubbleEx.Verify.Difference` holds the
  target policy and the per-case record of intended differences:
  `Matrix` computes them (`matrix.differences`, the owner-repo file
  `.wtf/verification/differences/<seed>.json`, and the report's
  `intended_differences` list), the generated matrix tests expect the
  stricter value (tagged `stricter_than_bubble`), `Matrix.result/4`
  reports such scenarios with the new result status
  `intended_difference` (counted as passing by `Result.evaluate/3` only
  when its `:differences` list every entry; `Result.intended_differences/1`
  is the owner's list), and the structural report and a new
  `:ash_policy_stricter_than_bubble` diagnostic list the rules.
  `BubbleEx.Verify.DataApi` models what the Data API shows (only fields
  the record holds; the ambiguous ID-only answer), the default for every
  comparison with a Bubble recording, and `BubbleEx.Verify.Calibration`
  compares Bubble recordings with the interpreter per op and per flag.

- **Opt-in pruning for the data loader** (WTF-414). `BubbleEx.Load` can
  now delete what a new complete export no longer holds among the rows the
  loader wrote itself, and nothing else. It works in two steps:
  `dry_run(..., prune: true)` reports the plan in `report.prune`, counts
  per type and list with a `sha256`. Then `run(..., prune: [expect:
  sha256])` prunes exactly that plan. A bare `prune: true` real run is
  refused, and a resumed run prunes only what is left of the plan
  recorded in its ledger.
  - `BubbleEx.Load.Written` records the Bubble IDs and join rows the
    loader wrote into a target, across its runs, in the ledger directory.
    It is bound to the database's load marker (a UUID in
    `bubble_ex_load_target`, created by the first real load), to the
    export's `app` and `source.base_url`, and to the newest export loaded.
    Its journal fails closed, every event carries the target identity, and
    it is file-locked while a run records into it.
  - Pruning is refused for an export of another app or version, an older
    export, a database whose marker differs or is missing, `allow_partial`
    or a partial export, a missing `:ledger_dir`, or an export lacking a
    type the loader wrote.
  - A type or list that would lose all, or more than half, of the loader's
    rows blocks (`load_prune_mass_delete`) unless it is named in
    `allow_mass_delete`. An export read with a non-admin token silently
    lacks the records it cannot see, and would look like this.
  - Records are deleted (`load_prune_record`). A join member loses only its
    list's column, and its row is deleted only when no other list's column
    is set (`load_prune_join_member`).
  - Rows the loader did not write are kept. Records are reported as
    `load_prune_unowned`; stale join rows still block
    (`load_join_stale_member`) unless named in `acknowledge_unowned`.
  - A user deleted in Bubble whose email a new signup reused now loads:
    the old record's email is cleared before the upserts, and the record
    is pruned.
  - A real run holds the target's lock (`with_lock/2`, a PostgreSQL
    advisory lock). The Ash adapter now requires `checkout:`
    (`&Repo.checkout/1`) for a real run, so every statement of the run
    stays on the connection that holds the lock. The lock records that
    connection's `pg_backend_pid()`: each prune statement fails on any
    other backend, and so does the unlock.
  - The marker and the other bindings guard against accidents, not
    against someone with write access: a `pg_dump` clone carries the
    marker too.
  - New adapter callbacks: `keys/2`, `delete/3` and `prune_join/4` (one
    statement per batch), plus `marker/2` and `with_lock/2`.
  - The ledger's snapshot and journal mechanics moved to
    `BubbleEx.Load.Journal`, and a corrupt line other than a torn last
    one is now an error.
  - The cutover path (`BubbleEx.Load`, step 5 of a live run) is now
    pruning.
  - `scripts/ash_compile_check/load.exs` checks all of this in PostgreSQL.

- **The check scripts fail closed** (`scripts/check_db.exs`).
  - `ASH_COMPILE_CHECK_DB` is required (`System.fetch_env!`), including
    in the generated scratch config. The Ash check therefore always runs
    its database steps.
  - The URL must name its port, and 5432 is refused unless
    `ASH_COMPILE_CHECK_ALLOW_5432=1` is set
    (`PHOENIX_COMPILE_CHECK_ALLOW_5432=1` for the Phoenix check).
  - Only databases with a check prefix are opened, created or dropped.
  - Without `PHOENIX_COMPILE_CHECK_DB`, the Phoenix check's scratch test
    config points at an unresolvable `.invalid` host rather than the
    template's `localhost:5432`.
  - CI runs PostgreSQL on port 55432.

- **Owner exposure waiver for replay** (WTF-385).
  `BubbleEx.Verify.Replay.ExposureWaiver` lets the replay preflight accept
  `:exposed` and `:may_leak` anonymous-exposure findings for named types,
  and nothing else. The file is the consent record, and nothing proves
  who wrote it: any process running as this user, agents included, can
  write one. So it may be written only after the owner's approval has
  been recorded, and that approval is quoted, with its date, in
  `approval_reference`. The app owner, or an operator acting on that
  recorded approval, writes it by hand. It is a JSON file with mode `0600`
  and a single link, in a `0700` directory whose real path is outside any
  git checkout, owned by the user running the driver. A file that changes
  while it is read is refused. It names the exact app, branch, branch
  ID, host, types with their Data API paths and a window of at most 24
  hours, plus `approved_by` and a dated `approval_reference`.
  `load_waiver/1` is the only way to obtain one; nothing builds one in
  code. The file is read again at every use: at `plan/4`, before the
  preflight, before each run and between scenarios. A waiver cannot be
  forged in memory; the file is the only authority. A struct built or
  edited in code, an edited or deleted file, a scope mismatch or expiry
  refuses the run, or stops it with cleanup. The probe's actual
  findings stay in the report with warnings. The file's SHA-256 is bound
  into the plan hash, the report and each ledger journal header.
  Fail-closed stays the default, and target verification still runs
  before any token is sent.

- **Page data** (WTF-420; see `docs/page-data.md`). `BubbleEx.PageData`
  lowers, stack-neutrally, a page's "Type of content" and the data
  sources of groups, repeating groups (with their page size) and
  reusable-element instances to Expression IR, with `:page_data_residue`
  diagnostics for what does not lower. `FrontendWorkflows.map/3` takes
  `page_data:` and binds them: searches (constraints, sort, `first item`,
  `item #`, `items until #`, `count`) become Ash queries whose inputs are
  pinned values computed from the page's state, other sources Elixir
  values, the page's thing a record read from the URL path
  (`/<page>/:bubble_thing`, Bubble IDs only). The generated
  `<Web>.BubbleData` loads them into `@bubble_data`, in dependency order,
  through Ash with the actor, bounded (a repeating group's first page;
  `:max_items`, default 100), **only with the existing `data_access:
  true` opt-in** (the resources have no authorizer under `privacy:
  :omit`); repeating groups render their template per item, text and
  image bindings read the data, workflows read it too (as data
  workflows). Reactivity: the resources the pages read publish through
  `Ash.Notifier.PubSub` to `<App>.Bubble.Changes` (topic names only, per
  type and per record) and the pages reload. A source that is not loaded,
  and a binding that reads one, is a `TODO(bubble:<id>)` marker, never an
  empty value; new residue reason `:page_data_in_cell`. Private fixture app: 805 of
  1,980 sources loaded; frontend workflows 553 native (was 531), 380
  wired (was 361), unavailable inputs 858 (was 1,027).
  `Target.Ash.Source.filter/1` prints a bare filter with `{:pin, var}`
  nodes; `:extend` takes `notifiers:`. Page change notifications are
  coalesced, related fields loaded in batches (related lists capped at
  100), and the disconnected mount no longer repeats the first read.
  The index page does not create a root catch-all thing route; query
  parameters cannot supply a page thing.

- **Target.Ash decisions, cut 3: joins and membership** (WTF-406, D-6 of
  WTF-352). `BubbleEx.Target.Ash.map/3` applies `normalize_list_to_join`
  and `membership_policy`: each decided list of things is dropped (no
  column) and becomes a `many_to_many` of the same name through a join
  resource (`project.joins`), one per join the findings name. Two
  mirrored lists share one table only with evidence they are one
  relation (a workflow maintains both, `basis: :coupled`); lists paired
  only as the only lists between their types get a table each. A join
  resource has the two record IDs as its primary key, no database
  foreign key (WTF-338), a btree index on the second ID and, per list, a
  membership column: a position when the order is kept (`keep_order`,
  default true) or a flag (`modify keep_order: false`); `join_name` names
  the join. A row is a member of a list only when that list's column is
  set, so lists sharing a table never mix members: each `many_to_many`
  reads its own rows (a declared join relationship filtered by the
  column). Names are locked in the name map (`joins`, and the owners'
  `join_relationships`). A `derive_count` of a normalized list is a count
  aggregate; an index hint over it is deferred; renaming it as an
  attribute is an error. With `privacy: :unverified`: a join row is
  readable only through a relationship (keyed `:read`, no `:search`) and
  only by an actor who may view, on its owner, a list the row is a member
  of (`privacy_<list>`, `privacy_visible`), each list's column only by
  those who may view that list (field policies), and rows read through a
  list's relationships only by those who may view that list (policies
  scoped with `accessing_from`); the owner's `many_to_many` is gated like
  the list, with a private twin; rules testing a normalized list (`contains`, `is
  empty`, also through a reference) compile to `exists(<many_to_many>,
  id == ^actor(:id))`, and rules testing the current user's normalized
  list (`Current User's list contains This Thing`) to `exists(<rows>,
  <owner column> == ^actor(:id))` through a private rows `has_many` on the
  member, filtered to that list's rows; its `doesn't contain` does not
  compile, so the rule is denied (`ash_expr_unsupported`). A field the
  rules let users auto-bind that a decision no longer stores gets
  `ash_policy_auto_binding_dropped`. Stale, altered or inconsistent
  entries are `:invalid_input` (a join ID that is not the hash of its
  lists, a basis that does not fit them, a second list that does not
  mirror the first, a list no longer a list, a membership over a list
  that is not of users, two decisions naming one join differently,
  invalid `keep_order`/`join_name`); a supported transform with a subject
  missing from the Model still fails with "subject is not in the Model"
  (bubble_wtf's capability probe). Project `schema_version` 7 (`joins`,
  `Resource.join`, the `many_to_many` and `membership` fields of
  `Relationship`); the existing goldens change only by these fields. The
  data loader loads the join tables (`Load.Plan.Join`, `Table.joined`,
  `Load.Joins`, the adapter's `upsert_join/4`), per list: one row per
  member, repeated members once (`load_join_duplicate`), dangling IDs
  kept and reported, each list setting only its own column (never
  another list's; `load_join_asymmetric` reports members not listed
  back), idempotent upserts and resumable batches in the ledger. Nothing
  is deleted from a join table: a member a list no longer holds keeps its
  row (and any access it grants), reported per list from the target's rows
  (`join_members/4`, `load_join_stale_member`, a warning with IDs and
  counts); pruning is WTF-414, which must land before a real cutover.
  `scripts/ash_compile_check.sh` renders `decided_cut3` (and
  `private_cut3` with a private export), checks the join tables, their
  primary keys, that a list reads only its rows, loads and positions,
  and with authorization on an asymmetric shared table (a Members list
  and a Workspaces list that do not list each other back: each rule,
  including "Current User's Workspaces contains This Workspace", holds
  only for its own list), a member, a lister and an outsider; two
  mutants without the join rows' policy or the many_to_many filters must
  leak; `load.exs` loads, resumes and reruns the joins in PostgreSQL and
  checks a later export deletes nothing. Fixed on the way: the Repo
  `BubbleEx.Target.Phoenix` scaffolds installs the project's extensions
  (`pg_trgm` for the trigram indexes of applied hints, cut 2) through a
  generated `RepoExtensions` module; it listed only `ash-functions` and
  `citext`, so such a project's migrations failed. `check_manifest/3`
  reports `extensions_unlisted` for an owned Repo scaffolded before it.

- **Structural verification pack** (WTF-386, V6 of WTF-358).
  `BubbleEx.Target.Phoenix.Structural` checks, offline and
  deterministically, that a generated project matches the Bubble model,
  and records every outcome as a structural (L0) `BubbleEx.Verify.Result`
  the cutover gates can read. **Structural, not behavioural**: every
  summary says so, and lists what it did not check (`not_run`).
  `run/2`, at generation with the model: `symbol_coverage` per category
  (data types, fields, option sets and values, pages, reusables,
  workflows, API calls), each symbol `generated` (emitted, and for the
  data model found in the rendered source's AST), `decision`, `residue`
  (not emitted, with an open non-generator task carrying its residue),
  `diagnosed`, `excluded` or `uncovered`, which fails: a generator node or
  an `:auto` task accounts for nothing; workflows count as generated when
  native in the backend (`Target.Ash.Workflows`) or page
  (`Target.Elixir.FrontendWorkflows`, input `frontend_workflows:`) Spec;
  `policy_coverage` (`skipped` for `privacy: :omit`: blocked on WTF-356);
  `bypass_inventory` (the lowering bypasses exactly Bubble's own "ignore
  privacy rules" workflows; every bypass site in the rendered `lib/` is a
  listed workflow body or an expected scaffold site; `skipped` when
  bypasses are expected and no Spec is given); `generated_unchanged`;
  `deterministic`. `project/2` and `mix wtf.verify structural --app
  APP_ID` in the owner's repository (advisory): the manifest, compile,
  lint (a known failure until WTF-416), `mix ash.codegen --check`, and the
  owned-code bypass inventory. `Structural.Bypasses` reads the AST: every
  `authorize?` not literally `true`, `Runtime.start(..., false)`, `bypass`
  policies, `authorize :never`/`:when_requested`, `authorizers: []`, Repo
  and `Ecto.Adapters.SQL` calls; each needs `# bubble:ignores_privacy`
  with a listed workflow (inside its body), `scaffold:<purpose>` (a closed
  vocabulary the generator now writes, counted per file in the new
  generated `.wtf/bypasses.json` per file, enclosing function and site
  kind) or `decision:<key>` (an active owner decision; hardening is
  WTF-424). A missing page or reusable is always uncovered; a missing
  workflow or API call is residue only through residue on itself or its
  own actions. `Verify.Result` diff entries may name `option_set` and
  `page`. `scripts/phoenix_compile_check/structural.sh` runs the task end
  to end; `test/support/verify/counts/structural.private-app.json` is the private fixture app's
  counts snapshot (private fixture).
- **Safe serving of migrated files** (WTF-415). The generated Phoenix app
  serves the files the data loader copied at `/uploads/<sha256>/<name>`
  (generated `<Web>.Uploads` and `<Web>.UploadsController`, routed by the
  generated `<Web>.BubbleRoutes`, so existing apps get them on
  regeneration). A Bubble file field can hold another app's hostile file,
  so every file is an attachment of an inert type (`application/octet-stream`
  or `application/pdf`) unless its magic bytes are PNG, JPEG, GIF or WebP
  (inline), always with `X-Content-Type-Options: nosniff` and
  `Content-Security-Policy: sandbox; default-src 'none'`; the name never
  decides the type. Content addresses only (SHA-256 and loader-safe name
  validated, regular files, no symlinks), single byte ranges, ETags. An
  optional `uploads_host` (`https://` and a host, validated at boot, fails
  closed) puts public files on a separate origin (the preferred production
  setup), where `<Web>.UploadsHostGuard` serves nothing else. Private files are off by default (404, no
  link) until the owner opts in with an authorization function or
  `:signed_in`; a raising or missing function denies, and the session is
  not read while they are off. Pages link file and image fields (and
  dynamic texts that are only one, optionally after `"https:"`) through
  `<Web>.Uploads.url/1`, nil when empty, never the stored URL
  (`BubbleEx.Target.Elixir` `:file_url` option). A generated
  `<Web>.UploadsTest` checks hostile files, traversal and the private
  default.

- **Frontend workflow lowering** (WTF-372, T6 of WTF-359; see
  `docs/frontend-workflows.md`). `BubbleEx.Workflows.Frontend` lowers every
  page and reusable-element workflow, stack-neutrally: events (click, input
  changed, page loaded, condition true, custom event, do every) and steps
  (show/hide/toggle/focus/scroll, reset inputs/group, set state, go to
  page, open URL, refresh, log out, the data operations, custom-event calls
  and schedules, scheduled API workflows, terminate), values as Expression
  IR; what does not lower is `Plan.Residue` with a
  `:frontend_workflow_residue` diagnostic, never dropped. The step
  vocabulary and value structs move to `BubbleEx.Workflows.Lowering`,
  shared with (and now used by) the backend lowering.
  `BubbleEx.Target.Elixir.FrontendWorkflows` binds it to LiveView (plain
  `Spec`; `backend:` the backend workflows spec; `blocked_by` and the
  coverage metric as the backend's). `Target.Phoenix.render/2` with
  `frontend_workflows:` (and `workflows:`) prints owned `Workflows` modules
  with step markers, the generated `<Web>.BubbleWorkflows` runtime,
  `phx-click` wiring (JS commands for element-only workflows), a
  `phx-change` form per tracked input, per-instance custom states and
  inputs, and owned smoke tests tagged `bubble_smoke:`. Data steps and
  scheduled API workflows run on the backend runtime
  (`Workflows.Runtime.root/2`, its job and call budgets). Browser event
  parameters are checked against the page's static lists and never become
  atoms; a workflow blocked by residue (its own, a custom event's or a
  scheduled backend workflow's) fails before its first step; data access
  is an explicit opt-in (`privacy: :omit` authorizes nothing). The overlay
  runtime moves to one hook (`<Web>.Bubble.runtime/1`, `overlay_keys/1`
  kept) that fixes T5's latent issues: reopening an open overlay no longer
  saves the focus twice, element steps target one instance, and a modal's
  focus falls back past an opener hidden since. Private fixture app: 531 of 2,275
  frontend workflows native (361 wired to a page trigger, 15.9%; 648 own
  body), 1,152 at IR level.
- **Backend workflow lowering** (WTF-373, T7 of WTF-359).
  `BubbleEx.Workflows.Backend.build/4` lowers every backend workflow (API
  workflows, backend custom events, database triggers) to a stack-neutral
  entry point and steps: create, change and delete things (and lists),
  change the current user, schedule an API workflow (and on a list),
  trigger a custom event, terminate with return values and return data
  from the API, each value compiled to `Expression.IR`. Anything else is
  residue (`Plan.Residue`, new reasons `:api_connector_action` and
  `:unsupported_option`) with a `:workflow_residue` diagnostic: API
  Connector calls (not yet wired to the WTF-374 clients), cancelling
  scheduled workflows, email, files, plugin and auth actions, detected
  request data (whose sample request, which can hold credentials, is never
  read), request headers, unresolved callees, parameters and fields, and
  uncompiled values. `Target.Ash.Workflows.map/3` binds it to Ash and Oban
  (`Workflows.Spec`, plain data) and `Target.Phoenix.render/2` prints it
  with `workflows:`: one generic-action resource per backend folder in the
  app's domain, a generated `Workflows.Registry`, `Runtime`, Oban
  `Scheduler` (one attempt, as Bubble) and database-trigger outbox change
  (a job inserted in the write's transaction carrying the record's ID
  and, before and after the change, **only the attributes the trigger
  workflows read** in their compiled conditions and steps: the rest of
  the record, including an email, never reaches `oban_jobs.args`; a
  trigger that does read an email or authentication data gets a
  `:workflow_trigger_sensitive_field` warning), the workflow API
  controller, and owned
  bodies with `# bubble:workflow` / `# bubble:step` markers.
  **A workflow whose body, or any workflow it calls or schedules
  (transitively), has residue fails before its first step** (`blocked_by`),
  so no partial run commits. **Privacy, as it actually is:** every
  generated data access passes the actor and `authorize?`, `false` only
  for a workflow whose own "ignore privacy rules" is on (a
  `:workflow_privacy_bypass` warning, `Registry.privacy_bypasses/0`);
  custom events take their caller's. But the Phoenix target renders
  `privacy: :omit` only, where no resource has an authorizer, so
  `authorize?` and the actor restrict nothing and any caller could act on
  other users' records. **The workflow API is therefore not served** until
  the owner sets `serve_workflow_api: true` (503 until then; a
  `:workflow_endpoint_not_served` warning per exposed workflow);
  scheduled jobs and triggers run. Under `privacy: :unverified` no policy
  authorizes writes, so generated writes are forbidden: how workflow
  writes are authorized is an open owner decision. When served, the API
  enforces each workflow's HTTP method (POST when unset; 405 otherwise),
  routes the name as `/:__wf_name` (a body parameter `name` is the
  workflow's), sends `nosniff` and allowlisted content types; duplicate
  endpoint names are diagnosed. Fan-out is bounded: one root run's jobs
  (schedules and triggers, over all generations) share `:max_jobs`, carried
  in job arguments (fail closed: a missing or malformed budget is none,
  and a budget is capped at `:max_jobs`; owned code enqueues root jobs
  with `Runtime.enqueue/3`), and synchronous custom-event calls share
  `:max_calls`;
  cycle chain and call depth limits remain. Whether Bubble lets a
  database trigger fire itself again through its own writes is an open
  replay question (WTF-358); here it does, within the job budget. The
  owned tests are smoke tests tagged `bubble_smoke`: they cannot fail on
  behavior, so they do not satisfy the plan's `unit_test` check, which
  needs a behavioral test tagged `bubble:`. The shared `Bubble.Runtime`
  no longer raises on unreadable decimals, unknown date units or
  non-text values, and runs caller-supplied regexes with a time limit.
  Coverage is defined by `Backend.coverage/1` (IR level) and
  `Workflows.Spec.coverage/1` (generated code, including callees); the
  The private fixture app's counts are in `test/support/target/workflows/counts/private-app.json`.
  The Phoenix compile check renders the workflow fixtures (including
  `hostile_ids`) and the private export with their workflows and runs
  behavior tests on `workflows_backend`. `Expression.Sites.workflow_env/4`
  is public.
- **Data and file loader** (WTF-357). `BubbleEx.Load` loads a Bubble
  export into a migrated target: `dry_run/4` reports per-type counts,
  schema mismatches, dangling references per field, type mismatches and
  drift of derived fields without writing anything; `run/4` copies files
  and upserts rows in batches, idempotently (a rerun changes nothing; a
  new export is a delta sync) and resumably (a ledger per export, plan and
  target). Stack-neutral: the target adapter gives a `Load.Plan` (Bubble
  IDs, tables, columns, encodings, derivations) through the
  `Load.Target` behaviour; `BubbleEx.Target.Ash.Loader` is the
  Ash/PostgreSQL adapter (schema check against `information_schema`, one
  `jsonb_populate_recordset` upsert per batch through the app's
  `Repo.query/2`). Semantics: the Bubble `_id` is the primary key (format
  checked); lists load as arrays; references keep dangling IDs (WTF-338),
  counted per field; `text_to_reference` values are trimmed and checked;
  `derive_count` lists lose IDs of deleted records; derived fields
  (`derive_*`, `has_many`) are not loaded and their drift is reported;
  users load without password material, with their trimmed email
  (duplicate emails block the run) and their email-confirmed status
  reported, as the project has no column for it; file and image fields
  get the target storage's references after a copy verified by SHA-256
  (`Load.Storage`, `Storage.Local`), private (`/fileupload/`) files stay
  private, failures keep the Bubble URL. Everything that does not fit is
  a diagnostic of the new `:load` stage (counts and sample record IDs,
  never stored values). `Load.DataApi` makes the export read-only from
  the Data API (GET only; the admin token from an option or the
  environment, sent only to the app's host and redacted; resumable
  cursor paging; files fetched with checksums). Tested offline with
  fixtures and a fake Data API; `scripts/ash_compile_check.sh` loads the
  fixtures into PostgreSQL (dry run, interrupted and resumed run, rerun,
  delta sync), reads them back through Ash, and checks the plan's column
  types against every fixture database. `postgrex` is a test-only
  dependency. Review hardening before merge: a file that fails, raises
  or times out fails alone and each copied file is in the ledger at once;
  the ledger is an append-only, `fsync`ed journal with periodic snapshots
  (linear, crash-safe), keyed also by the storage and the `:keys` map;
  exported emails are checked against the target's (`load_email_conflict`
  blocks; changed emails are cleared first, so swaps load); keys naming
  no field (`load_unmapped_key`) or several (`load_ambiguous_key`) block a
  real run unless allowed or mapped with `:keys`; only Bubble's storage
  hosts count as Bubble files; copied files should be served from a
  separate origin (documented; the generated Phoenix project serves no
  uploads yet); the exporter streams files to disk, hashing as it goes,
  under a configurable cap; NUL characters are stripped and reported;
  the schema check also flags NOT NULL columns; the token is a
  `Load.Secret` that never inspects to its value. `HTTP.request/5` takes a
  `sink:` for streamed bodies. Known limitation: an email changing only
  in case is not cleared first. Second review: `Export.delete/1` refuses
  symbolic links and deletes only the export's own regular files,
  removing directories only when empty and listing what it leaves; the
  ledger journal carries sequence numbers (a snapshot's events are never
  replayed twice), is compacted on open (nothing is appended after a torn
  line) and the directory is synced after a snapshot; the exporter sweeps
  partial downloads and gives each file task a margin beyond its HTTP
  deadline (`:file_timeout`, default one hour); a NOT NULL email explains
  how to proceed, and the docs say to keep the app closed and rerun
  until a load completes (email clearing is not transactional).

- **HEEx emitter over the normalized frontend** (WTF-370, T5 of WTF-359).
  `BubbleEx.Target.Phoenix.render/2` with `frontend:` renders each Bubble
  page as an owned LiveView (module + template) and each reusable element
  as an owned function component, with `data-bubble-id` on every element.
  Page routes live in the generated `<Web>.BubbleRoutes` (locked paths),
  which the owned router calls once whether or not the first scaffold had
  a frontend, so pages added in Bubble later are routed on regeneration; a
  router scaffolded before this lacks the call, and
  `check_manifest/3` (`unrouted`) and the generated surfaces test say so. Styles are Tailwind v4
  (`BubbleEx.Target.Phoenix.Tailwind`): tokens in `@theme`, named styles as
  component classes, each element's declarations as utilities, the rest in
  a generated `bubble_residue.css`; Preflight is not imported. Value
  bindings compiled by `BubbleEx.Target.Elixir.Frontend` become helpers
  over assigns (component attributes in reusables); the rest are
  `TODO(bubble:<id>)` markers. Popups, Group Focuses and Floating Groups
  follow the runtime model (`hidden`, `<Web>.Bubble.show_overlay/2`,
  outside-click dismissal, Escape closing only the topmost open overlay
  through one colocated hook per page, modal Popups as named dialogs in a
  focus trap that return the focus on close, one open Group Focus); dynamic
  Repeating Groups render their template per item of an assign. A reusable
  instance's link destination (allowlisted) and Text content (the static
  BBCode path, as a slot) reach its component. Bubble IDs in generated
  code are string literals, never spliced in. Surface names are locked in
  `.wtf/surfaces.json` (hand-edited names that are not valid are
  ignored).
  `scripts/heex_fidelity.sh` runs the frozen fidelity cases against the
  served LiveViews; the Phoenix compile check now also renders every
  frozen case's pages and mounts them.
- **Task CLI and verifier runner for the Phoenix target** (WTF-375, T9 of
  WTF-359). `mix wtf.task` works `.wtf/plan.json` in the owner's
  repository: `next` (ready top-level tasks in plan order, skipping claimed,
  blocked and waiting ones; `coordinate` edges shown), `show`, `claim` /
  `release` (time-limited), `complete` (binds every abstract criterion to a
  check and refuses unless all pass; records evidence), `review`
  (reviewer label is not an implementer label; spoofable, see WTF-411), `note` (`--needs-decision`
  blocks the task until resolved), `audit` (re-runs done tasks' checks,
  failures become `needs_reverify`) and `sync` (applies `Plan.diff/2` to
  the task states; writes only `.wtf/`). State is one canonical JSON file
  per task under `.wtf/tasks/` (`BubbleEx.Tasks.State`). Criteria bind to
  `BubbleEx.Target.Phoenix.Checks`: `check_manifest`, `mix compile
  --warnings-as-errors`, `mix format`/credo, `data-bubble-id` markers,
  `# bubble:step` comments, tests tagged `bubble: "<subject>"`, and
  `Verify.Result` evidence through `Result.evaluate/3`. `Plan.decode/1`
  reads a plan back with schema and `plan_sha256` checks. CI runs
  complete/audit end to end on a generated project. Every verdict is
  **advisory** (the agent being verified can edit everything checked);
  trusted verification anchored outside the repository is WTF-411.
- **`Target.Ash` applies owner decisions, cut 2** (WTF-405, WTF-352 §4.2).
  `derive_count` drops a stored count for a public calculation of the same
  name, the length of the stored list (`length(path.list || [])`), or a
  `count` aggregate (`authorize? false`) when the list is derived as a
  `has_many` in the same set; `text_to_reference` keeps the text attribute
  (name, column, type) with `references` and, for one ID, a `belongs_to`
  with no foreign key (the loader must convert the values);
  `derive_reverse_relationship` replaces a redundant reverse list by a
  `has_many` and records the finding's `rewrite_reads` in `project.applied`
  (privacy rules testing the list compile to `exists(...)`); `add_indexes`
  hints apply by default as `postgres custom_indexes` (btree for equality,
  range and sort; GIN trigram with the `pg_trgm` extension in
  `project.extensions`; GIN over a `to_tsvector` expression for keyword
  search; GIN over arrays for membership). Geographic accesses and indexes
  over derived fields stay in `project.deferred` (with the deferred
  `indexes`) and a warning. With `privacy: :unverified` derived fields read
  through private `*_for_privacy` twins (also of ungated relationships, so
  they sort) and a derived `has_many` is gated like the list it replaces
  (`privacy.relationship_checks`). New `Aggregate` and `Index` structs,
  `Resource.aggregates`/`indexes`, `Relationship` kind `:has_many`;
  Project schema version 5. The private fixture app with every cut-2 finding accepted: 55
  of 55 index hints apply (302 indexes: 289 btree, 8 GIN, 3 trigram, 2
  full text, none deferred), 15 `has_many`, 1 count and 1 text reference.

- **Generated Ash policy-matrix tests** (WTF-383, V3 of the WTF-358
  verification proposal; closes WTF-356's matrix criterion against the
  interpreter). `BubbleEx.Target.Ash.MatrixTests.render/3` prints, for a
  Project mapped with `privacy: :unverified` and a privacy matrix
  (`Verify.Matrix`, or the decoded `.wtf/verification` files via
  `MatrixTests.plan/1`), one ExUnit module for the generated project: it
  seeds the Ecto sandbox once (`Ash.Seed`, primary keys = Bubble IDs from a
  ledger, else deterministic Bubble-shaped synthetic IDs), loads each
  persona with the generated `load_actor/1` and, per scenario, compares
  keyed `:read` visibility, `:search` record sets and visible fields
  (`Ash.ForbiddenField`) with the expected recording: a Bubble recording
  when given (complete, not stale), else the `model` one. With
  `WTF_VERIFY_OBSERVATIONS` set the tests write their observations;
  `MatrixTests.results/3` turns them into `Verify.Result`s
  (`Matrix.result/4`, which now also accepts Bubble recordings) for
  `Result.evaluate/3`: passing, never Bubble-verified with the model
  oracle. `scripts/ash_compile_check.sh` runs them for every fixture with
  privacy rules (and a private export) against PostgreSQL and reports the
  counts.
- **Field defaults in the privacy interpreter and matrix seeds** (WTF-383).
  A field a record omits now reads as its Model default (WTF-338), behind
  the new assumption `defaults_applied_at_creation` (default true; 16
  flags), and verdicts resting on a default list it. Defaults the
  interpreter cannot express (lists, references, mismatched values,
  unknown option keys) make such reads unknown. `Interpreter.Dataset` keeps
  `nil` as an explicitly empty field. Matrix seeds describe records as
  Bubble stores them after creation: omitted defaulted fields are written
  out, and a defaulted field a branch needs empty is `null` (listed in
  `report.explicit_empties`: a loader must clear it after creation);
  `report.defaults` counts them. On the private fixture app: 185 defaulted fields,
  166 records, 1,554 checks; rules solved and observable unchanged
  (120 / 77).
- **API Connector → Req clients** (WTF-374, T8 of WTF-359).
  `BubbleEx.Target.ApiClients.map(model)` maps every API Connector group
  to a client module and every call to a function
  (`%BubbleEx.Target.ApiClients.Spec{}`: method, URL template, query,
  headers, JSON or form body template, authentication, arguments,
  environment variables, response decoding, residue with reasons), and
  `BubbleEx.Target.Phoenix.render(project, api_clients: spec)` prints them
  as generated, hash-guarded files: the `<App>.ApiClients` runtime (Req
  with timeouts and retries of safe requests; options from the call, the
  application environment per group and `:base_url`), one
  `<App>.ApiClients.<Group>` module per group, `<App>.ApiClients.Decode`
  (responses into the Project's external typed structs along Bubble's
  response paths, else maps), a `Req.Test` request-shape test per call
  (method, scheme, host, port, path, query, headers, body and decoding,
  with stubbed arguments and environment, no network) and
  `.wtf/api_clients.json` (environment variables, residue, names); the
  manifest records the Spec's hash. Private values, and every literal of a
  request that is not structure, are never in the code: they are
  read from deterministic, documented environment variables at call time
  (`<GROUP>_API_KEY`, `<GROUP>_<CALL>_<PARAM>`, `<GROUP>_<CALL>_LITERAL_<N>`,
  …; a header or parameter whose name Bubble strips holds `Name: value` /
  `name=value`). Supported authentication: none, private key in header or
  URL, basic. Redirects are not followed unless `follow_redirects: true`,
  and then another origin or a downgrade gets no headers or
  authentication and a cross-origin 307/308 is refused. App IDs and names
  are escaped everywhere they are printed. A host whose labels are not
  plain names is one `<GROUP>_HOST` variable per group, not needed when
  the group's `:base_url` is configured (well-known brand API hosts are
  not allowlisted: `safe_name?` decides). `scripts/phoenix_compile_check.sh`
  renders every fixture's clients (new fixture `phoenix_api_clients`) and
  runs their tests, each tagged `bubble: "api_call:<group>/<call>"` (the
  plan's subject); for `phoenix_api_clients` it also completes the plan's
  `api_call` tasks with `mix wtf.task`, whose `request_shape` check runs
  those tests. On the private fixture app's test export, 198 of 203 calls are generated,
  194 of them reading environment variables (residue: 2 non-JSON bodies,
  1 file parameter, 1 call without a URL, 1 query name that is not a
  plain name); 18 of 35 hosts are configured from the environment.
  Known gaps of the name check (`safe_name?`, a heuristic): random 6–7
  letter tokens pass 1–4% of the time, pronounceable random strings
  34–59%, dictionary-word passphrases about 90%; the Model's and Index's
  `host` keeps full hosts (never publish their JSON); the
  `generate:api_clients` task's `request_shape` lists every API call,
  residue included, so it fails while any call is residue (the `api_call`
  tasks of generated calls pass).
- **Leak-safe API Connector request templates** (WTF-374). The Model
  (`schema_version` 4) reads each call's request as a
  `BubbleEx.Model.ConnectorRequest`: scheme, port, path segments,
  query-string names, body JSON structure and type, response type, with
  `[param]`/`<param>` placeholders as references to the call's parameters
  by Bubble ID. Literals are **default-deny**: only API versions and
  dictionary path words (up to a segment named like a credential), a
  shared `Content-Type`/`Accept` media type, JSON booleans/null and empty
  text are kept; every other literal (query values, body strings and
  numbers, header values, other path segments) is `redacted` and read
  from an environment variable by the generated client. Query names and
  body keys must be plain names (dictionary, abbreviation or
  English-like segments under a letter-pair model; UUIDs, hex runs and
  detector matches refused; random tokens accepted under 0.5% per
  measured shape) or the call is unsupported; header and parameter names
  and `token_param_name` get the same check (a failing non-private name
  makes the call unsupported). Host labels that are not plain names
  (account-specific subdomains) are redacted, so the base URL comes from
  the environment. Media types are an allowlist. Parameter values are
  never read, except a group's non-private shared values, which pass the
  same policy (`Connector.shared_values`); groups gain `key_name`
  (`token_param_name`). The leak test and the security-review probes
  cover the Model JSON and hash, the Spec and the generated clients.
- **Phoenix target adapter** (WTF-369, T4 of WTF-359).
  `BubbleEx.Target.Phoenix.render(project, name:, module:, app:)` renders a
  `privacy: :omit` `BubbleEx.Target.Ash.Project` as the file map of a
  complete Phoenix 1.8 + Ash 3 application, porting bubble_wtf's
  `ProjectRenderer` (same file layout, `module_name/1`, `project_name/2`,
  `deps/1`, `ash-functions`, `default_string_length_count: :codepoints`)
  and extending it: exact framework pins (Phoenix 1.8.15, LiveView 1.2.12,
  AshPhoenix, AshAuthentication 4.15 + Phoenix 2.17, Oban 2.24, AshOban,
  Tailwind v4 via `tailwind`, esbuild), dev/test/prod/runtime config with
  production secrets from the environment, Oban through `AshOban.config/2`
  with its migration, AshAuthentication **magic link** sign-in on the User
  (WTF-355: unique email identity, registration disabled, token resource
  `Accounts.Token`, an Oban-backed sender stub and Swoosh mailer), an
  endpoint, router with sign-in routes and `/api/1.1/wf/:name`, Tailwind v4
  layouts with `@theme` tokens in `assets/css/bubble.css` (no daisyUI), a
  `.gitignore` with `.wtf/plan.key`, and a smoke test. The User email
  becomes a trimmed `:ci_string` (citext, PostgreSQL 14+) so case and
  whitespace never block sign-in; the authentication DSL is an owned
  `Spark.Dsl.Fragment` (`Accounts.UserAuthentication`); owned code reaches
  the User through the generated `Accounts.Resources`; magic-link jobs are
  unique per email for a minute and hold the link encrypted; production
  refuses to boot without `MAILER_ADAPTER` / `MAILER_FROM`; root modules
  that would shadow Elixir or dependency modules (`Task`, `Ecto`…) get an
  `App` suffix. Generated files (the Ash modules, with a "no authorization"
  warning, the token resource, `Accounts.Resources`, workflow API entry
  point, theme tokens, `.wtf/names.json`) carry a header and are listed
  with their SHA-256 in `.wtf/generated.json`
  (`BubbleEx.Target.Phoenix.Manifest`, with the project, decisions and
  applied hashes and the bubble_ex version); every other file is owned
  (scaffold once). `check_manifest/3` detects hand edits (file map or
  project directory) and, with `previous:`, stale generated files.
  `Target.Ash.Source.render/2` gains `:extend` (extensions, fragments and
  DSL for a resource) and `:extra_resources`; the Ash pins move to `Target.Ash.Versions`
  (`Target.Ash.versions/1` delegates). `scripts/phoenix_compile_check.sh`
  (CI job `phoenix-compile-check`: every fixture on Elixir 1.18, a subset
  on 1.20) renders the fixtures, compiles with `--warnings-as-errors`, generates and checks the
  migrations and runs the smoke test against PostgreSQL.
- **Popups, Group Focuses and Floating Groups are normalized** (WTF-407).
  Their content gets Exporter IDs, bindings and coverage like any container;
  they are native `:popup` / `:group_focus` / `:floating_group` nodes (every
  Floating Group anchor, not only always-visible top-right) and reusables
  with those bases keep their children. A new stack-neutral `runtime` field
  on `Normalized.Node` describes overlay behavior (initial state, workflow
  toggling, modality, placement, dismissal, backdrop, numeric `z_index`, a
  Floating Group's `plane` front/back) and marks the
  content of placeholder containers (dynamic Repeating Groups, Tables,
  plugin containers), now normalized as a runtime template the static
  export does not render. The static exporter emits Popup and Group Focus
  closed with `hidden` and `data-overlay` (shared CSS keeps them hidden),
  places an opened Popup fixed and centered and a Group Focus with CSS anchor
  positioning (behind `@supports (anchor-name: --x)`, static position
  otherwise); a Floating Group pinned to both vertical edges spans the
  viewport height. `test/support/fidelity/overlay-states.mjs` checks opened
  geometry against `bptvorpv`'s committed source observation. Normalized
  schema version 3. `Plan.Residue`: `:runtime_container` now means a
  placeholder container with runtime content (`detail.variant`); a workflow
  listening to an element of such a template is the new
  `:trigger_in_runtime_template`; plan element coverage counts template
  elements as `in_runtime_template` / `generated_in_runtime_template`, never
  `generated`. Private fixture app plan coverage: elements generated 3,359 → 5,360 of
  8,455 (1,288 more in runtime templates), not normalized 3,620 → 1,
  workflows blocked by `trigger_not_normalized` 832 → 0 (203 now
  `trigger_in_runtime_template`), frontend workflows auto 824 → 1,179 of
  2,275.

- **Replay driver prerequisites for a real app** (WTF-385). Bubble serves
  a child branch at `/version-<branch ID>/`, not at its name, and apps on a
  custom domain redirect `bubbleapps.io` to it. `Replay.Target.new/4` now
  requires the operator-supplied `branch_id:` (validated; `live`/`test`
  refused; the `wtfreplay…` name rules are unchanged and the name stays in
  ledgers, reports and recordings) and takes an optional owner-confirmed
  custom `host:` (bare DNS name, HTTPS, exact-host re-check on every
  request, no redirects, not another Bubble host). Recordings, ledgers and
  reports keep the branch ID and host; `Cleanup.resume/2` refuses a journal
  for another branch ID or host. Enabling the Data API on a branch exposes
  the development database it shares with `test` to anyone, as far as the
  privacy rules allow, so `Replay.Kit.preflight/4` now runs an anonymous
  exposure probe on every exposed type (no token, one page, field names and
  counts only) and refuses the run when a logged-out caller gets more than
  `_id`, `Created Date` and `Modified Date`; a seed that signs users up
  also needs a safely exposed `User` Data API (persona cleanup), otherwise
  the run is refused and must be recorded logged-out only.
  No token before verification: a client sends no token-bearing request
  until `Client.verify/2` has checked, without a token, Bubble's `/meta`
  shape and the kit's tokenless marker workflow (`wtf_replay_marker`),
  which must return exactly the branch name and the operator's
  `marker_nonce:` (required by `Target.new/4`), so a mistyped host or
  branch ID never receives the admin token. The exposure probe fails
  closed: it pages up to `:anonymous_cap` (200) records, `:exposed` on any
  extra field, `:may_leak` when records show only IDs and dates but `/meta`
  lists other fields (Bubble omits empty ones) and no proof
  (`anonymous_proof:`, `Kit.anonymous_proof/1` from the Model) is given,
  `:unproven` when no record answers (unless proven or accepted with
  `allow_unproven:`, as a warning). Branch IDs need a letter and a digit.
  The seeder clears a seed's explicit empties (`nil` fields, which Bubble
  would fill with defaults) after creation, journals each clear, and a
  refused clear makes the scenarios depending on that record
  (transitively, through references and personas) incomplete
  (`:clear_failed`). `docs/replay-kit.md` documents all of it.

- **PostgreSQL reference documentation in the catalog** (WTF-393). Besides
  the trailing `--` comment block, `Db.Sql.Postgres` now emits
  `COMMENT ON COLUMN "schema"."table"."column" IS E'References ... (no
  foreign key: ...)';` for every scalar reference kept without a foreign
  key, so database tools show it. The text is an escape string literal
  (`Db.Sql.Postgres.string_literal/1`: quotes and backslashes doubled, line
  breaks as backslash escapes), which reads the same whether
  `standard_conforming_strings` is on or off. SQLite and T-SQL keep only the
  `--` comments. Every PostgreSQL golden gains these statements; a new
  `hostile_names` fixture (quotes, `--`, `*/`, line breaks, LS/PS in names)
  has goldens for every format, and the PostgreSQL DDL job checks that its
  comments reach `pg_description` byte for byte in both
  `standard_conforming_strings` modes.

- **Bubble replay driver with a branch-only guard** (WTF-384, V4 of
  WTF-358). `BubbleEx.Verify.Replay.Target` takes a Bubble app ID and a
  `wtfreplay…` branch (live, test, `version-…` forms, look-alikes, domains
  and URLs are refused) plus the owner's replay admin token (redacted from
  `Inspect`), and builds every URL under
  `https://<app>.bubbleapps.io/version-<branch>/api/1.1/`;
  `check_url/2` re-checks each one before it is sent.
  `Replay.Client` is a Data API client over `BubbleEx.HTTP`: every search
  is constrained to the run's ledger IDs (an empty list makes no call; a
  result outside the constraint stops it), the kit preflight probes with an
  ID that cannot exist, and the only workflows it calls are the replay
  kit's sign-up and login (`call_kit/4`): **no app workflow is called**
  until V7 classifies them replay-safe. Admin, persona-token or anonymous
  auth, a call and a wall-time budget, backoff and `Retry-After` on 429/5xx
  (creates only on 429), no redirects, non-raising encoding, errors
  without bodies or credentials. Updates and deletes take a
  `Replay.Ledger` and a seed key, never a Bubble ID. The ledger is an
  fsynced journal (`<ledger_dir>/<run id>.jsonl`): the intent (with a
  sign-up's unique run email) is written before each create and the ID
  after. `Replay.Cleanup` deletes confirmed entries, finds unconfirmed
  sign-ups by their exact `+<run id>@` email, reports other unconfirmed
  creates, and `resume/2` finishes a dead run's cleanup from its journal.
  `Replay.Seeder` signs personas up and logs them in (per-run sink emails,
  random passwords in a redacted `Replay.Session`), creates records as
  their `Created By` user, defers forward references and supports
  delete-after-seed (dangling references). `Replay.Recorder` requires the
  dry run's `plan_sha256` and a `:ledger_dir`, refuses plans over budget
  and ops it cannot record yet, preflights the kit (read-only), records
  every scenario twice with `Replay.Differential` masks (in privacy, data
  and auth scenarios only differing field values are masked: a differing
  verdict, a field seen in one run only, or any other difference makes the
  recording incomplete), runs seeding and observing under `try` so cleanup
  always runs, reports calls, leftovers and the assumption flags each op
  can calibrate, and drops any recording that `Replay.CredentialScan`
  refuses. The owner checklist is `docs/replay-kit.md`.
  `BubbleEx.HTTP.request/5` now also accepts `:patch` and `:delete`.
  Tests run only against an in-memory fake Bubble.

- **Plugin inventory and replacement findings** (WTF-376, T10 of WTF-359).
  The index has a `:plugin` symbol (`plugin:<marketplace id>`, `installed`,
  `version`; `_current` / `_test` keys are the same plugin) for every
  plugin installed in `settings.client_safe.plugins` or used, and
  `:uses_plugin` edges (`role`, `code`) from its elements, actions, events
  and from symbols naming one of its data types
  (`api.<id>.plugin_api.<code>`); a new `:reads_step` edge records reads of
  an earlier step's result (index `schema_version` 3; Bubble's own
  plugins such as `apiconnector2` are not plugins).
  `BubbleEx.Plugins.Inventory.build(index)` lists each plugin's members
  and feature set, uses, state and step reads, surfaces and workflows. A
  new decision finding kind `:plugin` (one per plugin, subject
  `%{plugin: id}`) proposes `replace_plugin` with `options` among `drop`,
  `replace_native` (only when `BubbleEx.Plugins.Catalog`, per feature and
  for public marketplace plugins, has an equivalent for every feature
  used; code-level equivalents are low confidence) and `rebuild`, and the
  suggested `option`. Its proposal is the plugin and the set of features
  used (uses are evidence facts, so a new use of a used feature does not
  make a decision stale); its basis is the installed version.
  `Decision.Params` whitelists `option` (one of the finding's `options`)
  and, with `drop`, `delete_workflows` (among the finding's
  `evidence.rewire`); plugin findings cannot be rejected or acknowledged.
  `BubbleEx.Plan` (`schema_version` 3) gates each plugin task on its
  decision (an owner `decision:plugin/<id>` task while undecided). `drop`
  closes the plugin task (its subjects list what was removed), removes its
  elements and actions and the workflows its events trigger that run
  nothing else; workflows that run other actions keep them with
  `:trigger_dropped` residue unless the decision deletes them, and every
  read of a dropped element, action result or data type is
  `:reads_dropped_plugin` residue. The plugin decision is in the
  `decisions_sha256` of every task covering a use or read.
  `coverage.units.plugins` is now `%{tasks, undecided, dropped}`.
  `Target.Ash.map/3` skips plugin decisions. Finding IDs and hashes of the
  other kinds are unchanged (private fixture app: 147).

- **Privacy interpreter and matrix synthesis** (WTF-382, V2 of the WTF-358
  verification proposal). `BubbleEx.Verify.Interpreter` evaluates
  `BubbleEx.Privacy` rules (compiled to the expression IR) over seed data
  for a persona: visible by ID, visible field IDs, searchable. It
  implements the semantics the compiled Ash policies do (fail-safe actor
  guards, negation pushed to atoms, the `everyone` rule for users no other
  rule matches), and puts every unverified Bubble semantic behind a named
  flag of `Interpreter.Assumptions` (15; defaults: the compiler's reading), so
  V5 calibration can flip them; each verdict lists the flags it depends on.
  Unsupported rules make the verdicts they could decide `:unknown`.
  `BubbleEx.Verify.Matrix.synthesize/2` builds six personas (anonymous, an
  empty user, two world-1 members, a world-2 member, an admin), seeds that
  make every supported rule both hold and fail (a lazy, bounded solver
  builds chained records), one `privacy_read` scenario per (type, persona)
  and its `model`-oracle recording, a coverage report and owner-repo files;
  `Matrix.result/4` turns a subject's observations into a `Verify.Result`.
  Besides branch coverage ("solved") the report measures mutation
  coverage ("observable": dropping or negating a rule changes a recorded
  verdict; `Matrix.Coverage` synthesizes records isolating masked rules),
  false branches that rest only on the fail-safe actor guard, and per
  assumption flag the checks that depend on it (alone, or jointly with a
  fail-safe hedge); synthesis targets flags no check depends on yet.
  On the fixtures the interpreter agrees with the compiled conditions and
  generated policies in PostgreSQL (`scripts/ash_compile_check.sh` compares
  them; it covers IR-to-Ash lowering and the policy generator, not the
  shared expression compiler). On the private fixture app: 120 of 125 rules solved, 77
  observable. Counts snapshot in `test/support/verify/counts/`.
- **Per-task semantic hashes and `needs_reverify`** (WTF-367, T2 of
  WTF-359). `Plan.Content.digests(app, model, index, key: key)` makes keyed
  digests (HMAC-SHA256 under a per-project key of at least 32 bytes, never
  stored in the plan; `Plan.Content.generate_key/0`) of what the index does
  not record: the raw definition of every page, reusable, element (with its
  named style's definition), workflow (with its step order) and action,
  both key forms alike, without captions, editor state and canvas
  positions; field types and defaults, option value display text, order
  and attribute values, data type exposure; privacy rule conditions and
  permissions; whole API Connector groups and calls (URL path, parameters,
  body, header values) and response shapes. Passed to `Plan.build/5` as
  `content:`, it closes the raw-text gap. The algorithm and a key ID are
  recorded in `inputs.content` and hashed into every task, so another key,
  or none, changes every task (`Diff.content_changed`). Each covered
  symbol's digest (own content plus its references with their targets'
  content, 128 bits) is in the new top-level `symbols` table; a task's
  `source_sha256` hashes those digests, its residue and its new
  `decisions_sha256` (effective decisions plus, with `resolved:`, every
  current decision record naming a covered symbol and its state).
  `Plan.diff(old, new)` (`Plan.Diff`, plans or decoded plan JSON)
  classifies tasks as unchanged / changed / added / removed, with reasons
  and a symbol-ID diff per changed task, and propagates `needs_reverify`
  along every `depends_on` kind but the ordering-only `generate` and
  `early` (coordinate edges included) and from subtasks to parents. Report
  only: owned code is never touched. Plan `schema_version` is 2.

- **`BubbleEx.Plan`: stack-neutral migration task graph** (WTF-366, T1 of
  WTF-359). `Plan.build(model, index, frontend, applied, opts)` derives
  generator nodes (`generate:*`, auto), one task per page or reusable
  (mobile views excluded) and per backend workflow folder, workflows as
  subtasks that close automatically when they have no residue, workflow
  call cycles (SCC, more than one member) and reusables containing each
  other as one `cycle` task, fragments for large top-level containers,
  per-surface acceptance (reviewer), plugins, API groups and calls (used
  ones only), auth, secrets, style residue, data, replay, delivery and the
  cutover ladder. Dependencies are typed (`generate`, `early`, `secrets`,
  `decision`, `reusable`, `fragment`, `acceptance`, `plugin`, `api`,
  `calls`, `release`) with the symbols justifying them; an edge that would
  close a cycle between top-level tasks is kept as a non-blocking
  `coordinate` edge (the caller's `unit_test` re-runs after the callee;
  reported in `skipped`). Order is
  topological with batch affinity, then kind, then ID. Criteria are
  abstract checks (`Plan.Criteria`, 17 kinds; only `attested` can be
  waived). Stale applied decisions are rejected. A frontend workflow whose
  trigger element was not normalized is residue (`trigger_not_normalized`);
  an element counts as generated only when normalized without residue.
  Each task has a `source_sha256` over its subjects' content,
  references, residue and the effective decisions on them. Accepted
  `remove_writes` / `delete_workflows` (and hints applied by default) become generator nodes closed by the
  decision; deleted workflows get no task and dropped actions are not
  steps. `to_json/1` is canonical (`.wtf/plan.json`, schema_version 1);
  task IDs are kind plus Bubble IDs. `Plan.Residue` computes residue from
  the index, the normalized frontend, expressions (IR compile, with an
  optional target check) and named styles. Private opt-in dry run
  (`test/bubble_ex/plan_private_fixture_test.exs`) with a counts-only
  private fixture app snapshot (`test/support/plan/counts/private-app.json`).
- Index workflow symbols carry `folder` (the Bubble `wf_folder` ID);
  `Index.schema_version/0` is 2. The test split-export loader restores
  `wf_folder` from folder directories and loads named styles.
  `Index.WorkflowAnalysis.action_class/1` is public.
- **Parity exceptions name the checks they excuse** (WTF-381). `BubbleEx.Decision`
  parity exceptions take a required `params.checks`: a non-empty list of
  registered `BubbleEx.Verify.Check` names (sorted, unique). Still
  `schema_version` 1 (no parity exceptions had been stored); bubble_wtf
  (WTF-402) must send it when it bumps its bubble_ex pin.
- **`BubbleEx.Verify` formats** (WTF-381, V1 of the WTF-358 verification
  proposal). Stack-neutral, versioned (`schema_version` 1), strict JSON
  codecs with canonical encoding and content hashes for seeds
  (`Verify.Seed`), scenarios (`Verify.Scenario`), recordings
  (`Verify.Recording`) and check results (`Verify.Result`), plus canonical
  Bubble values (`Verify.Value`, WTF-338), observations, masks, the check
  registry (`Verify.Check`) and staleness (`Verify.Staleness`). Result
  status rules are enforced on decode: privacy, data and auth differences
  are accepted only through the owner's decisions, agents may only
  quarantine behaviour checks (at most 7 days from the first quarantine),
  owner waivers cannot be self-declared, structural and gate checks accept
  nothing; `decision` references are the decision `key` plus
  `proposal_sha256`. A decoded result never counts by itself:
  `Result.evaluate/3` links its decision against `Decision.resolve/3`
  (owner authorship, relevance, hashes, pinned scenario), trusts only
  listed reviewers and the cited recording, and reports passing and
  Bubble-verified (never on the `model` oracle). Bubble evidence comes only
  from `wtfreplay…` branches of a Bubble app ID (`Verify.Replay`); masks
  are part of the scenario hash and never hide a privacy verdict. Golden
  examples in `test/support/verify/`.

- **`Target.Ash.map/3` applies owner decisions, cut 1** (WTF-401, D-2 of
  WTF-352). `decisions` is the output of `Decision.applicable/2` (a list of
  `Decision.Applied`); raw decision records, stale entries (recorded basis
  differs from the finding's hashes), inconsistent keys, subjects missing
  from the Model, proposals that no longer fit it, two transforms of one
  field, `automatic` entries that are not undecided hints and owner
  decisions on unsupported transforms (cut 2/3) are `:invalid_input`;
  undecided hints with an unsupported transform (e.g. `add_indexes`) are
  deferred: `project.deferred` and an `:ash_decision_deferred` warning.
  `map/3` trusts its caller to have resolved the set (documented). `refine_number_type` stores
  `:integer` or `:decimal`; `derive_from_related` replaces the attribute
  by a public calculation of the same (locked) name over the relationship
  path; `rename` overrides a name-map slot with kind/subject, validity,
  reserved-name and collision checks; after the name lock a renamed
  attribute keeps its column (name map `columns`, rendered `source:`) and
  a table rename is an error; before the lock a rename that would displace
  another definition's name is an error listing the displaced names
  (renaming both swaps them); `endpoint_path` is an error. New
  `project.applied` (key, transform, subject, finding ID, hashes; no
  record IDs), `project.applied_sha256`, `project.deferred` and
  `project.decisions_sha256` (required option with decisions);
  diagnostics `:ash_decision_applied`, `:ash_decision_deferred` and
  `:ash_name_overridden`. `Decision.Applied` gains the finding's
  `proposal_sha256` / `basis_sha256` and the decision's `basis`;
  `Decision.reserved_module?/1` is public. `Calculation` gains `kind`,
  `type`, `constraints` and `public?`; `Attribute` gains `column`;
  `Project.schema_version/0` is 4 and `Project.summary/1` counts
  `applied`, `deferred` and `derived_calculations` (privacy `calculations` counts
  privacy calculations only; `summary/1` no longer fails on an `:omit`
  project). With `privacy: :unverified` a derived field keeps its field's
  field policies, reads through the ungated twin of a gated relationship
  (the private twins are now sortable, so a derived field sorts;
  `sort_input` still cannot name them) and is never auto-bound. `scripts/ash_compile_check.sh` renders two
  decided fixtures and (`decisions.exs`) checks in PostgreSQL that derived
  fields have no column, read back and sort (and `sort_input` cannot sort
  through the twin or the public relationship), and that refined numbers
  are bigint / numeric columns.
- **Owner decisions: `BubbleEx.Decision`** (WTF-400, D-1 of WTF-352). One
  stack-neutral envelope with kinds `finding` (accept / reject / modify a
  finding's proposal, or acknowledge a stale or orphaned decision),
  `rename` (a target name for a slot: `module`, `table`, `attribute`,
  `relationship`, `calculation`, `enum_module`, `endpoint_path`; accept or
  withdraw) and `parity_exception` (accept or withdraw); a strict,
  canonical JSON codec (`schema_version` 1); keys derived from the finding
  ID or a hash of the identity; append-only revisions (the highest
  revision of a key is current; `acknowledge/2` and `withdraw/2` build the
  next one). `Decision.Params` is the closed `modify` whitelist per
  transform; anything else is `:invalid_input`. `resolve/3` (requires
  `index:` and `now:`) computes each record's state (`:active`, `:stale`,
  `:orphaned`, `:acknowledged`, `:withdrawn`, `:superseded`, `:expired`,
  with reasons) and the undecided decision findings;
  `Resolved.blocking/1` is exactly what blocks publication (WTF-352 D2) and
  `Resolved.archived/1` the orphans whose subject is gone. `applicable/2`
  lists what generation may apply (active accepts, modifies and renames,
  and undecided hints by default); `decisions_sha256/1` hashes everything
  that decides state or application (including the basis hashes and
  `expires_at`) and nothing audit-only.
- **`Finding.basis_sha256`** and **`Index.subject_sha256/2`**: the hash of
  the content (kind, Bubble ID, parent, attributes; no paths, display
  names or action positions) of a finding's subject and the data-model
  symbols of its evidence (so a search hint's basis is its type and
  indexed columns, not the pages running the searches), set by
  `Findings.analyze/2` and included in `Finding.to_map/1`. It changes when
  e.g. a copied field's type changes and not on caption edits. Finding IDs
  and `proposal_sha256` are unchanged on every fixture and on the private fixture app.

- **API Connector call names from live payloads, URL hosts and header and
  parameter names** (WTF-396). `Model.ConnectorCall` reads its name in both
  key forms (`name`, live `%nm`) and gains `host` (the URL's host only: no
  scheme, user info, port, path or query string) and `parameters`
  (`Model.ConnectorParameter`: location `:header`/`:url`/`:body`/`:query`/
  `:param`, name from `key`/`%k`, Bubble's `private` flag); `Model.Connector`
  gains the group's shared `parameters`. Values, bodies and the rest of the
  URL are never read (`Model.ConnectorReader`; a leak test covers the Model,
  Index and Findings). Index `api_call` symbols carry `host`, `headers`
  (names) and `parameters`; `api_group` symbols the shared ones.
  `Model.summary/1` counts API connectors, calls (named, with a host) and
  parameters; `Model.schema_version/0` is 3. A URL with an `@` anywhere
  after `//` has no host (user info may end past `/`, `?` or `#`).
  Non-header parameter names holding `=`, `:` or whitespace are dropped.
- **The Model no longer keeps API Connector response data** (security
  review of WTF-396; present since WTF-380). `ConnectorCall.registry` keeps
  only type shapes (definition `caption` and `fields`; field `caption`,
  `path`, `ret_btype`, `ret_value`): Bubble's "initialize call"
  `sample_value`s and every other member are dropped. `types` is now
  `:malformed` instead of the malformed text, `raw` the JSON type of a call
  that is not an object instead of its content, and `returns` only a
  string. External types, their diagnostics and the data types are
  identical on every fixture and on the private fixture app; `source_sha256` still hashes
  the app input. Finding IDs and proposal hashes
  are unchanged on the private fixture export.

### Fixed

- **The workflow refusal notice is never covered** (WTF-474). The
  generated pages' `#bubble-notice` (role `status`, a polite live region)
  had `z-index: 50`, so an element with a higher one (a footer at 183)
  hid it. It is now an open manual popover, in the browser's top layer
  above every z-index, kept open while empty so its live region stays in
  the tree, and reopened for each notice so it rises above anything that
  entered the top layer since; with a modal `<dialog>` open, a visually
  hidden live region inside it announces the notice too. Without popover
  support it has CSS's
  maximum z-index; every z-index the frontend export emits (box, paint,
  responsive paint, shared styles, retained source `<style>` blocks) is
  clamped below it (`Frontend.Export.Css.z_index/1`; a value that is not
  a plain integer or keyword, such as `calc(...)`, becomes the bound).
- **Typing in an input no longer re-reads the whole page** (WTF-475).
  Each input change re-ran every data source of the page. Now each source
  in `__bubble__(:data)` lists the inputs it reads (`inputs`) and the
  page data it reads (`reads`); an input change reads again only the
  sources that read that input, and those reading them, transitively,
  keeping the rest (and their change subscriptions). If the current user
  differs from the one the page was read as (a changed role), the whole
  page reads again. The current user is read once per input change.
  Sources scaffolded before this (no `inputs`) still read the whole page.
- **Text inputs commit on blur** (WTF-475). Tracked text and multiline
  inputs debounce typing (`phx-debounce="300"`); the debounced change (and
  Enter) updates the value for the page's data and conditions only, and
  their "An input's value is changed" workflows run when the input is
  committed on blur (`bubble:commit`), once per value that differs from
  the last committed one, as Bubble's fire on blur. The field shows the
  value the page keeps (`Bubble.input(@bubble_inputs, ...)`), so a
  re-render never puts its first value back. Other inputs (checkboxes,
  dropdowns) still run them on every change.
- **Policy heads format the same on every Elixir version** (WTF-459).
  A `field_policy [...] do` or `policy [...] do` head that passed 98
  columns only by its ` do` stayed on one line on Elixir 1.17/1.18 and
  was broken by 1.19+, so a project rendered on one failed `mix format
  --check-formatted` on the other. `Target.Ash.Source` now writes such a
  head with its list already broken, which every version keeps.

- **Editor JSON: guessed heights are content-sized** (WTF-468, WTF-458).
  The 2026-10-01 replay showed that elements without a height flag or a
  min height render sized to their content in Bubble, not at their canvas
  height. `BubbleEx.Frontend.EditorGeometry` no longer turns the canvas
  height into a min height, and leaves the height flags as written (as
  Bubble's runtime payload does). Such an element no longer fills its
  Column; that it no longer stretches in its Row is inferred from the
  runtime payload, not measured. A Row child aligned to stretch still
  stretches, a Group still fills an Align-to-parent container, a fixed
  height stays fixed, and `single_height: false` still fills. An image
  that keeps its aspect ratio takes its height from its width (no
  height, min or max height, no fill, even with a written
  `fit_height: false`). Elements with nothing to size them keep their
  canvas height: a Shape without a height flag or ratio as a fixed
  height; an empty Group or Floating group with a background or border,
  and an element lowered to an empty placeholder, as a min height.
  Column children follow the same rules but were not in the replay
  sample. Runtime payloads lay out as before, byte for byte.

- **Editor JSON layout follow-ups** (WTF-446). The canvas min height of
  an element neither fixed nor fit is not applied when its max height is
  below its canvas height, nor inside a flow container of fixed height
  (children whose own min heights add up to more than such a parent
  still overflow it: documented in `BubbleEx.Frontend.EditorGeometry`).
  Bubble's own plugin elements (`select2-MultiDropdown`, ...) keep their
  canvas size like marketplace ones (`BubbleEx.Frontend.Payload.plugin_type?/1`).
  New `BubbleEx.Frontend.read_bubble_export/1` and `decode_bubble_export/1`
  decode a `.bubble` export marked as editor JSON (the vertical slice and
  the private-export test loader use them; split exports stay unmarked);
  `normalize/2` documents its `:geometry` option.

- **Editor JSON pages lay out in flow** (WTF-446). Bubble's editor JSON
  (a Buildprint v5 workspace, a `.bubble` export) writes every element's
  canvas box as `left`/`top`/`width`/`height`, also inside Column, Row
  and Align-to-parent containers, and leaves out sizing flags that are
  off. `BubbleEx.Frontend.normalize/2` read that box as a position and a
  size, so every element became `position: absolute` and fill or fit
  elements got `0px` sizes. `BubbleEx.Buildprint.V5.merge/2` now marks
  its app as editor JSON (`BubbleEx.Frontend.EditorGeometry.mark/1`; mark
  a decoded `.bubble` export the same way, or pass `geometry: :editor`),
  and `normalize/2` reads a marked app's layout as Bubble's runtime does:
  in flow, no canvas offsets and a size only on a fixed axis, missing
  flags off (neither fixed nor fit fills between min and max); plugin
  elements keep their canvas size; a reusable definition's canvas size
  does not size it; a flow page grows with its content and keeps its
  width only when `fixed_width`. *Assumption* (on the WTF-358 replay
  list): an element neither fixed nor fit on its height, without a min
  height, keeps its canvas height as a min height. Children of Fixed and
  layout-less (legacy) containers keep their canvas box. Unmarked apps,
  the fidelity cases among them, are read as before, byte for byte.
  `snapshot.reproduced` hashes the app without the mark.

- **`mix wtf.task complete` and `audit` no longer run `mix test` on a
  database nobody named** (WTF-448). Tagged-test criteria (`unit_test`,
  `request_shape`, `render_smoke`, and `traceability` of a page or
  reusable) run `mix test` in the owner's project, whose `test` alias runs
  `ash.setup` and so created `<app>_test` on whatever PostgreSQL listened
  on `localhost:5432`. Such a run now needs `WTF_TASK_TEST_DB` or
  `--test-db URL` (a loopback host unless
  `WTF_TASK_ALLOW_REMOTE_TEST_DB=1`, an explicit port, not 5432 unless
  `WTF_TASK_ALLOW_5432=1`, a database ending in `_test` or starting with
  `wtf_`, no query parameter but `ssl=true|false` (a `socket`,
  `socket_dir` or `port` parameter would bypass the host and port, and an
  invalid one makes Ecto print the URL with its password) and no
  fragment; passed to `mix test` as `TEST_DATABASE_URL` in its
  environment), or `--use-project-test-config`, which checks nothing
  (`config/test.exs` as it is: in a generated project `<app>_test` on
  `localhost:5432`), and is refused up front otherwise; `DATABASE_URL`
  is stripped from the subprocess's environment either way;
  tasks whose criteria need no database (manifest, compile, format and
  Credo, source scans, results, task state) run as before.
  `BubbleEx.Tasks.TestDb` validates the URL; `BubbleEx.Tasks.complete/3`
  and `audit/2` take `:test_db`, and
  `BubbleEx.Target.Phoenix.Checks.needs_database?/1` says which criteria
  run `mix test`. The generated `config/test.exs` uses `TEST_DATABASE_URL`
  when it is set (Phoenix's defaults otherwise) and never `DATABASE_URL`,
  which often points at a development or production database while the
  test alias creates and migrates its database (an empty
  `TEST_DATABASE_URL` counts as unset). A `--test-db` URL is refused for
  a project whose `config/test.exs` never reads it, whose
  `config/runtime.exs` reads `DATABASE_URL` or sets a Repo's connection
  outside an `if config_env() == :prod` block, or whose Repo config sets
  `socket` or `socket_dir` (a check of the code as written).
  `scripts/phoenix_compile_check/task_cli.sh` checks the refusals and runs
  its tagged tests with `--test-db`.

- **The `everyone` rule's reach negates an emptiness test exactly**
  (WTF-430). Its record-value guard (every value the negated rules read
  must be non-empty) turned the negation of `This Thing's X is not empty`
  into `X is empty and X is not empty`, always false. A value read only as
  the operand of an emptiness test (also through `defaulting to`) is no
  longer guarded that way, in the policy generator and the privacy
  interpreter alike; a reference read so must instead not be dangling (its
  ID is nil or its record exists), so the reach never depends on the
  uncalibrated `dangling_ref_is_empty`.

- A modal Popup with an authored HTML ID rendered two `id` attributes on
  its `<.focus_wrap>`, which fails `mix compile --warnings-as-errors`
  ("key :id will be overridden in map"). It now takes the authored ID
  (unique on the page) and the generated `bubble-overlay-…` ID only when it
  has none (WTF-378).
- The generated sign-in pages loaded AshAuthentication's default banner
  logo from ash-hq.org, a third-party request on every sign-in. The
  scaffold now includes an owned `<Web>.AuthOverrides` (a text banner with
  the project's name), listed first in the router's `overrides` (WTF-378).
- The loader's stale join rows (`details.stale_members` of
  `:load_join_stale_member` and `:load_prune_unowned`) are capped at
  `Load.Issues.stale_rows/0` rows, with `rows_total` and `truncated`: an
  `allow_partial` run could list a whole join (WTF-425). `Load.Report`'s
  docs say so.
- The written record's lock error for another host's lock names the lock
  file and says a crashed run's lock must be removed by hand (WTF-425).
- `docs/page-data.md`: writes that bypass Ash are not picked up by the
  next click since reads are stale-gated, and a "do every" workflow that
  changes nothing leaves sources using Current date/time frozen (WTF-425).

- **Pages read their data again only when it is stale** (post-audit of
  WTF-420). `<Web>.BubbleData` keeps `@bubble_data_stale`, set by a
  change notification, a data step (`BubbleWorkflows.backend/2`) or a
  custom state or input a workflow changed, and cleared by every read;
  events re-read only when it is set, and a read takes the notifications
  already delivered, so a write and its own notification are one read. A
  self-scheduling custom event: 2,002 reads over its 1,000 rounds before,
  0 now; a mount with a page-load workflow: 3 reads, now 1; a click
  running 5 workflows that change nothing: 6 reads, now 0 (query budgets
  in `page_data_behavior.exs`). Related lists loaded for bindings share
  one cap (`related_cap/0`: `:max_items`, at most 100) per record across
  nesting levels, `load_value/3` included; a cell source no longer
  reloads a relationship its list already loaded. Docs: a search stating
  `ignore_empty_constraints: true` returns every record to a logged-out
  visitor when its constraint is `Current User`.
- **Stale join members** (`:load_join_stale_member`): the diagnostic's
  details list every stale row with the join's table and columns (never
  the message), the blocked error names the ways forward before WTF-414
  (a fresh, empty database, or pruning those rows), and the docs note
  that an `allow_partial` run missing an owner type blocks the same way.
  Join resources say "member when <position> is not null" / "<flag> is
  true" instead of "is set".
- The structural check's `lint` must pass on fresh projects (WTF-416 is
  done): the known-failure branch is gone.

- **A condition-true loop no longer escapes the budgets** (WTF-421). The
  condition-true workflows an event fires inherit its budgets and chain
  (they started a fresh root run before), and what the event schedules is
  sent when they end, sharing what is left: "when flip is yes: set flip
  to no; schedule re-arm in 0s" now stops within `:max_calls` instead of
  running about 900 times a second. Regression test in the generated
  app's behavior tests.

### Changed (breaking)

- **`BubbleEx.Target.Ash.map/3` no longer generates privacy policies by
  default** (WTF-356 follow-up, WTF-398). The new `:privacy` option is
  `:omit` (the default) or `:unverified` (any other value is
  `:invalid_input`). `:omit` emits no policy machinery at all: no
  `Ash.Policy.Authorizer`, policies, field policies, privacy calculations,
  `*_for_privacy` relationships, relationship filters, keyed read,
  `:search`/`:auto_bind` actions, `<namespace>.Privacy` module, actor loads
  or authorization bypasses; resources keep the default actions and
  sortable relationships, so the rendered source is the pre-WTF-356 source
  (byte-identical on the `field_types` and `naming` goldens). The Project
  notes the rules it did not compile with the new info diagnostic
  `:ash_privacy_omitted` (outcome `:degraded`). `:unverified` is the
  WTF-356 output, unchanged. The default follows the ship gate recorded on
  WTF-356: generated policies must not reach an owner until WTF-397,
  WTF-384/385 and an aggregate lowering rule are done. `Project` gains
  `privacy` (the mode) and `Project.schema_version/0` is 3. The renderer
  prints `sortable?` only when false and the `Privacy` module only when a
  resource has policies. `Target.Ash.versions/0` becomes `versions/1`
  (`privacy:`, default `:omit`): PicoSAT is pinned only for
  `:unverified`. `scripts/ash_compile_check.sh` checks both modes: the
  `:omit` output compiles, migrates and round-trips in its own scratch
  project without PicoSAT, and every resource reads with authorization on.
- **The Index, Findings, Workflows explanations and expression schema read
  the data model only through `BubbleEx.Model`** (WTF-380).
  `Expression.Schema.from_app/1` and `from_user_types/1` are removed: use
  `BubbleEx.Model.schema/1`. `Privacy.parse/2` types conditions against the
  Model's pre-privacy schema (the `:schema` option; `BubbleEx.Model.build/1`
  passes it, so there is still one parser and no cycle). `Index.build/2`,
  `Findings.analyze/2` (`:model`) and `Workflows.inventory/2` take a prebuilt
  Model, checked with the new `Model.matches?/3` (`Model.for_app/3`) against
  the Model's new `source_sha256` (the canonical hash of the app it was
  built from; not in `to_map/1`), so a stale Model is rejected and a
  pipeline builds the Model and hashes the app once; the index keeps it in `Index.model` (not
  serialized) and Findings reuses it. The Model gains `connectors` (API
  Connector groups and calls, `Model.Connector`/`Model.ConnectorCall`, calls
  under `calls` or placed directly in the group, with decoded `types`
  registries), which the API Connector type resolver now reads instead of
  the settings, and
  `Model.Type` descriptor helpers (`reference/1`, `list_item/1`, `list?/1`,
  `listed/1`, `record/1`); `Model.schema_version/0` is 2. Index, Findings,
  Workflows and expression outputs are unchanged on every fixture and on the
  private fixture export, except that an option value whose `db_value` is
  `""` is now keyed by its Bubble ID in the index, as the Model keys it
  (`:model_option_key_missing`), instead of by the empty string, and calls
  placed directly in their group are now `:api_call` symbols (their
  `:field_type` references no longer dangle). `Model.build/2` now hashes the
  app (about 1.7 s on a large app); pass `source_sha256:` when it is known.

- **PostgreSQL, SQLite and T-SQL declare no foreign keys by default**
  (WTF-392). Bubble has no referential integrity, so real data holds
  dangling references, and the constraints on every scalar reference
  rejected it on load. As in `:ash` (WTF-338) and the Ecto migrations, each
  reference is now a plain column, listed in a trailing
  `-- References without a foreign key ...` comment
  (`-- <table>.<column> -> <table>.<key>`; CR, LF, VT, FF, NEL, LS and PS
  in names are escaped).
  PostgreSQL loses its `ALTER TABLE ... ADD FOREIGN KEY` statements, T-SQL
  its `ADD CONSTRAINT [FK_...]` statements (reference columns stay
  `NVARCHAR(450)`), and SQLite its inline `FOREIGN KEY` clauses and the
  `PRAGMA foreign_keys = ON;` preamble. A relaxed constraint (PostgreSQL
  `NOT VALID`, T-SQL `WITH NOCHECK`) was rejected: both still check every new
  insert. The new `foreign_keys: :enforced` option (`Db.Encoder.render/3`,
  `fetch_app/2`, each SQL encoder's `encode/2`) restores the previous output
  for cleaned data; `Created By` has no foreign key in either mode. An
  unknown mode is an `:invalid_input` error from the SQL encoders'
  `encode/2`, `render/3` and, before any request, `fetch_app/2` with a SQL
  `:format`; the other formats ignore the option. `Db.Encoder.foreign_key?/1`
  becomes `foreign_key?/2` (the mode is its second argument), with
  `scalar_reference?/1`, `foreign_keys_mode/1`, `validate_options/2`,
  `unconstrained_references/2` and `reference_comments/3` beside it.
- **Every `BubbleEx.Db.Reader` table has Bubble's built-in fields**
  (WTF-379). After `_id`, each data type's table gets the Model's
  `DataType.system_fields`: `Created Date` and `Modified Date`
  (`:utc_datetime_usec`), `Created By` (a `:reference` to User, so a
  many-to-one relationship to `User._id`), `Slug` (`:string`), and `email`
  (`:string`) on User, so the synthesized User is no longer just `_id`. They
  are claimed before the defined fields: a defined field repeating one of
  these names, case-insensitively, gets the next free suffix
  (`Created Date_2`, `db_name_suffixed`). Per encoder: **DBML** four more
  columns per table (five on User) and a `Ref:` from each table's
  `"Created By"` to `"User"."_id"`; **PostgreSQL / SQLite / T-SQL** the
  columns (`timestamptz` / `TEXT` / `DATETIME2` dates), with no foreign key
  on `"Created By"` (as in `:ash`: a creator can be a deleted user, or none
  for records made by backend workflows or logged-out visitors;
  `Db.Encoder.foreign_key?/1`); **Ecto**
  `field :created_date`, `:modified_date`, `:slug` (`:email`),
  `belongs_to :created_by, User, foreign_key: :created_by_id`, the migration
  columns and a `created_by_id` index; **Zod** nullish `'Created Date'`,
  `'Modified Date'` (ISO datetimes), `'Created By'`, `Slug`, `email`;
  **Xano** `created_date` / `modified_date` timestamps, `created_by` (a
  `ref:user._id` text field), `slug`, `email`; **Convex** `createdDate`,
  `modifiedDate` (`v.float64()`), `createdBy` (re-key to `v.id`), `slug`,
  `email`. Names follow each format's usual rules, so they are not `:ash`'s
  (`creator` / `creator_id`). Reader columns gain `system`, the built-in
  role (`:unique_id`, `:created_by`, ...) or nil. A deleted or malformed
  defined field no longer hides the built-in field with its Bubble ID in
  the Model (`DataType.system_fields`); only a live one replaces it.
- **`BubbleEx.Db.Reader`'s tables are a projection of `BubbleEx.Model`**
  (WTF-365). The Reader no longer reads data types, fields or option sets
  itself (a test forbids it), so DBML, PostgreSQL, SQLite, T-SQL, Ecto, Zod,
  Xano and Convex output now agree with the Model and `:ash`. API Connector
  type resolution moved from the Reader to the Model
  (`BubbleEx.Model.External.Resolver`); `Reader.field_pointer/4` is gone.
  `Reader.project/2` projects an already-built Model. Where the two readings
  differed, the Model's wins:

  | Drift | Before | Now |
  |---|---|---|
  | Option-set key | primary key `display` ("Display"); references point at it | primary key `db_value` (the value's stable key, `OptionValue.key`); references point at it; `display` ("Display") is an ordinary column |
  | Option-set columns in exports | derived from the values' keys (`db_value`, `sort_factor`, `comment`, `deleted`, attribute values), types guessed text/number | the declared `attributes`, with their declared types (references to data types and option sets now produce relationships) |
  | Option values (`table.values`) | always empty for exports; live form ordered by display name, `db_value` as supplied (may be nil) | both key forms; Model order (`sort_factor`, then ID); `db_value` is the stable key (the value's ID when it has none); a value repeating an earlier key is left out (`db_duplicate_option_value_dropped`) |
  | Deleted fields in exports | kept (only the live form's `%del` was honoured) | dropped in both key forms |
  | Deleted data types / option sets | kept as tables | dropped; references to them keep their column but lose the relationship (`db_reference_to_omitted`) |
  | Defaults in exports | `default` always nil | `default_val` kept |
  | `list.list.x`, `custom.` (empty target) | a list / a reference to `""` | `:unsupported` with the descriptor in `raw`, diagnosed |
  | Invalid `list.api.…` descriptor | cardinality `:unknown` | `:many` (the `list.` prefix is certain), so e.g. Zod renders `z.array(z.json())` |
  | User | a table only if the source defines it | always a table (Bubble's built-in User, synthesized when absent), so `user` references resolve |
  | Order | tables and columns by display name, `_id` wherever it sorted | data types then option sets, each by Bubble ID; injected columns (`_id`, or `db_value` and `display`) first, then fields by Bubble ID; relationships follow column order |
  | Missing display name | `nil` | the Bubble ID |
  | Repeated names | two tables or columns could share a display name (option attributes: never, they used IDs), giving invalid DDL | table names unique across all tables, column names unique per table, both case-insensitively and never a key column's (`_id`, `db_value`, `Display`): later ones in Bubble ID order (data types before option sets) get the first free `_2`, `_3`, ... suffix (`db_name_suffixed`); `naming: :id` is unaffected |
  | Malformed input | could raise | preserved and diagnosed by the Model; `parse/1` returns an `:invalid_input` error only for a non-object |
  | External types | those reached from non-deleted fields | those reached from projected columns |
  | `diagnostics` | the API Connector (`:read`) diagnostics | the Model's diagnostics about the tables: `:read`, `:model` (`model_*`) and the privacy parse's type-level `malformed_node` / `uninterpreted_field`; privacy-rule and expression diagnostics are left out. `Encoder.render/3` adds the projection's own (`db_*`, stage `{:target, format}`, from the new `projection_diagnostics` key) |

  Per encoder, beyond order: **DBML** refs to option sets end in `."db_value"`;
  option tables show `db_value [pk]` and `Display`. **PostgreSQL / SQLite /
  T-SQL** option tables' primary key and every option foreign key use
  `db_value`; a `Display` column is added; option attributes that reference
  data types or option sets get foreign keys. **Ecto** option-set schemas use
  `@primary_key {:db_value, …}`, gain `field :display`, and `belongs_to …
  references: :db_value`. **Zod** option schemas require `db_value` and make
  `Display` nullish. **Xano** describes `db_value` as the primary key.
  **Convex** option tables gain a `display` field (the primary key stays
  `bubbleId`). All formats: a `User` table, no deleted definitions, declared
  option attributes in exports, and suffixed repeated names. Generated
  comments now say option member values are "not rendered" instead of "not in
  IR" (they are in `table.values`). **T-SQL** list columns carry
  `/* list<…>: consider a junction table */` instead of a `--` comment that
  swallowed the following comma, so the DDL parses. The SQLite and PostgreSQL
  DDL of every fixture is now loaded into a real database in tests.
- **`BubbleEx.Db.Ash` is deleted** (no alias, no compatibility layer; WTF-362).
  Ash output now comes from the Model: `BubbleEx.Model.build/1` →
  `BubbleEx.Target.Ash.map/3` (a `%BubbleEx.Target.Ash.Project{}` of plain
  structs) → `BubbleEx.Target.Ash.Source.render/2` (one source file).
  `Db.Encoder.module_for(:ash)` and `Db.Encoder.render(:ash, …)` now return
  `:unknown_format`, and the `external_type_capabilities: %{ash: …}`
  attestation is gone. `fetch_app(id, format: :ash)` keeps working through
  the new path; for it the `:naming`, `:external_types` and
  `:external_type_capabilities` options no longer apply. The generated source
  changes: option sets are `Ash.Type.Enum` modules keyed by `db_value`
  instead of resources, list references are ordered `{:array, :string}` of
  Bubble IDs, scalar references are `belongs_to` with no database foreign
  key, strings are untrimmed, structured values and known API types are
  `Ash.TypedStruct`s, values with no usable shape use a generated
  `Types.JsonValue` (any JSON value, jsonb) instead of `:map`, date intervals
  are `:float` milliseconds, lists of dates migrate at microsecond precision,
  names follow WTF-339 (see `BubbleEx.Target.Ash.Naming`) and the primary key
  is `id`.
- One diagnostic type, `BubbleEx.Diagnostic`, replaces `BubbleEx.Expression.Diagnostic`
  (removed, no alias) and the Reader's and encoders' warning maps. It carries a
  stable `code`, `severity`, `outcome` (`:preserved | :degraded | :unresolved`),
  `stage` (`:read | :parse | :model | {:target, format}`), a `subject` of Bubble
  IDs, an RFC 6901 `path`, `details` and `message`. Severity, outcome and stage
  come from one registry, `BubbleEx.Diagnostic.Codes`. Lists are deduplicated on
  `{stage, code, subject, path}` and ordered by severity, subject, code and path.
- `BubbleEx.Db.Reader.parse/1`: the `:warnings` key is now `:diagnostics`. The old
  `%{kind: :external_type_resolution, category:, target:, occurrences:}` maps become
  one `:read` diagnostic per occurrence; `category` is the `code`, the target is in
  `details`, and the subject is the field whose descriptor failed (a nested
  external-type field is `%{external_type: id, field: field_id}`, with the
  originating data-type field in `details.root` and every hop in `details.via`).
  Columns gain `source_path`, and
  external types gain `source_path` (the pointer to their call's `types`).
- `BubbleEx.Db.Encoder.Result.warnings` is now `diagnostics`. Rendering maps
  (`kind: :external_type_rendering`, `reason:`) become `{:target, format}`
  diagnostics with codes `:external_type_unresolved_root`,
  `:external_type_unresolved_nested`, `:external_type_target_opaque`,
  `:external_type_cycle_edge`, `:external_type_opaque_mode` and
  `:external_type_legacy_mode`.
- App results use `:schema_diagnostics` / `:dbml_diagnostics` instead of
  `:schema_warnings` / `:dbml_warnings`.
- Expression and privacy diagnostics gain `outcome`, `stage`, `subject`
  (privacy: `%{type:, rule:}`) and `details`, and are returned sorted by severity.
  Canonical expression hashes are unchanged. Values behind `:preserved` privacy
  diagnostics are now actually kept: `Privacy.Rule` gains `extra` (unknown rule
  members), `Privacy.DataType` gains `raw` (a data type that is not an object),
  and a non-object `privacy_role` is kept in `DataType.extra`.
- Workflow inventory schema v3: diagnostics are `BubbleEx.Diagnostic` records
  (atom codes; objects with the full field set in JSON) with the workflow ID as
  subject for collection entries. `unresolved_order`, `alias_collision`,
  `malformed_node` and `uninterpreted_field` from the inventory are renamed
  `workflow_*` with their own severity and outcome. Diagnostic lists are
  deduplicated, so `coverage.diagnostics` now counts records after dedup. See
  `docs/workflows.md`.
- `Diagnostic.to_map/1` (and JSON encoding) makes `details` JSON-stable: string
  keys and primitive values throughout. Stages encode as `"read"`, `"parse"`,
  `"model"` or `"target:<format>"`; `Diagnostic.parse_stage/1` reverses this.

### Added

- Privacy rules compiled to Ash policies (WTF-356). `BubbleEx.Target.Ash.map/3`
  now gives every resource `policies` (a keyed primary `:read` for direct
  view: a separate policy with the generated `<namespace>.Privacy.KeyedRead`
  check allows only records selected by primary key or loaded through a
  relationship, for reads and aggregates alike; a new `:search` read for Bubble searches, an `:auto_bind` update with a policy
  per bindable field), `field_policies` (per-field visibility, the union of
  the rules showing each field) and private boolean `calculations`, one per
  rule condition (compiled fail-safe by `Target.Ash.Expressions`) and one
  per "everyone else" grant. Types without rules get Bubble's public
  defaults; a type whose rules the source lacks denies every read; a
  condition that does not compile grants nothing. Attachments and the Data
  API are kept as data and diagnosed; with the new `:index` option,
  workflows ignoring privacy rules become `authorization_bypasses`.
  `Project.actor_loads` and the rendered `<namespace>.Privacy.load_actor/1`
  load the actor afresh. **Safety gate:** `Project.policies_verified` is
  always `false`, every Project carries `:ash_policies_unverified`, and the
  rendered policies say "NOT VERIFIED AGAINST BUBBLE" until the WTF-384/385
  replay. `Project.schema_version` is 2; `Target.Ash.versions/0` adds
  `picosat_elixir` (Ash's SAT solver for policies). New diagnostic codes
  `ash_policies_unverified`, `ash_policy_*` and
  `ash_privacy_rules_unavailable`. The "everyone else" negation also
  requires the record values it reads to be non-empty, so it can only
  under-grant. Aggregates over fields some users may not view are not
  covered by Ash field policies: documented and diagnosed
  (`ash_policy_aggregates_unguarded`). `scripts/ash_compile_check.sh` runs
  `policies.exs`: every resource read through its policies, and a
  hand-authored persona table for the policy fixture.

- Typed expression compiler (WTF-368). `BubbleEx.Expression.Typing` resolves
  the type of every expression node from the Model and the app's element tree
  (`BubbleEx.Expression.Tree`): parent groups, repeating-group cells, page
  things, element states, reusable parameters, custom states, previous steps
  and trigger records. `BubbleEx.Expression.Compiler` lowers a typed AST to a
  stack-neutral `BubbleEx.Expression.IR`. Two backends consume it:
  `BubbleEx.Target.Ash.Expressions` (filters as `%BubbleEx.Target.Ash.Expr{}`
  data, printed by `BubbleEx.Target.Ash.Source.expr/1`; `privacy/2` compiles
  every privacy-rule condition, and `search/3` compiles searches) and
  `BubbleEx.Target.Elixir` (value expressions as Elixir source over a runtime
  module). `BubbleEx.Expression.Sites` finds every page, reusable and
  workflow expression with its context, and `BubbleEx.Target.CompileReport`
  counts what compiles. Comparisons with an actor-side value deny when it is
  empty (fail-safe for logged-out users); "empty is empty" between record
  values is not verified against Bubble. `BubbleEx.Target.Elixir.Runtime` is
  the behaviour the generated app's runtime module implements. New diagnostic
  codes: `expr_untyped_scope`, `expr_unresolved_accessor`, `expr_uncompiled`,
  `expr_option_by_id` (stage `:model`),
  `ash_expr_unsupported`, `ash_expr_unmapped_reference` (`{:target, :ash}`)
  and `elixir_expr_unsupported` (`{:target, :elixir}`).
  `scripts/ash_compile_check.sh` now also compiles every fixture's privacy
  filters, builds their AshPostgres queries and, with a database, runs them,
  compares the result with Ash's in-memory evaluation, and checks the
  expression fixture's filters against a hand-authored expectation table.

- `BubbleEx.Target.Ash` (WTF-362): maps a `BubbleEx.Model` to a
  `BubbleEx.Target.Ash.Project` describing Ash resources, attributes,
  `belongs_to` relationships, enums and typed structs as data, with the
  source-faithful defaults of WTF-338 and diagnostics at stage
  `{:target, :ash}` (new `ash_*` codes). Names are derived by
  `BubbleEx.Target.Ash.Naming` and recorded in a per-app name map
  (`project.names`); passing it back as `names:` keeps every name, so caption
  edits in Bubble do not rename code. `decisions` must be `[]` until WTF-352.
  `BubbleEx.Target.Ash.Source.render/2` prints a Project; a `mix xref` test
  keeps it independent of the Model and the Reader.
- `BubbleEx.Target.Ash.versions/0`: the `ash` / `ash_postgres` pins for
  projects using the generated source (3.31.3 / 2.11.0).
- `scripts/ash_compile_check.sh` (and the `ash-compile-check` CI job, with a
  PostgreSQL service) compiles the generated source of every fixture against
  `Target.Ash.versions/0`, checks the generated migrations (no foreign keys,
  microsecond date lists), runs them, and inserts and reads back sample rows
  for every resource.

- Deterministic model-refinement analyzers through `BubbleEx.Findings.analyze/2`
  / `BubbleEx.model_findings/2`. They emit `BubbleEx.Finding`s, a type separate
  from diagnostics: a registered `kind` and `category` (`:decision` or `:hint`,
  `BubbleEx.Finding.Kinds`), a subject of Bubble IDs, evidence (index symbol
  IDs and references), a stack-neutral `proposal`, a confidence with its
  reason, the readers and maintainers affected, `related` findings, a stable ID
  hashed from kind and subject and a `proposal_sha256` that changes with the
  proposal. Kinds: redundant reverse lists, fully traced denormalized (copied
  or counted) fields, used lists of things (mirrored lists share one join),
  privacy-access lists, IDs of app types stored in text, per-type search index
  hints and integer number fields.
- Build the stack-neutral data model through `BubbleEx.Model.build/1` /
  `BubbleEx.data_model/1`: data types with fields (content type, cardinality,
  resolved or unresolved target, default, `deleted`), Bubble's built-in fields,
  option sets (stable value keys, values in `sort_factor` order, typed
  attributes), API Connector types (known, empty, opaque, conflicted; cycle
  edges marked) and privacy rules (`BubbleEx.Privacy`), all keyed by Bubble IDs
  with no target-language names. Malformed nodes are kept raw and diagnosed with
  new `:model` codes (`model_*` in `BubbleEx.Diagnostic.Codes`). `to_json/1` is
  canonical and independent of input member order; `summary/1` gives aggregate
  counts; `schema/1` gives the expression-typing schema from the model.
- `Db.Reader`: an API Connector registry field definition that is not an object
  is now opaque with a diagnostic instead of crashing.
- Build a deterministic symbol and reference index through `BubbleEx.Index` /
  `BubbleEx.symbol_index/1`. Symbols (data types, fields, option sets and
  values, pages, reusables, elements, workflows, actions, API Connector calls,
  privacy rules) are keyed by stable Bubble IDs; reference edges cover field
  types, expression reads, privacy-rule field references, data writes
  (insert/update/delete per field), workflow calls with their kind, API calls
  and element targets. Workflows carry an execution class and invocation modes,
  and the call graph's cycles are reported (Tarjan SCC). Queries answer who
  reads or writes a field, which privacy rules reference it, what depends on a
  data type, and a workflow's callers, callees and writes. Cycles carry the
  kind of each call, so scheduled recursion is told apart from synchronous
  loops. Built-in fields (unique id, dates, Created By, Slug) are symbols.
  The index has a schema version, a content hash and a semantic hash of the
  reference graph that ignores source positions.

- Workflow inventory: previous-step references inside list-form workflow
  collections no longer raise.

- Parse data-type privacy rules through `BubbleEx.Privacy` /
  `BubbleEx.privacy_rules/1`: conditions, permissions and per-field visibility.
  Conditions and other Bubble expressions parse into a typed, stack-neutral AST
  (`BubbleEx.Expression`) from both export and live-payload key forms, with raw
  preservation and diagnostics for unmodeled pieces, source re-emission, and a
  canonical hash for round-trip checks. `BubbleEx.CanonicalJson` now provides the
  workflow inventory's canonical hash.

- Workflow inventory schema v2 explains bounded conditions and create/change-data
  assignments in JSON and Markdown, with grouped operators, scoped source-backed
  names, literal/dynamic values, disabled flags, support states and separate
  explanation coverage. Unknown source remains lossless. See `docs/workflows.md`
  for migration and the controlled-editor / authorized-payload verification record.

- Add a static workflow inventory through `BubbleEx.Workflows`,
  `BubbleEx.workflow_inventory/1`, `BubbleEx.export_workflows/2`, and
  `mix bubble.workflows`. JSON and Markdown exports retain source records,
  conditions, action ordering, supported references and explicit diagnostics.
  Missing data differs from empty collections. App-tree exports now include
  `workflow-inventory.json` and a root `WORKFLOWS.md`. No workflows are executed.

- Add an optional browser snapshot mode for one anonymous page at a declared
  viewport, with separate capture and offline export APIs, pinned Chromium,
  retained rendered content/shadow CSS/canvas visuals, frozen CSS animation
  state, local resources, inert source controls, and decoded credential checks.
  The default app-data renderer remains available. Install the optional backend
  with `mix bubble.snapshot.setup` and export with `mode: :snapshot` or
  `mix bubble.export_frontend URL --mode snapshot -o DIR`.

### Fixed

- **Replay driver against a real Bubble branch** (WTF-385, V5 of
  WTF-358). The first run on the private fixture app's replay branch found where the driver
  disagreed with Bubble:
  - Data API type paths keep dots, colons and emoji (`00.thing`,
    `🎙️msgs`) and are now percent-encoded instead of refused. A path must
    equal its NFKC form and holds no separator look-alike (`／`, `．`,
    `∕`), bidi or zero-width character (only the emoji joiner and variation
    selector are kept).
  - The preflight reads `/meta` as Bubble writes it: `post` entries named
    by `endpoint`; fields as `{id, display, type}` objects keyed by display
    name under `app_data.use_captions_for_get`; the built-in `id` `_id`
    (displayed `unique ID`) as `_id`.
  - Option-set values are sent and read by display text
    (`Replay.Names.to_api/4`, `from_api/4`; Bubble refuses the stored key
    with 400 `INVALID_DATA`). An option field with no reversible mapping
    is an error to send, and an unknown display text is observed as a
    mismatch (`{"unmapped_option": true}`), never as a key.
  - A `GET` answered 200 with only `_id` is recorded as not visible. Bubble
    does not 404 hidden records; this rests on one observation and may
    merge "hidden" with "findable but no field visible" (unverified).
  - The sign-up and login workflows are required only for a seed with
    users.
  - Ledger journals: the directory is made 0700 and checked before any
    file is created (a directory that stays open to group or others
    refuses the run); each journal is created with an exclusive open and
    set to 0600 before its first write, and a failed `chmod` refuses the
    run.

  `docs/replay-kit.md` records the observed semantics and warns that Data
  API writes fire the app's database triggers.

- **`generate:api_clients` no longer checks API calls the generator leaves
  out** (WTF-412). Its `request_shape` criterion listed every API call,
  including residue calls with no generated test, so
  `mix wtf.task complete generate:api_clients` failed whenever one existed
  (5 of 203 calls on the private fixture app). It now lists only the generated calls, and
  the task carries the residue calls' residue (part of its
  `source_sha256`, so a call turning residue re-verifies it). Residue
  calls stay visible: a used one is an open `api_call` task (four on
  the private fixture app, which were wrongly `auto` before), and those nothing kept uses
  are the new `api_clients:residue` task (kind `:api_clients_residue`,
  agent, open, one `attested` criterion; one on the private fixture app), after
  `generate:api_clients` and before `replay:app`. The plan and the
  generator now share one stack-neutral decision,
  `BubbleEx.Model.ConnectorSupport.unsupported/2` (malformed call,
  unsupported authentication such as OAuth, JWT or a custom token, unknown
  method, unnamed parameter, the request template's `unsupported`
  reasons): `Plan.Residue` gives every call it rejects one new
  `:not_generated` entry with those reasons, and `BubbleEx.Target.ApiClients`
  leaves exactly those calls out. The plan's own API call checks
  (`:dynamic_url`, `:oauth`, `:malformed_call`) are gone: they missed JWT
  and custom-token groups, unknown methods and unnamed parameters, and
  marked a call with a malformed `types` registry (which is generated,
  untyped) as residue. The three reasons still decode. Surfaces and workflows had no such check: their
  generator tasks run no tagged tests, and their residue is already
  surface and workflow task work. Plan coverage snapshots for the private fixture app are
  re-recorded (plan and plugins). `scripts/phoenix_compile_check/task_cli.sh`
  completes `generate:api_clients` and `api_clients:residue` on
  `phoenix_api_clients` (three residue calls).
- **Cut-2 follow-ups** (WTF-410). A `derive_count` computed as a list
  length now says in its `ash_decision_applied` diagnostic that the loader
  must drop IDs of deleted records from the list, which Bubble's `:count`
  hides (WTF-357); the behaviour is unchanged. The trigram index is
  documented as serving `contains` against a value (LIKE/ILIKE), not
  against another column (strpos). The cut-2 fixture's Card has a Creator
  read rule, and `scripts/ash_compile_check.sh` loads the derived
  `has_many` through its public relationship with authorization on (a
  non-creator sees `[]`, the creator only their child). The private fixture app's encoder
  count snapshot records the Postgres DDL size after WTF-393's
  `COMMENT ON COLUMN`.

- **T-SQL names cannot split the sqlcmd batch** (WTF-409). T-SQL allows raw
  line breaks inside `[...]`, so a Bubble name holding a line that is only
  `GO` (or `GO 5`, `go`, a `:r` or `!!` sqlcmd command) cut the generated
  script into batches under sqlcmd/SSMS. Identifiers now go through
  `Db.Encoder.Literal.tsql_bracketed/1`: `]` is doubled, and a name with
  line breaks or other control characters has each replaced by a space and
  gets a `_` + 8-hex SHA-256 suffix (deterministic, distinct from the
  spaced name). A new `hostile_go_separators` fixture has goldens for every
  format, and `DbSyntaxTest` checks every fixture's T-SQL: the only
  batch-tool lines are the encoder's own `GO` after `CREATE SCHEMA`.
  `hostile_names.tsql` golden changed accordingly.

- **DBML and Zod escape hostile names** (WTF-408). The `hostile_names`
  fixture showed DBML writing `"` unescaped inside quoted identifiers and
  Zod writing a raw line break inside a quoted object key (a TypeScript
  syntax error); a line break or LS/PS in a table name also ended Zod's
  `// <table>` comment and ran as code. The new
  `Db.Encoder.Literal` quotes per format: DBML identifiers
  (`dbml_quoted/1`: `\"`, `\\`, and `\n`, `\r`, `\t`, `\v`, `\f` or `\uXXXX`
  for control characters, NEL, LS and PS), JavaScript single-quoted strings
  (`js_single_quoted/1`, the same escapes plus `\'`) and line comments
  (`line_comment/1`, formerly the SQL encoders' private reference-comment
  escaping, now also used for Zod's comments). DBML's project name and API
  type names use the same quoting. Ecto's string literals also escape `#{`.
  Only the `hostile_names` DBML and Zod goldens change: each name now stays
  on one line with its escapes. Convex, Xano, Ecto, SQLite, PostgreSQL and
  T-SQL were already correct for this fixture (converted names, JSON
  encoding or SQL quoting). A new syntax check
  (`test/support/syntax_check`, pinned `@dbml/core` 10.2.0 and TypeScript
  5.9.3) parses the DBML, Zod and Convex output of every schema fixture, both
  namings and both external-type modes, and checks that hostile names parse
  back unchanged; CI runs it with `mix test --only syntax_check` in the
  fidelity job. Without Node, a structural check over `hostile_names` (no
  literal or comment crosses a line) runs in the default suite.

- **Ecto, Convex, Xano and Zod names are unique after case conversion**
  (WTF-391). The Reader's names are unique case-insensitively, but the
  converting encoders could merge them again: a type with `created_date`,
  `Created-By` and `created_by_id` gave Ecto two `field :created_date`, two
  `belongs_to :created_by` and `created_by_id` three times (it did not
  compile), Convex repeated `createdDate` / `createdBy` keys (TS1117), and
  Xano repeated field names; tables differing only by punctuation (`Blog
  Post`, `Blog-Post`) shared an Ecto module and table, a Convex table key, a
  Xano table and a Zod schema const. One decision point,
  `BubbleEx.Db.Encoder.Names` (each converting encoder's `names/2`), now
  assigns every converted name per scope: tables across the schema, columns
  per table. The primary key and the built-in fields claim first, so they
  keep their names; later names, in Bubble ID order, take the next free
  `_2`, `_3`, ... (`2`, `3`, ... in camelCase and PascalCase). An Ecto
  reference claims its association and foreign key together
  (`created_by_2` / `created_by_2_id`), so a field named `created_by_id`
  becomes `created_by_id_2`; a data type named `Repo` becomes `Repo2` (not
  the app's repo); a Convex field that converts to `bubbleId` takes
  `bubbleId2`; a Zod table const does not take an API Connector type's.
  Ecto names are cut to 63 characters (PostgreSQL's identifier limit), which
  also keeps module atoms under the VM's 255, so the long-name fixture now
  compiles; each cut name is a `db_converted_name_truncated` diagnostic. Every
  Ecto `create index` now has an explicit `name:` (Ecto's default
  `<table>_<fk>_index`, cut to 63 characters and claimed beside the table
  names, since PostgreSQL keeps tables and indexes in one namespace: a cut
  index name could otherwise repeat its own table's). Each suffix is a
  `db_converted_name_suffixed` diagnostic (stage `{:target, format}`). The
  SQL formats, DBML and Zod field keys keep display names and are
  unchanged. `scripts/ash_compile_check.sh` also compiles the Ecto output
  of every schema fixture and, with `ASH_COMPILE_CHECK_DB`, runs its
  migrations.

- Preserve snapshot stylesheet cascade order, adopted styles, embedded frame
  state and local frame assets. Restore captured scroll offsets with a fixed,
  CSP-hashed initializer while continuing to remove source execution. Keep
  inactive `noscript` fallbacks out of frozen screenshots, and escape CSS raw-text
  terminators before embedding restored styles. Report malformed source links
  instead of allowing MHTML to turn them into homepage links.

- Preserve simple authored element IDs and supported inline head styles in
  fetched exports, with per-page scope, bounded parsing, omission findings, and
  credential checks on the retained CSS. This restores authored section clipping.

- Apply page-width minimum-size overrides to the size and both bounds of an
  authored fixed axis, instead of retaining its desktop width or height.

- Respect initial hidden states on icon controls and restore the native display
  mode when an exact page-width condition shows a native element.
- Ignore stale vertical editor bounds on fit-height aspect-ratio images.

- Accept Bubble's inert Message editor metadata during bounded list evaluation;
  continue rejecting unknown arguments and operators.
- Retain dynamic image alt text as a binding and resolve literal reusable
  parameter values separately for each instance, including nested forwarding.
  Collect each instance's assets, bindings, and safety findings independently.

- Preserve shared-style page-width conditions and literal breakpoint thresholds;
  reject chained conditions in the older collapsed-visibility lowering.
- Subtract authored side margins from fill dimensions, including responsive
  changes, and keep reusable instance sizing separate from definition defaults.
- Preserve button default line height and reusable children's parent layout.

- Preserve compact shared-style references, authored design tokens and default
  typography without reapplying the editor's element-creation default styles.
- Correct modern fill sizing, stacking order, reusable floating anchors, and
  aspect-ratio image content boxes, including responsive border changes.
- Keep native dropdown typography available during initial option rendering;
  preserve plain-text spacing without adding whitespace around block BBCode.
- Resolve links to known, unexported pages against the public source route.

- Keep Popup and Group Focus as explicit hidden runtime placeholders, retaining
  their full definitions and reporting the runtime boundary. Do not infer an
  open dialog from `is_visible` or paint Group Focus in the page layout.
- Restore the actual Popup source in `bpndkqfs`, correlate its closed state,
  and recapture it on `dev02`. Add initial-state case `bptvorpv` plus separate
  source-only opening/dismissal observations; update the native support matrix.
- Reject ambiguous fidelity selectors and withdraw one invalid shared-icon
  collapse sample while retaining both icon instances' structural checks.
- Keep the range-slider wrapper transparent as in Bubble when restoring the
  complete source styling; retain existing pixel tolerances.
- Correct Bubble Input/DateInput enum mappings and reject invalid frozen source
  formats. Repair and recapture four affected cases from authorized branch `dev02`.
- Preserve explicit control borders/backgrounds over native defaults, render
  static percentage/currency/US phone values, and compare captured Input values
  independently of screenshot tolerances.

### Added

- Literal text/number data on typed Groups and reusable definitions, with
  explicit parent-data forwarding. Original data-source expressions remain
  bindings; missing/mismatched types and database searches stay unresolved.

- Bounded literal horizontal Repeating Groups with leaf templates, scalar
  current-cell values, portable image assets, and unique repeated instance IDs.
  Database searches, nested templates, and runtime scrolling remain unsupported.

- Static Phosphor regular, bold, and fill icons, with bounded group/path SVG
  sanitization that preserves stroke geometry and rejects active content.

- Static Material outlined icons and sanitized path-only inline SVG elements;
  separate icon/label colors and authored icon placement, size, and spacing.
- Exact configured-breakpoint paint/spacing rules and conservative fetched
  initial snapshots for direct logged-out visibility and formatted year text.
  Original expressions remain bindings and the snapshot time is recorded.
- Repeatable private landing-page exports, captures, and a locked acceptance
  rubric covering visuals, layout, content, typography, assets, and navigation.

- Frozen S1 range Slider / Popup case `bpndkqfs` (`bubbleex-i69-range-popup`)

- S1 two-handle SliderInput (paired `type=range` inputs). Popup and Group Focus
  remain runtime placeholders; the earlier static overlay lowerings were
  withdrawn after source characterization.

- Frozen S1 slider/search case `bplvejcw` (`bubbleex-i67-slider-search`)

- S1 simple SliderInput (`type=range`) and static AutocompleteDropdown
  (`type=search` + `<datalist>`). Dynamic/Google search stays a placeholder.
  Authorized page `bubbleex-i67-slider-search`
  is on `example-plugin` Test.

- Frozen S1 PictureInput case `bpdimzwm` (`bubbleex-i65-picture-input`)

- S1 PictureInput lowering as `<input type="file" accept="image/*">`.
  Authorized page `bubbleex-i65-picture-input` is on `example-plugin` Test.

- Frozen S1 numbers / datetime / FileInput case `bpoyzixi`
  (`bubbleex-i63-datetime-numbers-file`)

- S1 numbers-only Input, datetime DateInput, and FileInput lowering.
  Numbers use `inputmode=numeric`. Datetime stays `type=text` (no
  native picker). FileInput is `<input type="file">` with no upload.
  Authorized page `bubbleex-i63-datetime-numbers-file` is on
  `example-plugin` Test. Google address autocomplete remains deferred
  (needs a live Google contract).

- Frozen S1 Address Input / DateInput case `bpizatjd`
  (`bubbleex-i61-address-dateinput`)

- S1 Address Input and DateInput lowering as `type=text` (no Google
  autocomplete, no native date-picker chrome). Authorized page
  `bubbleex-i61-address-dateinput` is on `example-plugin` Test.

- Frozen S1 extra Input formats case `bpjehwxg`
  (`bubbleex-i59-input-formats`)

- S1 decimal / percent / currency / US phone / euro-date Input lowering
  as `type=text` with matching `inputmode`. Authorized page
  `bubbleex-i59-input-formats` is on `example-plugin` Test; freeze is a
  follow-up.

- Frozen S1 date / integer Input case `bpqkcldq`
  (`bubbleex-i57-date-integer-input`)

- S1 date and integer Input lowering (`content_format` `date` / `integer`
  as `type=text`, integer `inputmode=numeric`). Authorized page
  `bubbleex-i57-date-integer-input` is on `example-plugin` Test; freeze is a
  follow-up.

- Frozen S1 fit-height MultiLineInput case `bpuzekut`
  (`bubbleex-i55-fit-height-multiline`)

- S1 fit-height MultiLineInput lowering (`fit_height` + static content →
  `field-sizing: content`). Authorized page `bubbleex-i55-fit-height-multiline`
  is on `example-plugin` Test; freeze is a follow-up.

- Frozen S1 icon Link case `bpaupfbj` (`bubbleex-i53-icon-link`)

- S1 icon / icon+label Link lowering for static Font Awesome 4 icons
  (`show_icon` or `link_type: icon`). Authorized page `bubbleex-i53-icon-link`
  is on `example-plugin` Test; freeze is a follow-up.

- Literal newlines in Text become `<br>` so 404 boilerplate keeps its paragraph
  break. Native Input chrome uses `appearance: none`, white fill, and a 1px border.

- S1 icon / icon+label Button lowering for static Font Awesome 4 icons, with frozen
  case `bpiordvb` on `example-plugin` Test (`bubbleex-i51-icon-button`).

- Theme tokens: export emits `:root` CSS variables from
  `settings.client_safe` color/font tokens. Existing unstyled elements retain
  native defaults; the editor's `default_styles` choices apply during creation.

- Empty-page hydration: a page-specific fetch that returns layout properties but
  no `%el` (internal-link targets like `bubbleex-i36-target`) is treated as a
  hydrated empty page instead of failing the export.

- Frontend export falls back to `BubbleEx.Secrets.Native` when the default
  Trufflehog CLI is missing (`:cli_missing`), so `mix bubble.export_frontend`
  works without Trufflehog. An explicit non-Trufflehog adapter is unchanged.

- Frozen BBCode Text case `bpwipyqn` (#44): controlled `bubbleex-i44-bbcode-text`
  page on `example-plugin` Test. Block BBCode (`[ul]/[ol]`) exports as a `div`
  with Bubble-like list/link CSS; `[b]`, `[url=https]` stay inline.

- Selected live-page hydration (#40): `BubbleEx.export_frontend/3` and
  `mix bubble.export_frontend` fetch each requested metadata-only page from the
  sanitized app origin, preserving `/version-test` and `/version-development`
  prefixes. Extra page fetches are deduplicated and capped at 20 by default;
  use `max_page_fetches:` or `--max-page-fetches` to override the bound.

- Button-to-link inference (#21): a label-only Button with exactly one
  unconditioned `ButtonClicked` workflow whose only action is a static
  `ChangePage` or `OpenURL` is exported as a semantic `<a>`. The original
  workflow payload is preserved on the node. Multi-action, conditioned,
  parameterized, disabled, icon, and `ListGoToPage` clicks stay buttons.

- S1 frontend exporter: `BubbleEx.Frontend.normalize/2`, `export/3`,
  `export_payload/3`, `BubbleEx.export_frontend/3`, and
  `mix bubble.export_frontend`. Writes a portable HTML/CSS package with
  bindings, findings, and coverage for the modern responsive renderer.
  S1 lowers Page, Group (Fixed / Align to Parent / Row / Column), plain
  Text, public Image, decorative Shape, label-only Button, text-only
  resolved Link, and Text/Email/Password Input. Everything else is a
  dimension-preserving placeholder.

- Authenticated/private-app frontend export (#33): HTTP Basic Auth can come
  from `BUBBLE_EX_FRONTEND_USERNAME` plus `BUBBLE_EX_FRONTEND_PASSWORD`, or
  URL userinfo; `BUBBLE_EX_FRONTEND_SESSION_COOKIE` imports an existing Bubble
  application-user session. Payload auth is HTTPS exact-origin scoped, and
  `--authenticated-assets` explicitly opts same-origin assets into auth.
  Credentials and sessions are never persisted. Login, session renewal,
  private workflow execution, and private-record fetching remain out of scope.

- Frozen-case fidelity gates (#30): `mix bubble.fidelity` and `mix test --only
  fidelity` render committed cases through the S1 exporter and compare them
  to frozen Bubble references (0 CSS-px geometry, byte-identical PNGs). PR
  CI runs the gate; live recapture is opt-in and never default.

- Frozen S1 Image case `bprkyexk` (#35): Stretch, Rescale, Zoom, and
  Adjust-element-height on one authorized page, with public image bytes
  hashed and rewritten by the exporter. This is case-correct, not S1
  slice-complete.

- Frozen S1 text-only Link case `bptaixqv` (#36): resolved external and
  internal destinations, new-tab + nofollow, wrapping, and literal disabled
  behavior on one authorized page. Internal Bubble page ids are rewritten to
  portable package paths.

- Frozen S1 Text/Password Input case `bpewigqu` (#37): empty Text placeholder
  paint and a benign masked Password literal on one authorized page. The
  exporter preserves Bubble's `content` field, emits exact native input types,
  and supplies placeholder-backed accessible names. This validates the static
  Text/Email/Password subset, not broader Input behavior.

- Frozen S1 normal/H4 Text case `bpcybc` (#38): explicit `normal` and `h4`
  paint, geometry, typography, fixed-width two-line wrapping, and exporter-owned
  `<p>` / `<h4>` semantics on one authorized page. Shared CSS neutralizes browser
  paragraph and heading defaults before authored typography is applied. An
  authorized full-suite live review found all five cases and 34 viewports
  byte-identical to their committed references, with exact tracked geometry and
  typography.

- Frozen static native controls case `bpqqfagk` (#32): fixed-height Multiline
  Input, literal checked/unchecked Checkboxes, static Dropdown, and static Radio
  Buttons.
  The normalized schema is now v2. Exported controls preserve resolved value,
  choices/default, placeholder, maxlength, checked/required/disabled state,
  labels, and native keyboard semantics. Fit-height multiline and dynamic
  checkbox/dropdown/radio variants remain dimension-preserving placeholders.
  The authorized two-viewport Bubble capture passes with zero geometry error
  and byte-identical Chromium 140 PNGs.

- API Connector v2 External API types are resolved into the universal database
  map and rendered deliberately by every registered schema encoder. Detailed
  rendering and app enrichment expose structured, artifact-scoped warnings.

- `BubbleEx.AppTree.generate/3` and `mix bubble.app_tree`: explode a
  `.bubble.json` export into a two-layer, agent-readable source tree
  (lossless split with round-trip guarantee + generated OUTLINE/WORKFLOWS/
  API/STYLES/SETTINGS/DBML views with honest coverage reporting).
- `BubbleEx.Db.Reader.parse/1` now also accepts the readable `.bubble.json`
  export shape (`display`/`fields`/`values`) in addition to the scraped
  `%d`/`%f3` shape.
- Added `BubbleEx.Secrets.Native`, a pure-Elixir offline secret-scanning adapter
  (regex + base64 + opt-in entropy, no live verification).
- Added the frozen Issue #42 complex-composition fidelity case with two selected
  pages, nested reusable expansion, local image/font/icon assets, a viewport
  Floating Group, portable navigation, and an explicit Repeating Group boundary.
  The gate now records bounded material pixel metrics rather than treating all
  PNG drift as an unqualified mismatch. A pinned Pixelmatch comparator excludes
  detected edge antialiasing from the gate while retaining raw pixel telemetry.
- Added `scripts/package_consumer_smoke.sh` and an Elixir 1.18.4 / OTP 28 CI lane
  to compile and execute the unpacked production package from a fresh project.

### Security

- `BubbleEx.Target.Ash.versions/0` pins Ash 3.33.11 and AshPostgres 2.13.1
  (were 3.31.3 / 2.11.0; WTF-397), past the policy advisories
  EEF-CVE-2026-86338 (forbidden calculations and aggregates not set to nil),
  -82747 (a runtime read policy returns denied records) and -82746
  (`update_many`'s atomic path skips policies), and the other Ash, AshSql
  and Postgrex advisories fixed since. The compile check's lock follows
  (ash_sql 0.7.6, postgrex 0.22.4). Projects using the generated source must
  now set `config :ash, default_string_length_count: :codepoints` (Ash 3.33
  requires it); the generated source is unchanged. Re-checked on the new
  version: aggregates over hidden fields through `:search` (`min`/`max`
  still return hidden values), sorts through a relationship (still ordered
  by the destination's hidden fields), aggregates skipping a read action's
  `before_action` hooks, and filters through gated relationships matching
  nothing: all unchanged, so `sortable?: false`, the generated caveats and
  `:ash_policy_aggregates_unguarded` stay.
- Link destinations use a safe scheme allowlist. CSS values that can escape a
  declaration or fetch a remote URL are omitted with explicit findings.
- Cross-origin public assets must resolve to public HTTP(S) destinations. The
  validated address is pinned for the connection, and every redirect is
  revalidated. Failed or missing local assets never retain a remote HTML/network
  fallback.
- Secret-scan errors and frontend export errors redact raw token material.
  Trufflehog inputs now live in random private temporary directories instead of
  payload-derived paths. The fidelity harness uses Playwright 1.55.1, which fixes
  its browser download certificate-validation advisory.

### Changed

- Page hydration now merges page-bundle shared styles with the same deterministic
  precedence as reusable definitions. Reusable package directories are
  collision-safe, and legacy fixed-container placement dimensions remain
  authoritative during normalization.

- Frontend live-payload parsing now applies Bubble's data-only
  `Object.assign(..., JSON.parse(...))` page patches instead of exporting only
  the initial page metadata. Decoded `%nm` names, aliased text expressions,
  and common paint aliases are normalized through the existing payload seam.
  `collapse_when_hidden` is treated as behavior, not current visibility.
  Selected live metadata-only pages are hydrated from their page-specific URLs
  before one combined export. A requested page that remains metadata-only still
  fails closed instead of reporting empty 100% coverage.

- New Reader output uses `external_types: :preserve`, which may add by-value
  shapes to generated artifacts. Use `external_types: :legacy` during migration
  for pre-feature output, or `:opaque` for JSON/map containers without shape
  expansion. No schema is inferred from connector response samples.

## [0.3.0] - 2026-06-21

### Added

- Telemetry. BubbleEx now emits `:telemetry` span events for its major
  operations — see `BubbleEx.Telemetry` for the full contract:
  - `[:bubble_ex, :http, :request, :start | :stop | :exception]`
  - `[:bubble_ex, :apps, :fetch_app, :start | :stop | :exception]`
  - `[:bubble_ex, :secrets, :scan, :start | :stop | :exception]`
- `:finch` option / `config :bubble_ex, :finch` to run requests through a
  dedicated named Finch pool (default unchanged: Req's built-in pool).

### Changed

- `Apps.Parser.find_app_line/1` scans for the app marker instead of splitting the
  whole (multi-MB) response body, reducing peak memory on large bundles. Output
  is unchanged.

## [0.2.0] - 2026-06-20

Maturity refactor. **This is a breaking release** — the public surface was
reshaped around a single HTTP client and a single error type.

### Breaking Changes

- **All public functions now return `{:ok, result} | {:error, %BubbleEx.Error{}}`.**
  Errors are no longer bare atoms, English strings, `{:http_error, ...}` tuples,
  or leaked HTTP structs. Pattern-match on `error.kind` (a closed atom set).
- **Removed `BubbleEx.Meta`** (the cookie-authenticated "my apps" API) entirely.
- **Removed the legacy delegators on `BubbleEx.Apps`:** `get_dynamic_js/1`,
  `find_app_line/1`, `extract_json_string/1`, `get_app_json/1`,
  `get_plugins_from_payload/1`, `handle_get_latest_change/1`,
  `enrich_obj_endpoints/1`, `enrich_wf_endpoints/1`. Call the underlying modules
  directly (`BubbleEx.Apps.Parser`, `BubbleEx.Apps.Enricher`).
- **Renamed `BubbleEx.Apps.is_dedicated/2` → `BubbleEx.Apps.dedicated?/2`.**
- **Removed `BubbleEx.TrufflehogAdapter`.** Secret scanning is now pluggable via
  the `BubbleEx.Secrets` behaviour; the default adapter is
  `BubbleEx.Secrets.Trufflehog`. When the CLI is absent, scans return
  `{:error, %BubbleEx.Error{kind: :cli_missing}}` instead of raising.
- **Removed `BubbleEx.Utils`** (orphaned helpers, duplicate key-rename tables,
  duplicate validators, `get_page/2`).
- `BubbleEx.Db.Dbml.quote_special_chars?/1` (which returned a string) was renamed
  to `quote_identifier/1`; the other `Db.Reader`/`Db.Dbml` internals are now
  private.

### Added

- `BubbleEx.Error` — the single error type (`kind`, `message`, `context`).
- `BubbleEx.HTTP` — one Req-based client with retries, redirects, auth, and the
  high-level `fetch_page`/`fetch_json`/`post_json`/`check_redirect` helpers;
  `Req.Test`-stubbable.
- `BubbleEx.Secrets` behaviour + `BubbleEx.Secrets.Trufflehog` adapter.
- Real `config/*.exs` files backing `BubbleEx.Config`.
- A trustworthy, mostly-offline test suite (live tests tagged `:integration`).

### Fixed

- Double-retry of transient HTTP failures (Req's auto-retry layered under the
  explicit retry loop).
- `BubbleEx.Server` now runs scans under a `Task.Supervisor` instead of a raw
  `spawn` + manual monitor + "fake task struct"; the `nil`-key `Map.delete` bug
  is gone.
- Trufflehog command is built with `Port.open({:spawn_executable, ...}, args: ...)`
  instead of shell-string interpolation (no command-injection surface).

## [0.1.0]

- Initial release.
