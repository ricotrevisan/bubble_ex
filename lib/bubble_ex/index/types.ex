defmodule BubbleEx.Index.Types do
  @moduledoc false

  # Bubble value types ("custom.task", "list.user", "option.status",
  # "api.apiconnector2.G.C.body", …) to the symbol they name.

  alias BubbleEx.Index.Symbol

  @type target :: %{id: Symbol.id(), list: boolean(), attrs: map()}

  @spec target(term()) :: target() | nil
  def target("list." <> item) do
    case target(item) do
      nil -> nil
      t -> %{t | list: true}
    end
  end

  def target("user"), do: %{id: Symbol.id(:data_type, "user"), list: false, attrs: %{}}

  def target("custom." <> id) when id != "",
    do: %{id: Symbol.id(:data_type, id), list: false, attrs: %{}}

  def target("option." <> id) when id != "",
    do: %{id: Symbol.id(:option_set, id), list: false, attrs: %{}}

  def target("api.apiconnector2." <> rest) do
    case String.split(rest, ".", parts: 3) do
      [group, call] ->
        %{id: Symbol.id(:api_call, [group, call]), list: false, attrs: %{}}

      [group, call, sub] ->
        %{id: Symbol.id(:api_call, [group, call]), list: false, attrs: %{response_path: sub}}

      _ ->
        nil
    end
  end

  def target(_), do: nil

  @doc "The data type key of a record (or list of records) type, e.g. `\"task\"`."
  @spec data_type_key(term()) :: String.t() | nil
  def data_type_key("list." <> item), do: data_type_key(item)
  def data_type_key("user"), do: "user"
  def data_type_key("custom." <> id) when id != "", do: id
  def data_type_key(_), do: nil

  @doc "The Bubble type of a record of data type `key` (inverse of `data_type_key/1`)."
  @spec record_type(String.t()) :: String.t()
  def record_type("user"), do: "user"
  def record_type(key), do: "custom." <> key

  @spec option_set_key(term()) :: String.t() | nil
  def option_set_key("list." <> item), do: option_set_key(item)
  def option_set_key("option." <> id) when id != "", do: id
  def option_set_key(_), do: nil
end
