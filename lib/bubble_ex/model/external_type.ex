defmodule BubbleEx.Model.ExternalType do
  @moduledoc """
  An API Connector type (e.g. `"api.apiconnector2.bTa.bTb.obj"`) reached from
  a data-type field or option-set attribute, directly or through other
  external types. The Model resolves it against the API Connector call's
  `types` registry, and the diagnostics (stage `:read`) say why a type is not
  known.

    * `id` - the descriptor; identity
    * `name` - the type's caption, verbatim
    * `connector` / `call` - the API Connector group and call Bubble IDs
    * `resolution`
      * `:resolved` - its shape is known: `fields`
      * `:resolved_empty` - defined with no fields
      * `:opaque` - the connector, call or definition is missing or
        malformed; its shape is unknown
      * `:conflicted` - defined differently by more than one call; opaque
    * `fields` - `BubbleEx.Model.ExternalField`s in response-path order
    * `path` - JSON pointer to the call's `types` registry, or `nil`
  """

  alias BubbleEx.Model.ExternalField

  @enforce_keys [:id, :resolution]
  defstruct [:id, :name, :connector, :call, :resolution, :path, fields: []]

  @type resolution :: :resolved | :resolved_empty | :opaque | :conflicted
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          connector: String.t() | nil,
          call: String.t() | nil,
          resolution: resolution(),
          path: String.t() | nil,
          fields: [ExternalField.t()]
        }

  @doc "Whether the type's shape is known (`:resolved` or `:resolved_empty`)."
  @spec known?(t()) :: boolean()
  def known?(%__MODULE__{resolution: r}), do: r in [:resolved, :resolved_empty]
end

defmodule BubbleEx.Model.ExternalField do
  @moduledoc """
  A field of a `BubbleEx.Model.ExternalType`.

    * `id` / `name` - its Bubble ID and caption
    * `response_path` - where the value sits in the API response, as supplied
    * `type` - its `BubbleEx.Model.Type` (`:scalar`, `:external` or `:opaque`)
    * `cycle` - true on the edge that closes a cycle of external types
      (recursive or mutually recursive). The Model keeps the reference by ID;
      a target that cannot express recursion cuts the graph here. Cycles are
      found depth-first from each type in Bubble ID order, following fields
      in order, so the cut is deterministic.
  """

  alias BubbleEx.Model.Type

  @enforce_keys [:id, :type]
  defstruct [:id, :name, :response_path, :type, cycle: false]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          response_path: term(),
          type: Type.t(),
          cycle: boolean()
        }
end
