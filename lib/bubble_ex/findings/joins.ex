defmodule BubbleEx.Findings.Joins do
  @moduledoc false

  # The join each `list of <type>` field would become. Two lists that mirror
  # each other (A has a list of B and B a list of A, e.g. User's Workspaces
  # and Workspace's Members) are the two sides of one many-to-many and share
  # one join, so accepting both findings cannot create two joins.
  #
  # Lists L1 on A and L2 on B pair when each is the other's only candidate
  # (a list on the other type pointing back), preferring coupled candidates:
  # lists written by a workflow that also writes the other side. Fields of
  # `:redundant_reverse_list` findings (one-to-many) are excluded.
  #
  # A join is `%{id, between, fields}`: `between` the two data type symbol
  # IDs, `fields` the list field IDs it replaces (one or two), `basis`
  # `:single`, `:coupled` (a workflow maintains both sides) or `:unique_types`
  # (the only lists between the two types). `id` hashes `fields`.

  alias BubbleEx.{CanonicalJson, Index}
  alias BubbleEx.Findings.Context

  @type join :: %{id: String.t(), between: [String.t()], fields: [String.t()], basis: atom()}

  @spec build(Context.t(), MapSet.t()) :: %{String.t() => join()}
  def build(ctx, excluded) do
    lists =
      for field <- Context.all_fields(ctx),
          not Map.has_key?(field.attrs, :builtin),
          not MapSet.member?(excluded, field.id),
          %{type: to, list: true} <- [Context.target(ctx, field.id)],
          do: {field.id, Context.type_of_field(field), to}

    workflows = Map.new(lists, fn {id, _, _} -> {id, writer_workflows(ctx, id)} end)

    candidates =
      Map.new(lists, fn {id, from, to} ->
        {id, for({other, ^to, ^from} <- lists, other != id, do: other)}
      end)

    Map.new(lists, fn {id, from, to} ->
      case partner(id, candidates, workflows) do
        nil -> {id, join([id], from, to, :single)}
        {other, basis} -> {id, join(Enum.sort([id, other]), from, to, basis)}
      end
    end)
  end

  defp writer_workflows(ctx, field_id) do
    ctx.index
    |> Index.writers(field_id)
    |> Enum.map(&Context.workflow_of(ctx, &1.from))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp partner(id, candidates, workflows) do
    coupled = fn a ->
      Enum.filter(candidates[a], &(not MapSet.disjoint?(workflows[a], workflows[&1])))
    end

    case {coupled.(id), candidates[id]} do
      {[other], _} ->
        if coupled.(other) == [id], do: {other, :coupled}

      {[], [other]} ->
        if candidates[other] == [id] and coupled.(other) == [], do: {other, :unique_types}

      _ ->
        nil
    end
  end

  defp join(fields, from, to, basis) do
    %{
      id: "join:" <> binary_part(CanonicalJson.sha256(fields), 0, 16),
      between: Enum.sort(["data_type:" <> from, "data_type:" <> to]),
      fields: fields,
      basis: basis
    }
  end
end
