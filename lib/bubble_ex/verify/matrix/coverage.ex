defmodule BubbleEx.Verify.Matrix.Coverage do
  @moduledoc """
  What a privacy matrix actually checks, beyond branch coverage
  (`BubbleEx.Verify.Matrix`), and the synthesis that improves it.

  **Observable rules (mutation coverage).** A rule is *observable* when a
  mutant of it changes some recorded verdict (a decided cell: visible,
  visible fields, searchable): for a conditional rule, dropping it or
  negating its condition; for `everyone`, dropping its grants. A rule whose
  condition is exercised both ways can still be unobservable: other rules
  grant the same wherever it holds (*masked*), or it grants nothing.
  `isolate/3` looks, for each unobservable rule, for a new record that makes
  a mutant differ for some persona (a record where this rule alone decides),
  using the solver's goal search (`BubbleEx.Verify.Matrix.Solver.find/5`).
  `observability/4` then classifies every rule: `:observable`, or
  unobservable with a reason (`:unsolved`, `:grants_nothing`, `:masked`).

  **Checks that depend on an assumption.** V5 calibration can only settle
  an assumption flag (`BubbleEx.Verify.Interpreter.Assumptions`) if some
  recorded check depends on it. `exercise_flags/3` looks, per flag and per
  type whose rules read the shape the flag governs, for a record whose
  verdict for some persona changes when the flag flips, when no recorded
  cell of that type depends on it yet. `dangling_ref_is_empty` cannot be
  exercised: V1 seeds cannot hold a reference to a missing record. Where a
  fail-safe hedge (`everyone_guards_record_values`, `actor_empty_denies`)
  hides a flag entirely, it looks for cells that depend on the flag with
  the hedge lifted (`joint/4` counts them).
  """

  alias BubbleEx.Expression.IR
  alias BubbleEx.Verify.Interpreter
  alias BubbleEx.Verify.Interpreter.{Assumptions, Dataset, Eval}
  alias BubbleEx.Verify.Matrix.Solver

  @personas ~w(w1_member w1_other w2_member admin logged_in_empty anonymous)
  @budget 1500
  @flag_budget 600

  @unexercisable %{
    dangling_ref_is_empty:
      "seeds cannot hold a reference to a missing record (V1 seed references must resolve)"
  }

  # --- observability ------------------------------------------------------------------

  @doc """
  The dataset with records added so that unobservable rules become
  observable where possible.
  """
  @spec isolate(Interpreter.t(), Dataset.t(), map()) :: Dataset.t()
  def isolate(%Interpreter{} = interpreter, ds, personas) do
    for {type_id, %{status: :rules} = info} <- Enum.sort(interpreter.types),
        rule_id <- candidates(info),
        reduce: ds do
      ds ->
        mutants = mutants(interpreter, type_id, rule_id)

        if observable?(interpreter, mutants, ds, personas, type_id),
          do: ds,
          else: isolate_rule(interpreter, mutants, ds, personas, info)
    end
  end

  # Supported rules that grant something (or, conditional, whose absence
  # could change the everyone rule's reach).
  defp candidates(info) do
    all_supported = Enum.all?(info.rules, &(&1.status == :ok))

    conditional =
      for %{status: :ok, rule: rule} <- info.rules,
          not (grants_nothing?(rule, info) and grants_nothing?(info.default, info)),
          do: rule.id

    everyone =
      if info.default != nil and all_supported and not grants_nothing?(info.default, info),
        do: ["everyone"],
        else: []

    conditional ++ everyone
  end

  defp isolate_rule(interpreter, mutants, ds, personas, info) do
    irs = Enum.map(info.rules, & &1.ir)

    Enum.find_value(@personas, ds, fn persona ->
      user = personas[persona]

      goal = fn ds, key ->
        base = Interpreter.observe(interpreter, ds, user, key)
        decided?(base) and Enum.any?(mutants, &(Interpreter.observe(&1, ds, user, key) != base))
      end

      case Solver.find(interpreter, ds, info.type.id, goal, irs: irs, budget: @budget) do
        {:ok, ds, _key} -> ds
        :none -> nil
      end
    end)
  end

  @doc """
  Every rule's observability: `%{type, rule, default, status}` with status
  `:observable` or `{:unobservable, reason, detail}`. `rules` are the
  matrix's rule statuses (unsolved rules are unobservable).
  """
  @spec observability(Interpreter.t(), Dataset.t(), map(), [map()]) :: [map()]
  def observability(%Interpreter{} = interpreter, ds, personas, rules) do
    for %{type: type_id, rule: rule_id} = r <- rules do
      info = Interpreter.type(interpreter, type_id)
      rule = if r.default, do: info.default, else: Enum.find(info.type.rules, &(&1.id == rule_id))

      status =
        cond do
          match?({:unsolved, _, _}, r.status) ->
            {:unobservable, :unsolved, "unsolved: #{elem(r.status, 1)}"}

          nothing = nothing_granted(r.default, rule, info) ->
            nothing

          observable?(interpreter, mutants(interpreter, type_id, rule_id), ds, personas, type_id) ->
            :observable

          true ->
            masked(info)
        end

      Map.put(Map.delete(r, :status), :status, status)
    end
  end

  defp nothing_granted(true = _default, rule, info) do
    if grants_nothing?(rule, info),
      do: {:unobservable, :grants_nothing, "the everyone rule grants nothing"}
  end

  defp nothing_granted(false, rule, info) do
    if grants_nothing?(rule, info) and grants_nothing?(info.default, info),
      do: {:unobservable, :grants_nothing, "neither it nor the everyone rule grants anything"}
  end

  defp masked(info) do
    if Enum.any?(info.rules, &(&1.status != :ok)),
      do:
        {:unobservable, :undecided_type,
         "another rule of the type is unsupported, so the verdicts it could change are unknown"},
      else:
        {:unobservable, :masked,
         "no persona and record where it changes a verdict: other rules decide wherever it could"}
  end

  defp mutants(interpreter, type_id, "everyone"),
    do: [Interpreter.mutate(interpreter, type_id, "everyone", :drop)]

  defp mutants(interpreter, type_id, rule_id),
    do: for(m <- [:drop, :negate], do: Interpreter.mutate(interpreter, type_id, rule_id, m))

  defp observable?(interpreter, mutants, ds, personas, type_id) do
    Enum.any?(cells(ds, personas, type_id), fn {user, key} ->
      base = Interpreter.observe(interpreter, ds, user, key)
      decided?(base) and Enum.any?(mutants, &(Interpreter.observe(&1, ds, user, key) != base))
    end)
  end

  # A verdict that is recorded: nothing about it unknown.
  defp decided?({visible, _fields, unknown, searchable}),
    do: visible != :unknown and searchable != :unknown and unknown == []

  defp cells(ds, personas, type_id),
    do: for({_, user} <- Enum.sort(personas), key <- Dataset.keys(ds, type_id), do: {user, key})

  defp grants_nothing?(nil, _info), do: true
  defp grants_nothing?(%{permissions: nil}, _info), do: true

  defp grants_nothing?(%{permissions: p}, info) do
    fields = for f <- p.view_fields || [], MapSet.member?(info.field_ids, f), do: f
    p.view_all != true and fields == [] and p.search_for != true
  end

  # --- assumption flags ------------------------------------------------------------

  @doc """
  The dataset with records added so that each assumption flag has, in
  every type whose rules read what it governs, a cell whose verdict
  depends on it (where one can be found).
  """
  @spec exercise_flags(Interpreter.t(), Dataset.t(), map()) :: Dataset.t()
  def exercise_flags(%Interpreter{} = interpreter, ds, personas) do
    for flag <- Assumptions.names(),
        not Map.has_key?(@unexercisable, flag),
        flipped = %{interpreter | assumptions: Assumptions.flip(interpreter.assumptions, flag)},
        {type_id, %{status: :rules} = info} <- Enum.sort(interpreter.types),
        relevant?(flag, info),
        reduce: ds do
      ds ->
        cond do
          depends?(interpreter, flipped, ds, personas, type_id) -> ds
          exercised = exercise(interpreter, flipped, ds, personas, info) -> exercised
          true -> exercise_jointly(interpreter, flag, ds, personas, info)
        end
    end
  end

  # The fail-safe hedges that can hide a flag entirely: with one of them
  # lifted, a cell may depend on the flag (V5 calibrates them together).
  @partners [:everyone_guards_record_values, :actor_empty_denies]

  defp exercise_jointly(interpreter, flag, ds, personas, info) do
    Enum.find_value(@partners -- [flag], ds, fn partner ->
      base = flip(interpreter, [partner])
      both = flip(interpreter, [partner, flag])

      if depends?(base, both, ds, personas, info.type.id),
        do: ds,
        else: exercise(base, both, ds, personas, info)
    end)
  end

  defp flip(interpreter, flags),
    do: %{
      interpreter
      | assumptions: Enum.reduce(flags, interpreter.assumptions, &Assumptions.flip(&2, &1))
    }

  defp exercise(interpreter, flipped, ds, personas, info) do
    irs = for %{status: :ok, ir: ir} <- info.rules, do: ir

    Enum.find_value(@personas, fn persona ->
      user = personas[persona]

      goal = fn ds, key ->
        base = Interpreter.observe(interpreter, ds, user, key)
        decided?(base) and Interpreter.observe(flipped, ds, user, key) != base
      end

      case Solver.find(interpreter, ds, info.type.id, goal,
             irs: irs,
             empty_first: true,
             budget: @flag_budget
           ) do
        {:ok, ds, _key} -> ds
        :none -> nil
      end
    end)
  end

  defp depends?(interpreter, flipped, ds, personas, type_id) do
    Enum.any?(cells(ds, personas, type_id), fn {user, key} ->
      base = Interpreter.observe(interpreter, ds, user, key)
      decided?(base) and Interpreter.observe(flipped, ds, user, key) != base
    end)
  end

  @expression_ops %{
    empty_list_contains_nothing: [:member],
    empty_item_not_contained: [:member],
    empty_text_contains_nothing: [:text_contains],
    ordering_with_empty_false: [:gt, :lt, :gte, :lte]
  }

  # Whether a type's supported rules read the shape `flag` governs.
  defp relevant?(flag, info) do
    irs = for %{status: :ok, ir: ir} <- info.rules, do: ir

    case flag do
      :empty_yes_no_is_no ->
        Enum.any?(irs, &yes_no_comparison?/1)

      :empty_equals_empty ->
        Enum.any?(irs, &record_comparison?/1)

      flag when flag in [:actor_empty_denies, :logged_out_user_is_empty] ->
        Enum.any?(irs, &Eval.reads_actor?/1)

      flag when is_map_key(@expression_ops, flag) ->
        ops = @expression_ops[flag]
        Enum.any?(irs, fn ir -> Enum.any?(IR.ops(ir), &(&1 in ops)) end)

      _ ->
        irs != [] or info.default != nil
    end
  end

  # `x is y` / `is not` between two values read from records (not the
  # user, not a literal): where empty-is-empty decides.
  defp record_comparison?(ir), do: any_node?(ir, &record_pair?/1)

  defp record_pair?(%IR{op: op, args: [l, r]}) when op in [:eq, :neq],
    do: record_side?(l) and record_side?(r)

  defp record_pair?(_), do: false

  defp record_side?(%IR{op: :field} = ir), do: not Eval.actor?(ir)
  defp record_side?(_), do: false

  # A stored yes/no compared with something other than `yes`: where an
  # empty yes/no reading as no decides.
  defp yes_no_comparison?(ir), do: any_node?(ir, &yes_no_pair?/1)

  defp yes_no_pair?(%IR{op: op, args: [l, r]}) when op in [:eq, :neq],
    do: (yes_no?(l) and not yes?(r)) or (yes_no?(r) and not yes?(l))

  defp yes_no_pair?(_), do: false

  defp yes_no?(%IR{op: :field, type: "boolean"}), do: true
  defp yes_no?(_), do: false
  defp yes?(%IR{op: :literal, args: [true]}), do: true
  defp yes?(_), do: false

  defp any_node?(%IR{args: args} = ir, pred?),
    do: pred?.(ir) or Enum.any?(args, &any_node?(&1, pred?))

  defp any_node?(list, pred?) when is_list(list), do: Enum.any?(list, &any_node?(&1, pred?))
  defp any_node?(_, _), do: false

  @doc """
  For the flags no check depends on alone: per flag and partner hedge
  (`everyone_guards_record_values`, `actor_empty_denies`), the number of
  recorded cells whose verdict, with the partner lifted, changes when the
  flag flips too. `%{flag => %{partner => count}}` (non-zero only).
  """
  @spec joint(Interpreter.t(), Dataset.t(), map(), [atom()]) :: map()
  def joint(%Interpreter{} = interpreter, ds, personas, flags) do
    types = for {id, %{status: :rules}} <- Enum.sort(interpreter.types), do: id
    recorded = for type <- types, cell <- cells(ds, personas, type), do: cell

    for flag <- flags,
        partners = joint_partners(interpreter, flag, ds, recorded),
        partners != %{},
        into: %{},
        do: {flag, partners}
  end

  defp joint_partners(interpreter, flag, ds, recorded) do
    for partner <- @partners -- [flag],
        base = flip(interpreter, [partner]),
        both = flip(interpreter, [partner, flag]),
        n = Enum.count(recorded, &jointly?(interpreter, base, both, ds, &1)),
        n > 0,
        into: %{},
        do: {partner, n}
  end

  defp jointly?(interpreter, base, both, ds, {user, key}) do
    decided?(Interpreter.observe(interpreter, ds, user, key)) and
      Interpreter.observe(base, ds, user, key) != Interpreter.observe(both, ds, user, key)
  end

  @doc """
  Per flag, whether some recorded check depends on it, and if none, why:
  `%{flag => :exercised | {:not_exercised, reason}}`, from the matrix's
  per-op `dependencies`.
  """
  @spec flag_outcomes(Interpreter.t(), map()) :: map()
  def flag_outcomes(%Interpreter{} = interpreter, dependencies) do
    used = dependencies |> Map.values() |> List.flatten() |> MapSet.new()

    Map.new(Assumptions.names(), fn flag ->
      outcome =
        cond do
          MapSet.member?(used, flag) ->
            :exercised

          reason = @unexercisable[flag] ->
            {:not_exercised, reason}

          not Enum.any?(interpreter.types, fn {_, i} ->
            i.status == :rules and relevant?(flag, i)
          end) ->
            {:not_exercised, "no supported rule reads what it governs"}

          true ->
            {:not_exercised, "no persona and record found whose verdict it decides"}
        end

      {flag, outcome}
    end)
  end
end
