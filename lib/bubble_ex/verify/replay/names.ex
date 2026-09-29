defmodule BubbleEx.Verify.Replay.Names do
  @moduledoc """
  How the Bubble Data API names what seeds and observations name by Bubble
  ID: a type descriptor (`custom.task`, `user`) has a Data API path
  (`/obj/<path>`), and a field ID (`title_text`) has a JSON key in Data API
  bodies.

  **Unverified (WTF-358 §10, "Data API field keys can be mapped back to
  field IDs through the model").** `from_model/1` guesses Bubble's
  convention: the path is the type's display name lowercased with spaces
  removed, and a field's key is its display name (built-in fields keep
  their names: `_id`, `Created Date`, `Modified Date`, `Created By`,
  `Slug`, `email`). V5 checks the guess against a real branch; `new/1`
  takes explicit maps when it is wrong. A type or field without a mapping is
  an error, never a guess at request time.

  **Option values.** The Data API reads and writes an option-set value by
  its **display text**, not its stored key (`db_value`): on a private production app a
  create with `"sent"` for a value displayed `Sent` was refused, `"Sent"`
  accepted (WTF-385). `options` maps, per type and option field, each key
  to its display text; `to_api/4` and `from_api/4` translate seed and
  observed values. The translation is strict:

    * sending an option value for a field with no map, or whose set's
      display texts repeat (`:ambiguous`: no reversible map), is an error;
      keys are never sent in place of display texts
    * an observed display text the map does not know (or on a field with
      no map) becomes `{:json, %{"unmapped_option" => true}}`, a mismatch
      against any expected option, never a key

  Values that are not options pass through.
  """

  alias BubbleEx.Error
  alias BubbleEx.Model
  alias BubbleEx.Model.Type

  @type t :: %__MODULE__{
          types: %{String.t() => String.t()},
          fields: %{String.t() => %{String.t() => String.t()}},
          options: %{String.t() => %{String.t() => %{String.t() => String.t()}}}
        }

  defstruct types: %{}, fields: %{}, options: %{}

  @doc """
  Explicit names: `types` maps type descriptors to Data API paths,
  `fields` maps type descriptors to `%{field ID => Data API key}`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    attrs = Map.new(attrs)

    names = %__MODULE__{
      types: Map.get(attrs, :types, %{}),
      fields: Map.get(attrs, :fields, %{}),
      options: Map.get(attrs, :options, %{})
    }

    reversible? =
      Enum.all?(names.fields, fn {_type, map} ->
        map |> Map.values() |> Enum.uniq() |> length() == map_size(map)
      end)

    if reversible?,
      do: {:ok, names},
      else: {:error, Error.new(:invalid_input, "two fields of a type share a Data API key")}
  end

  @doc "Names guessed from the Model's display names (see the moduledoc)."
  @spec from_model(Model.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_model(%Model{data_types: types} = model) do
    live = Enum.reject(types, & &1.deleted)

    new(
      options:
        Map.new(live, fn t ->
          {Type.record(t.id),
           for(
             f <- t.fields,
             not f.deleted,
             match?(%Type{kind: :option}, f.type),
             into: %{},
             do: {f.id, option_map(model, f.type.target) || :ambiguous}
           )}
        end),
      types: Map.new(live, &{Type.record(&1.id), path(&1.name || &1.id)}),
      fields:
        Map.new(live, fn t ->
          fields =
            (t.system_fields ++ t.fields)
            |> Enum.reject(&(&1.deleted or &1.id == "_id"))
            |> Map.new(&{&1.id, &1.name || &1.id})

          {Type.record(t.id), fields}
        end)
    )
  end

  # key => display text, when every display text is distinct (reversible);
  # nil otherwise (the field is then `:ambiguous`).
  defp option_map(model, set_id) do
    case Model.option_set(model, set_id) do
      %{values: values} ->
        map = for v <- values, not v.deleted, is_binary(v.name), into: %{}, do: {v.key, v.name}

        if map |> Map.values() |> Enum.uniq() |> length() == map_size(map), do: map

      _ ->
        nil
    end
  end

  @doc "A seed value of `type`'s `field` in Data API form: option keys become display texts."
  @spec to_api(t(), String.t(), String.t(), term()) :: {:ok, term()} | {:error, Error.t()}
  def to_api(%__MODULE__{} = names, type, field, value) do
    case {option_map(names, type, field), options?(value)} do
      {_, false} -> {:ok, value}
      {map, true} when is_map(map) -> translate(map, value, :to_api)
      {:ambiguous, true} -> unmapped(:ambiguous_option_field)
      {nil, true} -> unmapped(:unmapped_option_field)
    end
  end

  defp unmapped(reason),
    do:
      {:error,
       Error.new(:invalid_input, "option field has no display-text mapping in the model", %{
         reason: reason
       })}

  defp options?({:option, _}), do: true
  defp options?({:list, items}), do: Enum.any?(items, &options?/1)
  defp options?(_), do: false

  @unmapped {:json, %{"unmapped_option" => true}}

  @doc "An observed value of `type`'s `field` back in seed form: display texts become keys."
  @spec from_api(t(), String.t(), String.t(), term()) :: term()
  def from_api(%__MODULE__{} = names, type, field, value) do
    inverse =
      case option_map(names, type, field) do
        map when is_map(map) -> Map.new(map, fn {k, v} -> {v, k} end)
        _ -> %{}
      end

    back(inverse, value)
  end

  defp back(inverse, {:option, v}) do
    case Map.fetch(inverse, v) do
      {:ok, key} -> {:option, key}
      :error -> @unmapped
    end
  end

  defp back(inverse, {:list, items}), do: {:list, Enum.map(items, &back(inverse, &1))}
  defp back(_inverse, value), do: value

  defp option_map(names, type, field), do: names.options |> Map.get(type, %{}) |> Map.get(field)

  defp translate(map, {:option, v}, dir) do
    case Map.fetch(map, v) do
      {:ok, out} ->
        {:ok, {:option, out}}

      :error ->
        {:error,
         Error.new(:invalid_input, "option value has no display text in the model", %{
           reason: :unknown_option,
           direction: dir
         })}
    end
  end

  defp translate(map, {:list, items}, dir) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case translate(map, item, dir) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, {:list, Enum.reverse(list)}}
      error -> error
    end
  end

  defp translate(_map, value, _dir), do: {:ok, value}

  defp path(name), do: name |> String.downcase() |> String.replace(~r/\s+/, "")

  @doc "The Data API path of a type descriptor."
  @spec type_path(t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def type_path(%__MODULE__{types: types}, type) do
    case Map.fetch(types, type) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, Error.new(:invalid_input, "no Data API path for type", %{type: type})}
    end
  end

  @doc "The Data API key of a field."
  @spec field_key(t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def field_key(%__MODULE__{fields: fields}, type, field) do
    case fields |> Map.get(type, %{}) |> Map.fetch(field) do
      {:ok, key} ->
        {:ok, key}

      :error ->
        {:error,
         Error.new(:invalid_input, "no Data API key for field", %{type: type, field: field})}
    end
  end

  @doc "The field ID of a Data API key, or nil."
  @spec field_id(t(), String.t(), String.t()) :: String.t() | nil
  def field_id(%__MODULE__{fields: fields}, type, key) do
    fields |> Map.get(type, %{}) |> Enum.find_value(fn {id, k} -> k == key && id end)
  end
end
