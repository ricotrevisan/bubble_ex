defmodule BubbleEx.Verify.Observation do
  @moduledoc """
  One thing an oracle saw when it ran a scenario op, in Bubble vocabulary
  (type, field, workflow and element Bubble IDs; record keys from the seed;
  `BubbleEx.Verify.Value`s).

  JSON: `{"op": "o1", "kind": "visible_fields", "record": "task_w1", "value": …}`.
  `record` is required for the per-record kinds and `null` otherwise.

  | `kind` | Ops | `value` |
  |--------|-----|---------|
  | `visible` | `get` | boolean: the persona can view the record |
  | `visible_fields` | `get` | field IDs the persona can view (a set: sorted, unique) |
  | `values` | `get` | `{field ID: Value}` of the visible fields |
  | `record_set` | `search` | `{"ordered": bool, "records": [key]}`; an unordered set is sorted and unique |
  | `status` | `call_api_workflow` | HTTP status (100–599) |
  | `response` | `call_api_workflow` | the response body, any JSON (compared after masks) |
  | `db_diff` | `call_api_workflow`, `trigger`, `visit`, `click`, `input` | `[{"change": "created"/"updated"/"deleted", "type", "record", "fields": {field ID: Value}}]` in the order the oracle saw them (creation order correlates new records) |
  | `step_trace` | `call_api_workflow`, `trigger` | `[{"workflow", "step" (1-based), "action"}]`, in execution order |
  | `dom_text` | `visit`, `click`, `input` | `{element ID: {"visible": bool, "text": string or [string]}}` (a repeating group is a list of cell texts) |
  """

  alias BubbleEx.Verify.{Json, Value}

  @kinds [
    :visible,
    :visible_fields,
    :values,
    :record_set,
    :status,
    :response,
    :db_diff,
    :step_trace,
    :dom_text
  ]
  @per_record [:visible, :visible_fields, :values]
  @changes [:created, :updated, :deleted]

  @type kind ::
          :visible
          | :visible_fields
          | :values
          | :record_set
          | :status
          | :response
          | :db_diff
          | :step_trace
          | :dom_text
  @type t :: %__MODULE__{op: String.t(), kind: kind(), record: String.t() | nil, value: term()}

  @enforce_keys [:op, :kind, :value]
  defstruct [:op, :kind, :record, :value]

  @doc "The observation kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The kinds that describe one record (`record` required)."
  @spec per_record() :: [kind()]
  def per_record, do: @per_record

  @doc "Decodes and validates the JSON form."
  @spec from_map(term()) :: {:ok, t()} | {:error, BubbleEx.Error.t()}
  def from_map(map) do
    with :ok <- Json.members(map, ~w(op kind record value), ~w(op kind value), "observation"),
         {:ok, op} <- Json.symbol(map["op"], "observation op"),
         {:ok, kind} <- Json.enum(map["kind"], @kinds, "observation kind"),
         {:ok, record} <- record(kind, map["record"]),
         {:ok, value} <- value(kind, map["value"]) do
      {:ok, %__MODULE__{op: op, kind: kind, record: record, value: value}}
    end
  end

  defp record(kind, nil) when kind in @per_record,
    do: Json.error("a #{kind} observation needs a record")

  defp record(kind, key) when kind in @per_record, do: Json.symbol(key, "observation record")
  defp record(_kind, nil), do: {:ok, nil}
  defp record(kind, _), do: Json.error("a #{kind} observation has no record")

  defp value(:visible, v), do: Json.boolean(v, "visible")
  defp value(:visible_fields, v), do: Json.string_set(v, "visible_fields")
  defp value(:values, v), do: Json.object(v, "values", &Value.cast/1)
  defp value(:status, v) when is_integer(v) and v in 100..599, do: {:ok, v}
  defp value(:status, v), do: Json.error("status must be an HTTP status", %{value: v})
  defp value(:response, v), do: {:ok, v}
  defp value(:record_set, v), do: record_set(v)
  defp value(:db_diff, v), do: Json.list(v, "db_diff", &change/1)
  defp value(:step_trace, v), do: Json.list(v, "step_trace", &step/1)
  defp value(:dom_text, v), do: Json.object(v, "dom_text", &element/1)

  defp record_set(map) do
    with :ok <- Json.members(map, ~w(ordered records), ~w(ordered records), "record_set"),
         {:ok, ordered} <- Json.boolean(map["ordered"], "record_set ordered"),
         {:ok, records} <- records(ordered, map["records"]) do
      {:ok, %{ordered: ordered, records: records}}
    end
  end

  defp records(false, keys), do: Json.string_set(keys, "record_set records", &Json.symbol/2)
  defp records(true, keys), do: Json.list(keys, "record_set records", &Json.symbol(&1, "record"))

  defp change(map) do
    with :ok <-
           Json.members(map, ~w(change type record fields), ~w(change type record), "change"),
         {:ok, change} <- Json.enum(map["change"], @changes, "db_diff change"),
         {:ok, type} <- Json.string(map["type"], "db_diff type"),
         {:ok, record} <- Json.symbol(map["record"], "db_diff record"),
         {:ok, fields} <-
           Json.object(Map.get(map, "fields", %{}), "db_diff fields", &Value.cast/1) do
      {:ok, %{change: change, type: type, record: record, fields: fields}}
    end
  end

  defp step(map) do
    with :ok <- Json.members(map, ~w(workflow step action), ~w(workflow step action), "step"),
         {:ok, workflow} <- Json.string(map["workflow"], "step workflow"),
         {:ok, action} <- Json.string(map["action"], "step action") do
      case map["step"] do
        n when is_integer(n) and n > 0 -> {:ok, %{workflow: workflow, step: n, action: action}}
        n -> Json.error("step must be a positive integer", %{value: n})
      end
    end
  end

  defp element(map) do
    with :ok <- Json.members(map, ~w(visible text), ~w(visible text), "dom_text element"),
         {:ok, visible} <- Json.boolean(map["visible"], "dom_text visible"),
         {:ok, text} <- text(map["text"]) do
      {:ok, %{visible: visible, text: text}}
    end
  end

  defp text(text) when is_binary(text), do: {:ok, text}

  defp text(texts) when is_list(texts) do
    if Enum.all?(texts, &is_binary/1),
      do: {:ok, texts},
      else: Json.error("dom_text text items must be strings")
  end

  defp text(other), do: Json.error("dom_text text must be a string or a list", %{value: other})

  @doc "JSON form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = o) do
    %{
      "op" => o.op,
      "kind" => Atom.to_string(o.kind),
      "record" => o.record,
      "value" => value_json(o)
    }
  end

  @doc "The JSON form of the observation's value."
  @spec value_json(t()) :: term()
  def value_json(%__MODULE__{kind: :values, value: fields}), do: values_json(fields)

  def value_json(%__MODULE__{kind: :db_diff, value: changes}) do
    Enum.map(changes, fn c ->
      %{
        "change" => Atom.to_string(c.change),
        "type" => c.type,
        "record" => c.record,
        "fields" => values_json(c.fields)
      }
    end)
  end

  def value_json(%__MODULE__{value: value}), do: Json.json(value)

  defp values_json(fields), do: Map.new(fields, fn {k, v} -> {k, Value.to_json(v)} end)

  @doc "Canonical order: by op, kind, record."
  @spec sort([t()]) :: [t()]
  def sort(observations),
    do:
      Enum.sort_by(
        observations,
        &{&1.op, Enum.find_index(@kinds, fn k -> k == &1.kind end), &1.record || ""}
      )

  @doc "The identity of an observation within a recording: op, kind, record."
  @spec key(t()) :: {String.t(), kind(), String.t() | nil}
  def key(%__MODULE__{op: op, kind: kind, record: record}), do: {op, kind, record}
end
