defmodule BubbleEx.Model do
  @moduledoc """
  The stack-neutral model of a Bubble app's data: what Bubble actually has,
  in Bubble's own terms, keyed by Bubble IDs.

      {:ok, model} = BubbleEx.Model.build(app)

      BubbleEx.Model.data_type(model, "task")
      BubbleEx.Model.field(model, "task", "title_text")   # => {:ok, %Field{type: %Type{}}}
      BubbleEx.Model.schema(model)                        # typed field lookup for expressions

  It holds data types (`BubbleEx.Model.DataType`) with their fields, Bubble's
  built-in fields and privacy rules; option sets (`BubbleEx.Model.OptionSet`)
  with stable value keys, values and attributes; and the API Connector types
  reached from them (`BubbleEx.Model.ExternalType`). Every field has a
  content type (`BubbleEx.Model.Type`): a scalar, file reference, structured
  value, reference to a data type, option set or external type (resolved or
  not), or an opaque/unknown value kept verbatim.

  Target stacks map from the Model; it contains no target-language names,
  types or keys. Identity is the Bubble ID; display names are attributes and
  are kept verbatim. Deleted types, fields, option sets, values and
  attributes are kept with `deleted: true`.

  ## Input

  Decoded app JSON in either key form: a `.bubble` export (`display`,
  `fields`, `value`, `deleted`) or the live payload (`%d`, `%f3`, `%v`,
  `%del`). Privacy rules and API Connector settings exist only in exports.
  The Model is built from the same reading as `BubbleEx.Db.Reader` (its API
  Connector resolution, and its diagnostics) and `BubbleEx.Privacy` (its
  rules, type-level flags and diagnostics). It does not use the Reader's
  table output, which drops deleted fields and values and orders by display
  name.

  ## Order

  Output is identical across runs and independent of input map order.
  Bubble supplies an order only for option values (`sort_factor`); they
  follow it, then their Bubble ID. Everything else is in Bubble ID order;
  external-type fields follow their response path, as in the Reader; privacy
  rules are ordered as `BubbleEx.Privacy` orders them.

  ## Diagnostics

  `diagnostics` holds every `BubbleEx.Diagnostic` from building the Model,
  normalized: the Reader's API Connector diagnostics (stage `:read`), the
  privacy parse's (`:parse`) and the Model's own (`:model`, codes prefixed
  `model_`). Nothing in the source is dropped: what the Model does not model
  is kept in an `extra` or `raw` member and diagnosed. A data type that is
  not a JSON object is kept in `DataType.raw` with the privacy parse's
  `:malformed_node`; other malformed nodes get `:model_malformed_node`.
  """

  alias BubbleEx.{CanonicalJson, Diagnostic, Error, Expression}
  alias BubbleEx.Model.{Builder, DataType, ExternalType, Field, OptionSet, Type}
  alias BubbleEx.Privacy.Rule

  @schema_version 1

  @enforce_keys [:schema_version]
  defstruct [
    :schema_version,
    :bubble_id,
    data_types: [],
    option_sets: [],
    external_types: [],
    extra: %{},
    diagnostics: []
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          bubble_id: String.t() | nil,
          data_types: [DataType.t()],
          option_sets: [OptionSet.t()],
          external_types: [ExternalType.t()],
          extra: map(),
          diagnostics: [Diagnostic.t()]
        }

  @doc "The Model format version; it changes whenever `to_map/1` does."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Builds the Model from decoded app JSON. Top-level `user_types` or
  `option_sets` that are not objects are kept in `extra` and diagnosed.
  """
  @spec build(term()) :: {:ok, t()} | {:error, Error.t()}
  def build(app) when is_map(app) and not is_struct(app) do
    result = Builder.build(app)

    {:ok,
     %__MODULE__{
       schema_version: @schema_version,
       bubble_id: if(is_binary(app["_id"]), do: app["_id"]),
       data_types: result.data_types,
       option_sets: result.option_sets,
       external_types: result.external_types,
       extra: result.extra,
       diagnostics: result.diagnostics
     }}
  end

  def build(_), do: {:error, Error.new(:invalid_input, "expected a decoded app JSON object")}

  # --- lookups -----------------------------------------------------------------

  @doc "The data type with Bubble ID `id`, or nil."
  @spec data_type(t(), String.t()) :: DataType.t() | nil
  def data_type(%__MODULE__{data_types: types}, id), do: Enum.find(types, &(&1.id == id))

  @doc "The option set with Bubble ID `id`, or nil."
  @spec option_set(t(), String.t()) :: OptionSet.t() | nil
  def option_set(%__MODULE__{option_sets: sets}, id), do: Enum.find(sets, &(&1.id == id))

  @doc "The external type with descriptor `id`, or nil."
  @spec external_type(t(), String.t()) :: ExternalType.t() | nil
  def external_type(%__MODULE__{external_types: types}, id),
    do: Enum.find(types, &(&1.id == id))

  @doc """
  A field of data type `type_id` by Bubble ID, including built-in fields
  (e.g. `"Created Date"`, `"_id"`).
  """
  @spec field(t(), String.t(), String.t()) :: {:ok, Field.t()} | :error
  def field(model, type_id, field_id) do
    with %DataType{} = type <- data_type(model, type_id),
         %Field{} = field <- Enum.find(type.fields ++ type.system_fields, &(&1.id == field_id)) do
      {:ok, field}
    else
      _ -> :error
    end
  end

  @doc """
  The Model's data types as a `BubbleEx.Expression.Schema` (field lookup for
  typing expressions): every defined field with its display name and source
  type descriptor. Built-in fields are resolved by the expression schema
  itself.
  """
  @spec schema(t()) :: BubbleEx.Expression.Schema.t()
  def schema(%__MODULE__{data_types: types}) do
    for %DataType{raw: nil} = type <- types, into: %{} do
      fields =
        for field <- type.fields, is_nil(field.raw), into: %{} do
          value = if is_binary(field.type.source), do: field.type.source
          {field.id, %{display: field.name, value: value}}
        end

      {type.id, %{display: type.name, fields: fields}}
    end
  end

  # --- serialization -------------------------------------------------------------

  @doc """
  JSON form: string keys and JSON values only, so it encodes and decodes back
  to the same shape. Atoms become strings; privacy-rule conditions use the
  expression's canonical form (`BubbleEx.Expression.to_map/1`); per-rule
  diagnostics are omitted (the Model's `diagnostics` include them).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = model), do: json(model)

  @doc "Canonical JSON text of `to_map/1`: byte-identical for the same Model."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = model), do: model |> to_map() |> CanonicalJson.encode()

  @doc "Lowercase hex SHA-256 of `to_json/1`."
  @spec sha256(t()) :: String.t()
  def sha256(%__MODULE__{} = model), do: model |> to_map() |> CanonicalJson.sha256()

  defp json(%Diagnostic{} = d), do: Diagnostic.to_map(d)

  defp json(%Rule{} = rule) do
    rule
    |> Map.from_struct()
    |> Map.delete(:diagnostics)
    |> Map.update!(:condition, &condition/1)
    |> json()
  end

  defp json(%_{} = struct), do: struct |> Map.from_struct() |> json()
  defp json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(value) when value in [true, false, nil], do: value
  defp json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json(value), do: value

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: k

  defp condition(nil), do: nil

  defp condition(ast) do
    {:ok, map} = Expression.to_map(ast)
    map
  end

  # --- summary -------------------------------------------------------------------

  @doc """
  Aggregate counts, with string keys (for reports and count snapshots):
  data types, fields by kind, relationships, option sets, values and
  attributes, external types by resolution, cycle cuts, privacy rules and
  diagnostics by code. Counts include deleted definitions; `deleted_*`
  counts them separately.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = model) do
    fields = Enum.flat_map(model.data_types, & &1.fields)
    attributes = Enum.flat_map(model.option_sets, & &1.attributes)
    values = Enum.flat_map(model.option_sets, & &1.values)
    external_fields = Enum.flat_map(model.external_types, & &1.fields)
    relationships = Enum.filter(fields, &(&1.type.kind == :ref and not &1.deleted))

    %{
      "data_types" => length(model.data_types),
      "deleted_data_types" => Enum.count(model.data_types, & &1.deleted),
      "malformed_data_types" => Enum.count(model.data_types, &(not is_nil(&1.raw))),
      "fields" => length(fields),
      "deleted_fields" => Enum.count(fields, & &1.deleted),
      "fields_by_kind" => frequencies(fields, &kind_key(&1.type)),
      "system_fields" => model.data_types |> Enum.map(&length(&1.system_fields)) |> Enum.sum(),
      "relationships" => frequencies(relationships, &relationship_key(&1.type)),
      "option_sets" => length(model.option_sets),
      "deleted_option_sets" => Enum.count(model.option_sets, & &1.deleted),
      "option_values" => length(values),
      "deleted_option_values" => Enum.count(values, & &1.deleted),
      "option_attributes" => length(attributes),
      "option_attributes_by_kind" => frequencies(attributes, &kind_key(&1.type)),
      "external_types" => frequencies(model.external_types, &Atom.to_string(&1.resolution)),
      "external_fields" => length(external_fields),
      "cycle_cuts" => Enum.count(external_fields, & &1.cycle),
      "privacy_rules" => model.data_types |> Enum.map(&length(&1.rules)) |> Enum.sum(),
      "diagnostics" => frequencies(model.diagnostics, &Atom.to_string(&1.code))
    }
  end

  defp frequencies(list, fun), do: list |> Enum.frequencies_by(fun) |> Map.new()

  defp kind_key(%Type{kind: kind, cardinality: :many}), do: "list #{kind}"
  defp kind_key(%Type{kind: kind}), do: Atom.to_string(kind)

  defp relationship_key(%Type{resolved: false}), do: "unresolved"
  defp relationship_key(%Type{cardinality: cardinality}), do: Atom.to_string(cardinality)
end
