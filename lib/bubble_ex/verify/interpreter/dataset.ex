defmodule BubbleEx.Verify.Interpreter.Dataset do
  @moduledoc """
  The records the privacy interpreter reads: symbolic keys to a data type ID
  (the Model's, e.g. `"task"`, `"user"`) and field values keyed by field
  Bubble ID, as canonical `BubbleEx.Verify.Value`s (`{:ref, key}` names
  another record). A reference to a key with no record is dangling, as a
  deleted record's ID left behind in Bubble data.

  A field a record **omits** holds what Bubble stores on creation: its
  default, if it has one (`defaults_applied_at_creation`, see
  `BubbleEx.Verify.Interpreter.Assumptions`), else empty. A field present
  with `nil` is **explicitly empty** (cleared), default or not.

  Built from a `BubbleEx.Verify.Seed` (`from_seed/1`) or directly
  (`new/1`), e.g. from data loaded elsewhere. Matrix synthesis also holds
  *open* records: their unset fields are still to be chosen, and reading one
  asks the caller for a value (see `BubbleEx.Verify.Interpreter.Eval`).
  """

  alias BubbleEx.Error
  alias BubbleEx.Model.Type
  alias BubbleEx.Verify.{Seed, Value}

  @type entry :: %{type: String.t(), fields: %{String.t() => Value.t()}, open: boolean()}
  @type t :: %__MODULE__{records: %{String.t() => entry()}}

  defstruct records: %{}

  @doc """
  A dataset from `{key, type_id, fields}` triples (or maps with those
  keys). A `nil` value is kept as an explicitly empty field; every value
  must be canonical.
  """
  @spec new([{String.t(), String.t(), map()} | map()]) :: {:ok, t()} | {:error, Error.t()}
  def new(records) do
    Enum.reduce_while(records, {:ok, %__MODULE__{}}, fn record, {:ok, ds} ->
      {key, type, fields} = triple(record)

      with {:ok, fields} <- canonical(fields, key),
           false <- Map.has_key?(ds.records, key) do
        {:cont, {:ok, put(ds, key, type, fields)}}
      else
        true -> {:halt, {:error, Error.new(:invalid_input, "duplicate record key", %{key: key})}}
        error -> {:halt, error}
      end
    end)
  end

  defp triple({key, type, fields}), do: {key, type, fields}
  defp triple(%{key: key, type: type, fields: fields}), do: {key, type, fields}

  defp canonical(fields, key) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {field, value}, {:ok, acc} ->
      case Value.canonical(value) do
        {:ok, v} -> {:cont, {:ok, Map.put(acc, field, v)}}
        {:error, e} -> {:halt, {:error, %{e | context: Map.merge(e.context, %{record: key})}}}
      end
    end)
  end

  @doc "The dataset of a seed set: record types are converted to Model type IDs."
  @spec from_seed(Seed.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_seed(%Seed{records: records}) do
    records
    |> Enum.map(fn r -> {r.key, type_id(r.type), r.fields} end)
    |> new()
  end

  @doc "`\"custom.task\"` -> `\"task\"`; `\"user\"` stays."
  @spec type_id(String.t()) :: String.t()
  def type_id(descriptor) do
    case Type.reference(descriptor) do
      {:data_type, id} -> id
      _ -> descriptor
    end
  end

  @doc "Adds or replaces a record (closed unless `open`)."
  @spec put(t(), String.t(), String.t(), map(), boolean()) :: t()
  def put(%__MODULE__{} = ds, key, type, fields, open \\ false),
    do: %{ds | records: Map.put(ds.records, key, %{type: type, fields: fields, open: open})}

  @doc "Sets one field of an existing record (`nil` leaves it empty but set)."
  @spec set(t(), String.t(), String.t(), Value.t()) :: t()
  def set(%__MODULE__{} = ds, key, field, value),
    do: update_in(ds.records[key].fields, &Map.put(&1, field, value))

  @doc "The record with `key`, or nil (a dangling key)."
  @spec fetch(t(), String.t()) :: entry() | nil
  def fetch(%__MODULE__{records: records}, key), do: Map.get(records, key)

  @doc "Keys of the records of type `type_id`, sorted."
  @spec keys(t(), String.t()) :: [String.t()]
  def keys(%__MODULE__{records: records}, type_id),
    do: for({k, %{type: ^type_id}} <- records, do: k) |> Enum.sort()

  @doc """
  Closes every open record: its unset fields are omitted (as created: a
  default applies), and fields set to `nil` stay explicitly empty.
  """
  @spec close(t()) :: t()
  def close(%__MODULE__{} = ds) do
    records = Map.new(ds.records, fn {k, r} -> {k, %{r | open: false}} end)
    %{ds | records: records}
  end
end
