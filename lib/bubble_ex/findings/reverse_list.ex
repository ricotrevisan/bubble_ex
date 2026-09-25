defmodule BubbleEx.Findings.ReverseList do
  @moduledoc false

  # `:redundant_reverse_list` - B has a `list of A` that workflows maintain,
  # while A has a scalar reference R to B: the list mirrors "the As whose R is
  # this B" and can be derived from R (a has-many), so it and its maintaining
  # writes can go.
  #
  # R is identified by coupling: some workflow that writes the list also
  # writes R. Exactly one coupled reference is required; without coupling a
  # shared type is no evidence that the list mirrors the reference (it may
  # be an unrelated many-to-many), so nothing is reported. Built-in
  # `Created By` never counts: a user's list of things is rarely exactly
  # the things they created, even when the creating workflow adds to it.
  #
  # Confidence: high when every workflow maintaining the list also writes R,
  # or creates or deletes an A; medium when some maintain it on their own,
  # since the list may then hold a filtered subset (e.g. only open items)
  # rather than every A.
  #
  # A missing reverse list is not a finding: the has-many comes free from
  # the other side's reference.

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Findings.Context

  @spec run(Context.t()) :: [Finding.t()]
  def run(ctx) do
    for field <- Context.all_fields(ctx),
        not Map.has_key?(field.attrs, :builtin),
        %{type: a, list: true} <- [Context.target(ctx, field.id)],
        finding <- analyze(ctx, field, a),
        do: finding
  end

  defp analyze(ctx, list, a) do
    b = Context.type_of_field(list)
    writes = Index.writers(ctx.index, list.id)
    workflows = ctx |> workflows(writes) |> Enum.uniq()

    candidates =
      ctx |> Context.scalar_refs(a, b) |> Enum.reject(&Map.has_key?(&1.attrs, :builtin))

    coupled =
      for ref <- candidates,
          ref_workflows = MapSet.new(workflows(ctx, Index.writers(ctx.index, ref.id))),
          Enum.any?(workflows, &MapSet.member?(ref_workflows, &1)),
          do: {ref, ref_workflows}

    case coupled do
      [{ref, ref_workflows}] ->
        [
          finding(
            ctx,
            %{list: list, b: b, a: a, ref: ref, writes: writes, workflows: workflows},
            ref_workflows
          )
        ]

      _ ->
        []
    end
  end

  defp workflows(ctx, refs),
    do: refs |> Enum.map(&Context.workflow_of(ctx, &1.from)) |> Enum.reject(&is_nil/1)

  defp finding(
         ctx,
         %{list: list, b: b, a: a, ref: ref, writes: writes, workflows: workflows},
         ref_workflows
       ) do
    readers = Index.readers(ctx.index, list.id)
    rules = Index.privacy_rules_referencing(ctx.index, list.id)

    alone =
      Enum.reject(
        workflows,
        &(MapSet.member?(ref_workflows, &1) or creates_or_deletes?(ctx, &1, a))
      )

    {confidence, reason} =
      if alone == [],
        do:
          {:high,
           "every workflow maintaining the list also sets the reference, or creates or deletes the record"},
        else:
          {:medium,
           "#{length(alone)} of #{length(workflows)} workflows maintain the list without setting the reference " <>
             "or creating or deleting the record; " <>
             "it may hold a filtered subset"}

    Finding.new(:redundant_reverse_list, %{type: b, field: list.bubble_id},
      path: list.path,
      evidence: %{
        symbols: [list.id, ref.id, "data_type:" <> a],
        references: writes ++ Index.writers(ctx.index, ref.id),
        writes: length(writes),
        reads: length(readers)
      },
      proposal: %{
        transform: :derive_reverse_relationship,
        drop_field: list.id,
        relationship: %{source_type: "data_type:" <> a, via: ref.id, cardinality: :many},
        remove_writes: writes |> Enum.map(& &1.from) |> Enum.uniq() |> Enum.sort(),
        maintaining_workflows: Enum.sort(workflows)
      },
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, Enum.map(writes ++ readers ++ rules, & &1.from)),
      message:
        "“#{Context.name(ctx, list.id)}” on “#{Context.name(ctx, "data_type:" <> b)}” lists the " <>
          "“#{Context.name(ctx, "data_type:" <> a)}” records whose “#{Context.name(ctx, ref.id)}” points back; " <>
          "derive it from that reference and drop the #{length(writes)} write(s) maintaining it"
    )
  end

  defp creates_or_deletes?(ctx, workflow, a) do
    ctx.index
    |> Index.workflow_writes(workflow)
    |> Enum.any?(
      &(&1.kind == :writes_type and &1.to == "data_type:" <> a and
          &1.attrs.operation in [:insert, :delete])
    )
  end
end
