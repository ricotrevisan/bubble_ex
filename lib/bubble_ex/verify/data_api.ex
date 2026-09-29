defmodule BubbleEx.Verify.DataApi do
  @moduledoc """
  What Bubble's Data API can show of a privacy verdict, so that
  predictions and other subjects compare fairly with Bubble recordings
  (WTF-426, from the V5 calibration of WTF-385).

  **The Data API omits empty fields.** A `get` answers only the fields
  that hold a value, so a field the persona may view but that is empty on
  the record never appears. Comparisons therefore restrict predicted (and
  observed) visible fields to the fields the record **holds**
  (`held/2`): its non-empty seed values, plus the built-in fields Bubble
  always fills (`Created Date`, `Modified Date` and `Created By`, which a
  create sets itself). This is the default of every comparison against a
  Bubble recording (`BubbleEx.Verify.Calibration`,
  `BubbleEx.Verify.Matrix.result/4`, `BubbleEx.Target.Ash.MatrixTests`).

  **An ID-only answer is ambiguous.** A `get` of a record the privacy
  rules hide answers 200 with only `_id`, and so does a `get` of a record
  the persona may read when no field it may view holds a value (observed:
  an `everyone` rule granting search and two listed fields, both empty).
  The recorder records both as `visible: false` with no fields.
  `answer/3` models this explicitly: a verdict's Data API answer is
  `:id_only` when it is not visible, or visible with no held field; and
  `{:fields, fields}` otherwise. Two verdicts compare equal when their
  answers do. A search op tells the two ID-only cases apart (the search
  finds a readable record, `search_independent_of_view` permitting), which
  `ambiguous?/3` flags.
  """

  alias BubbleEx.Verify.{Observation, Seed}

  @always_held ["Created By", "Created Date", "Modified Date"]

  @type answer :: :id_only | {:fields, [String.t()]}

  @doc "The built-in fields every created record holds (Bubble sets them)."
  @spec always_held() :: [String.t()]
  def always_held, do: @always_held

  @doc """
  The fields seed record `key` holds once created: its non-empty values
  and the built-ins Bubble sets. Sorted. An unknown key holds only the
  built-ins.
  """
  @spec held(Seed.t(), String.t()) :: [String.t()]
  def held(%Seed{} = seed, key) do
    fields =
      case Seed.record(seed, key) do
        %{fields: fields} -> for {f, v} <- fields, not empty?(v), do: f
        nil -> []
      end

    Enum.sort(Enum.uniq(fields ++ @always_held))
  end

  @doc "`held/2` for every record of the seed: `%{key => fields}`."
  @spec held_map(Seed.t()) :: %{String.t() => [String.t()]}
  def held_map(%Seed{} = seed), do: Map.new(seed.records, &{&1.key, held(seed, &1.key)})

  defp empty?(v), do: v in [nil, {:text, ""}, {:list, []}]

  @doc """
  The Data API answer to a `get` for a verdict (`visible`, `fields`) on a
  record holding `held`: `:id_only` or `{:fields, visible held fields}`.
  """
  @spec answer(boolean(), [String.t()], [String.t()]) :: answer()
  def answer(false, _fields, _held), do: :id_only

  def answer(true, fields, held) do
    case Enum.sort(Enum.uniq(fields)) -- (Enum.sort(Enum.uniq(fields)) -- held) do
      [] -> :id_only
      shown -> {:fields, shown}
    end
  end

  @doc """
  Whether a verdict's ID-only answer hides a readable record: visible
  (or found by the search) with no held field to show.
  """
  @spec ambiguous?(boolean(), [String.t()], [String.t()]) :: boolean()
  def ambiguous?(visible, fields, held), do: visible and answer(true, fields, held) == :id_only

  @doc """
  Observations as the Data API would show them, given each record's held
  fields (`held_map/1`): a `get`'s `visible` and `visible_fields` become
  its `answer/3` (`visible: false` and no fields for `:id_only`); `values`
  keep only the fields shown; other kinds are unchanged.
  """
  @spec project([Observation.t()], %{String.t() => [String.t()]}) :: [Observation.t()]
  def project(observations, held) do
    answers =
      observations
      |> Enum.filter(&(&1.kind in [:visible, :visible_fields]))
      |> Enum.group_by(&{&1.op, &1.record})
      |> Map.new(fn {{_op, record} = key, obs} ->
        {key, get_answer(obs, held_of(held, record))}
      end)

    Enum.map(observations, &shown(&1, answers[{&1.op, &1.record}], held))
  end

  defp held_of(held, record), do: Map.get(held, record, @always_held)

  # A get observing only its fields is visible when it shows any.
  defp get_answer(obs, held) do
    fields = Enum.find_value(obs, [], &(&1.kind == :visible_fields && &1.value))

    visible =
      case Enum.find(obs, &(&1.kind == :visible)) do
        nil -> fields != []
        o -> o.value == true
      end

    answer(visible, fields, held)
  end

  defp shown(%{kind: :visible} = o, :id_only, _held), do: %{o | value: false}
  defp shown(%{kind: :visible} = o, {:fields, _}, _held), do: %{o | value: true}
  defp shown(%{kind: :visible_fields} = o, :id_only, _held), do: %{o | value: []}
  defp shown(%{kind: :visible_fields} = o, {:fields, f}, _held), do: %{o | value: f}

  defp shown(%{kind: :values} = o, _answer, held),
    do: %{o | value: Map.take(o.value, held_of(held, o.record))}

  defp shown(o, _answer, _held), do: o
end
