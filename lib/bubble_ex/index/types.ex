defmodule BubbleEx.Index.Types do
  @moduledoc false

  # Bubble value types ("custom.task", "list.user", "option.status",
  # "api.apiconnector2.G.C.body", …) to the symbol they name. Descriptors are
  # read by `BubbleEx.Model.Type`; this maps them to symbol IDs.

  alias BubbleEx.Index.Symbol
  alias BubbleEx.Model.Type

  @type target :: %{id: Symbol.id(), list: boolean(), attrs: map()}

  @spec target(term()) :: target() | nil
  def target(descriptor) do
    case Type.list_item(descriptor) do
      nil ->
        single(Type.reference(descriptor))

      item ->
        case target(item) do
          nil -> nil
          t -> %{t | list: true}
        end
    end
  end

  defp single({:data_type, id}), do: %{id: Symbol.id(:data_type, id), list: false, attrs: %{}}
  defp single({:option_set, id}), do: %{id: Symbol.id(:option_set, id), list: false, attrs: %{}}

  defp single({:api_call, connector, call, nil}),
    do: %{id: Symbol.id(:api_call, [connector, call]), list: false, attrs: %{}}

  defp single({:api_call, connector, call, path}),
    do: %{id: Symbol.id(:api_call, [connector, call]), list: false, attrs: %{response_path: path}}

  defp single(nil), do: nil

  @doc "The data type key of a record (or list of records) type, e.g. `\"task\"`."
  @spec data_type_key(term()) :: String.t() | nil
  def data_type_key(descriptor) do
    case {Type.list_item(descriptor), Type.reference(descriptor)} do
      {nil, {:data_type, id}} -> id
      {nil, _} -> nil
      {item, _} -> data_type_key(item)
    end
  end

  @doc "The Bubble type of a record of data type `key` (inverse of `data_type_key/1`)."
  @spec record_type(String.t()) :: String.t()
  defdelegate record_type(key), to: Type, as: :record

  @spec option_set_key(term()) :: String.t() | nil
  def option_set_key(descriptor) do
    case {Type.list_item(descriptor), Type.reference(descriptor)} do
      {nil, {:option_set, id}} -> id
      {nil, _} -> nil
      {item, _} -> option_set_key(item)
    end
  end
end
