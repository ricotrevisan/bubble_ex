defmodule BubbleEx.Findings.Denormalized do
  @moduledoc false

  # `:denormalized_field` - a scalar field (text, number, date, yes/no or
  # option) every write of which copies a field of a related record, or
  # counts a list,
  # e.g. a join record's "Sort: Title" set from its Thing's Title. The value
  # can be derived instead, and the writes that maintain it dropped.
  #
  # A write counts as a copy when its value is a field chain ending in field G
  # of data type U and either
  #   * U is the written type T and the value counts a list of T (an
  #     aggregate over the record's own list), or
  #   * T has a scalar reference R to U: named in the chain just before G
  #     (`This Thing's R's G`), or T's only reference to U.
  # Copies of another field of the same type, of a `unique id` (see
  # `:id_in_text`), formatted text, inputs and arithmetic are not
  # derivations. Reference fields are not considered.
  #
  # Every indexed write must be a traced copy. When only some are, the field
  # is usually owned data that is also seeded from a related record, and
  # deriving it would lose the other writes; no finding is emitted (so
  # evidence always has traced == total writes). The proposal removes exactly
  # those writes (`%{action, field}`), deletes only workflows whose every
  # action is such a removal, and lists the calls to the deleted workflows.
  #
  # Confidence: low when writes copy different sources (the most common is
  # proposed, the others are alternatives); high when the source never
  # changes (a related record's Created Date or Created By), or updates keep
  # the copy in sync; medium for copies taken only on creation (possibly a
  # deliberate snapshot).

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Findings.{Context, Values}
  alias BubbleEx.Index.Symbol

  @scalars ~w(text number date boolean)

  @spec run(Context.t()) :: [Finding.t()]
  def run(ctx) do
    for field <- Context.all_fields(ctx),
        candidate?(field),
        finding <- analyze(ctx, field),
        do: finding
  end

  defp candidate?(%Symbol{attrs: attrs}) do
    not Map.has_key?(attrs, :builtin) and
      (attrs[:value_type] in @scalars or match?("option." <> _, attrs[:value_type]))
  end

  # Only fields every write of which is a traced copy: a field that is also
  # set from literals, inputs or parameters is owned data, and deriving it
  # would lose those values (see the moduledoc).
  defp analyze(ctx, field) do
    type = Context.type_of_field(field)
    writes = Index.writers(ctx.index, field.id)
    traced = for w <- writes, d = derivation(ctx, type, field, w), do: {w, d}

    if writes != [] and length(traced) == length(writes),
      do: [finding(ctx, field, type, writes, group(traced))],
      else: []
  end

  # Derivations ordered by support (most writes first), then by content.
  defp group(traced) do
    traced
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.sort_by(fn {d, ws} -> {-length(ws), d.via != [], inspect(d)} end)
  end

  defp derivation(ctx, type, field, write) do
    with {ast, reads} <- Context.write_value(ctx, write),
         {op, chain} when op in [:read, :count] <- Values.describe(ast, reads),
         owner when is_binary(owner) <- chain.owner do
      source = Symbol.id(:field, [owner, Values.last(chain)])
      source_derivation(ctx, type, field, op, chain, owner, source)
    else
      _ -> nil
    end
  end

  # A count needs a list source and a copy a scalar one.
  defp source_derivation(ctx, type, field, op, chain, owner, source) do
    list? = match?(%{list: true}, Context.target(ctx, source)) or list_type?(ctx, source)
    usable? = source != field.id and derivable_source?(ctx, source) and op == :count == list?

    cond do
      not usable? -> nil
      owner == type -> if op == :count, do: %{aggregate: :count, via: [], source_field: source}
      true -> related(ctx, type, owner, op, chain, source)
    end
  end

  defp related(ctx, type, owner, op, chain, source) do
    case via(ctx, type, owner, chain) do
      nil -> nil
      via -> %{aggregate: aggregate(op), via: [via], source_field: source}
    end
  end

  # Unique IDs are references stored as text (`:id_in_text`), not copies.
  defp derivable_source?(ctx, source) do
    case Index.symbol(ctx.index, source) do
      nil -> false
      %{attrs: %{builtin: :unique_id}} -> false
      _ -> true
    end
  end

  defp aggregate(:count), do: :count
  defp aggregate(:read), do: nil

  defp list_type?(ctx, id) do
    case Index.symbol(ctx.index, id) do
      %{attrs: %{value_type: "list." <> _}} -> true
      _ -> false
    end
  end

  # The reference from `type` to `owner` the value goes through.
  defp via(ctx, type, owner, chain) do
    refs = ctx |> Context.scalar_refs(type, owner) |> Enum.map(& &1.id)
    named = named_ref(chain, type)

    cond do
      named in refs -> named
      match?([_], refs) -> hd(refs)
      true -> nil
    end
  end

  defp named_ref(%{keys: keys, owners: owners}, type) when length(keys) >= 2 do
    key = Enum.at(keys, -2)
    owner = Enum.at(owners, -2)
    if owner in [type, nil], do: Symbol.id(:field, [type, key])
  end

  defp named_ref(_, _), do: nil

  defp finding(ctx, field, type, writes, [{primary, _} | alternatives]) do
    workflows =
      writes
      |> Enum.map(&Context.workflow_of(ctx, &1.from))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    updated? = Enum.any?(writes, &(&1.attrs.operation == :update))
    {confidence, reason} = confidence(ctx, primary, alternatives, updated?)

    {transform, derivation} = transform(primary)

    readers = Index.readers(ctx.index, field.id)
    deletable = deletable(ctx, workflows, MapSet.new(writes, &{&1.from, &1.to}))

    value_reads =
      for w <- writes,
          {_, reads} <- [Context.write_value(ctx, w)],
          r <- reads,
          do: r

    Finding.new(:denormalized_field, %{type: type, field: field.bubble_id},
      path: field.path,
      evidence: %{
        symbols: [field.id, primary.source_field | primary.via],
        references: writes ++ value_reads,
        writes: %{total: length(writes), traced: length(writes)},
        reads: length(readers)
      },
      proposal: %{
        transform: transform,
        field: field.id,
        derivation: derivation,
        alternatives:
          Enum.map(alternatives, fn {d, ws} ->
            {transform, derivation} = transform(d)
            %{transform: transform, derivation: derivation, writes: length(ws)}
          end),
        remove_writes:
          writes |> Enum.map(&%{action: &1.from, field: &1.to}) |> Enum.uniq() |> Enum.sort(),
        delete_workflows: deletable,
        remove_calls:
          deletable
          |> Enum.flat_map(&Index.callers(ctx.index, &1))
          |> Enum.map(& &1.action)
          |> Enum.uniq()
          |> Enum.sort()
      },
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, Enum.map(readers, & &1.from), Enum.map(writes, & &1.from)),
      message: message(ctx, field, type, primary, length(writes), length(workflows))
    )
  end

  defp transform(%{aggregate: nil} = d), do: {:derive_from_related, Map.delete(d, :aggregate)}
  defp transform(%{aggregate: :count} = d), do: {:derive_count, Map.delete(d, :aggregate)}

  @immutable [:created_date, :created_by]

  defp confidence(_ctx, _primary, [_ | _] = alternatives, _updated?),
    do:
      {:low,
       "writes copy #{length(alternatives) + 1} different sources; the most common one is proposed"}

  defp confidence(ctx, %{aggregate: nil, source_field: source}, [], updated?) do
    case Index.symbol(ctx.index, source) do
      %{attrs: %{builtin: builtin}} when builtin in @immutable ->
        {:high, "every write copies a source that never changes, so the copy always equals it"}

      _ ->
        maintained(updated?)
    end
  end

  defp confidence(_ctx, _primary, [], updated?), do: maintained(updated?)

  defp maintained(true),
    do: {:high, "every write copies the same source, including updates that keep it in sync"}

  defp maintained(false),
    do:
      {:medium,
       "every write copies the same source, but only on creation; it may be a deliberate snapshot"}

  # Removable actions only change records, and every field they write is one
  # of this finding's traced copies. A workflow can go only when all of its
  # actions are removable (schedules, custom events, API and plugin calls,
  # creations and deletions keep it).
  @change_actions ~w(ChangeThing ChangeListOfThings MakeChangeCurrentUser)

  defp deletable(ctx, workflows, copies) do
    workflows
    |> Enum.filter(fn wf ->
      actions = ctx.index |> Index.children(wf) |> Enum.filter(&(&1.kind == :action))
      actions != [] and Enum.all?(actions, &removable?(ctx, &1, copies))
    end)
    |> Enum.sort()
  end

  defp removable?(ctx, action, copies) do
    field_writes = Index.references_from(ctx.index, action.id, [:writes_field])

    action.attrs[:type] in @change_actions and field_writes != [] and
      Enum.all?(field_writes, &MapSet.member?(copies, {&1.from, &1.to}))
  end

  defp message(ctx, field, type, d, writes, workflows) do
    source = Context.name(ctx, d.source_field)
    what = if d.aggregate == :count, do: "the count of “#{source}”", else: "“#{source}”"

    of =
      case d.via do
        [] -> "of the same record"
        [via] -> "of the related record via “#{Context.name(ctx, via)}”"
      end

    "“#{Context.name(ctx, field.id)}” on “#{Context.name(ctx, "data_type:" <> type)}” stores #{what} " <>
      "#{of}, maintained by #{writes} write(s) in #{workflows} workflow(s); derive it and drop those writes"
  end
end
