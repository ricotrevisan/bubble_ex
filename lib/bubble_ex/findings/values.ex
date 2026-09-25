defmodule BubbleEx.Findings.Values do
  @moduledoc false

  # What a written value is, in the few shapes the analyzers reason about:
  #
  #   {:read, chain}          - a field chain, e.g. `This Thing's Thing's Title`
  #   {:count, chain}         - `<chain>:count`
  #   {:literal, value}       - a JSON literal
  #   {:arith, op, l, r}      - arithmetic on two described values
  #   :opaque                 - anything else (formatted text, inputs, …)
  #
  # A chain lists its field keys from the root (`keys`), its `root` kind and
  # the data type owning the last key (`owner`), taken from the typed AST or,
  # when the AST could not type it (previous-step results, …), from the
  # index's typed reads made inside the value.

  alias BubbleEx.Expression.Ast
  alias BubbleEx.Findings.Context
  alias BubbleEx.Index.{Reference, Types}

  @type chain :: %{
          keys: [String.t()],
          owners: [String.t() | nil],
          root: atom(),
          owner: String.t() | nil
        }
  @type t ::
          {:read, chain()}
          | {:count, chain()}
          | {:literal, term()}
          | {:arith, atom(), t(), t()}
          | :opaque

  @spec describe(Ast.t(), [Reference.t()]) :: t()
  def describe(ast, reads), do: ast |> unwrap() |> shape(reads)

  defp unwrap(%Ast.DynamicText{parts: [part]}) when is_struct(part), do: unwrap(part)
  defp unwrap(%Ast.ArbitraryText{text: text}), do: unwrap(text)
  defp unwrap(%Ast.Fallback{subject: subject}), do: unwrap(subject)
  defp unwrap(node), do: node

  defp shape(%Ast.Literal{value: value}, _reads), do: {:literal, value}
  defp shape(%Ast.Empty{}, _reads), do: {:literal, nil}

  defp shape(%Ast.ListOp{op: :count, subject: subject}, reads) do
    case chain(unwrap(subject), reads) do
      nil -> :opaque
      chain -> {:count, chain}
    end
  end

  defp shape(%Ast.Arithmetic{op: op, left: l, right: r}, reads),
    do: {:arith, op, describe(l, reads), describe(r, reads)}

  defp shape(node, reads) do
    case chain(node, reads) do
      nil -> :opaque
      chain -> {:read, chain}
    end
  end

  @doc "The field chain of `node`, or nil when it does not end in a field."
  @spec chain(Ast.t(), [Reference.t()]) :: chain() | nil
  def chain(node, reads) do
    case steps(node, []) do
      {_root, []} ->
        nil

      {root, steps} ->
        keys = Enum.map(steps, &elem(&1, 0))
        owners = Enum.map(steps, &elem(&1, 1))
        last = List.last(keys)
        owner = List.last(owners) || owner_from_reads(last, reads)
        %{keys: keys, owners: owners, root: root, owner: owner}
    end
  end

  defp steps(%Ast.Field{subject: s, field: f}, acc),
    do: steps(s, [{f, Types.data_type_key(s.type)} | acc])

  defp steps(%Ast.Property{subject: s, name: n}, acc), do: steps(s, [{n, nil} | acc])
  defp steps(%Ast.ThisThing{}, acc), do: {:this_thing, acc}
  defp steps(%Ast.CurrentUser{}, acc), do: {:current_user, acc}
  defp steps(%Ast.Scope{kind: kind}, acc), do: {kind, acc}
  defp steps(%Ast.Search{}, acc), do: {:search, acc}
  defp steps(_, acc), do: {:expression, acc}

  # The single data type whose field `key` the value reads, per the index.
  defp owner_from_reads(key, reads) do
    owners =
      for %Reference{to: to} <- reads,
          {type, ^key} <- [Context.split_field(to)],
          uniq: true,
          do: type

    case owners do
      [owner] -> owner
      _ -> nil
    end
  end

  @doc "The last field key of a chain."
  @spec last(chain()) :: String.t()
  def last(%{keys: keys}), do: List.last(keys)
end
