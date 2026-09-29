defmodule BubbleEx.Verify.Calibration do
  @moduledoc """
  Calibrates the privacy interpreter (`BubbleEx.Verify.Interpreter`)
  against Bubble recordings of a privacy matrix (V5 of WTF-358, WTF-426):
  per op, whether the interpreter's prediction agrees with what Bubble
  answered, and per assumption flag
  (`BubbleEx.Verify.Interpreter.Assumptions`), how the ops that depend on
  it fare and what flipping it would fix or break.

      {:ok, report} = Calibration.compare(model, plan, bubble_recordings)
      report.agree / report.ops
      report.flags[:actor_empty_denies]
      #=> %{dependent: 83, agree: 14, disagree: 69, flip_fixes: 64, flip_breaks: 5, verdict: :refuted}

  **Fair by default.** Bubble's Data API omits empty fields and answers a
  readable record with no field to show exactly like a hidden one (ID
  only). Predictions are therefore compared as the Data API would show
  them (`BubbleEx.Verify.DataApi`): visible fields restricted to those the
  seed record holds, and a readable record with no held field as ID-only
  (`held_only: false` compares raw verdicts instead). The ID-only case is
  counted explicitly: `id_only.ambiguous` ops predicted readable but
  answered ID-only, and of those `id_only.found_by_search` where the same
  scenario's search found the record (telling the two cases apart).

  **Verdicts** (`verdict`, a suggestion for `Assumptions.evidence/0`, never
  applied automatically): `:not_exercised` when no op depends on the flag;
  with fewer than `:min_samples` dependent ops (default 10),
  `:leaning_flipped` when flipping fixes more than it breaks, else
  `:unclear`; otherwise `:refuted` when flipping fixes more than it breaks
  and most dependent ops disagree, `:supported` when flipping breaks more
  than it fixes, else `:unclear`. A disagreement can also mean the model
  is stale (privacy rules changed since the export the matrix was built
  from): refresh the export before trusting a verdict.

  Only complete Bubble recordings of the plan's scenarios are compared;
  others are counted in `skipped`.
  """

  alias BubbleEx.{Error, Model}
  alias BubbleEx.Verify.{DataApi, Observation, Recording, Scenario, Seed}
  alias BubbleEx.Verify.Interpreter
  alias BubbleEx.Verify.Interpreter.{Assumptions, Dataset}

  @min_samples 10

  @type flag_report :: %{
          dependent: non_neg_integer(),
          agree: non_neg_integer(),
          disagree: non_neg_integer(),
          flip_fixes: non_neg_integer(),
          flip_breaks: non_neg_integer(),
          verdict: Assumptions.status()
        }

  @type report :: %{
          ops: non_neg_integer(),
          agree: non_neg_integer(),
          disagree: non_neg_integer(),
          held_only: boolean(),
          flags: %{Assumptions.name() => flag_report()},
          id_only: %{ambiguous: non_neg_integer(), found_by_search: non_neg_integer()},
          disagreements: [%{scenario: String.t(), op: String.t()}],
          skipped: non_neg_integer()
        }

  @doc """
  Compares Bubble `recordings` with the interpreter's predictions for the
  matrix `plan` (`%{seed, scenarios}`: a `BubbleEx.Verify.Matrix` or
  `BubbleEx.Target.Ash.MatrixTests.plan/1`) built from `model`.

  Options: `:assumptions` (the reading compared, default Bubble's:
  `Assumptions.defaults/0` with these overrides), `:held_only` (default
  true), `:min_samples` (default #{@min_samples}).
  """
  @spec compare(Model.t(), map(), [Recording.t()], keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def compare(model, plan, recordings, opts \\ [])

  def compare(%Model{} = model, %{seed: %Seed{} = seed, scenarios: scenarios}, recordings, opts)
      when is_list(recordings) do
    with {:ok, interpreter} <-
           Interpreter.new(model, assumptions: Keyword.get(opts, :assumptions, [])),
         {:ok, ds} <- Dataset.from_seed(seed) do
      held_only = Keyword.get(opts, :held_only, true)
      held = DataApi.held_map(seed)
      by_id = Map.new(scenarios, &{&1.id, &1})

      {usable, skipped} =
        Enum.split_with(recordings, fn r ->
          r.oracle == :bubble and r.complete and Map.has_key?(by_id, r.scenario.id)
        end)

      readings =
        [{:base, interpreter}] ++
          for flag <- Assumptions.names(),
              do:
                {flag,
                 %{interpreter | assumptions: Assumptions.flip(interpreter.assumptions, flag)}}

      ctx = %{ds: ds, seed: seed, held: held, held_only: held_only, readings: readings}

      ops =
        for r <- Enum.sort_by(usable, & &1.scenario.id),
            scenario = by_id[r.scenario.id],
            op <- scenario.ops,
            op.op in [:get, :search],
            do: op_outcome(ctx, scenario, op, r)

      {:ok,
       report(ops, held_only, length(skipped), Keyword.get(opts, :min_samples, @min_samples))}
    end
  end

  def compare(_model, _plan, _recordings, _opts),
    do:
      {:error,
       Error.new(:invalid_input, "expected a Model, a matrix plan and a list of recordings")}

  # One op: what Bubble recorded, and per reading whether the prediction
  # agrees with it.
  defp op_outcome(ctx, %Scenario{} = scenario, op, recording) do
    user = ctx.seed.personas[scenario.persona][:user]
    type = Dataset.type_id(op.type)

    recorded =
      recording.observations
      |> Enum.filter(&(&1.op == op.id))
      |> view(ctx)
      |> comparable()

    predictions =
      Map.new(ctx.readings, fn {name, interpreter} ->
        {name, ctx |> predict(interpreter, op, user, type) |> view(ctx) |> comparable()}
      end)

    %{
      scenario: scenario.id,
      op: op.id,
      agrees: Map.new(predictions, fn {name, p} -> {name, p == recorded} end),
      changed: Map.new(predictions, fn {name, p} -> {name, p != predictions.base} end),
      ambiguous: ambiguous(ctx, op, user, type, recording)
    }
  end

  defp view(observations, %{held_only: true, held: held}), do: DataApi.project(observations, held)
  defp view(observations, _ctx), do: observations

  defp comparable(observations) do
    observations
    |> Enum.map(fn
      %Observation{kind: :record_set, value: v} ->
        {:record_set, nil, Enum.sort(v.records)}

      %Observation{kind: :visible_fields, value: v} = o ->
        {:visible_fields, o.record, Enum.sort(v)}

      o ->
        {o.kind, o.record, o.value}
    end)
    |> Enum.sort()
  end

  defp predict(ctx, interpreter, %{op: :get} = op, user, _type) do
    {visible, fields, _unknown, _searchable} =
      Interpreter.observe(interpreter, ctx.ds, user, op.record)

    for kind <- op.observe, kind in [:visible, :visible_fields] do
      value = if kind == :visible, do: visible == true, else: Enum.sort(fields)
      %Observation{op: op.id, kind: kind, record: op.record, value: value}
    end
  end

  defp predict(ctx, interpreter, %{op: :search} = op, user, type) do
    records =
      for key <- Dataset.keys(ctx.ds, type),
          {_, _, _, true} <- [Interpreter.observe(interpreter, ctx.ds, user, key)],
          do: key

    [
      %Observation{
        op: op.id,
        kind: :record_set,
        value: %{ordered: false, records: Enum.sort(records)}
      }
    ]
  end

  # A get predicted readable whose Data API answer is ID-only, and whether
  # the scenario's search found the record.
  defp ambiguous(ctx, %{op: :get} = op, user, _type, recording) do
    {_, interpreter} = List.keyfind(ctx.readings, :base, 0)
    {visible, fields, _, _} = Interpreter.observe(interpreter, ctx.ds, user, op.record)

    if DataApi.ambiguous?(visible == true, fields, Map.get(ctx.held, op.record, [])) do
      found =
        Enum.any?(recording.observations, fn
          %Observation{kind: :record_set, value: %{records: records}} -> op.record in records
          _ -> false
        end)

      {:ambiguous, found}
    end
  end

  defp ambiguous(_ctx, _op, _user, _type, _recording), do: nil

  defp report(ops, held_only, skipped, min_samples) do
    agree = Enum.count(ops, & &1.agrees.base)

    %{
      ops: length(ops),
      agree: agree,
      disagree: length(ops) - agree,
      held_only: held_only,
      flags: Map.new(Assumptions.names(), &{&1, flag_report(ops, &1, min_samples)}),
      id_only: %{
        ambiguous: Enum.count(ops, &match?({:ambiguous, _}, &1.ambiguous)),
        found_by_search: Enum.count(ops, &match?({:ambiguous, true}, &1.ambiguous))
      },
      disagreements: for(%{agrees: %{base: false}} = o <- ops, do: Map.take(o, [:scenario, :op])),
      skipped: skipped
    }
  end

  # An op depends on a flag when flipping it changes the prediction (as
  # the Data API shows it). Of those: agreeing and disagreeing now, and
  # the disagreements the flip fixes and agreements it breaks.
  defp flag_report(ops, flag, min_samples) do
    dependent = Enum.filter(ops, & &1.changed[flag])
    agree = Enum.count(dependent, & &1.agrees.base)

    counts = %{
      dependent: length(dependent),
      agree: agree,
      disagree: length(dependent) - agree,
      flip_fixes: Enum.count(dependent, &(not &1.agrees.base and &1.agrees[flag])),
      flip_breaks: Enum.count(dependent, &(&1.agrees.base and not &1.agrees[flag]))
    }

    Map.put(counts, :verdict, verdict(counts, min_samples))
  end

  defp verdict(%{dependent: 0}, _min), do: :not_exercised

  defp verdict(%{dependent: n, flip_fixes: fixes, flip_breaks: breaks}, min) when n < min,
    do: if(fixes > breaks, do: :leaning_flipped, else: :unclear)

  defp verdict(%{flip_fixes: fixes, flip_breaks: breaks, disagree: d, agree: a}, _min) do
    cond do
      fixes > breaks and d > a -> :refuted
      breaks > fixes -> :supported
      true -> :unclear
    end
  end
end
