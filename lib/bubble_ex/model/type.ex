defmodule BubbleEx.Model.Type do
  @moduledoc """
  The content type of a field, option-set attribute or external-type field,
  in Bubble's own terms (no target-language types).

    * `kind`
      * `:scalar` - `base` is `:text`, `:number`, `:boolean` or `:date`
        (external fields may also be `:date_unix`)
      * `:file_ref` - an uploaded file; `base` is `:file` or `:image`
      * `:structured` - a named structured Bubble value; `base` is
        `:geographic_address`, `:date_range`, `:number_range` or
        `:date_interval`, whose parts are in `BubbleEx.Model.Structured`
        (`components/1`)
      * `:ref` - a record of the data type `target`
      * `:option` - a value of the option set `target`
      * `:external` - a value of the API Connector type `target`
      * `:opaque` - an external value with no usable type (e.g. an invalid
        `api.` descriptor); `source` keeps it
      * `:unknown` - a descriptor outside Bubble's type vocabulary, or a
        missing or malformed one; `source` keeps it
    * `cardinality` - `:one`, `:many` (a Bubble list; order is preserved) or
      `:unknown` (an opaque external value whose list-ness is unknown)
    * `target` - the Bubble ID that `:ref`, `:option` and `:external` name,
      kept even when it does not resolve
    * `resolved` - for `:ref` and `:option`, whether `target` is defined in
      the app; for `:external`, whether the API Connector type's shape is
      known (see `BubbleEx.Model.ExternalType`); `nil` for other kinds
    * `source` - the descriptor exactly as supplied (e.g.
      `"list.custom.task"`), or the raw value when it is not a string
  """

  @enforce_keys [:kind, :cardinality, :source]
  defstruct [:kind, :base, :target, :resolved, :cardinality, :source]

  @type kind ::
          :scalar | :file_ref | :structured | :ref | :option | :external | :opaque | :unknown
  @type t :: %__MODULE__{
          kind: kind(),
          base: atom() | nil,
          target: String.t() | nil,
          resolved: boolean() | nil,
          cardinality: :one | :many | :unknown,
          source: term()
        }

  @bases %{
    "text" => {:scalar, :text},
    "number" => {:scalar, :number},
    "boolean" => {:scalar, :boolean},
    "date" => {:scalar, :date},
    "file" => {:file_ref, :file},
    "image" => {:file_ref, :image},
    "geographic_address" => {:structured, :geographic_address},
    "date_range" => {:structured, :date_range},
    "number_range" => {:structured, :number_range},
    "dateinterval" => {:structured, :date_interval}
  }

  @doc """
  Classifies a Bubble type descriptor. Returns the type (targets not yet
  resolved) and `nil`, or `:malformed` (missing or not a string) or
  `:unsupported` (outside the vocabulary) for a type of kind `:unknown`.
  API Connector descriptors (`api.…`) classify as `:external`; their
  resolution is `BubbleEx.Model.External`'s.
  """
  @spec classify(term()) :: {t(), nil | :malformed | :unsupported}
  def classify(descriptor) when is_binary(descriptor) do
    {inner, cardinality} = strip_list(descriptor)

    case base(inner) do
      {kind, base, target} ->
        {%__MODULE__{
           kind: kind,
           base: base,
           target: target,
           cardinality: cardinality,
           source: descriptor
         }, nil}

      nil ->
        {unknown(descriptor), :unsupported}
    end
  end

  def classify(descriptor), do: {unknown(descriptor), :malformed}

  @doc """
  The component parts of a `:structured` type from
  `BubbleEx.Model.Structured` (e.g. a geographic address's
  `formatted_address`, `lat` and `lng`); `[]` for other kinds.
  """
  @spec components(t()) :: [BubbleEx.Model.Structured.component()]
  def components(%__MODULE__{kind: :structured, base: base}),
    do: BubbleEx.Model.Structured.fetch(base).components

  def components(%__MODULE__{}), do: []

  @doc "Whether the type names another definition (`:ref`, `:option` or `:external`)."
  @spec reference?(t()) :: boolean()
  def reference?(%__MODULE__{kind: kind}), do: kind in [:ref, :option, :external]

  # --- descriptors ---------------------------------------------------------------
  #
  # Readers outside the Model (the index, analyzers, workflow explanations)
  # see Bubble value types only as descriptors (e.g. an expression's type or
  # a symbol's `value_type`). These read them the one way the Model does.

  @doc """
  The data type, option set or API Connector call a single (not list)
  descriptor names: `{:data_type, id}` (`"user"`, `"custom.<id>"`),
  `{:option_set, id}` (`"option.<id>"`), `{:api_call, connector, call,
  response_path}` (`"api.apiconnector2.<connector>.<call>[.<path>]"`, path
  `nil` when absent), or `nil`.
  """
  @spec reference(term()) ::
          {:data_type, String.t()}
          | {:option_set, String.t()}
          | {:api_call, String.t(), String.t(), String.t() | nil}
          | nil
  def reference("user"), do: {:data_type, "user"}
  def reference("custom." <> id) when id != "", do: {:data_type, id}
  def reference("option." <> id) when id != "", do: {:option_set, id}

  def reference("api.apiconnector2." <> rest) do
    case String.split(rest, ".", parts: 3) do
      [connector, call] -> {:api_call, connector, call, nil}
      [connector, call, path] -> {:api_call, connector, call, path}
      _ -> nil
    end
  end

  def reference(_), do: nil

  @doc "The item descriptor of a list descriptor (`\"list.<item>\"`), or nil."
  @spec list_item(term()) :: String.t() | nil
  def list_item("list." <> item), do: item
  def list_item(_), do: nil

  @doc "Whether `descriptor` is a list descriptor."
  @spec list?(term()) :: boolean()
  def list?(descriptor), do: list_item(descriptor) != nil

  @doc "The list descriptor of `descriptor`; a list descriptor is kept."
  @spec listed(String.t()) :: String.t()
  def listed("list." <> _ = descriptor), do: descriptor
  def listed(descriptor), do: "list." <> descriptor

  @doc "The descriptor of a record of data type `id` (`\"user\"` or `\"custom.<id>\"`)."
  @spec record(String.t()) :: String.t()
  def record("user"), do: "user"
  def record(id), do: "custom." <> id

  defp unknown(source), do: %__MODULE__{kind: :unknown, cardinality: :one, source: source}

  defp strip_list("list." <> inner), do: {inner, :many}
  defp strip_list(descriptor), do: {descriptor, :one}

  defp base("list." <> _), do: nil
  defp base("user"), do: {:ref, nil, "user"}
  defp base("custom." <> id) when id != "", do: {:ref, nil, id}
  defp base("option." <> id) when id != "", do: {:option, nil, id}
  defp base("api." <> _ = id), do: {:external, nil, id}

  defp base(name) do
    case @bases[name] do
      {kind, base} -> {kind, base, nil}
      nil -> nil
    end
  end
end
