defmodule BubbleEx.Target.Ash.Project do
  @moduledoc """
  An Ash project described as plain data: what `BubbleEx.Target.Ash.map/3`
  derives from a `BubbleEx.Model`, and all a renderer needs to print it.
  There is no Ash dependency; nothing here is `use Ash`.

    * `resources` - `BubbleEx.Target.Ash.Resource`s (one per data type), in
      Bubble ID order
    * `enums` - `BubbleEx.Target.Ash.Enum`s (one per option set), in Bubble
      ID order
    * `typed_structs` - `BubbleEx.Target.Ash.TypedStruct`s (structured
      Bubble values, then API Connector types), ordered so every struct
      follows the structs its fields use
    * `names` - the per-app name map (see "Name map"), updated with every
      name this mapping derived
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

      %{
        "version" => 1,
        "resources" => %{
          "task" => %{
            "module" => "Task",
            "table" => "task",
            "attributes" => %{"_id" => "id", "title_text" => "title", "project_custom_project" => "project_id"},
            "relationships" => %{"project_custom_project" => "project"}
          }
        },
        "enums" => %{"status" => %{"module" => "Status", "attributes" => %{"color" => "color"}}},
        "external_types" => %{"api.…" => %{"module" => "Obj", "fields" => %{"name" => "name"}}}
      }
  """

  alias BubbleEx.{CanonicalJson, Diagnostic}
  alias BubbleEx.Target.Ash.{Resource, TypedStruct}

  @schema_version 1

  @enforce_keys [:schema_version]
  defstruct [
    :schema_version,
    :bubble_id,
    resources: [],
    enums: [],
    typed_structs: [],
    names: %{},
    diagnostics: []
  ]

  @type type :: atom() | {:array, type()} | {:module, String.t()}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          bubble_id: String.t() | nil,
          resources: [Resource.t()],
          enums: [BubbleEx.Target.Ash.Enum.t()],
          typed_structs: [TypedStruct.t()],
          names: map(),
          diagnostics: [Diagnostic.t()]
        }

  @doc "The Project format version; it changes whenever `to_map/1` does."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  JSON form: string keys and JSON values only. Atoms become strings and
  tuples lists (`{:array, :string}` is `["array", "string"]`).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = project), do: json(project)

  @doc "Canonical JSON text of `to_map/1`: byte-identical for the same Project."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = project), do: project |> to_map() |> CanonicalJson.encode()

  defp json(%Diagnostic{} = d), do: Diagnostic.to_map(d)
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
  resources, attributes by Ash type (`enum` and `typed_struct` for
  generated modules), relationships by kind, database references by mode,
  enums and their values, typed structs by source, and diagnostics by code.
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
      "diagnostics" => frequencies(project.diagnostics, &Atom.to_string(&1.code))
    }
  end

  defp module_kinds(project) do
    Map.new(project.enums, &{&1.module, "enum"})
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
    * `actions` - the `defaults` action list, e.g.
      `[:read, :destroy, create: :*, update: :*]`
    * `description` - text for the module's documentation, or nil
  """

  alias BubbleEx.Target.Ash.{Attribute, Identity, Relationship}

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
    actions: [:read, :destroy, create: :*, update: :*]
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
          actions: keyword() | [atom() | {atom(), term()}]
        }
end

defmodule BubbleEx.Target.Ash.Attribute do
  @moduledoc """
  An attribute of a resource, or a field of a typed struct.

    * `name` - the attribute name (a snake-case identifier)
    * `type` - its `t:BubbleEx.Target.Ash.Project.type/0`
    * `constraints` - Ash type constraints, e.g.
      `[trim?: false, allow_empty?: true]` or `[items: [...]]` for arrays
    * `primary_key?`, `allow_nil?`, `writable?`, `public?` - as in Ash
    * `default` - `{:value, term}` for a static default, or nil for none
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
    db_reference: :ignore
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
          source: map()
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
