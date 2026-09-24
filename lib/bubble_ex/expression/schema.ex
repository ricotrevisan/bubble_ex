defmodule BubbleEx.Expression.Schema do
  @moduledoc """
  Data-type field lookup used to type field chains. Built from `user_types` in
  either key form: `.bubble` exports (`display`, `fields`, `value`) or the live
  payload (`%d`, `%f3`, `%v`).
  """

  alias BubbleEx.Expression.Vocabulary

  @type field :: %{display: String.t() | nil, value: String.t() | nil}
  @type t :: %{
          optional(String.t()) => %{display: String.t() | nil, fields: %{String.t() => field()}}
        }

  @spec from_app(term()) :: t()
  def from_app(%{"user_types" => types}), do: from_user_types(types)
  def from_app(_), do: %{}

  @spec from_user_types(term()) :: t()
  def from_user_types(types) when is_map(types) do
    for {id, type} <- types, is_map(type), into: %{} do
      {id, %{display: text(type, ["display", "%d"]), fields: fields(type)}}
    end
  end

  def from_user_types(_), do: %{}

  @doc "The Bubble value type of a record of data type `type_id`."
  @spec thing_type(String.t()) :: String.t()
  def thing_type("user"), do: "user"
  def thing_type(type_id), do: "custom." <> type_id

  @doc """
  Resolves `field` on a subject of Bubble type `subject_type`. Fields on a list
  map over its items, so their type becomes a list.
  """
  @spec field(t(), String.t() | nil, String.t()) :: {:ok, field()} | :unknown_type | :error
  def field(schema, "list." <> item_type, name) do
    with {:ok, field} <- field(schema, item_type, name),
         do: {:ok, %{field | value: listed(field.value)}}
  end

  def field(schema, subject_type, name) do
    case {Vocabulary.builtin_field(name), type_id(subject_type)} do
      {{_, value}, id} when is_binary(id) -> {:ok, %{display: name, value: value}}
      {_, nil} -> :unknown_type
      {_, id} -> lookup(schema, id, name)
    end
  end

  # Built into every Bubble User but absent from exported field lists.
  defp lookup(_schema, "user", "email"), do: {:ok, %{display: "email", value: "text"}}

  defp lookup(schema, id, name) do
    case schema do
      %{^id => %{fields: %{^name => field}}} -> {:ok, field}
      %{^id => _} -> :error
      _ -> :unknown_type
    end
  end

  defp type_id("user"), do: "user"
  defp type_id("custom." <> id), do: id
  defp type_id(_), do: nil

  defp listed(nil), do: nil
  defp listed("list." <> _ = value), do: value
  defp listed(value), do: "list." <> value

  defp fields(type) do
    case Map.get(type, "fields") || Map.get(type, "%f3") do
      fields when is_map(fields) ->
        for {id, field} <- fields, is_map(field), into: %{} do
          {id, %{display: text(field, ["display", "%d"]), value: text(field, ["value", "%v"])}}
        end

      _ ->
        %{}
    end
  end

  defp text(map, keys), do: Enum.find_value(keys, &(is_binary(map[&1]) && map[&1]))
end
