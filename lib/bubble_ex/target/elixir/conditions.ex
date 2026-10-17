defmodule BubbleEx.Target.Elixir.Conditions do
  @moduledoc """
  Drops the redundant terms of a compiled condition's `and`/`or` chains
  (WTF-555), so the source has no check Elixir's type checker can prove
  always true or always false.

  A condition compiled from a Bubble expression can repeat its checks:
  `is logged in` is `not is_nil(current_user)`, each comparison with the
  current user's values has its own emptiness guard, and Bubble's `and`s
  nest (`a and b and (a and c)`). Since Elixir 1.20
  the type checker narrows a variable after a check, so a repeated
  `not is_nil(current_user)` in one chain (or an `is_nil(current_user)`
  after it) warns that the comparison is always true or false, and the
  generated app no longer compiles with `--warnings-as-errors`.

  `simplify/1` flattens nested chains of one operator and, walking each
  chain left to right with what the terms before it established, drops a
  term already known to hold in an `and` (or to fail in an `or`): `a and b
  and (a and c)` is `a and b and c`, `not is_nil(x) and (is_nil(x) or y)`
  is `not is_nil(x) and y`. Terms are compared as code (no metadata);
  every term is pure, so a dropped term changes no result. A term known
  to have the opposite value (a contradiction in the Bubble expression) is
  kept as written. What a term establishes reaches only the terms after it in
  its chains (through `and`, `or` and `not`); a chain inside other code
  (`(a and a) == true`, an `if`'s condition) is simplified on its own.
  """

  @parse [
    literal_encoder: &__MODULE__.encode_literal/2,
    token_metadata: true,
    unescape: false,
    emit_warnings: false
  ]

  @doc false
  def encode_literal(literal, meta), do: {:ok, {:__block__, meta, [literal]}}

  @doc """
  `source` with its redundant condition terms dropped, or unchanged when
  it has none (or does not parse).
  """
  @spec simplify(String.t()) :: String.t()
  def simplify(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, @parse),
         {simplified, true} <- term(ast, %{}) do
      simplified
      |> Code.quoted_to_algebra(escape: false)
      |> Inspect.Algebra.format(98)
      |> IO.iodata_to_binary()
    else
      _ -> source
    end
  end

  # `{ast, changed?}`: a term with its chains simplified under `facts`
  # (code without metadata => its known value).
  defp term({op, _meta, [_, _]} = ast, facts) when op in [:and, :or] do
    {kept, changed?} = chain(op, terms(op, ast), facts)
    if changed?, do: {rebuild(op, kept), true}, else: {ast, false}
  end

  defp term({:not, meta, [x]}, facts) do
    {x2, changed?} = term(x, facts)
    {{:not, meta, [x2]}, changed?}
  end

  defp term(ast, _facts), do: walk(ast)

  # Any other code: the chains inside it (`(a and a) == true`, an `if`'s
  # condition), each on its own.
  defp walk({form, meta, args}) when is_list(args) do
    {form, form_changed?} = walk(form)
    {args, changed} = args |> Enum.map(&walk_term/1) |> Enum.unzip()
    {{form, meta, args}, form_changed? or Enum.any?(changed)}
  end

  defp walk({l, r}) do
    {l, l_changed?} = walk(l)
    {r, r_changed?} = walk(r)
    {{l, r}, l_changed? or r_changed?}
  end

  defp walk(list) when is_list(list) do
    {items, changed} = list |> Enum.map(&walk/1) |> Enum.unzip()
    {items, Enum.any?(changed)}
  end

  defp walk(other), do: {other, false}

  defp walk_term({op, _, [_, _]} = ast) when op in [:and, :or], do: term(ast, %{})
  defp walk_term({:not, _, [_]} = ast), do: term(ast, %{})
  defp walk_term(ast), do: walk(ast)

  # A chain's terms in order, nested chains of the same operator flattened.
  defp terms(op, {op, _meta, [l, r]}), do: terms(op, l) ++ terms(op, r)
  defp terms(op, {:__block__, _meta, [{op, _, [_, _]} = inner]}), do: terms(op, inner)
  defp terms(_op, ast), do: [ast]

  # The terms kept: a term known to hold (`and`) or to fail (`or`) given
  # the terms before it is dropped; each kept term is known afterwards.
  # A flattened chain counts as changed only when a term is dropped or
  # simplified, so an untouched condition keeps its source.
  defp chain(op, terms, facts) do
    redundant = op == :and

    {kept, _facts, changed?} =
      Enum.reduce(terms, {[], facts, false}, fn t, {kept, facts, changed?} ->
        case known(t, facts) do
          {:ok, ^redundant} ->
            {kept, facts, true}

          # the opposite value: a contradiction (or a tautology) as the
          # expression was written; kept, and nothing learnt from it
          {:ok, _decides} ->
            {[t | kept], facts, changed?}

          :error ->
            {t2, simplified?} = term(t, facts)
            {[t2 | kept], learn(t2, redundant, facts), changed? or simplified?}
        end
      end)

    # A nested chain whose every term is redundant is a value its parent
    # has not ruled out: it stays as written.
    case kept do
      [] -> {terms, false}
      _ -> {Enum.reverse(kept), changed?}
    end
  end

  defp known(t, facts) do
    key = strip(t)

    case {Map.fetch(facts, key), key} do
      {{:ok, v}, _} ->
        {:ok, v}

      {:error, {:not, [], [x]}} ->
        with {:ok, v} <- Map.fetch(facts, x), do: {:ok, not v}

      _ ->
        :error
    end
  end

  defp learn(t, value, facts) do
    key = strip(t)
    facts = Map.put(facts, key, value)

    case key do
      {:not, [], [x]} -> Map.put(facts, x, not value)
      _ -> facts
    end
  end

  defp rebuild(op, [first | rest]), do: Enum.reduce(rest, first, &{op, [], [&2, &1]})

  # Code without metadata; a parenthesized single expression is itself.
  defp strip(ast) do
    Macro.prewalk(ast, fn
      {:__block__, _meta, [{_, _, _} = inner]} -> strip_meta(inner)
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp strip_meta({form, _meta, args}), do: {form, [], args}
end
