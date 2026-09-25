defmodule BubbleEx.Expression.Schema do
  @moduledoc """
  Data-type field lookup used to type field chains: each data type's display
  name and its fields' display names and type descriptors. It is read by the
  Model: `BubbleEx.Model.schema/1` of a built Model, or the same schema
  before privacy (which `BubbleEx.Privacy` types rule conditions against).
  """

  alias BubbleEx.Expression.Vocabulary
  alias BubbleEx.Model.Type

  @type field :: %{display: String.t() | nil, value: String.t() | nil}
  @type t :: %{
          optional(String.t()) => %{display: String.t() | nil, fields: %{String.t() => field()}}
        }

  @doc "The Bubble value type of a record of data type `type_id`."
  @spec thing_type(String.t()) :: String.t()
  defdelegate thing_type(type_id), to: Type, as: :record

  @doc """
  Resolves `field` on a subject of Bubble type `subject_type`. Fields on a list
  map over its items, so their type becomes a list.
  """
  @spec field(t(), String.t() | nil, String.t()) :: {:ok, field()} | :unknown_type | :error
  def field(schema, subject_type, name) do
    case Type.list_item(subject_type) do
      nil -> item_field(schema, subject_type, name)
      item_type -> with {:ok, field} <- field(schema, item_type, name), do: {:ok, listed(field)}
    end
  end

  defp item_field(schema, subject_type, name) do
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

  defp type_id(type) do
    case Type.reference(type) do
      {:data_type, id} -> id
      _ -> nil
    end
  end

  defp listed(%{value: nil} = field), do: field
  defp listed(field), do: %{field | value: Type.listed(field.value)}
end
