defmodule BubbleEx.Verify.Mask do
  @moduledoc """
  A mask marks part of an observation as nondeterministic, so a comparison
  ignores it (or, for times, compares it within a tolerance).

  Scenarios declare masks known in advance (values from `random*`
  operators, "now"); recordings add the ones found by recording twice
  (`differential`: the two Bubble runs disagreed) and the IDs of records
  created during the run (`created_id`).

  JSON:

  ```json
  {"op": "o1", "kind": "response", "record": null,
   "pointer": "/body/*/created_at", "reason": "time", "tolerance_ms": 5000}
  ```

    * `op` - the scenario op ID whose observations it covers (required)
    * `kind` - one observation kind (`BubbleEx.Verify.Observation.kinds/0`),
      or `null` for every kind of that op
    * `record` - one record key, or `null` for every record
    * `pointer` - an RFC 6901 JSON pointer into the observation's JSON
      `value` (`""`: the whole value); a `*` segment matches every member or
      item. A pointer that matches nothing masks nothing
    * `reason` - `random`, `time`, `created_id`, `differential` or
      `external`
    * `tolerance_ms` - `time` masks only: compare within this many
      milliseconds of the recording's `t0`-relative value instead of
      ignoring it. `null` ignores the value

  `masked_value/2` replaces every masked part of an observation's JSON value by
  `{"masked": "<reason>"}`, except tolerance masks, which a comparator
  applies itself.
  """

  alias BubbleEx.Verify.{Json, Observation}

  @reasons [:random, :time, :created_id, :differential, :external]
  @members ~w(op kind record pointer reason tolerance_ms)

  @type reason :: :random | :time | :created_id | :differential | :external
  @type t :: %__MODULE__{
          op: String.t(),
          kind: Observation.kind() | nil,
          record: String.t() | nil,
          pointer: String.t(),
          reason: reason(),
          tolerance_ms: non_neg_integer() | nil
        }

  @enforce_keys [:op, :reason]
  defstruct [:op, :kind, :record, :reason, :tolerance_ms, pointer: ""]

  @doc "The reasons."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc "Decodes and validates the JSON form."
  @spec from_map(term()) :: {:ok, t()} | {:error, BubbleEx.Error.t()}
  def from_map(map) do
    with :ok <- Json.members(map, @members, ~w(op reason), "mask"),
         {:ok, op} <- Json.symbol(map["op"], "mask op"),
         {:ok, kind} <- Json.optional_enum(map["kind"], Observation.kinds(), "mask kind"),
         {:ok, record} <- optional_symbol(map["record"], "mask record"),
         {:ok, pointer} <- pointer(Map.get(map, "pointer", "")),
         {:ok, reason} <- Json.enum(map["reason"], @reasons, "mask reason"),
         {:ok, tolerance} <- Json.count(map["tolerance_ms"], "mask tolerance_ms", :optional),
         :ok <- tolerance(reason, tolerance) do
      {:ok,
       %__MODULE__{
         op: op,
         kind: kind,
         record: record,
         pointer: pointer,
         reason: reason,
         tolerance_ms: tolerance
       }}
    end
  end

  defp optional_symbol(nil, _), do: {:ok, nil}
  defp optional_symbol(value, name), do: Json.symbol(value, name)

  defp pointer("" = p), do: {:ok, p}
  defp pointer("/" <> _ = p), do: {:ok, p}
  defp pointer(p), do: Json.error("mask pointer must be \"\" or start with /", %{pointer: p})

  defp tolerance(:time, _), do: :ok
  defp tolerance(_reason, nil), do: :ok
  defp tolerance(_reason, _), do: Json.error("only time masks have a tolerance_ms")

  @doc "JSON form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = m) do
    %{
      "op" => m.op,
      "kind" => Json.json(m.kind),
      "record" => m.record,
      "pointer" => m.pointer,
      "reason" => Atom.to_string(m.reason),
      "tolerance_ms" => m.tolerance_ms
    }
  end

  @doc "Canonical order: by op, kind, record, pointer, reason."
  @spec sort([t()]) :: [t()]
  def sort(masks) do
    masks
    |> Enum.sort_by(&{&1.op, to_string(&1.kind), &1.record || "", &1.pointer, &1.reason})
    |> Enum.dedup()
  end

  @doc "Whether `mask` covers observation `obs`."
  @spec covers?(t(), Observation.t()) :: boolean()
  def covers?(%__MODULE__{} = m, %Observation{} = obs) do
    m.op == obs.op and m.kind in [nil, obs.kind] and m.record in [nil, obs.record]
  end

  @doc """
  The observation's JSON value (`Observation.value_json/1`) with every part
  an ignoring mask covers replaced by `{"masked": "<reason>"}`.
  """
  @spec masked_value(Observation.t(), [t()]) :: term()
  def masked_value(%Observation{} = obs, masks) do
    masks
    |> Enum.filter(&(is_nil(&1.tolerance_ms) and covers?(&1, obs)))
    |> Enum.reduce(Observation.value_json(obs), fn m, value ->
      replace(value, segments(m.pointer), %{"masked" => Atom.to_string(m.reason)})
    end)
  end

  defp segments(""), do: []

  defp segments("/" <> rest) do
    rest
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
  end

  defp replace(_value, [], marker), do: marker

  defp replace(map, ["*" | rest], marker) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, replace(v, rest, marker)} end)

  defp replace(list, ["*" | rest], marker) when is_list(list),
    do: Enum.map(list, &replace(&1, rest, marker))

  defp replace(map, [key | rest], marker) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> Map.put(map, key, replace(v, rest, marker))
      :error -> map
    end
  end

  defp replace(list, [index | rest], marker) when is_list(list) do
    case Integer.parse(index) do
      {i, ""} when i >= 0 and i < length(list) ->
        List.update_at(list, i, &replace(&1, rest, marker))

      _ ->
        list
    end
  end

  defp replace(value, _segments, _marker), do: value
end
