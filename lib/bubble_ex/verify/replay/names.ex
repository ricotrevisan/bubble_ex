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
  """

  alias BubbleEx.Error
  alias BubbleEx.Model
  alias BubbleEx.Model.Type

  @type t :: %__MODULE__{
          types: %{String.t() => String.t()},
          fields: %{String.t() => %{String.t() => String.t()}}
        }

  defstruct types: %{}, fields: %{}

  @doc """
  Explicit names: `types` maps type descriptors to Data API paths,
  `fields` maps type descriptors to `%{field ID => Data API key}`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    attrs = Map.new(attrs)
    names = %__MODULE__{types: Map.get(attrs, :types, %{}), fields: Map.get(attrs, :fields, %{})}

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
  def from_model(%Model{data_types: types}) do
    live = Enum.reject(types, & &1.deleted)

    new(
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
