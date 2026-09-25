defmodule BubbleEx.Findings.ListRelationship do
  @moduledoc false

  # `:list_relationship` - a `list of <data type>` field. The faithful default
  # keeps it as an ordered array of IDs; a join resource (one record per
  # member) makes it queryable, lets it grow past Bubble's 10,000-item list
  # cap and gives it a foreign key. Fields already covered by a
  # `:redundant_reverse_list` or `:privacy_access_list` finding are skipped:
  # those propose a more specific model for the same list.

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Findings.Context

  @spec run(Context.t(), MapSet.t()) :: [Finding.t()]
  def run(ctx, covered) do
    for field <- Context.all_fields(ctx),
        not Map.has_key?(field.attrs, :builtin),
        not MapSet.member?(covered, field.id),
        %{type: to, list: true} <- [Context.target(ctx, field.id)],
        do: finding(ctx, field, to)
  end

  defp finding(ctx, field, to) do
    type = Context.type_of_field(field)
    writes = Index.writers(ctx.index, field.id)
    readers = Index.readers(ctx.index, field.id)
    rules = Index.privacy_rules_referencing(ctx.index, field.id)
    changes = writes |> Enum.map(& &1.attrs[:change]) |> Enum.uniq() |> Enum.sort()

    {confidence, reason} =
      cond do
        Enum.any?(changes, &(&1 in ["add", "remove"])) ->
          {:high,
           "workflows add and remove members one at a time, so the list grows without bound"}

        writes != [] or readers != [] ->
          {:medium,
           "a join resource is the relational form; whether the list's order matters needs the owner"}

        true ->
          {:low, "no workflow or expression uses the field; it may be unused"}
      end

    Finding.new(:list_relationship, %{type: type, field: field.bubble_id},
      path: field.path,
      evidence: %{
        symbols: [field.id, "data_type:" <> to],
        references: writes,
        writes: length(writes),
        reads: length(readers),
        changes: changes
      },
      proposal: %{
        transform: :extract_join_resource,
        field: field.id,
        from_type: "data_type:" <> type,
        to_type: "data_type:" <> to,
        source_order: :preserved,
        source_limit: 10_000
      },
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, Enum.map(writes ++ readers ++ rules, & &1.from)),
      message:
        "“#{Context.name(ctx, field.id)}” on “#{Context.name(ctx, "data_type:" <> type)}” is a list of " <>
          "“#{Context.name(ctx, "data_type:" <> to)}”; model it as a join resource " <>
          "(Bubble lists stop at 10,000 items)"
    )
  end
end
