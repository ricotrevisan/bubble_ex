defmodule BubbleEx.Target.Ash.Project do
  @moduledoc """
  An Ash project described as plain data: what `BubbleEx.Target.Ash.map/3`
  derives from a `BubbleEx.Model`, and all a renderer needs to print it.
  There is no Ash dependency; nothing here is `use Ash`.

    * `resources` - `BubbleEx.Target.Ash.Resource`s (one per data type), in
      Bubble ID order
    * `enums` - `BubbleEx.Target.Ash.Enum`s (one per option set), in Bubble
      ID order
    * `types` - `BubbleEx.Target.Ash.CustomType`s: generated Ash types
      such as `Types.JsonValue` (any JSON value), present when used
    * `typed_structs` - `BubbleEx.Target.Ash.TypedStruct`s (structured
      Bubble values, then API Connector types), ordered so every struct
      follows the structs its fields use
    * `names` - the per-app name map (see "Name map"), updated with every
      name this mapping derived
    * `privacy` - the privacy mode it was mapped with (`:omit`, the
      default, or `:unverified`; see `BubbleEx.Target.Ash`, "Privacy
      modes"). With `:omit` no resource has policies, field policies,
      privacy calculations, extra actions or `privacy_relationships`, and
      `actor_loads` and `authorization_bypasses` are empty
    * `policies_verified` - always `false`: the generated policies (each
      resource's `policies`, `field_policies` and privacy `calculations`)
      are **not verified against Bubble**. They must not be shipped to an
      app's users before the replay verification of WTF-384/385 confirms
      the Bubble semantics they rest on (see `BubbleEx.Target.Ash`,
      "Privacy rules"). Nothing sets it to `true` yet.
    * `actor_loads` - relationship paths of the User resource that the
      privacy calculations read through `^actor(...)` (e.g.
      `[["active_membership"]]`), sorted: the actor must be loaded with
      them, afresh, on every request and LiveView mount
    * `authorization_bypasses` - `BubbleEx.Target.Ash.Bypass`es: workflows
      that run ignoring privacy rules in Bubble and so need an explicit
      authorization bypass (`authorize?: false`) when they are lowered;
      empty unless an index was given to `BubbleEx.Target.Ash.map/3`
    * `applied` - the owner decisions applied (see `BubbleEx.Target.Ash`,
      "Decisions"), sorted by key: `%{key, kind, transform, subject, target,
      decision_id, finding_id, automatic, params, proposal_sha256,
      basis_sha256}`, so a manifest, plan or verification can cite them
    * `decisions_sha256` - `BubbleEx.Decision.decisions_sha256/1` of the
      decision set the applied decisions come from, as passed to
      `BubbleEx.Target.Ash.map/3`; nil when mapped without decisions
    * `diagnostics` - the Model's diagnostics plus the mapping's (stage
      `{:target, :ash}`), normalized

  ## Modules and types

  Module names are relative to a root namespace the renderer chooses:
  `"Task"`, `"Enums.Status"`, `"Types.GeographicAddress"`,
  `"External.Obj"`. An Ash type is `t:type/0`: a built-in type atom
  (`:string`, `:float`, …), `{:array, type}`, or `{:module, relative_name}`
  for a generated enum or typed struct.

  ## Name map

  A JSON-stable map (string keys) from Bubble IDs to generated names. Pass
  it back as `names:` to `BubbleEx.Target.Ash.map/3` and every name in it is
  kept, so later caption edits in Bubble do not rename code; new definitions
  get new names that avoid the locked ones. Entries whose definition is gone
  are kept.

  `columns` lists the attributes whose column is not their name: an
  attribute renamed after the name lock (an owner `rename` decision) keeps
  its column, rendered as the attribute's `source:`.

      %{
        "version" => 1,
        "resources" => %{
          "task" => %{
            "module" => "Task",
            "table" => "task",
            "attributes" => %{"_id" => "id", "title_text" => "title", "project_custom_project" => "project_id"},
            "relationships" => %{"project_custom_project" => "project"},
            "privacy_rules" => %{"owner_" => "privacy_rule_owner"},
            "privacy_relationships" => %{"project_custom_project" => "project_for_privacy"},
            "columns" => %{"title_text" => "name"}
          }
        },
        "enums" => %{"status" => %{"module" => "Status", "attributes" => %{"color" => "color"}}},
        "external_types" => %{"api.…" => %{"module" => "Obj", "fields" => %{"name" => "name"}}}
      }
  """

  alias BubbleEx.{CanonicalJson, Diagnostic}
  alias BubbleEx.Target.Ash.{Bypass, CustomType, Resource, TypedStruct}

  @schema_version 4

  @enforce_keys [:schema_version]
  defstruct [
    :schema_version,
    :bubble_id,
    resources: [],
    enums: [],
    types: [],
    typed_structs: [],
    names: %{},
    privacy: :omit,
    policies_verified: false,
    actor_loads: [],
    authorization_bypasses: [],
    applied: [],
    decisions_sha256: nil,
    diagnostics: []
  ]

  @type type :: atom() | {:array, type()} | {:module, String.t()}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          bubble_id: String.t() | nil,
          resources: [Resource.t()],
          enums: [BubbleEx.Target.Ash.Enum.t()],
          types: [CustomType.t()],
          typed_structs: [TypedStruct.t()],
          names: map(),
          privacy: :omit | :unverified,
          policies_verified: false,
          actor_loads: [[String.t()]],
          authorization_bypasses: [Bypass.t()],
          applied: [map()],
          decisions_sha256: String.t() | nil,
          diagnostics: [Diagnostic.t()]
        }

  @doc "The Project format version; it changes whenever `to_map/1` does."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  JSON form: string keys and JSON values only. Atoms become strings, tuples
  lists (`{:array, :string}` is `["array", "string"]`) and a `DateTime` its
  ISO 8601 text.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = project), do: json(project)

  @doc "Canonical JSON text of `to_map/1`: byte-identical for the same Project."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = project), do: project |> to_map() |> CanonicalJson.encode()

  defp json(%Diagnostic{} = d), do: Diagnostic.to_map(d)
  defp json(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp json(%_{} = struct), do: struct |> Map.from_struct() |> json()
  defp json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json()
  defp json(value) when value in [true, false, nil], do: value
  defp json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json(value), do: value

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: k

  @doc """
  Aggregate counts, with string keys (for reports and count snapshots):
  resources, attributes by Ash type (`enum`, `typed_struct` and `json_value`
  for generated modules), relationships by kind, database references by mode,
  enums and their values, typed structs by source, derived calculations,
  applied decisions by transform, privacy (see `privacy_summary/1`) and
  diagnostics by code.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = project) do
    attributes = Enum.flat_map(project.resources, & &1.attributes)
    relationships = Enum.flat_map(project.resources, & &1.relationships)
    kinds = module_kinds(project)

    %{
      "resources" => length(project.resources),
      "synthesized_resources" => Enum.count(project.resources, & &1.synthesized),
      "attributes" => length(attributes),
      "attributes_by_type" => frequencies(attributes, &type_key(&1.type, kinds)),
      "relationships" => frequencies(relationships, &Atom.to_string(&1.kind)),
      "db_references" => frequencies(relationships, &Atom.to_string(&1.db_reference)),
      "enums" => length(project.enums),
      "enum_values" => project.enums |> Enum.map(&length(&1.values)) |> Enum.sum(),
      "typed_structs" => frequencies(project.typed_structs, &source_key(&1.source)),
      "derived_calculations" =>
        project.resources
        |> Enum.flat_map(& &1.calculations)
        |> Enum.count(&(&1.kind == :derived)),
      "applied" => frequencies(project.applied, &Atom.to_string(&1.transform)),
      "privacy" => privacy_summary(project),
      "diagnostics" => frequencies(project.diagnostics, &Atom.to_string(&1.code))
    }
  end

  @doc """
  Privacy counts, with string keys: resources by privacy source
  (`rules`, `public_default`, `unavailable`), rules by outcome (`compiled`,
  `denied`: a condition that does not compile, so the rule grants nothing),
  policies, their checks by test, field policies, privacy calculations,
  gated relationships (each with a private twin),
  auto-binding actions, actor loads and authorization bypasses.
  """
  @spec privacy_summary(t()) :: map()
  def privacy_summary(%__MODULE__{} = project) do
    # nil with privacy: :omit
    privacy = for r <- project.resources, r.privacy, do: r.privacy
    policies = Enum.flat_map(project.resources, & &1.policies)
    field_policies = Enum.flat_map(project.resources, & &1.field_policies)
    checks = Enum.flat_map(policies ++ field_policies, & &1.checks)

    %{
      "resources" => frequencies(privacy, &Atom.to_string(&1.source)),
      "rules" => %{
        "compiled" => privacy |> Enum.map(&length(&1.compiled_rules)) |> Enum.sum(),
        "denied" => privacy |> Enum.map(&length(&1.denied_rules)) |> Enum.sum()
      },
      "policies" => length(policies),
      "field_policies" => length(field_policies),
      "checks" => frequencies(checks, &check_key/1),
      "calculations" =>
        project.resources
        |> Enum.flat_map(& &1.calculations)
        |> Enum.count(&(&1.kind == :privacy)),
      "gated_relationships" =>
        project.resources |> Enum.map(&length(&1.privacy_relationships)) |> Enum.sum(),
      "auto_bind_actions" =>
        Enum.count(project.resources, fn r ->
          Enum.any?(r.extra_actions, &(&1.name == "auto_bind"))
        end),
      "actor_loads" => length(project.actor_loads),
      "authorization_bypasses" => length(project.authorization_bypasses)
    }
  end

  defp check_key(%{kind: kind, test: :always}), do: "#{kind} always"
  defp check_key(%{kind: kind, test: :keyed}), do: "#{kind} keyed"
  defp check_key(%{kind: kind, test: {:calculation, _}}), do: "#{kind} calculation"

  defp module_kinds(project) do
    Map.new(project.enums, &{&1.module, "enum"})
    |> Map.merge(Map.new(project.types, &{&1.module, Atom.to_string(&1.kind)}))
    |> Map.merge(Map.new(project.typed_structs, &{&1.module, "typed_struct"}))
  end

  defp type_key({:array, type}, kinds), do: "array " <> type_key(type, kinds)
  defp type_key({:module, module}, kinds), do: Map.get(kinds, module, "module")
  defp type_key(atom, _kinds), do: Atom.to_string(atom)

  defp source_key(%{structured: _}), do: "structured"
  defp source_key(%{external_type: _}), do: "external"

  defp frequencies(list, fun), do: list |> Enum.frequencies_by(fun) |> Map.new()
end

defmodule BubbleEx.Target.Ash.Resource do
  @moduledoc """
  An `Ash.Resource` with the AshPostgres data layer, for one Bubble data
  type.

    * `module` - relative module name; `table` - the PostgreSQL table
    * `source` - `%{type: bubble_id}`; `bubble_name` - the display name
    * `synthesized` - Bubble's built-in User, absent from the source
    * `attributes` - `BubbleEx.Target.Ash.Attribute`s: the primary key,
      then Bubble's built-in fields, then the defined fields (Bubble ID
      order)
    * `relationships` - `BubbleEx.Target.Ash.Relationship`s
    * `identities` - `BubbleEx.Target.Ash.Identity`s
    * `migration_types` - `{attribute_name, type}` overrides of the
      AshPostgres migration type (`postgres do migration_types …`), e.g.
      `{:array, :utc_datetime_usec}`, which AshPostgres would otherwise
      migrate at second precision
    * `actions` - the `defaults` action list, e.g.
      `[:read, :destroy, create: :*, update: :*]`
    * `extra_actions` - `BubbleEx.Target.Ash.Action`s beyond the defaults
      (the `:search` read and the `:auto_bind` update of privacy rules)
    * `calculations` - `BubbleEx.Target.Ash.Calculation`s: fields derived
      by an owner decision (public, in attribute order), then the private
      boolean calculations the policies test (one per privacy rule, one
      per "everyone else" grant)
    * `policies` - `BubbleEx.Target.Ash.Policy`s (`policies do`); with
      any policy the resource uses `Ash.Policy.Authorizer`
    * `field_policies` - `BubbleEx.Target.Ash.FieldPolicy`s
    * `privacy_relationships` - private, ungated `belongs_to` twins of the
      relationships whose ID attribute some users may not view (their
      `filter` gates them): only the privacy calculations and the actor
      loads read through them (see `BubbleEx.Target.Ash`, "Privacy rules")
    * `privacy` - the `BubbleEx.Target.Ash.ResourcePrivacy` the policies
      were derived from
    * `description` - text for the module's documentation, or nil
  """

  alias BubbleEx.Target.Ash.{
    Action,
    Attribute,
    Calculation,
    FieldPolicy,
    Identity,
    Policy,
    Relationship,
    ResourcePrivacy
  }

  @enforce_keys [:module, :table, :source]
  defstruct [
    :module,
    :table,
    :source,
    :bubble_name,
    :description,
    synthesized: false,
    attributes: [],
    relationships: [],
    identities: [],
    migration_types: [],
    actions: [:read, :destroy, create: :*, update: :*],
    extra_actions: [],
    calculations: [],
    policies: [],
    field_policies: [],
    privacy_relationships: [],
    privacy: nil
  ]

  @type t :: %__MODULE__{
          module: String.t(),
          table: String.t(),
          source: %{type: String.t()},
          bubble_name: String.t() | nil,
          description: String.t() | nil,
          synthesized: boolean(),
          attributes: [Attribute.t()],
          relationships: [Relationship.t()],
          identities: [Identity.t()],
          migration_types: [{String.t(), BubbleEx.Target.Ash.Project.type()}],
          actions: keyword() | [atom() | {atom(), term()}],
          extra_actions: [Action.t()],
          calculations: [Calculation.t()],
          policies: [Policy.t()],
          field_policies: [FieldPolicy.t()],
          privacy_relationships: [Relationship.t()],
          privacy: ResourcePrivacy.t() | nil
        }
end

defmodule BubbleEx.Target.Ash.Action do
  @moduledoc """
  An action beyond a resource's `defaults`.

    * `type` - `:read` or `:update`; `name` - the action name
    * `primary?` - the primary action of its type
    * `keyed?` - a read that, when authorized, is forbidden unless its
      filter selects records by primary key (`id == x` or `id in [...]`,
      at the top level) or it loads a relationship: its policy starts with
      `authorize_if <namespace>.Privacy.KeyedRead` in its own policy, a policy check, so
      aggregates (count, exists, ...) are held to it too. Relationship
      loads and `Ash.get` are keyed
    * `accept` - attribute names an update accepts (`[]` for a read)
    * `description` - the action's `description`
  """

  @enforce_keys [:type, :name]
  defstruct [:type, :name, :description, primary?: false, keyed?: false, accept: []]

  @type t :: %__MODULE__{
          type: :read | :update,
          name: String.t(),
          primary?: boolean(),
          keyed?: boolean(),
          accept: [String.t()],
          description: String.t() | nil
        }
end

defmodule BubbleEx.Target.Ash.Calculation do
  @moduledoc """
  An expression calculation (`calculate name, type, expr(...), public?:
  ...`).

    * `name` - the calculation name
    * `kind` - `:privacy`: a private boolean calculation a policy or field
      policy tests; `:derived`: a field an owner decision derives from a
      related record (`derive_from_related`), public, named like the
      attribute it replaces
    * `type`, `constraints` - its Ash type (`:boolean` for `:privacy`) and
      type constraints
    * `public?` - as in Ash
    * `expr` - the `BubbleEx.Target.Ash.Expr` it computes; `^actor(...)`
      templates read the query's actor
    * `source` - `%{type: _, rule: _}` for a privacy rule's condition,
      `%{type: _, except_rules: [...]}` for "no rule in the list matches"
      (the `everyone` rule's grants, see `BubbleEx.Target.Ash`), or
      `%{type: _, field: _}` for a derived field
    * `description` - the calculation's description
  """

  alias BubbleEx.Target.Ash.Expr

  @enforce_keys [:name, :expr, :source]
  defstruct [
    :name,
    :expr,
    :source,
    :description,
    kind: :privacy,
    type: :boolean,
    constraints: [],
    public?: false
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          kind: :privacy | :derived,
          type: BubbleEx.Target.Ash.Project.type(),
          constraints: keyword(),
          public?: boolean(),
          expr: Expr.t(),
          source: map(),
          description: String.t() | nil
        }
end

defmodule BubbleEx.Target.Ash.PolicyCheck do
  @moduledoc """
  One check of a policy or field policy, in order: the first check that
  decides wins.

    * `kind` - `:authorize_if` or `:forbid_if`
    * `test` - `:always`; `:keyed` (the `<namespace>.Privacy.KeyedRead`
      check: the read selects by primary key or loads a relationship); or
      `{:calculation, name}`: the resource's boolean calculation `name` is
      true for the record
    * `source` - what grants it: `%{rules: [rule_id]}` for a rule,
      `%{default: true, except_rules: [...]}` for the `everyone` rule's
      grant to users no listed rule matches, `%{default: true}` for Bubble's
      public defaults or an unconditional `everyone` grant, `%{}` for a
      denial
  """

  @enforce_keys [:kind, :test]
  defstruct [:kind, :test, source: %{}]

  @type t :: %__MODULE__{
          kind: :authorize_if | :forbid_if,
          test: :always | :keyed | {:calculation, String.t()},
          source: map()
        }
end

defmodule BubbleEx.Target.Ash.Policy do
  @moduledoc """
  A policy (`policy <condition> do ... end`).

    * `action` - the action name the policy applies to
    * `changing` - attribute names: the policy applies only when the
      action changes one of them (`changing_attributes([...])`); nil for
      every call of the action
    * `description` - the policy's `description`
    * `checks` - `BubbleEx.Target.Ash.PolicyCheck`s
    * `permission` - the Bubble permission it enforces (`:view`,
      `:search_for`, `:auto_binding`), or `:keyed` for the key requirement
      of the primary `:read`
  """

  alias BubbleEx.Target.Ash.PolicyCheck

  @enforce_keys [:action, :checks, :permission]
  defstruct [:action, :changing, :description, :checks, :permission]

  @type t :: %__MODULE__{
          action: String.t(),
          changing: [String.t()] | nil,
          description: String.t() | nil,
          checks: [PolicyCheck.t()],
          permission: atom()
        }
end

defmodule BubbleEx.Target.Ash.FieldPolicy do
  @moduledoc """
  A field policy (`field_policy [fields] do ... end`): who may read the
  listed attributes. Fields a check does not authorize read as
  `%Ash.ForbiddenField{}`.

    * `fields` - attribute names, in attribute order
    * `checks` - `BubbleEx.Target.Ash.PolicyCheck`s
  """

  alias BubbleEx.Target.Ash.PolicyCheck

  @enforce_keys [:fields, :checks]
  defstruct [:fields, :checks, :description]

  @type t :: %__MODULE__{
          fields: [String.t()],
          checks: [PolicyCheck.t()],
          description: String.t() | nil
        }
end

defmodule BubbleEx.Target.Ash.ResourcePrivacy do
  @moduledoc """
  The privacy facts a resource's policies were derived from.

    * `source` - `:rules` (the type's own privacy rules), `:public_default`
      (a type the source lists without rules: Bubble's public defaults) or
      `:unavailable` (the source cannot say, e.g. a live payload: every
      access is denied)
    * `compiled_rules` / `denied_rules` - rule IDs whose condition compiled,
      and those that grant nothing because it did not (or is missing)
    * `attachments` - `BubbleEx.Target.Ash.PolicyCheck`s for Bubble's "view
      attached files", which Ash cannot enforce (file fields are URLs; the
      file store must): data for the owner and later lowering only
    * `file_fields` - the attribute names holding files or images
    * `data_api` - the Data API: `%{exposed: boolean | nil, create: checks,
      modify: checks, delete: checks}`. No API action is generated (the
      Data API is out of scope, WTF-359 Q6); data only
  """

  @enforce_keys [:source]
  defstruct [
    :source,
    compiled_rules: [],
    denied_rules: [],
    attachments: [],
    file_fields: [],
    data_api: %{exposed: nil, create: [], modify: [], delete: []}
  ]

  @type t :: %__MODULE__{
          source: :rules | :public_default | :unavailable,
          compiled_rules: [String.t()],
          denied_rules: [String.t()],
          attachments: [BubbleEx.Target.Ash.PolicyCheck.t()],
          file_fields: [String.t()],
          data_api: map()
        }
end

defmodule BubbleEx.Target.Ash.Bypass do
  @moduledoc """
  A workflow that runs ignoring privacy rules in Bubble (a backend workflow
  set to ignore them, or a custom event it triggers): when lowered, its
  reads need an explicit authorization bypass (`authorize?: false`).
  Recorded here, not generated: workflow lowering is a later step.

    * `workflow` - the workflow's Bubble ID
    * `own` - true when its own setting says so; false when it inherits it
      from a caller
    * `types` - data type IDs it reads or searches, sorted
  """

  @enforce_keys [:workflow]
  defstruct [:workflow, own: false, types: []]

  @type t :: %__MODULE__{workflow: String.t(), own: boolean(), types: [String.t()]}
end

defmodule BubbleEx.Target.Ash.Attribute do
  @moduledoc """
  An attribute of a resource, or a field of a typed struct.

    * `name` - the attribute name (a snake-case identifier)
    * `type` - its `t:BubbleEx.Target.Ash.Project.type/0`
    * `constraints` - Ash type constraints, e.g.
      `[trim?: false, allow_empty?: true]` or `[items: [...]]` for arrays
    * `primary_key?`, `allow_nil?`, `writable?`, `public?` - as in Ash
    * `column` - the column name when it is not `name` (an attribute
      renamed after the name lock keeps its column; rendered as
      `source:`), else nil
    * `default` - `{:value, term}` for a static default (`{:value,
      {:decimal, "1.5"}}` for a decimal), or nil for none
    * `source` - the Bubble IDs it maps (`%{type: _, field: _}`,
      `%{external_type: _, field: _}` or `%{structured: _, component: _}`)
    * `bubble_type` - the Bubble type descriptor as supplied, or nil
    * `references` - for an attribute holding Bubble IDs of records,
      `%{target: bubble_id, cardinality: :one | :many}`; nil otherwise
  """

  @enforce_keys [:name, :type, :source]
  defstruct [
    :name,
    :type,
    :source,
    :bubble_type,
    :default,
    :references,
    :column,
    constraints: [],
    primary_key?: false,
    allow_nil?: true,
    writable?: true,
    public?: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          type: BubbleEx.Target.Ash.Project.type(),
          constraints: keyword(),
          primary_key?: boolean(),
          allow_nil?: boolean(),
          writable?: boolean(),
          public?: boolean(),
          default: {:value, term()} | nil,
          column: String.t() | nil,
          source: map(),
          bubble_type: term(),
          references: %{target: String.t(), cardinality: :one | :many} | nil
        }
end

defmodule BubbleEx.Target.Ash.Relationship do
  @moduledoc """
  A relationship of a resource. Only `:belongs_to` is produced today.

    * `name` - the relationship name; `destination` - relative module name
    * `source_attribute` / `destination_attribute` - attribute names
    * `attribute_type` - the source attribute's type
    * `define_attribute?` - false: the source attribute is listed among the
      resource's attributes with its own constraints
    * `allow_nil?`, `public?` - as in Ash
    * `db_reference` - `:ignore` (no database foreign key: AshPostgres
      `references … ignore?: true`) or `:foreign_key`
    * `source` - `%{type: _, field: _}` Bubble IDs
    * `sortable?` - false when privacy policies are generated (WTF-356):
      Ash applies field policies to a resource's own fields in `sort_input`
      but not to fields reached through a relationship, so sorting by
      `rel.hidden_field` would order by a value the actor may not view
    * `gate` - nil, or who may follow it (WTF-356): `{:visible_if, calcs}`
      (`filter expr(parent(a or b))`: one of the source record's privacy
      calculations holds, those authorizing its ID attribute) or `:never`
      (`filter expr(false)`)
  """

  @enforce_keys [:kind, :name, :destination, :source_attribute, :source]
  defstruct [
    :kind,
    :name,
    :destination,
    :source_attribute,
    :source,
    destination_attribute: "id",
    attribute_type: :string,
    define_attribute?: false,
    allow_nil?: true,
    public?: true,
    db_reference: :ignore,
    sortable?: true,
    gate: nil
  ]

  @type t :: %__MODULE__{
          kind: :belongs_to,
          name: String.t(),
          destination: String.t(),
          source_attribute: String.t(),
          destination_attribute: String.t(),
          attribute_type: BubbleEx.Target.Ash.Project.type(),
          define_attribute?: boolean(),
          allow_nil?: boolean(),
          public?: boolean(),
          db_reference: :ignore | :foreign_key,
          source: map(),
          sortable?: boolean(),
          gate: nil | :never | {:visible_if, [String.t()]}
        }
end

defmodule BubbleEx.Target.Ash.Identity do
  @moduledoc """
  A resource identity (`identity name, keys`). None is produced from the
  source-faithful mapping: Bubble declares no unique fields besides the
  primary key.
  """

  @enforce_keys [:name, :keys]
  defstruct [:name, :keys, :source]

  @type t :: %__MODULE__{name: String.t(), keys: [String.t()], source: map() | nil}
end

defmodule BubbleEx.Target.Ash.Enum do
  @moduledoc """
  A generated `Ash.Type.Enum` module for one option set, storing each value
  as its stable key (Bubble's `db_value`) in a string column.

    * `module` - relative module name, e.g. `"Enums.Status"`
    * `source` - `%{option_set: bubble_id}`; `bubble_name` - display name
    * `values` - `BubbleEx.Target.Ash.EnumValue`s in Bubble's order
    * `attributes` - `BubbleEx.Target.Ash.EnumAttribute`s: the option set's
      attributes, whose values each `EnumValue` carries for lookup
    * `description` - text for the module's documentation, or nil
  """

  alias BubbleEx.Target.Ash.{EnumAttribute, EnumValue}

  @enforce_keys [:module, :source]
  defstruct [:module, :source, :bubble_name, :description, values: [], attributes: []]

  @type t :: %__MODULE__{
          module: String.t(),
          source: %{option_set: String.t()},
          bubble_name: String.t() | nil,
          description: String.t() | nil,
          values: [EnumValue.t()],
          attributes: [EnumAttribute.t()]
        }
end

defmodule BubbleEx.Target.Ash.EnumValue do
  @moduledoc """
  One enum value.

    * `value` - the stored string: the option value's `db_value`
    * `label` - its display text, or nil
    * `attributes` - attribute values by `EnumAttribute.name`, as supplied
      (nil when the value has none)
    * `source` - `%{option_set: _, value: _}` Bubble IDs
  """

  @enforce_keys [:value, :source]
  defstruct [:value, :label, :source, attributes: %{}]

  @type t :: %__MODULE__{
          value: String.t(),
          label: String.t() | nil,
          attributes: %{String.t() => term()},
          source: map()
        }
end

defmodule BubbleEx.Target.Ash.EnumAttribute do
  @moduledoc """
  An option-set attribute exposed as lookup data on its enum.

    * `name` - the lookup key (snake case)
    * `bubble_type` - the Bubble type descriptor as supplied
    * `source` - `%{option_set: _, field: _}` Bubble IDs
  """

  @enforce_keys [:name, :source]
  defstruct [:name, :bubble_type, :source]

  @type t :: %__MODULE__{name: String.t(), bubble_type: term(), source: map()}
end

defmodule BubbleEx.Target.Ash.TypedStruct do
  @moduledoc """
  A generated `Ash.TypedStruct` (a by-value type stored as JSON), for a
  structured Bubble value or an API Connector type.

    * `module` - relative module name
    * `kind` - `:typed_struct`. `:embedded_resource` is reserved for types
      that need validation; none is produced today
    * `source` - `%{structured: base}` or `%{external_type: bubble_id}`
    * `fields` - `BubbleEx.Target.Ash.Attribute`s
    * `metadata` - source facts the struct cannot express, e.g. a range's
      `bounds: %{start: :unverified, end: :unverified}`
    * `description` - text for the module's documentation, or nil
  """

  alias BubbleEx.Target.Ash.Attribute

  @enforce_keys [:module, :source]
  defstruct [
    :module,
    :source,
    :bubble_name,
    :description,
    kind: :typed_struct,
    fields: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          module: String.t(),
          kind: :typed_struct | :embedded_resource,
          source: map(),
          bubble_name: String.t() | nil,
          description: String.t() | nil,
          fields: [Attribute.t()],
          metadata: map()
        }
end

defmodule BubbleEx.Target.Ash.CustomType do
  @moduledoc """
  A generated Ash type module (not a typed struct or an enum).

    * `module` - relative module name, e.g. `"Types.JsonValue"`
    * `kind` - `:json_value`: any JSON value (object, array, string, number,
      boolean or null), stored as jsonb. `Ash.Type.Map` accepts only
      objects, so values whose shape is unknown use this to be kept verbatim
    * `description` - text for the module's documentation
  """

  @enforce_keys [:module, :kind]
  defstruct [:module, :kind, :description]

  @type t :: %__MODULE__{module: String.t(), kind: :json_value, description: String.t() | nil}
end
