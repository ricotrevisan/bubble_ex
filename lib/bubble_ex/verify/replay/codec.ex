defmodule BubbleEx.Verify.Replay.Codec do
  @moduledoc """
  Between `BubbleEx.Verify.Value`s (seeds, observations) and Data API JSON.

  **Encoding (seeding).** Text, numbers, yes/no, files and images as they
  are; dates as ISO 8601; a `ref` as the Bubble ID the ledger bound its key
  to; an option as its key; a geographic address as its formatted address;
  `json` verbatim; lists item by item. Ranges and date intervals are not
  seeded yet (`:invalid_input`): their Data API form is unverified.

  **Decoding (observations).** Guided by the seed value's type when the
  seed has one, and by the built-in fields (`Created Date`, `Modified
  Date` are dates; `Created By` is a reference) otherwise. A Bubble ID the
  ledger knows becomes a `ref` to its seed key; one it does not (a record
  this run did not create) becomes `{"json": {"unmapped_id": true}}`, never
  the ID itself.
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Replay.{Ledger, Target}
  alias BubbleEx.Verify.Value

  @doc "Encodes a value for a Data API body."
  @spec encode(Value.t(), Ledger.t()) :: {:ok, term()} | {:error, Error.t()}
  def encode({:list, items}, ledger) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case encode(item, ledger) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  def encode({:ref, key}, ledger) do
    case Ledger.id(ledger, key) do
      nil -> {:error, Error.new(:invalid_input, "reference to an unseeded record", %{ref: key})}
      id -> {:ok, id}
    end
  end

  def encode({:date, ms}, _ledger),
    do: {:ok, ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()}

  def encode({:geographic_address, %{formatted_address: address}}, _ledger)
      when is_binary(address),
      do: {:ok, address}

  def encode({tag, value}, _ledger)
      when tag in [:text, :number, :boolean, :file, :image, :option, :json],
      do: {:ok, value}

  def encode({tag, _}, _ledger),
    do:
      {:error,
       Error.new(:invalid_input, "this value type is not seeded through the Data API yet", %{
         type: tag
       })}

  @doc """
  Decodes a Data API value of field `field` into a `Value`, guided by the
  seed's value `hint` (or nil).
  """
  @spec decode(term(), String.t(), Value.t(), Ledger.t()) :: Value.t()
  def decode(nil, _field, _hint, _ledger), do: nil
  def decode([], _field, _hint, _ledger), do: nil

  def decode(list, field, hint, ledger) when is_list(list) do
    item_hint =
      case hint do
        {:list, [first | _]} -> first
        _ -> nil
      end

    items = Enum.map(list, &decode(&1, field, item_hint, ledger))

    # A Value list has one item type and no empty items; anything else is
    # kept as JSON.
    case items |> Enum.map(&(&1 && elem(&1, 0))) |> Enum.uniq() do
      [tag] when tag not in [nil, :list] -> {:list, items}
      _ -> {:json, list}
    end
  end

  def decode(raw, _field, {:ref, _}, ledger), do: ref(raw, ledger)
  def decode(raw, "Created By", _hint, ledger), do: ref(raw, ledger)
  def decode(raw, _field, {:date, _}, _ledger), do: date(raw)

  def decode(raw, field, nil, _ledger) when field in ["Created Date", "Modified Date"],
    do: date(raw)

  def decode(raw, _field, {:text, _}, _ledger) when is_binary(raw), do: {:text, raw}
  def decode(raw, _field, {:option, _}, _ledger) when is_binary(raw), do: {:option, raw}
  def decode(raw, _field, {:number, _}, _ledger) when is_number(raw), do: {:number, raw / 1}
  def decode(raw, _field, {:boolean, _}, _ledger) when is_boolean(raw), do: {:boolean, raw}

  def decode(raw, _field, {tag, _}, _ledger) when tag in [:file, :image] and is_binary(raw),
    do: {tag, if(String.starts_with?(raw, "//"), do: "https:" <> raw, else: raw)}

  def decode(raw, _field, nil, ledger) when is_binary(raw) do
    if Target.record_id?(raw), do: ref(raw, ledger), else: {:text, raw}
  end

  def decode(raw, _field, _hint, _ledger) when is_number(raw), do: {:number, raw / 1}
  def decode(raw, _field, _hint, _ledger) when is_boolean(raw), do: {:boolean, raw}
  def decode(raw, _field, _hint, _ledger), do: {:json, raw}

  defp ref(id, ledger) when is_binary(id) do
    case Ledger.key_for_id(ledger, id) do
      nil -> {:json, %{"unmapped_id" => true}}
      key -> {:ref, key}
    end
  end

  defp ref(raw, _ledger), do: {:json, raw}

  defp date(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> {:date, DateTime.to_unix(dt, :millisecond)}
      _ -> {:json, raw}
    end
  end

  defp date(raw) when is_integer(raw), do: {:date, raw}
  defp date(raw), do: {:json, raw}
end
