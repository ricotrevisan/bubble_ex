# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Changed (breaking)

- **The Index, Findings, Workflows explanations and expression schema read
  the data model only through `BubbleEx.Model`** (WTF-380).
  `Expression.Schema.from_app/1` and `from_user_types/1` are removed: use
  `BubbleEx.Model.schema/1`. `Privacy.parse/2` types conditions against the
  Model's pre-privacy schema (the `:schema` option; `BubbleEx.Model.build/1`
  passes it, so there is still one parser and no cycle). `Index.build/2`,
  `Findings.analyze/2` (`:model`) and `Workflows.inventory/2` take a prebuilt
  Model, checked with the new `Model.matches?/2` (`Model.for_app/2`), so a
  pipeline builds it once; the index keeps it in `Index.model` (not
  serialized) and Findings reuses it. The Model gains `connectors` (API
  Connector groups and calls, `Model.Connector`/`Model.ConnectorCall`) and
  `Model.Type` descriptor helpers (`reference/1`, `list_item/1`, `list?/1`,
  `listed/1`, `record/1`); `Model.schema_version/0` is 2. Index, Findings,
  Workflows and expression outputs are unchanged on every fixture and on the
  private mm-137 export, except that an option value whose `db_value` is
  `""` is now keyed by its Bubble ID in the index, as the Model keys it
  (`:model_option_key_missing`), instead of by the empty string.

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
  and recapture it on `83jop`. Add initial-state case `bptvorpv` plus separate
  source-only opening/dismissal observations; update the native support matrix.
- Reject ambiguous fidelity selectors and withdraw one invalid shared-icon
  collapse sample while retaining both icon instances' structural checks.
- Keep the range-slider wrapper transparent as in Bubble when restoring the
  complete source styling; retain existing pixel tolerances.
- Correct Bubble Input/DateInput enum mappings and reject invalid frozen source
  formats. Repair and recapture four affected cases from authorized branch `83jop`.
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
  is on `tiptap-plugin` Test.

- Frozen S1 PictureInput case `bpdimzwm` (`bubbleex-i65-picture-input`)

- S1 PictureInput lowering as `<input type="file" accept="image/*">`.
  Authorized page `bubbleex-i65-picture-input` is on `tiptap-plugin` Test.

- Frozen S1 numbers / datetime / FileInput case `bpoyzixi`
  (`bubbleex-i63-datetime-numbers-file`)

- S1 numbers-only Input, datetime DateInput, and FileInput lowering.
  Numbers use `inputmode=numeric`. Datetime stays `type=text` (no
  native picker). FileInput is `<input type="file">` with no upload.
  Authorized page `bubbleex-i63-datetime-numbers-file` is on
  `tiptap-plugin` Test. Google address autocomplete remains deferred
  (needs a live Google contract).

- Frozen S1 Address Input / DateInput case `bpizatjd`
  (`bubbleex-i61-address-dateinput`)

- S1 Address Input and DateInput lowering as `type=text` (no Google
  autocomplete, no native date-picker chrome). Authorized page
  `bubbleex-i61-address-dateinput` is on `tiptap-plugin` Test.

- Frozen S1 extra Input formats case `bpjehwxg`
  (`bubbleex-i59-input-formats`)

- S1 decimal / percent / currency / US phone / euro-date Input lowering
  as `type=text` with matching `inputmode`. Authorized page
  `bubbleex-i59-input-formats` is on `tiptap-plugin` Test; freeze is a
  follow-up.

- Frozen S1 date / integer Input case `bpqkcldq`
  (`bubbleex-i57-date-integer-input`)

- S1 date and integer Input lowering (`content_format` `date` / `integer`
  as `type=text`, integer `inputmode=numeric`). Authorized page
  `bubbleex-i57-date-integer-input` is on `tiptap-plugin` Test; freeze is a
  follow-up.

- Frozen S1 fit-height MultiLineInput case `bpuzekut`
  (`bubbleex-i55-fit-height-multiline`)

- S1 fit-height MultiLineInput lowering (`fit_height` + static content →
  `field-sizing: content`). Authorized page `bubbleex-i55-fit-height-multiline`
  is on `tiptap-plugin` Test; freeze is a follow-up.

- Frozen S1 icon Link case `bpaupfbj` (`bubbleex-i53-icon-link`)

- S1 icon / icon+label Link lowering for static Font Awesome 4 icons
  (`show_icon` or `link_type: icon`). Authorized page `bubbleex-i53-icon-link`
  is on `tiptap-plugin` Test; freeze is a follow-up.

- Literal newlines in Text become `<br>` so 404 boilerplate keeps its paragraph
  break. Native Input chrome uses `appearance: none`, white fill, and a 1px border.

- S1 icon / icon+label Button lowering for static Font Awesome 4 icons, with frozen
  case `bpiordvb` on `tiptap-plugin` Test (`bubbleex-i51-icon-button`).

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
  page on `tiptap-plugin` Test. Block BBCode (`[ul]/[ol]`) exports as a `div`
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
