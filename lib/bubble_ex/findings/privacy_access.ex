defmodule BubbleEx.Findings.PrivacyAccess do
  @moduledoc false

  # `:privacy_access_list` - a `list of User` that privacy-rule conditions
  # read, typically `This Thing's Members contains Current User`. It is an
  # access-control list; a membership join with a membership-based access
  # rule expresses it directly. The proposal names the join (see
  # `BubbleEx.Findings.Joins`), shared with a mirrored list on User. Rules on other types that reach the list
  # through references (`This Thing's Workspace's Members …`) are included.
  #
  # High confidence when some rule tests the current user's membership
  # (`contains Current User` / `Current User is in`); medium when rules only
  # read the list otherwise.

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Expression.Ast
  alias BubbleEx.Findings.{Context, Values}
  alias BubbleEx.Index.Symbol

  @spec run(Context.t(), map()) :: [Finding.t()]
  def run(ctx, joins) do
    for field <- Context.all_fields(ctx),
        not Map.has_key?(field.attrs, :builtin),
        %{type: "user", list: true} <- [Context.target(ctx, field.id)],
        rule_reads = condition_reads(ctx, field.id),
        rule_reads != [],
        do: finding(ctx, field, rule_reads, Map.fetch!(joins, field.id))
  end

  defp condition_reads(ctx, field_id) do
    ctx.index
    |> Index.privacy_rules_referencing(field_id)
    |> Enum.filter(&(&1.kind == :reads_field))
  end

  defp finding(ctx, field, rule_reads, join) do
    type = Context.type_of_field(field)
    key = field.bubble_id

    checks =
      rule_reads
      |> Enum.uniq_by(& &1.from)
      |> Enum.map(fn ref ->
        vias =
          case Context.expression_at(ctx, ref) do
            nil -> []
            ast -> membership_checks(ast, key, [])
          end

        %{rule: ref.from, membership_test: vias != [], via: vias |> Enum.uniq() |> List.first([])}
      end)

    tested = Enum.count(checks, & &1.membership_test)

    {confidence, reason} =
      if tested > 0,
        do: {:high, "#{tested} rule(s) grant access when the current user is in the list"},
        else: {:medium, "privacy rules read the list, but not as a plain membership test"}

    writes = Index.writers(ctx.index, field.id)
    readers = Index.readers(ctx.index, field.id)

    Finding.new(:privacy_access_list, %{type: type, field: key},
      path: field.path,
      evidence: %{
        symbols: [field.id | Enum.map(checks, & &1.rule) ++ join.fields],
        references: rule_reads,
        writes: length(writes),
        rules: length(checks)
      },
      proposal: %{
        transform: :membership_policy,
        field: field.id,
        member_type: "data_type:user",
        join: join,
        checks: Enum.sort_by(checks, & &1.rule)
      },
      confidence: confidence,
      confidence_reason: reason,
      affects:
        Context.affects(
          ctx,
          Enum.map(rule_reads ++ readers, & &1.from),
          Enum.map(writes, & &1.from)
        ),
      message:
        "“#{Context.name(ctx, field.id)}” on “#{Context.name(ctx, "data_type:" <> type)}” is a list of users " <>
          "that #{length(checks)} privacy rule(s) check for access; model it as a membership " <>
          "join with a membership-based access rule"
    )
  end

  # Membership tests of the current user against a chain ending in the list;
  # each result is the chain's field IDs before the list (the path to it).
  defp membership_checks(
         %Ast.ListOp{op: :contains, subject: list, arg: %Ast.CurrentUser{}} = n,
         key,
         acc
       ),
       do: descend(n, key, via(list, key, acc))

  defp membership_checks(
         %Ast.ListOp{op: :is_contained_by, subject: %Ast.CurrentUser{}, arg: list} = n,
         key,
         acc
       ),
       do: descend(n, key, via(list, key, acc))

  defp membership_checks(node, key, acc), do: descend(node, key, acc)

  defp descend(%_{} = node, key, acc) do
    if Ast.node?(node) or match?(%Ast.Constraint{}, node) do
      node
      |> Map.from_struct()
      |> Map.drop([:meta, :raw])
      |> Enum.sort()
      |> Enum.reduce(acc, fn {_, v}, a -> descend_value(v, key, a) end)
    else
      acc
    end
  end

  defp descend_value(list, key, acc) when is_list(list),
    do: Enum.reduce(list, acc, &descend_value(&1, key, &2))

  defp descend_value(%_{} = node, key, acc), do: membership_checks(node, key, acc)
  defp descend_value(_, _key, acc), do: acc

  defp via(list, key, acc) do
    case Values.chain(list, []) do
      %{keys: keys, owners: owners} = chain ->
        if Values.last(chain) == key, do: [path_to(keys, owners) | acc], else: acc

      nil ->
        acc
    end
  end

  # Field IDs of the chain before the list (the raw key where untyped).
  defp path_to(keys, owners) do
    keys
    |> Enum.drop(-1)
    |> Enum.zip(Enum.drop(owners, -1))
    |> Enum.map(fn
      {k, nil} -> k
      {k, owner} -> Symbol.id(:field, [owner, k])
    end)
  end
end
