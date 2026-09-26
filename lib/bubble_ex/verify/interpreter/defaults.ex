defmodule BubbleEx.Verify.Interpreter.Defaults do
  @moduledoc """
  Field defaults as the privacy interpreter reads them (WTF-338: defaults
  are kept): what Bubble stores in a field a record was created without,
  under the `defaults_applied_at_creation` assumption
  (`BubbleEx.Verify.Interpreter.Assumptions`).

  `build/1` maps every data type's fields with a default to
  `{:ok, value}` (a canonical `BubbleEx.Verify.Value`) or `:unmodeled` (a
  default the interpreter cannot express: a list or reference default, a
  value that does not fit the field's type, an option key the set does not
  have). The mapping mirrors `BubbleEx.Target.Ash`'s: text, number (a
  float), yes/no, a file or image URL, a fixed ISO 8601 date and an option
  key. Reading an omitted field whose default is `:unmodeled` makes a
  verdict unknown, never a guess.
  """

  alias BubbleEx.Model
  alias BubbleEx.Model.{Field, Type}
  alias BubbleEx.Verify.Value

  @type entry :: {:ok, Value.t()} | :unmodeled
  @type t :: %{String.t() => %{String.t() => entry()}}

  @doc "The defaults of every data type's fields, by type ID then field ID."
  @spec build(Model.t()) :: t()
  def build(%Model{} = model) do
    for type <- model.data_types,
        fields = defaults(type.fields, model),
        fields != %{},
        into: %{},
        do: {type.id, fields}
  end

  defp defaults(fields, model) do
    for %Field{default: default} = f <- fields,
        default != nil,
        is_nil(f.system),
        into: %{},
        do: {f.id, value(f.type, default, model)}
  end

  @doc "A default as a canonical value of `type`, or `:unmodeled`."
  @spec value(Type.t(), term(), Model.t()) :: entry()
  def value(%Type{cardinality: :one} = type, raw, model) do
    case {type.kind, type.base, raw} do
      {:scalar, :text, v} when is_binary(v) -> {:ok, {:text, v}}
      {:scalar, :number, v} when is_number(v) -> canonical({:number, v / 1})
      {:scalar, :boolean, v} when is_boolean(v) -> {:ok, {:boolean, v}}
      {:scalar, :date, v} when is_binary(v) -> date(v)
      {:file_ref, base, v} when base in [:file, :image] and is_binary(v) -> canonical({base, v})
      {:option, _, v} when is_binary(v) -> option(model, type.target, v)
      _ -> :unmodeled
    end
  end

  def value(_type, _raw, _model), do: :unmodeled

  defp canonical(value) do
    case Value.canonical(value) do
      {:ok, v} when v != nil -> {:ok, v}
      _ -> :unmodeled
    end
  end

  defp date(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, {:date, DateTime.to_unix(datetime, :millisecond)}}
      {:error, _} -> :unmodeled
    end
  end

  defp option(model, set_id, key) do
    case Model.option_set(model, set_id) do
      %{values: values} ->
        if Enum.any?(values, &(&1.key == key and not &1.deleted)),
          do: {:ok, {:option, key}},
          else: :unmodeled

      nil ->
        :unmodeled
    end
  end
end
