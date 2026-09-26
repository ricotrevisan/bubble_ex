defmodule BubbleEx.Verify.Matrix.Solver do
  @moduledoc """
  Finds a record that makes one privacy rule's condition true (or false)
  for one persona: the seed records of a privacy matrix.

  The search is lazy: the rule's record starts *open* (no field chosen),
  and the condition is evaluated (`BubbleEx.Verify.Interpreter.Eval`); when
  it reads a field no one has chosen yet, the solver tries each value of
  that field's domain in turn, depth first, until the condition has the
  wanted value under the interpreter's assumptions:

    * a reference: the records of the target type already in the dataset
      (persona users, their records, anchors, earlier witnesses), then a new
      open record of that type (chains such as `This's Created By's role's
      workspace` are built this way, at most 2 levels deep and 4 new records
      per solution), then empty
    * a list of records: each such record alone, a new one, then empty
    * an option: the options the condition names, then one it does not,
      then empty; a yes/no: yes, no, empty; text and numbers: the literals
      the condition uses, values already in the dataset (e.g. a persona's
      name), then a sample value, then empty; a date: two fixed days, then
      empty
    * anything else: empty

  When looking for false, empty comes first. The search is bounded (3000
  evaluations) and deterministic; new records get keys `r.<type>.<n>`.
  """

  alias BubbleEx.Expression.IR
  alias BubbleEx.Model
  alias BubbleEx.Model.Type
  alias BubbleEx.Verify.Interpreter
  alias BubbleEx.Verify.Interpreter.Dataset
  alias BubbleEx.Verify.Matrix.Personas

  @budget 3000
  @max_depth 2
  @max_new 4
  @max_existing 16
  @max_present 8
  @day 86_400_000
  @base_date 1_759_363_200_000

  @doc """
  A dataset extending `ds` with the records that make rule `info` (an
  `Interpreter.rule_info`) of type `type_id` evaluate to `target` for
  `user`, or `:none`.
  """
  @spec solve(Interpreter.t(), map(), Dataset.t(), String.t(), String.t() | nil, boolean()) ::
          {:ok, Dataset.t(), String.t()} | :none
  def solve(%Interpreter{} = interpreter, info, %Dataset{} = ds, type_id, user, target) do
    this = next_key(ds, type_id)

    st = %{
      interpreter: interpreter,
      info: info,
      user: user,
      this: this,
      target: target,
      budget: @budget,
      depth: %{this => 0},
      new: 1,
      literals: literals(info.ir)
    }

    case search(Dataset.put(ds, this, type_id, %{}, true), st) do
      {:ok, ds} -> {:ok, Dataset.close(ds), this}
      {:none, _st} -> :none
    end
  end

  defp search(_ds, %{budget: budget} = st) when budget <= 0, do: {:none, st}

  defp search(ds, st) do
    st = %{st | budget: st.budget - 1}

    try do
      case Interpreter.eval_rule(st.interpreter, st.info, ds, st.user, st.this) do
        {b, _flags} when b == st.target -> {:ok, ds}
        _ -> {:none, st}
      end
    catch
      {:need, key, field} -> branch(ds, key, field, st)
    end
  end

  defp branch(ds, key, field, st) do
    record = Dataset.fetch(ds, key)

    type =
      case Model.field(st.interpreter.model, record.type, field) do
        {:ok, %{type: t}} -> t
        :error -> nil
      end

    ds
    |> candidates(type, key, st)
    |> Enum.reduce_while({:none, st}, fn candidate, {_, st} ->
      {ds, st, value} = materialize(ds, candidate, key, st)

      case search(Dataset.set(ds, key, field, value), st) do
        {:ok, ds} -> {:halt, {:ok, ds}}
        {:none, st} -> {:cont, {:none, st}}
      end
    end)
  end

  defp materialize(ds, {:new, type_id, wrap}, parent, st) do
    key = next_key(ds, type_id)
    depth = Map.fetch!(st.depth, parent) + 1
    ds = Dataset.put(ds, key, type_id, %{}, true)
    st = %{st | depth: Map.put(st.depth, key, depth), new: st.new + 1}
    {ds, st, wrap.({:ref, key})}
  end

  defp materialize(ds, {:value, v}, _parent, st), do: {ds, st, v}

  # --- domains ----------------------------------------------------------------------

  defp candidates(ds, type, parent, st) do
    values = domain(ds, type, parent, st)
    if st.target, do: values ++ [{:value, nil}], else: [{:value, nil} | values]
  end

  defp domain(ds, %Type{kind: :ref, cardinality: card, target: target}, parent, st) do
    wrap = if card == :many, do: &{:list, [&1]}, else: & &1
    existing = for key <- existing(ds, target), do: {:value, wrap.({:ref, key})}

    fresh =
      if Map.fetch!(st.depth, parent) < @max_depth and st.new < @max_new,
        do: [{:new, target, wrap}],
        else: []

    existing ++ fresh
  end

  defp domain(_ds, %Type{kind: :option, cardinality: card, target: set}, _parent, st) do
    named = for {:option, ^set, key} <- st.literals, do: key
    options = options(st.interpreter.model, set)
    other = Enum.take(options -- named, 1)
    for key <- Enum.uniq(named ++ other), do: {:value, many(card, {:option, key})}
  end

  defp domain(ds, %Type{kind: :scalar, base: base, cardinality: card}, _parent, st) do
    values =
      case base do
        :boolean ->
          [{:boolean, true}, {:boolean, false}]

        :text ->
          texts(st.literals) ++ present(ds, :text) ++ [{:text, "sample"}]

        :number ->
          numbers(st.literals) ++ present(ds, :number) ++ [{:number, 1.0}, {:number, 10.0}]

        :date ->
          [{:date, @base_date}, {:date, @base_date + @day}]

        _ ->
          []
      end

    for v <- Enum.uniq(values), do: {:value, many(card, v)}
  end

  defp domain(_ds, _type, _parent, _st), do: []

  defp many(:many, v), do: {:list, [v]}
  defp many(_, v), do: v

  # Persona users, their records and anchors first, then earlier records.
  defp existing(ds, type_id) do
    {own, rest} =
      ds |> Dataset.keys(type_id) |> Enum.split_with(&(not String.starts_with?(&1, "r.")))

    Enum.take(own ++ rest, @max_existing)
  end

  defp options(model, set) do
    case Model.option_set(model, set) do
      %{values: values} -> for v <- values, not v.deleted, is_binary(v.key), do: v.key
      nil -> []
    end
  end

  # Values already in the dataset (e.g. a persona's name), so a condition
  # comparing a record field with a user field can hold.
  defp present(ds, tag) do
    ds.records
    |> Enum.sort()
    |> Enum.flat_map(fn {_, r} -> r.fields |> Enum.sort() |> Enum.map(&elem(&1, 1)) end)
    |> Enum.flat_map(fn
      {:list, items} -> items
      v -> [v]
    end)
    |> Enum.filter(&match?({^tag, _}, &1))
    |> Enum.uniq()
    |> Enum.take(@max_present)
  end

  defp texts(literals), do: for({:text, v} <- literals, do: {:text, v})
  defp numbers(literals), do: for({:number, v} <- literals, do: {:number, v})

  defp literals(ir) do
    ir
    |> collect()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp collect(%IR{op: :literal, args: [v]}) when is_binary(v), do: [{:text, v}]
  defp collect(%IR{op: :literal, args: [v]}) when is_number(v), do: [{:number, v / 1}]

  defp collect(%IR{op: :option, args: [set, _, key]}) when is_binary(key),
    do: [{:option, set, key}]

  defp collect(%IR{args: args}), do: Enum.flat_map(args, &collect/1)
  defp collect(list) when is_list(list), do: Enum.flat_map(list, &collect/1)
  defp collect(_), do: []

  @doc "The next free key `r.<type>.<n>` of type `type_id`."
  @spec next_key(Dataset.t(), String.t()) :: String.t()
  def next_key(ds, type_id) do
    prefix = "r.#{Personas.slug(type_id)}."

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&(prefix <> Integer.to_string(&1)))
    |> Enum.find(&is_nil(Dataset.fetch(ds, &1)))
  end
end
