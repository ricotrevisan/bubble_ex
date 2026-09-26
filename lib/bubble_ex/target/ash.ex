defmodule BubbleEx.Target.Ash do
  @moduledoc """
  Maps a `BubbleEx.Model` to an Ash project described as data
  (`BubbleEx.Target.Ash.Project`). Pure and deterministic: the same Model,
  decisions and name map give the same Project, byte for byte.

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, source} = BubbleEx.Target.Ash.Source.render(project)

  This module owns every Bubble-to-Ash decision. Renderers
  (`BubbleEx.Target.Ash.Source`, and WTF's multi-file project renderer)
  only print a Project and never look at Bubble types.

  ## Source-faithful mapping (WTF-338)

  With no decisions, the mapping keeps what Bubble has:

  | Bubble | Ash |
  |--------|-----|
  | record ID (`_id`) | writable `:string` primary key `id` holding the Bubble ID, `trim?: false, allow_empty?: true` |
  | text | `:string`, `trim?: false, allow_empty?: true` (empty kept distinct from nil) |
  | number | `:float` |
  | yes / no | `:boolean` |
  | date | `:utc_datetime_usec` (a list of dates also migrates at microsecond precision: `migration_types`) |
  | file, image | `:string` (the URL), no trim |
  | geographic address, date range, number range | a generated `Ash.TypedStruct` (`Types.*`) with the parts in `BubbleEx.Model.Structured`; a range's unverified bounds are kept in `metadata` |
  | date interval | `:float` milliseconds (Bubble: "the difference between two dates, expressed as milliseconds"), diagnosed (info) |
  | a thing (scalar reference) | `belongs_to` with a writable `:string` `<name>_id` attribute and no database foreign key (`db_reference: :ignore`) |
  | list of things | `{:array, :string}` of Bubble IDs, order preserved |
  | reference to a missing or omitted type | `:string` / `{:array, :string}` of IDs, diagnosed |
  | option set | a generated `Ash.Type.Enum` (`Enums.*`) whose values are the stable keys (`db_value`), stored as a string, with the set's attributes as lookup data |
  | API type, known shape | a generated `Ash.TypedStruct` (`External.*`) |
  | API type, unknown shape; opaque or unknown value | the generated `Types.JsonValue`: any JSON value (a list is a JSON array), stored as jsonb and kept verbatim, diagnosed |
  | recursive API types | the edge closing a cycle becomes `Types.JsonValue`, diagnosed |
  | Created Date, Modified Date, Slug (and User's email) | writable attributes `created_date`, `modified_date`, `slug`, `email` |
  | Created By | `belongs_to :creator` (User) with a writable `creator_id` |
  | deleted type, field, option set, value or attribute | omitted, diagnosed (info) |
  | nullability | every attribute allows nil (except the primary key) |
  | defaults | text, number (as a float), yes/no, file, a fixed ISO 8601 date and an option key are kept; others (lists, references, mismatched values) are omitted and diagnosed |

  Bubble's built-in User is always a resource: when the source does not
  define it, the Model's synthesized User (built-in fields only) is used.

  ## Privacy modes

  The `:privacy` option chooses whether privacy rules are compiled:

    * `:omit` (the default) - no policy machinery at all: no authorizer,
      policies, field policies, privacy calculations, `*_for_privacy`
      relationships, relationship filters, keyed read, `Privacy` module or
      actor loads, and relationships stay sortable. Every resource has the
      default `:read`, `:create`, `:update` and `:destroy` actions and no
      authorization: any caller reads and writes every record and field.
      When the source has privacy rules (or cannot say what they are) the
      Project carries `:ash_privacy_omitted`. `Project.privacy` is `:omit`.
    * `:unverified` - the policies below are generated. They are **not
      verified against Bubble** ("Not verified" below): opt in only to
      inspect or test them, never to ship them to an app's users.

  `:omit` is the default because of the ship gate recorded on WTF-356:
  generated policies must not reach an app owner until the Ash policy
  advisories are cleared (WTF-397), the replay verification confirms the
  semantics they rest on (WTF-384/385) and aggregates have a lowering
  rule. A caller that forgets the option gets output without them.

  ## Privacy rules (WTF-356, `privacy: :unverified`)

  Each resource gets Ash policies (`Ash.Policy.Authorizer`) derived from
  its data type's privacy rules (`BubbleEx.Privacy`), as data in the
  Project (`policies`, `field_policies`, `calculations`, `extra_actions`,
  `privacy` on each `BubbleEx.Target.Ash.Resource`):

  | Bubble | Ash |
  |--------|-----|
  | a rule's condition | a private boolean calculation `privacy_rule_<name>` (`expr(...)` compiled fail-safe by `BubbleEx.Target.Ash.Expressions`); every check tests one |
  | direct view (a record reached by ID or through a reference) | the primary `:read` action, **keyed**: when authorized it is forbidden unless its filter selects by primary key or it loads a relationship (a separate policy, `authorize_if <namespace>.Privacy.KeyedRead`: a policy check, so it also holds for aggregates), so `Ash.get` and relationship loads work but listing and counting do not. `policy action(:read)` authorizes records of which the user may view some field (`view_all`, or a non-empty `view_fields`) |
  | `search_for` ("find this in searches") | a `:search` read action: `policy action(:search)`. "Do a search for" lowers to it |
  | `view_all` / `view_fields` | `field_policies` (`private_fields :hide`): one `field_policy` per group of attributes with the same grants (every attribute but the primary key); a hidden field reads as `%Ash.ForbiddenField{}`, and `filter_input` / `sort_input` see it as nil |
  | a reference whose ID attribute some users may not view | the `belongs_to` gets `filter expr(parent(<the checks authorizing the attribute>))` (or `filter expr(false)`), so loading, filtering and sorting through it reveal nothing more than the attribute; a private, ungated twin `<name>_for_privacy` (`privacy_relationships`) is what the privacy calculations and the actor loads read through |
  | `auto_binding` / `binding_fields` | an `:auto_bind` update accepting every bindable field: `policy action(:auto_bind)` (some auto-binding grant holds) and, per field, `policy [action(:auto_bind), changing_attributes([field])]` |
  | `view_attachments` | not enforceable in Ash (file fields hold URLs; the file store must enforce it): the grant is kept as data (`privacy.attachments`), diagnosed when a type with file fields does not grant it to everyone |
  | Data API (`exposed_api`, `create_api` / `modify_api` / `delete_api`) | out of scope unless requested (WTF-359 Q6): no API actions; the grants are kept as data (`privacy.data_api`), and an exposed type is diagnosed |
  | a backend workflow set to ignore privacy rules | not a policy: `authorization_bypasses` (with an index, see `map/3`) records that its lowered reads need `authorize?: false` |
  | writes by workflows | not governed by privacy rules; no policy authorizes `create`, `update` or `destroy`, so they are forbidden unless the caller bypasses authorization (fail-safe, for workflow lowering to decide) |

  **Union.** A user holds a permission when any rule whose condition they
  match grants it (checks are `authorize_if`, in rule order). The
  `everyone` rule applies to users no other rule matches; when it grants a
  permission, that grant becomes "no rule lacking the permission holds",
  one negated condition compiled by the same compiler (so its actor guards
  are kept; `:ash_policy_default_rule_negated`), or `always()` when no rule
  lacks it. Because a compiled condition is fail-safe only on the actor
  side (record-side emptiness is not verified), the negation also requires
  every record value the negated conditions read to be non-empty: it can
  only under-grant. Field lists union the same way.

  **Defaults.** A type the source lists without rules gets Bubble's public
  defaults: view all, search and attachments for everyone, no auto-binding,
  no Data API writes. A type whose rules the source cannot say (a live
  payload) denies every read (`:ash_privacy_rules_unavailable`).

  **Fail-safe.** Where this mapping is uncertain it denies: a rule whose condition
  does not compile (`:ash_expr_unsupported`, an unmapped reference, a
  missing condition) grants nothing (`:ash_policy_rule_denied`); an
  `everyone` grant that would need it negated is denied too
  (`:ash_policy_default_grant_denied`). A permission nobody holds is
  `forbid_if always()`. A read whose policy is false for the actor before
  running (e.g. logged out where every rule reads the actor) returns
  `Ash.Error.Forbidden`; Bubble shows nothing, so treat it as empty. What
  it does not decide: the compiled conditions' own record-side semantics
  (see "Not verified" below), and code. Field policies guard reads and
  `*_input` filters and sorts, not expressions written in code: a filter,
  sort or calculation built in code that references a field the actor may
  not view, or a `*_for_privacy` relationship, sees the real value. Lowered
  searches must reference only fields the searcher may view. Aggregates
  (count, min, max, sum, list, first, ...) over a field are not covered by
  field policies either (`:ash_policy_aggregates_unguarded`): generated
  code must not aggregate a field the actor may not view. Public
  relationships are generated `sortable?: false`: Ash applies field
  policies to a resource's own fields in `sort_input`, not to fields
  reached through a relationship. The private twins stay sortable
  (`sort_input` cannot name them), so a derived field sorts.
  The primary `:read`'s key requirement is a policy check
  (a policy, `authorize_if <namespace>.Privacy.KeyedRead`), so it holds for
  aggregate queries too.

  **Actor loads.** `Project.actor_loads` lists the User relationships the
  calculations read through `^actor(...)`. The rendered `<namespace>.Privacy`
  module's `load_actor/1` reads the actor afresh with them (through the
  ungated twins) (bypassing
  authorization, so the policies see current values); call it on every
  request and LiveView mount, so a role change is never served stale.

  **Not verified (safety gate).** The policies rest on Bubble semantics that
  the replay tests of WTF-384/385 have yet to confirm: empty-is-empty
  between two record fields, `yes/no is no` on an empty field, `doesn't
  contain` on an empty list, dangling references as empty, the `everyone`
  rule applying only to users no other rule matches, built-in fields
  (Created Date, Created By, ...) being hidden when `view_all` is false and
  they are not listed, a record with no visible field being unreadable by
  direct view, and absent permission flags meaning "not granted". Until
  then `Project.policies_verified` is `false`, every non-empty Project
  carries `:ash_policies_unverified`, the rendered policies carry a "NOT
  VERIFIED" header and `<namespace>.Privacy.verified?/0` returns false:
  **do not ship them to an app's users.** Ash is pinned at 3.33.11
  (WTF-397), past the policy advisories EEF-CVE-2026-86338, -82747 and
  -82746. On it, the field-policy gaps above (aggregates over hidden
  fields, sorts through a relationship), aggregates skipping a read
  action's `before_action` hooks and the gated-relationship under-grant
  are unchanged; re-check them on every bump.

  ## Names (WTF-339)

  Names are derived by `BubbleEx.Target.Ash.Naming` in Bubble ID order
  (built-in fields first) and recorded in the Project's name map. Pass a
  name map back as `names:` and its names are kept: a caption edit in
  Bubble does not rename generated code. See
  `BubbleEx.Target.Ash.Project` for the map's shape.

  ## Decisions (WTF-352, cut 1)

  `decisions` are the owner's decisions that apply to this snapshot,
  exactly as `BubbleEx.Decision.applicable/2` returns them:

      {:ok, %{findings: findings}} = BubbleEx.Findings.analyze(app, model: model, index: index)
      {:ok, resolved} = BubbleEx.Decision.resolve(records, findings, index: index, now: now)
      applied = BubbleEx.Decision.applicable(resolved, findings)

      {:ok, project} =
        BubbleEx.Target.Ash.map(model, applied,
          names: locked_names,
          decisions_sha256: BubbleEx.Decision.decisions_sha256(records)
        )

  **Input contract.** A list of `BubbleEx.Decision.Applied` structs, each
  with a unique key, from `resolve/3` and `applicable/2` over this
  snapshot's findings. `map/3` trusts that: it checks each entry's
  consistency against itself and the Model, but it cannot re-resolve the
  set (it has no findings or records), and it records `decisions_sha256`
  without verifying it. Anything else is `:invalid_input`, never ignored:

    * a `BubbleEx.Decision` record (unresolved: it may be stale, orphaned
      or superseded), or any other term
    * an applied finding whose key, finding ID, kind, subject, transform
      and proposal disagree, that lacks the finding's `proposal_sha256` and
      `basis_sha256`, or whose recorded `basis` differs from them (a stale
      decision: `applicable/2` never lists one)
    * an owner's decision on a transform Target.Ash does not apply yet
      (`derive_count`, `text_to_reference`, `derive_reverse_relationship`,
      `add_indexes`, `normalize_list_to_join`, `membership_policy`). A hint
      nobody decided (`automatic`) with such a transform is not an error:
      it is deferred, listed in `project.deferred` with an
      `:ash_decision_deferred` warning
    * an `automatic` entry that is not an undecided hint
    * a subject missing from the Model or deleted, or a proposal that no
      longer fits it (not a number field, a derivation that is not a path
      of references to the source's type, a source of another type): the
      Model is not the snapshot the findings came from
    * two transforms of one field, or a derived field whose source is
      derived too
    * with decisions, a missing or malformed `decisions_sha256:` option

  **Transforms.**

  | Transform | Ash |
  |-----------|-----|
  | `refine_number_type` | the attribute is `:integer` (bigint) or `:decimal` (numeric), per `proposal.to` (a `modify` sets it); an integral default becomes an integer, a non-integral one with `:integer` is an error |
  | `derive_from_related` | the attribute is dropped (no column) and becomes a public calculation of the same name, `calculate <name>, <source type>, expr(<relationship path>.<source attribute>)`: owned code that reads it still compiles; only writes to it break, and the decision removes those |
  | `rename` | overrides one name of the name map (below) |

  **Renames.** `slot` names what is renamed; the name must be valid for it
  and not reserved (`BubbleEx.Target.Ash.Naming.reserved/1`, Elixir and
  library namespaces, the generated `Privacy` module), must not be taken in
  its scope (another attribute, relationship, privacy calculation or
  column of the resource; another module or table), and the slot must fit
  the subject:

  | Slot | Subject | Renames |
  |------|---------|---------|
  | `module` | a data type, or a known API Connector type | the resource or typed-struct module |
  | `table` | a data type | the table, only before the name lock |
  | `attribute` | a stored field (not the unique ID, not a derived field) or an option-set attribute | the attribute (the `<rel>_id` attribute of a reference) or the enum's lookup key |
  | `relationship` | a reference to a mapped data type | the `belongs_to` |
  | `calculation` | a field derived by a decision of the same set | the calculation |
  | `enum_module` | an option set | the enum module |

  `endpoint_path` renames are an error: Target.Ash maps no endpoints.
  A name is **locked** when the `names:` map holds it (WTF-352 D5: the map
  stored at first publish). After the lock a rename changes Elixir names
  only: a renamed attribute keeps its column (the name map's `columns`,
  rendered `source: :column`), and a table rename is an error. The
  returned `project.names` holds the overrides, so it can be stored and
  passed back. Before the lock a rename may not take the name another
  definition is given (it would get a suffixed name, locked at first
  publish): that is an error listing the displaced names; rename both in
  one set to swap names.

  **Record.** `project.applied` lists every applied decision (key, kind,
  transform, subject, finding ID, parameters and the finding's hashes; no
  record IDs, which are audit data) and `project.applied_sha256` hashes
  it; `project.deferred` lists the deferred hints;
  `project.decisions_sha256` records the decision set; each
  applied finding adds an `:ash_decision_applied` diagnostic and each
  rename an `:ash_name_overridden` one. Both privacy modes apply the same
  decisions: with `privacy: :unverified` a derived field stands for the
  stored copy it replaces. It is covered by the field policies its field
  had, reads through the ungated `*_for_privacy` twin of a gated
  relationship (the related record's visibility never hid the copy), is
  readable by privacy-rule conditions, and is not auto-bindable.

  ## Diagnostics

  The Project's `diagnostics` are the Model's plus the mapping's own, stage
  `{:target, :ash}` (codes prefixed `ash_`, and the shared
  `external_type_*` codes), normalized.
  """

  alias BubbleEx.{CanonicalJson, Diagnostic, Error, Model}
  alias BubbleEx.Model.{DataType, ExternalType, Field, OptionSet, OptionValue, Structured, Type}

  alias BubbleEx.Target.Ash.{
    Attribute,
    CustomType,
    Decisions,
    EnumAttribute,
    EnumValue,
    Naming,
    Policies,
    Project,
    Relationship,
    Resource,
    TypedStruct
  }

  alias BubbleEx.Target.Ash.Enum, as: AshEnum

  @text [trim?: false, allow_empty?: true]
  @json {:module, "Types.JsonValue"}

  # Dependency pins for a project using the generated source: the versions
  # scripts/ash_compile_check.sh compiles and runs it against.
  # Ash policies need a SAT solver: PicoSAT, as Ash recommends.
  @versions [ash: "3.33.11", ash_postgres: "2.13.1"]
  @policy_versions [picosat_elixir: "0.2.3"]
  @privacy_modes [:omit, :unverified]
  @names_version 1

  # Built-in fields: fixed names, claimed before the defined fields.
  @system_names %{
    unique_id: "id",
    created_date: "created_date",
    modified_date: "modified_date",
    created_by: "creator",
    slug: "slug",
    email: "email"
  }

  @type privacy :: :omit | :unverified
  @type option ::
          {:names, map()}
          | {:index, BubbleEx.Index.t()}
          | {:privacy, privacy()}
          | {:decisions_sha256, String.t()}

  @doc """
  Dependency pins for a project that compiles the generated source, as Mix
  dependency tuples. With `privacy: :omit` (the default, as in `map/3`):
  `[{:ash, "== 3.33.11"}, {:ash_postgres, "== 2.13.1"}]`; with
  `privacy: :unverified` the policies also need Ash's SAT solver, PicoSAT:
  `{:picosat_elixir, "== 0.2.3"}` is appended. The generated modules need
  nothing else (Ecto and Postgrex come with AshPostgres).
  `scripts/ash_compile_check.sh` compiles and runs the generated source of
  each mode against exactly its versions. Any other `:privacy` value
  raises `ArgumentError`.

  Ash 3.33 refuses to compile a resource until the project sets
  `config :ash, default_string_length_count: :codepoints` (or `:mixed`).
  The generated source sets no string length constraints, so either
  choice leaves it unchanged; `:codepoints` is Ash's recommendation.
  """
  @spec versions([{:privacy, privacy()}]) :: [{atom(), String.t()}]
  def versions(opts \\ []) when is_list(opts) do
    pins =
      case Keyword.get(opts, :privacy, :omit) do
        :omit -> @versions
        :unverified -> @versions ++ @policy_versions
        other -> raise ArgumentError, "unknown privacy mode #{inspect(other)}"
      end

    Enum.map(pins, fn {app, version} -> {app, "== " <> version} end)
  end

  @doc """
  Maps `model` to a `BubbleEx.Target.Ash.Project`, applying `decisions`
  (`BubbleEx.Decision.Applied` structs from `BubbleEx.Decision.applicable/2`;
  see "Decisions" above).

  ## Options

    * `:privacy` - `:omit` (default) or `:unverified`; see "Privacy modes".
      Any other value is an `:invalid_input` error.
    * `:names` - a name map from an earlier mapping (`project.names`); its
      names are kept. An invalid map, or one giving two definitions in the
      same scope the same name, is an `:invalid_input` error.
    * `:index` - a `BubbleEx.Index` of the same app: with
      `privacy: :unverified`, its workflows that run ignoring privacy rules
      become `authorization_bypasses` (with `:omit` nothing is authorized,
      so there is nothing to bypass)
    * `:decisions_sha256` - `BubbleEx.Decision.decisions_sha256/1` of the
      decision records `decisions` were resolved from, recorded as
      `project.decisions_sha256`. Required when `decisions` is not empty
  """
  @spec map(Model.t(), list(), [option()]) :: {:ok, Project.t()} | {:error, Error.t()}
  def map(model, decisions \\ [], opts \\ [])

  def map(%Model{} = model, decisions, opts) when is_list(decisions) and is_list(opts) do
    with {:ok, privacy} <- validate_privacy(Keyword.get(opts, :privacy, :omit)),
         {:ok, names} <- validate_names(Keyword.get(opts, :names, %{})),
         {:ok, index} <- validate_index(Keyword.get(opts, :index)),
         {:ok, sha} <- validate_decisions_sha256(Keyword.get(opts, :decisions_sha256), decisions),
         {:ok, plan} <- Decisions.plan(model, decisions, names) do
      project = build(model, plan, index, privacy, sha)

      undisplaced(
        project,
        fn -> build(model, %{plan | names: names}, index, privacy, sha) end,
        plan
      )
    end
  catch
    {:name_conflict, error} -> {:error, error}
  end

  def map(_model, _decisions, _opts),
    do: {:error, Error.new(:invalid_input, "expected a BubbleEx.Model, a list and options")}

  # --- build ---------------------------------------------------------------------

  defp validate_privacy(mode) when mode in @privacy_modes, do: {:ok, mode}

  defp validate_privacy(mode) do
    {:error,
     Error.new(
       :invalid_input,
       "the :privacy option must be :omit or :unverified, got #{inspect(mode)}",
       %{privacy: inspect(mode)}
     )}
  end

  defp validate_index(nil), do: {:ok, nil}
  defp validate_index(%BubbleEx.Index{} = index), do: {:ok, index}

  defp validate_index(_),
    do: {:error, Error.new(:invalid_input, "the :index option must be a BubbleEx.Index")}

  defp validate_decisions_sha256(nil, []), do: {:ok, nil}

  defp validate_decisions_sha256(nil, _decisions) do
    {:error,
     Error.new(
       :invalid_input,
       "decisions need the :decisions_sha256 option (BubbleEx.Decision.decisions_sha256/1)"
     )}
  end

  defp validate_decisions_sha256(sha, _decisions) do
    if is_binary(sha) and sha =~ ~r/\A[0-9a-f]{64}\z/,
      do: {:ok, sha},
      else:
        {:error,
         Error.new(:invalid_input, "the :decisions_sha256 option must be a SHA-256 hex digest")}
  end

  # Renames before the lock must not move another definition's name:
  # compare with the mapping without them.
  defp undisplaced(project, _baseline, %{owners: []}), do: {:ok, project}

  defp undisplaced(project, baseline, plan) do
    with :ok <- Decisions.displaced(project.names, baseline.().names, plan.owners),
         do: {:ok, project}
  end

  # What was applied, pinned (records hold no audit metadata).
  defp applied_sha256(_applied, nil), do: nil

  defp applied_sha256(applied, _decisions_sha256),
    do:
      %Project{schema_version: 0, applied: applied}
      |> Project.to_map()
      |> Map.fetch!("applied")
      |> CanonicalJson.sha256()

  defp build(model, plan, index, privacy, decisions_sha256) do
    names = plan.names

    {types, type_diags} = live(model.data_types, &type_subject/1, "data_type")
    {sets, set_diags} = live(model.option_sets, &%{option_set: &1.id}, "option_set")

    ctx = %{
      model: model,
      types: Map.new(types, &{&1.id, &1}),
      sets: Map.new(sets, &{&1.id, &1}),
      externals: Map.new(model.external_types, &{&1.id, &1}),
      names: names
    }

    ctx = assign_modules(ctx, types, sets)
    ctx = Map.put(ctx, :pks, Map.new(types, &{&1.id, pk_name(&1, ctx.names)}))

    {enums, enum_diags, ctx} = map_all(sets, ctx, &enum/2)
    ctx = Map.put(ctx, :enum_values, Map.new(enums, &{&1.source.option_set, values(&1)}))

    {resources, resource_diags, ctx} = map_all(types, ctx, &resource/2)
    resources = Decisions.apply(resources, plan)
    {externals, external_diags, ctx} = map_all(ctx.external_order, ctx, &external/2)

    typed_structs = structured(resources) ++ externals

    project = %Project{
      schema_version: Project.schema_version(),
      bubble_id: model.bubble_id,
      resources: resources,
      enums: enums,
      types: custom_types(resources, typed_structs),
      typed_structs: typed_structs,
      names: ctx.names,
      privacy: privacy,
      applied: plan.applied,
      applied_sha256: applied_sha256(plan.applied, decisions_sha256),
      deferred: plan.deferred,
      decisions_sha256: decisions_sha256
    }

    {project, privacy_diags} = privacy(privacy, project, model, types, index)

    %{
      project
      | diagnostics:
          Diagnostic.normalize(
            model.diagnostics ++
              type_diags ++
              set_diags ++
              enum_diags ++
              resource_diags ++ external_diags ++ privacy_diags ++ plan.diagnostics
          )
    }
  end

  defp privacy(:unverified, project, model, _types, index) do
    {project, policy_diags} = Policies.apply(project, model)
    {bypasses, bypass_diags} = if index, do: Policies.bypasses(index), else: {[], []}
    {%{project | authorization_bypasses: bypasses}, policy_diags ++ bypass_diags}
  end

  # No policy machinery: the Project is the plain mapping. The rules the
  # source has (or may have) are noted, never silently dropped.
  defp privacy(:omit, project, _model, types, _index) do
    with_rules = for t <- types, t.privacy == :present, t.rules != [], do: t
    unavailable = for t <- types, t.privacy == :unavailable, do: t.id

    if with_rules == [] and unavailable == [] do
      {project, []}
    else
      rules = with_rules |> Enum.map(&length(&1.rules)) |> Enum.sum()

      diag =
        Diagnostic.new(
          :ash_privacy_omitted,
          "",
          "privacy rules were not compiled (privacy: :omit): #{rules} rules on " <>
            "#{length(with_rules)} data types" <>
            if(unavailable == [],
              do: "",
              else:
                ", and #{length(unavailable)} data types whose rules the source does not include"
            ) <>
            "; the generated resources have no authorization",
          target: :ash,
          details: %{
            types: Enum.map(with_rules, & &1.id),
            rules: rules,
            unavailable: unavailable
          }
        )

      {project, [diag]}
    end
  end

  defp map_all(items, ctx, fun) do
    {mapped, {diags, ctx}} =
      Enum.map_reduce(items, {[], ctx}, fn item, {diags, ctx} ->
        {mapped, item_diags, ctx} = fun.(item, ctx)
        {mapped, {[item_diags | diags], ctx}}
      end)

    {mapped, diags |> Enum.reverse() |> List.flatten(), ctx}
  end

  defp values(enum), do: MapSet.new(enum.values, & &1.value)

  defp type_subject(%DataType{id: id}), do: %{type: id}

  # Definitions that are emitted, and diagnostics for the deleted and
  # malformed ones, which are not.
  defp live(items, subject, kind) do
    Enum.reduce(Enum.reverse(items), {[], []}, fn item, {keep, diags} ->
      case omission(item, subject.(item), %{kind: kind}) do
        nil -> {[item | keep], diags}
        diag -> {keep, [diag | diags]}
      end
    end)
  end

  defp omission(%{raw: raw} = item, subject, details) when not is_nil(raw) do
    Diagnostic.new(
      :ash_malformed_omitted,
      item.path,
      "#{details.kind} #{inspect(item.id)} is malformed in the source and is not mapped",
      target: :ash,
      subject: subject,
      details: details
    )
  end

  defp omission(%{deleted: true} = item, subject, details) do
    Diagnostic.new(
      :ash_deleted_omitted,
      item.path,
      "deleted #{details.kind} #{inspect(item.id)} is omitted",
      target: :ash,
      subject: subject,
      details: details
    )
  end

  defp omission(_item, _subject, _details), do: nil

  # --- module names ------------------------------------------------------------

  defp assign_modules(ctx, types, sets) do
    ctx = assign_section(ctx, "resources", "module", types, &resource_base/1, :pascal, :module)
    ctx = assign_section(ctx, "resources", "table", types, &table_base(&1, ctx), :snake, :table)

    ctx = assign_section(ctx, "enums", "module", sets, &enum_base/1, :pascal, :none)
    order = external_order(ctx)
    ctx = Map.put(ctx, :external_order, order)
    assign_section(ctx, "external_types", "module", order, &external_base/1, :pascal, :none)
  end

  defp resource_base(type), do: Naming.base(:pascal, type.name, type.id, "Resource")
  defp enum_base(set), do: Naming.base(:pascal, set.name, set.id, "Enum")
  defp external_base(type), do: Naming.base(:pascal, type.name, type.id, "External")

  defp table_base(type, ctx),
    do: ctx.names |> get_in(["resources", type.id, "module"]) |> Naming.underscore()

  # Assigns `names[section][id][key]` for every item, in item order. Names
  # already in the map are kept and never given to another definition.
  defp assign_section(ctx, section, key, items, base, style, scope) do
    entries = Map.get(ctx.names, section, %{})
    locked = for {id, %{^key => name}} <- entries, into: %{}, do: {id, name}
    ids = Enum.map(items, & &1.id)
    check_unique!(locked, ids, "#{section} #{key}")

    {entries, _used} =
      Enum.reduce(items, {entries, MapSet.new(Map.values(locked))}, fn item, {entries, used} ->
        if Map.has_key?(locked, item.id) do
          {entries, used}
        else
          {name, used} = Naming.claim(base.(item), used, style, scope)
          entry = entries |> Map.get(item.id, %{}) |> Map.put(key, name)
          {Map.put(entries, item.id, entry), used}
        end
      end)

    %{ctx | names: Map.put(ctx.names, section, entries)}
  end

  defp check_unique!(locked, ids, scope) do
    live = Map.take(locked, ids)

    live
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.filter(fn {_name, ids} -> length(ids) > 1 end)
    |> Enum.sort()
    |> case do
      [] ->
        :ok

      [{name, ids} | _] ->
        throw(
          {:name_conflict,
           Error.new(:invalid_input, "the name map gives #{scope} #{inspect(name)} twice", %{
             name: name,
             ids: Enum.sort(ids)
           })}
        )
    end
  end

  defp module_of(ctx, section, id), do: get_in(ctx.names, [section, id, "module"])

  # --- API Connector types reached from emitted fields --------------------------

  # Known external types reachable from the live data types' live fields,
  # through edges that do not close a cycle. Every struct follows the
  # structs it uses (depth-first post-order from each root in Bubble ID
  # order).
  defp external_order(ctx) do
    roots =
      for type <- Map.values(ctx.types),
          %Field{deleted: false, raw: nil, type: %Type{kind: :external} = t} <- type.fields,
          known_external?(ctx, t.target),
          uniq: true,
          do: t.target

    {order, _seen} =
      roots
      |> Enum.sort()
      |> Enum.reduce({[], MapSet.new()}, &visit_external(&1, ctx, &2))

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(ctx.externals, &1))
  end

  defp visit_external(id, ctx, {order, seen}) do
    if MapSet.member?(seen, id) do
      {order, seen}
    else
      {order, seen} =
        for(
          field <- Map.fetch!(ctx.externals, id).fields,
          field.type.kind == :external and not field.cycle and
            known_external?(ctx, field.type.target),
          do: field.type.target
        )
        |> Enum.reduce({order, MapSet.put(seen, id)}, &visit_external(&1, ctx, &2))

      {[id | order], seen}
    end
  end

  defp known_external?(ctx, id) do
    case Map.get(ctx.externals, id) do
      %ExternalType{} = type -> ExternalType.known?(type)
      nil -> false
    end
  end

  # --- resources ---------------------------------------------------------------

  # The primary key's name, as `resource/2` will claim it: `_id` is claimed
  # first, so only the resource's locked names can be in the way.
  defp pk_name(type, names) do
    entry = get_in(names, ["resources", type.id])

    case get_in(entry, ["attributes", "_id"]) do
      nil -> "id" |> Naming.claim(scope(entry).used, :snake, :none) |> elem(0)
      name -> name
    end
  end

  defp resource(%DataType{} = type, ctx) do
    fields = type.system_fields ++ type.fields
    entry = get_in(ctx.names, ["resources", type.id])
    scope = scope(entry)
    check_unique!(scope.locked, scope_ids(fields), "attributes of #{type.id}")

    {items, {diags, _used, entry}} =
      Enum.map_reduce(fields, {[], scope.used, entry}, fn field, acc ->
        field_item(field, type, ctx, acc)
      end)

    items = List.flatten(items)
    attributes = for {:attribute, a} <- items, do: a
    relationships = for {:relationship, r} <- items, do: r

    attributes = primary_key(attributes, type, ctx) ++ attributes

    resource = %Resource{
      module: Map.fetch!(entry, "module"),
      table: Map.fetch!(entry, "table"),
      source: %{type: type.id},
      bubble_name: type.name,
      synthesized: type.synthesized,
      attributes: attributes,
      relationships: relationships,
      migration_types: migration_types(attributes)
    }

    names = put_in(ctx.names, ["resources", type.id], entry)
    {resource, Enum.reverse(diags), %{ctx | names: names}}
  end

  # AshPostgres migrates `{:array, :utc_datetime_usec}` as `{:array,
  # :utc_datetime}` (timestamp(0)[]), losing microseconds: state the type.
  defp migration_types(attributes) do
    for %Attribute{type: {:array, :utc_datetime_usec} = type, name: name} <- attributes,
        do: {name, type}
  end

  # The generated custom types the attributes use.
  defp custom_types(resources, typed_structs) do
    types =
      for r <- resources, a <- r.attributes, do: a.type

    types = types ++ for(t <- typed_structs, f <- t.fields, do: f.type)

    if Enum.any?(types, &(unwrap(&1) == @json)) do
      [
        %CustomType{
          module: elem(@json, 1),
          kind: :json_value,
          description:
            "Any JSON value (object, array, string, number, boolean or null), stored as jsonb. " <>
              "Holds Bubble values whose shape is not known, verbatim."
        }
      ]
    else
      []
    end
  end

  # The locked attribute and relationship names of a resource, and every
  # name they reserve.
  defp scope(entry) do
    attributes = Map.get(entry, "attributes", %{})
    relationships = Map.get(entry, "relationships", %{})

    locked =
      Enum.map(attributes, fn {id, name} -> {{:attribute, id}, name} end) ++
        Enum.map(relationships, fn {id, name} -> {{:relationship, id}, name} end)

    # Privacy calculation names (WTF-356) are claimed after the fields, but
    # a locked one is never given to a field.
    privacy = Map.values(Map.get(entry, "privacy_rules", %{}))
    privacy = privacy ++ Map.values(Map.get(entry, "privacy_relationships", %{}))

    # A renamed attribute's column is never given to another attribute.
    columns = Map.values(Map.get(entry, "columns", %{}))

    %{
      locked: Map.new(locked),
      used: MapSet.new(Map.values(attributes) ++ Map.values(relationships) ++ privacy ++ columns)
    }
  end

  defp scope_ids(fields),
    do: Enum.flat_map(fields, &[{:attribute, &1.id}, {:relationship, &1.id}])

  # The Bubble `_id` is the primary key; every record has one.
  defp primary_key(attributes, type, ctx) do
    if Enum.any?(attributes, & &1.primary_key?) do
      []
    else
      [pk_attribute(Map.fetch!(ctx.pks, type.id), %{type: type.id, field: "_id"}, "text")]
    end
  end

  defp pk_attribute(name, source, bubble_type) do
    %Attribute{
      name: name,
      type: :string,
      constraints: @text,
      primary_key?: true,
      allow_nil?: false,
      source: source,
      bubble_type: bubble_type
    }
  end

  defp field_item(%Field{} = field, type, _ctx, {diags, used, entry})
       when field.deleted or not is_nil(field.raw) do
    diag = omission(field, %{type: type.id, field: field.id}, %{kind: "field"})
    {[], {[diag | diags], used, entry}}
  end

  defp field_item(%Field{id: "_id"} = field, type, _ctx, {diags, used, entry}) do
    {name, used, entry} = name_for(entry, "attributes", field.id, "id", used, :none)
    attribute = pk_attribute(name, %{type: type.id, field: field.id}, field.type.source)
    {[{:attribute, attribute}], {diags, used, entry}}
  end

  defp field_item(%Field{type: %Type{kind: :ref, cardinality: :one} = t} = field, type, ctx, acc)
       when is_map_key(ctx.types, t.target) do
    {diags, used, entry} = acc
    subject = %{type: type.id, field: field.id}
    scope = if field.system, do: :none, else: :attribute
    base = field_base(field)
    {rel, used, entry} = name_for(entry, "relationships", field.id, base, used, scope)
    {attr, used, entry} = name_for(entry, "attributes", field.id, rel <> "_id", used, :none)

    attribute = %Attribute{
      name: attr,
      type: :string,
      constraints: @text,
      source: subject,
      bubble_type: t.source,
      references: %{target: t.target, cardinality: :one},
      column: column(entry, field.id, attr)
    }

    relationship = %Relationship{
      kind: :belongs_to,
      name: rel,
      destination: module_of(ctx, "resources", t.target),
      source_attribute: attr,
      destination_attribute: Map.fetch!(ctx.pks, t.target),
      source: subject
    }

    # A reference's default is not mapped: diagnosed, never dropped silently.
    {_default, default_diags} = default(field, ctx, subject)
    items = [{:attribute, attribute}, {:relationship, relationship}]
    {items, {Enum.reverse(default_diags) ++ diags, used, entry}}
  end

  defp field_item(%Field{} = field, type, ctx, {diags, used, entry}) do
    subject = %{type: type.id, field: field.id}
    scope = if field.system, do: :none, else: :attribute
    {name, used, entry} = name_for(entry, "attributes", field.id, field_base(field), used, scope)
    {ash_type, constraints, type_diags} = content(field.type, ctx, subject, field.path)
    {default, default_diags} = default(field, ctx, subject)

    attribute = %Attribute{
      name: name,
      type: ash_type,
      constraints: constraints,
      default: default,
      source: subject,
      bubble_type: field.type.source,
      references: references(field.type),
      column: column(entry, field.id, name)
    }

    {[{:attribute, attribute}], {Enum.reverse(type_diags ++ default_diags) ++ diags, used, entry}}
  end

  # The column of a renamed attribute (the name map's `columns`), when it
  # differs from the attribute's name.
  defp column(entry, id, name) do
    case get_in(entry, ["columns", id]) do
      ^name -> nil
      column -> column
    end
  end

  defp field_base(%Field{system: nil} = field),
    do: Naming.base(:snake, field.name, field.id, "field")

  defp field_base(%Field{system: role}), do: Map.fetch!(@system_names, role)

  defp references(%Type{kind: :ref, target: target, cardinality: c}) when c in [:one, :many],
    do: %{target: target, cardinality: c}

  defp references(_type), do: nil

  # The locked name of `id` in `names[kind]`, or a newly claimed one.
  defp name_for(entry, kind, id, base, used, scope) do
    case get_in(entry, [kind, id]) do
      nil ->
        {name, used} = Naming.claim(base, used, :snake, scope)
        entry = Map.update(entry, kind, %{id => name}, &Map.put(&1, id, name))
        {name, used, entry}

      name ->
        {name, used, entry}
    end
  end

  # --- content types -------------------------------------------------------------

  # The Ash type and constraints for a Model content type, and diagnostics
  # for what is lost.
  defp content(%Type{cardinality: :unknown} = type, _ctx, subject, path),
    do: {@json, [], [opaque(type, subject, path, "its list-ness is unknown")]}

  # A list of values with no usable type is one JSON value (a JSON array).
  defp content(%Type{cardinality: :many} = type, ctx, subject, path) do
    case content(%{type | cardinality: :one}, ctx, subject, path) do
      {@json, [], diags} ->
        {@json, [], diags}

      {base, constraints, diags} ->
        constraints = if constraints == [], do: [], else: [items: constraints]
        {{:array, base}, constraints, diags}
    end
  end

  defp content(%Type{kind: :scalar, base: base}, _ctx, _subject, _path),
    do: {scalar(base), if(base == :text, do: @text, else: []), []}

  defp content(%Type{kind: :file_ref}, _ctx, _subject, _path), do: {:string, @text, []}

  # Bubble documents a date interval as "the difference between two dates,
  # expressed as milliseconds"
  # (https://manual.bubble.io/help-guides/data/the-database/data-types-and-fields.md).
  defp content(%Type{kind: :structured, base: :date_interval} = type, _ctx, subject, path),
    do: {:float, [], [date_interval(type, subject, path)]}

  defp content(%Type{kind: :structured, base: base} = type, _ctx, subject, path) do
    case Type.components(type) do
      [] -> {@json, [], [opaque(type, subject, path, "Bubble's #{base} shape is not modeled")]}
      _ -> {{:module, structured_module(base)}, [], []}
    end
  end

  defp content(%Type{kind: :ref} = type, ctx, subject, path) do
    if Map.has_key?(ctx.types, type.target),
      do: {:string, @text, []},
      else: {:string, @text, [unresolved(type, ctx, subject, path)]}
  end

  defp content(%Type{kind: :option} = type, ctx, subject, path) do
    if Map.has_key?(ctx.sets, type.target),
      do: {{:module, "Enums." <> module_of(ctx, "enums", type.target)}, [], []},
      else: {:string, @text, [unresolved(type, ctx, subject, path)]}
  end

  defp content(%Type{kind: :external} = type, ctx, subject, path) do
    case module_of(ctx, "external_types", type.target) do
      nil when is_map_key(subject, :external_type) ->
        {@json, [], [external_diag(:external_type_unresolved_nested, type, subject, path)]}

      nil ->
        {@json, [], [external_diag(:external_type_unresolved_root, type, subject, path)]}

      module ->
        {{:module, "External." <> module}, [], []}
    end
  end

  defp content(%Type{} = type, _ctx, subject, path),
    do: {@json, [], [opaque(type, subject, path, "the value has no usable type")]}

  defp scalar(:text), do: :string
  defp scalar(:number), do: :float
  defp scalar(:boolean), do: :boolean
  defp scalar(:date), do: :utc_datetime_usec
  defp scalar(:date_unix), do: :integer

  defp structured_module(base), do: "Types." <> Macro.camelize(Atom.to_string(base))

  defp opaque(type, subject, path, why) do
    Diagnostic.new(
      :ash_opaque_value,
      path,
      "#{describe(subject)} is kept as any JSON value (#{elem(@json, 1)}): #{why}",
      target: :ash,
      subject: subject,
      details: %{
        kind: type.kind,
        base: type.base,
        cardinality: type.cardinality,
        source: source_text(type.source),
        fallback: :json
      }
    )
  end

  defp date_interval(type, subject, path) do
    Diagnostic.new(
      :ash_date_interval_as_number,
      path,
      "#{describe(subject)} is a date interval, mapped to :float milliseconds",
      target: :ash,
      subject: subject,
      details: %{cardinality: type.cardinality, unit: :millisecond, fallback: :float}
    )
  end

  defp unresolved(type, ctx, subject, path) do
    {kind, known} =
      if type.kind == :ref,
        do: {"data_type", ctx.model.data_types},
        else: {"option_set", ctx.model.option_sets}

    reason = if Enum.any?(known, &(&1.id == type.target)), do: "omitted", else: "missing"

    Diagnostic.new(
      :ash_unresolved_reference,
      path,
      "#{describe(subject)} references #{String.replace(kind, "_", " ")} " <>
        "#{inspect(type.target)} (#{reason}); its Bubble IDs are kept as strings",
      target: :ash,
      subject: subject,
      details: %{
        target: type.target,
        target_kind: kind,
        reason: reason,
        cardinality: type.cardinality,
        fallback: :string
      }
    )
  end

  defp external_diag(code, type, subject, path) do
    Diagnostic.new(
      code,
      path,
      "#{describe(subject)} is rendered as JSON: external type #{inspect(type.target)} has no known shape",
      target: :ash,
      subject: subject,
      details: %{external_type: type.target, cardinality: type.cardinality, fallback: :json}
    )
  end

  defp describe(subject) do
    owner = subject[:type] || subject[:external_type] || subject[:option_set]
    "#{owner}.#{subject[:field]}"
  end

  defp source_text(source) when is_binary(source), do: source
  defp source_text(source), do: inspect(source)

  # --- defaults ------------------------------------------------------------------

  defp default(%Field{default: nil}, _ctx, _subject), do: {nil, []}

  defp default(%Field{default: value, type: type} = field, ctx, subject) do
    case default_value(type, value, ctx) do
      {:ok, value} ->
        {{:value, value}, []}

      :error ->
        diag =
          Diagnostic.new(
            :ash_default_unmapped,
            field.path,
            "#{describe(subject)}: the default #{inspect(value)} has no Ash equivalent and is omitted",
            target: :ash,
            subject: subject,
            details: %{default: value, source: source_text(type.source)}
          )

        {nil, [diag]}
    end
  end

  defp default_value(%Type{kind: :ref}, _value, _ctx), do: :error

  defp default_value(%Type{cardinality: :one} = type, value, ctx) do
    case {type.kind, type.base, value} do
      {:scalar, :text, v} when is_binary(v) -> {:ok, v}
      {:scalar, :number, v} when is_number(v) -> {:ok, v * 1.0}
      {:scalar, :boolean, v} when is_boolean(v) -> {:ok, v}
      {:scalar, :date, v} when is_binary(v) -> iso_datetime(v)
      {:file_ref, _, v} when is_binary(v) -> {:ok, v}
      {:option, _, v} when is_binary(v) -> enum_default(ctx, type.target, v)
      _ -> :error
    end
  end

  defp default_value(_type, _value, _ctx), do: :error

  # A fixed ISO 8601 timestamp with an offset, at microsecond precision.
  defp iso_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} ->
        {us, _precision} = datetime.microsecond
        {:ok, %{datetime | microsecond: {us, 6}}}

      {:error, _} ->
        :error
    end
  end

  defp enum_default(ctx, set, value) do
    if MapSet.member?(Map.get(ctx.enum_values, set, MapSet.new()), value),
      do: {:ok, value},
      else: :error
  end

  # --- enums ---------------------------------------------------------------------

  defp enum(%OptionSet{} = set, ctx) do
    entry = get_in(ctx.names, ["enums", set.id])
    locked = Map.get(entry, "attributes", %{})
    check_unique!(locked, Enum.map(set.attributes, & &1.id), "attributes of #{set.id}")
    subject = %{option_set: set.id}

    {attrs, attr_diags} =
      live(set.attributes, &Map.put(subject, :field, &1.id), "option_set_attribute")

    {attrs, {entry, _used}} =
      Enum.map_reduce(attrs, {entry, MapSet.new(Map.values(locked))}, fn attr, {entry, used} ->
        base = Naming.base(:snake, attr.name, attr.id, "attribute")
        {name, used, entry} = name_for(entry, "attributes", attr.id, base, used, :field)
        {{attr, name}, {entry, used}}
      end)

    {values, value_diags} = enum_values(set, attrs)

    enum = %AshEnum{
      module: "Enums." <> Map.fetch!(entry, "module"),
      source: subject,
      bubble_name: set.name,
      values: values,
      attributes:
        Enum.map(attrs, fn {attr, name} ->
          %EnumAttribute{
            name: name,
            bubble_type: attr.type.source,
            source: %{option_set: set.id, field: attr.id}
          }
        end)
    }

    ctx = %{ctx | names: put_in(ctx.names, ["enums", set.id], entry)}
    {enum, attr_diags ++ value_diags, ctx}
  end

  defp enum_values(set, attrs) do
    {values, {diags, _seen}} =
      Enum.flat_map_reduce(set.values, {[], MapSet.new()}, fn value, {diags, seen} ->
        subject = %{option_set: set.id}

        case omission(value, subject, %{kind: "option_value", value: value.id}) do
          nil -> enum_value(value, set, attrs, diags, seen)
          diag -> {[], {[diag | diags], seen}}
        end
      end)

    {values, Enum.reverse(diags)}
  end

  defp enum_value(%OptionValue{} = value, set, attrs, diags, seen) do
    if MapSet.member?(seen, value.key) do
      diag =
        Diagnostic.new(
          :ash_duplicate_enum_value,
          value.path,
          "option value #{inspect(value.id)} repeats the key #{inspect(value.key)} and is omitted from the enum",
          target: :ash,
          subject: %{option_set: set.id},
          details: %{value: value.id, key: value.key}
        )

      {[], {[diag | diags], seen}}
    else
      mapped = %EnumValue{
        value: value.key,
        label: value.name,
        source: %{option_set: set.id, value: value.id},
        attributes: Map.new(attrs, fn {attr, name} -> {name, value.attributes[attr.id]} end)
      }

      {[mapped], {diags, MapSet.put(seen, value.key)}}
    end
  end

  # --- typed structs -------------------------------------------------------------

  defp structured(resources) do
    used =
      for resource <- resources,
          attribute <- resource.attributes,
          {:module, "Types." <> _ = module} <- [unwrap(attribute.type)],
          into: MapSet.new(),
          do: module

    for entry <- Structured.all(),
        entry.components != [],
        module = structured_module(entry.base),
        MapSet.member?(used, module) do
      %TypedStruct{
        module: module,
        source: %{structured: entry.base},
        description: structured_description(entry),
        metadata: if(entry.bounds, do: %{bounds: entry.bounds}, else: %{}),
        fields:
          Enum.map(entry.components, fn component ->
            type = %Type{kind: :scalar, base: component.base, cardinality: :one, source: nil}
            {ash_type, constraints, []} = content(type, %{}, %{}, "")

            %Attribute{
              name: Naming.base(:snake, component.id, nil, "part"),
              type: ash_type,
              constraints: constraints,
              source: %{structured: entry.base, component: component.id},
              bubble_type: Atom.to_string(component.base)
            }
          end)
      }
    end
  end

  defp unwrap({:array, type}), do: unwrap(type)
  defp unwrap(type), do: type

  defp structured_description(%{base: base, bounds: nil}),
    do: "A Bubble #{String.replace(Atom.to_string(base), "_", " ")}."

  defp structured_description(%{base: base}) do
    "A Bubble #{String.replace(Atom.to_string(base), "_", " ")}. Whether each end is " <>
      "inclusive is not verified against Bubble."
  end

  defp external(%ExternalType{} = type, ctx) do
    entry = get_in(ctx.names, ["external_types", type.id])
    locked = Map.get(entry, "fields", %{})
    check_unique!(locked, Enum.map(type.fields, & &1.id), "fields of #{type.id}")

    {fields, {diags, entry, _used}} =
      Enum.map_reduce(type.fields, {[], entry, MapSet.new(Map.values(locked))}, fn field,
                                                                                   {diags, entry,
                                                                                    used} ->
        subject = %{external_type: type.id, field: field.id}
        base = Naming.base(:snake, field.name, field.id, "field")
        {name, used, entry} = name_for(entry, "fields", field.id, base, used, :field)
        path = type.path || ""
        {ash_type, constraints, field_diags} = external_field(field, ctx, subject, path)

        attribute = %Attribute{
          name: name,
          type: ash_type,
          constraints: constraints,
          source: subject,
          bubble_type: source_text(field.type.source)
        }

        {attribute, {Enum.reverse(field_diags) ++ diags, entry, used}}
      end)

    struct = %TypedStruct{
      module: "External." <> Map.fetch!(entry, "module"),
      source: %{external_type: type.id},
      bubble_name: type.name,
      fields: fields
    }

    ctx = %{ctx | names: put_in(ctx.names, ["external_types", type.id], entry)}
    {struct, Enum.reverse(diags), ctx}
  end

  defp external_field(%{cycle: true} = field, _ctx, subject, path) do
    diag =
      Diagnostic.new(
        :external_type_cycle_edge,
        path,
        "#{describe(subject)} closes a cycle of external types and is rendered as JSON",
        target: :ash,
        subject: subject,
        details: %{
          external_type: field.type.target,
          cardinality: field.type.cardinality,
          fallback: :json
        }
      )

    {@json, [], [diag]}
  end

  defp external_field(field, ctx, subject, path), do: content(field.type, ctx, subject, path)

  # --- the name map --------------------------------------------------------------

  # Each member: its key, style (or `:names` for a map of snake names) and
  # naming scope, whose reserved words a supplied name may not use.
  @sections %{
    "resources" => [
      {"module", :pascal, :module},
      {"table", :snake, :table},
      {"attributes", :names, :attribute},
      {"relationships", :names, :attribute},
      {"privacy_rules", :names, :attribute},
      {"privacy_relationships", :names, :attribute},
      {"columns", :names, :attribute}
    ],
    "enums" => [{"module", :pascal, :none}, {"attributes", :names, :field}],
    "external_types" => [{"module", :pascal, :none}, {"fields", :names, :field}]
  }

  defp validate_names(names) when is_map(names) and not is_struct(names) do
    with :ok <- check_version(Map.get(names, "version", @names_version)),
         :ok <- check_sections(names) do
      {:ok, Map.put(names, "version", @names_version)}
    end
  end

  defp validate_names(_), do: invalid_names("the name map must be a map")

  defp check_version(@names_version), do: :ok
  defp check_version(v), do: invalid_names("unsupported name map version #{inspect(v)}")

  defp check_sections(names) do
    Enum.reduce_while(@sections, :ok, fn {section, keys}, :ok ->
      case check_section(section, Map.get(names, section, %{}), keys) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_section(section, entries, _keys) when not is_map(entries),
    do: invalid_names("#{section} must be a map")

  defp check_section(section, entries, keys) do
    case Enum.find(entries, &(not valid_entry?(&1, keys))) do
      nil -> :ok
      {id, _} -> invalid_names("invalid #{section} entry #{inspect(id)}")
    end
  end

  defp valid_entry?({id, entry}, keys) when is_binary(id) and is_map(entry),
    do: Enum.all?(keys, &valid_member?(entry, &1))

  defp valid_entry?(_entry, _keys), do: false

  defp valid_member?(entry, {key, :names, scope}),
    do: valid_names?(Map.get(entry, key, %{}), scope)

  defp valid_member?(entry, {key, style, scope}),
    do: not Map.has_key?(entry, key) or valid_name?(style, entry[key], scope)

  defp valid_names?(map, scope) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and valid_locked?(k, v, scope) end)

  defp valid_names?(_, _scope), do: false

  # The primary key (Bubble `_id`) is the one attribute named `id`.
  defp valid_locked?("_id", "id", :attribute), do: true
  defp valid_locked?(_id, name, scope), do: valid_name?(:snake, name, scope)

  defp valid_name?(style, name, scope),
    do: Naming.valid?(style, name) and name not in Naming.reserved(scope)

  defp invalid_names(message), do: {:error, Error.new(:invalid_input, message)}
end
