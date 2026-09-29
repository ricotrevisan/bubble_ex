defmodule BubbleEx.Load.Joins do
  @moduledoc false

  # The rows of the plan's join tables (`BubbleEx.Load.Plan.Join`, WTF-352
  # cut 3), per list, from the list values the scan kept: one row per
  # member, keyed by the two record IDs, with the list's membership column
  # (the member's index, from 0, or true). Two mirrored lists sharing a
  # join table are written separately, each setting only its own column:
  # a member one list holds is never added to the other; one it does not
  # list back is reported. Dangling IDs are kept (no foreign key; they
  # load nothing through the relationship) and reported, like references
  # (WTF-338); a member a list repeats is one row, at its first index,
  # reported. Nothing is deleted here (pruning is `BubbleEx.Load.Prune`). Deterministic: rows sorted by the two
  # IDs, so a resumed run batches them as the interrupted one did.

  alias BubbleEx.Load.{Convert, Issues, Plan, Scan}

  @type built :: %{
          key: String.t(),
          join: Plan.Join.t(),
          side: Plan.Join.side(),
          rows: [map()]
        }

  @doc false
  # One entry per list of every join, keyed `<join ID>/<type>/<field>` (the
  # ledger's and the report's key).
  @spec build(Plan.t(), Scan.t(), Issues.t()) :: {[built()], Issues.t()}
  def build(%Plan{joins: joins}, %Scan{} = scan, issues) do
    {built, issues} =
      Enum.flat_map_reduce(joins, issues, fn join, issues ->
        {sides, issues} = Enum.map_reduce(join.sides, issues, &side(join, &1, scan, &2))
        issues = asymmetry(sides, scan, issues)

        built =
          for {side, pairs} <- sides,
              do: %{key: key(join, side), join: join, side: side, rows: rows(join, side, pairs)}

        {built, issues}
      end)

    {built, issues}
  end

  defp rows(join, side, pairs) do
    pairs
    |> Enum.sort()
    |> Enum.map(fn {{l, r}, index} ->
      %{
        join.left.column => l,
        join.right.column => r,
        side.column => if(side.kind == :position, do: index, else: true)
      }
    end)
  end

  @doc false
  def key(join, side), do: "#{join.id}/#{side.type}/#{side.field}"

  # The `{pair, index}` members of one list, over its exported owners.
  defp side(join, side, scan, issues) do
    member_type = if side.owner == :left, do: join.right.type, else: join.left.type
    members = Map.get(scan.ids, member_type, MapSet.new())

    {pairs, issues} =
      scan.ids
      |> Map.get(side.type, MapSet.new())
      |> Enum.sort()
      |> Enum.flat_map_reduce(issues, fn id, issues ->
        value = get_in(scan.values, [side.type, id, side.field])
        list_pairs(side, id, value, members, issues)
      end)

    {{side, pairs}, issues}
  end

  defp list_pairs(_side, _id, nil, _members, issues), do: {[], issues}

  defp list_pairs(side, id, list, members, issues) when is_list(list) do
    add = &Issues.add(&1, &2, side.type, side.field, id, &3)

    {items, issues} =
      list
      |> Enum.with_index()
      |> Enum.flat_map_reduce(issues, fn
        {item, index}, issues when is_binary(item) and item != "" ->
          {[{item, index}], issues}

        {_item, _index}, issues ->
          {[], add.(issues, :load_type_mismatch, :not_an_id)}
      end)

    unique = Enum.uniq_by(items, &elem(&1, 0))
    dropped = length(items) - length(unique)
    issues = if dropped > 0, do: add.(issues, :load_join_duplicate, dropped), else: issues

    issues =
      Enum.reduce(unique, issues, fn {member, _}, issues ->
        cond do
          MapSet.member?(members, member) -> issues
          Convert.record_id?(member) -> add.(issues, :load_dangling_reference, :missing)
          true -> add.(issues, :load_dangling_reference, :not_an_id)
        end
      end)

    pairs =
      for {member, index} <- unique do
        pair = if side.owner == :left, do: {id, member}, else: {member, id}
        {pair, index}
      end

    {pairs, issues}
  end

  defp list_pairs(side, id, _value, _members, issues),
    do: {[], Issues.add(issues, :load_type_mismatch, side.type, side.field, id, :not_a_list)}

  # Mirrored lists: a member one list holds whose own list (exported) does
  # not list the owner back. Reported; the other list is not changed.
  defp asymmetry([_], _scan, issues), do: issues

  defp asymmetry([{a, a_pairs}, {b, b_pairs}], scan, issues) do
    issues = one_way(a, a_pairs, b, b_pairs, scan, issues)
    one_way(b, b_pairs, a, a_pairs, scan, issues)
  end

  defp one_way(side, pairs, other, other_pairs, scan, issues) do
    back = MapSet.new(other_pairs, &elem(&1, 0))
    exported = Map.get(scan.ids, other.type, MapSet.new())

    for {{l, r} = pair, _index} <- pairs,
        not MapSet.member?(back, pair),
        member = if(side.owner == :left, do: r, else: l),
        MapSet.member?(exported, member),
        reduce: issues do
      issues ->
        owner = if side.owner == :left, do: l, else: r
        Issues.add(issues, :load_join_asymmetric, side.type, side.field, owner, :not_listed_back)
    end
  end
end
