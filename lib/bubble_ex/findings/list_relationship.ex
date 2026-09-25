defmodule BubbleEx.Findings.ListRelationship do
  @moduledoc false

  # `:list_relationship` - a used `list of <data type>` field. The faithful
  # default keeps it as an ordered array of IDs; a join (one row per member)
  # makes it queryable, lets it grow past Bubble's 10,000-item list cap and
  # gives it a foreign key. The proposal names the join (see
  # `BubbleEx.Findings.Joins`); two mirrored lists share one.
  #
  # Skipped: lists no workflow writes and no expression or rule reads
  # (unused fields are a separate, future kind), and fields covered by a
  # `:redundant_reverse_list` or `:privacy_access_list` finding, which
  # propose a more specific model for the same list.
  #
  # Confidence: high when workflows add and remove members one at a time;
  # medium otherwise.

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Findings.Context

  @spec run(Context.t(), MapSet.t(), map()) :: [Finding.t()]
  def run(ctx, covered, joins) do
    for field <- Context.all_fields(ctx),
        not Map.has_key?(field.attrs, :builtin),
        not MapSet.member?(covered, field.id),
        %{type: to, list: true} <- [Context.target(ctx, field.id)],
        writes = Index.writers(ctx.index, field.id),
        readers = Index.readers(ctx.index, field.id),
        writes != [] or readers != [],
        do: finding(ctx, field, to, writes, readers, Map.fetch!(joins, field.id))
  end

  defp finding(ctx, field, to, writes, readers, join) do
    type = Context.type_of_field(field)
    changes = writes |> Enum.map(& &1.attrs[:change]) |> Enum.uniq() |> Enum.sort()

    {confidence, reason} =
      if Enum.any?(changes, &(&1 in ["add", "remove"])),
        do:
          {:high,
           "workflows add and remove members one at a time, so the list grows without bound"},
        else:
          {:medium,
           "a join is the relational form; whether the list's order matters needs the owner"}

    Finding.new(:list_relationship, %{type: type, field: field.bubble_id},
      path: field.path,
      evidence: %{
        symbols: [field.id, "data_type:" <> to | join.fields],
        references: writes,
        writes: length(writes),
        reads: length(readers),
        changes: changes
      },
      proposal: %{
        transform: :normalize_list_to_join,
        field: field.id,
        from_type: "data_type:" <> type,
        to_type: "data_type:" <> to,
        join: join,
        source_order: :preserved,
        source_limit: 10_000
      },
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, Enum.map(readers, & &1.from), Enum.map(writes, & &1.from)),
      message:
        "“#{Context.name(ctx, field.id)}” on “#{Context.name(ctx, "data_type:" <> type)}” is a list of " <>
          "“#{Context.name(ctx, "data_type:" <> to)}”; model it as a join" <>
          if(length(join.fields) > 1, do: " shared with the list on the other side", else: "") <>
          " (Bubble lists stop at 10,000 items)"
    )
  end
end
