defmodule BubbleEx.Index.Reference do
  @moduledoc """
  A directed reference edge between two symbols.

  `from` and `to` are `BubbleEx.Index.Symbol` IDs. `to` may name a symbol
  absent from the index (a dangling reference, also reported as an
  `:index_unresolved_reference` diagnostic). `path` is the RFC 6901 pointer of the
  source JSON that makes the reference (for expression reads, the outermost
  expression). `attrs` holds kind-specific facts; see `BubbleEx.Index` for the
  edge kinds.
  """

  alias BubbleEx.Index.Symbol

  @type kind ::
          :field_type
          | :reads_field
          | :reads_type
          | :reads_option
          | :reads_element
          | :writes_type
          | :writes_field
          | :grants_view
          | :grants_binding
          | :calls_workflow
          | :calls_api
          | :listens_to
          | :targets_element
          | :instance_of
          | :uses_plugin

  @type t :: %__MODULE__{
          from: Symbol.id(),
          to: Symbol.id(),
          kind: kind(),
          path: String.t(),
          attrs: map()
        }

  @enforce_keys [:from, :to, :kind, :path]
  defstruct [:from, :to, :kind, :path, attrs: %{}]

  @kinds ~w(field_type reads_field reads_type reads_option reads_element writes_type writes_field grants_view
            grants_binding calls_workflow calls_api listens_to targets_element instance_of uses_plugin)a

  @doc "All reference kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc false
  @spec sort_key(t()) :: tuple()
  def sort_key(%__MODULE__{} = r),
    do: {r.from, r.kind, r.to, r.path, r.attrs |> Enum.sort() |> inspect()}
end
