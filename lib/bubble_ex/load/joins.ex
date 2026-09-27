defmodule BubbleEx.Load.Joins do
  @moduledoc false

  # The rows of the plan's join tables (`BubbleEx.Load.Plan.Join`, WTF-352
  # cut 3), from the list values the scan kept: one row per member of each
  # list, keyed by the two record IDs, with the member's index (from 0) in
  # each ordered list. Two mirrored lists share one join: a row is their
  # union, and a member one list holds but the other does not list back is
  # reported. Dangling IDs are kept (no foreign key; they load nothing
  # through the relationship) and reported, like references (WTF-338); a
  # member a list repeats is one row, at its first index, reported.
  # Deterministic: rows sorted by the two IDs, so a resumed run batches
  # them as the interrupted one did.

  alias BubbleEx.Load.{Convert, Issues, Plan, Scan}

  @type built :: %{
          join: Plan.Join.t(),
          rows: [map()],
          owners: %{left: [String.t()], right: [String.t()]}
        }

  @doc false
  @spec build(Plan.t(), Scan.t(), Issues.t()) :: {[built()], Issues.t()}
  def build(%Plan{joins: joins}, %Scan{} = scan, issues) do
    Enum.map_reduce(joins, issues, &join(&1, scan, &2))
  end

  defp join(%Plan.Join{} = join, scan, issues) do
    {sides, issues} = Enum.map_reduce(join.sides, issues, &side(join, &1, scan, &2))
    issues = asymmetry(join, sides, scan, issues)
    positions = for %{position: p} <- join.sides, p != nil, do: p

    rows =
      sides
      |> Enum.flat_map(fn {side, pairs} ->
        for {pair, index} <- pairs, do: {pair, side.position, index}
      end)
      |> Enum.reduce(%{}, fn {{l, r}, position, index}, acc ->
        row =
          Map.get(acc, {l, r}, %{join.left.column => l, join.right.column => r})
          |> put_position(position, index)

        Map.put(acc, {l, r}, row)
      end)
      |> Enum.sort()
      |> Enum.map(fn {_pair, row} -> Enum.reduce(positions, row, &Map.put_new(&2, &1, nil)) end)

    owners =
      Enum.reduce(join.sides, %{left: [], right: []}, fn side, acc ->
        ids = scan.ids |> Map.get(side.type, MapSet.new()) |> Enum.sort()
        Map.update!(acc, side.owner, &Enum.uniq(&1 ++ ids))
      end)

    {%{join: join, rows: rows, owners: owners}, issues}
  end

  defp put_position(row, nil, _index), do: row
  defp put_position(row, column, index), do: Map.put(row, column, index)

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
  # not list the owner back. Both load (the join is their union).
  defp asymmetry(_join, [_], _scan, issues), do: issues

  defp asymmetry(_join, [{a, a_pairs}, {b, b_pairs}], scan, issues) do
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
