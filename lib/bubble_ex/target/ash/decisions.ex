defmodule BubbleEx.Target.Ash.Decisions do
  @moduledoc false

  # Owner decisions applied by `BubbleEx.Target.Ash.map/3` (WTF-352 §4,
  # cuts 1 and 2). `plan/3` validates the applicable decisions against the
  # Model and the name map and returns the name map with the rename
  # overrides, the field transforms, the indexes, the `project.applied`
  # and `project.deferred` records and the diagnostics; `apply/2` rewrites
  # the mapped resources (`text_to_reference` is mapped by
  # `BubbleEx.Target.Ash` itself, which names the new relationship). The
  # input contract and the semantics are documented in
  # `BubbleEx.Target.Ash` ("Decisions").

  alias BubbleEx.{Decision, Diagnostic, Error, Finding, Model}
  alias BubbleEx.Decision.Applied
  alias BubbleEx.Finding.Kinds
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Model.{ExternalType, Type}
  alias BubbleEx.Target.Ash.{Aggregate, Calculation, Expr, Index, Naming, Relationship, Resource}

  @supported [
    :refine_number_type,
    :derive_from_related,
    :rename,
    :derive_count,
    :text_to_reference,
    :derive_reverse_relationship,
    :add_indexes
  ]

  # Transforms a later cut of Target.Ash will apply (WTF-352 §4.2).
  @later %{
    normalize_list_to_join: "cut 3",
    membership_policy: "cut 3"
  }

  # Field transforms: each drops or changes one field's attribute.
  @field_ops [:refine, :derive, :count, :text_ref, :reverse]

  # Index methods per access pattern (`BubbleEx.Findings.SearchIndex`).
  @btree_access [:equality, :range, :sort]

  # PostgreSQL identifiers are at most 63 bytes.
  @max_identifier 63

  @number_types [:integer, :decimal]

  # Transforms that are not the schema's: the plan interprets them
  # (`BubbleEx.Plan`), so the schema generator skips them.
  @not_schema [:replace_plugin]

  # Resource name map members holding names in one attribute scope.
  @resource_scope ~w(attributes relationships privacy_rules privacy_relationships)

  # The generated `<namespace>.Privacy` module (privacy: :unverified).
  @generated_modules ~w(Privacy)

  @type field_key :: {String.t(), String.t()}
  @type plan :: %{
          names: map(),
          refine: %{field_key() => map()},
          derive: %{field_key() => map()},
          count: %{field_key() => map()},
          text_ref: %{field_key() => map()},
          reverse: %{field_key() => map()},
          indexes: %{String.t() => [map()]},
          applied: [map()],
          deferred: [map()],
          owners: [tuple()],
          diagnostics: [Diagnostic.t()]
        }

  @doc false
  @spec plan(Model.t(), list(), map()) :: {:ok, plan()} | {:error, Error.t()}
  def plan(%Model{} = model, decisions, names) when is_list(decisions) do
    ctx = context(model)

    with :ok <- all_applied(decisions),
         :ok <- unique_keys(decisions),
         decisions = decisions |> Enum.reject(&(&1.transform in @not_schema)),
         decisions = Enum.sort_by(decisions, & &1.key),
         {:ok, checked} <- collect(decisions, &check(&1, ctx)),
         {deferred, checked} = Enum.split_with(checked, &(elem(&1, 0) == :defer)),
         :ok <- one_per_field(checked),
         fields =
           for({op, a, subject, data} <- checked, op in @field_ops, do: {op, subject, a, data}),
         ops = Map.new(@field_ops, fn op -> {op, field_map(fields, op)} end),
         ctx = Map.merge(ctx, ops),
         :ok <- stored_sources(ctx),
         {:ok, indexes, index_deferred, index_diags} <- indexes(checked, ctx),
         {:ok, names, rename_diags} <- renames(checked, names, ctx) do
      applied =
        for {op, a, _, _} <- checked,
            op != :indexes or Map.has_key?(indexes, a.key),
            do: record(a)

      {:ok,
       Map.merge(ops, %{
         names: names,
         indexes: indexes |> Map.values() |> Enum.group_by(& &1.type, & &1.indexes),
         applied: applied,
         deferred:
           Enum.sort_by(
             Enum.map(deferred, &Map.put(record(elem(&1, 1)), :indexes, nil)) ++ index_deferred,
             & &1.key
           ),
         owners: for({:rename, a, _, _} <- checked, do: owner(a.params.slot, a.subject)),
         diagnostics:
           Enum.flat_map(fields, &field_diag(&1, ctx)) ++
             index_diags ++
             rename_diags ++ Enum.map(deferred, &deferred_diag(elem(&1, 1), ctx))
       })
       |> Map.update!(:indexes, fn by_type ->
         Map.new(by_type, fn {t, lists} -> {t, List.flatten(lists)} end)
       end)}
    end
  end

  defp field_map(fields, op),
    do: for({^op, s, a, data} <- fields, into: %{}, do: {s, Map.put(data, :key, a.key)})

  # --- the input contract ----------------------------------------------------------

  defp all_applied(decisions) do
    case Enum.find(decisions, &(not is_struct(&1, Applied))) do
      nil ->
        :ok

      %Decision{key: key} ->
        error(
          "decisions must be resolved first: pass BubbleEx.Decision.applicable/2 " <>
            "(of BubbleEx.Decision.resolve/3), not decision records",
          %{key: key}
        )

      other ->
        error("expected BubbleEx.Decision.Applied structs", %{value: inspect(other, limit: 5)})
    end
  end

  defp unique_keys(decisions) do
    case decisions |> Enum.frequencies_by(& &1.key) |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> :ok
      {key, _} -> error("two applied decisions share a key", %{key: key})
    end
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp check(%Applied{kind: :finding} = a, ctx) do
    with :ok <- known(a),
         :ok <- finding_identity(a),
         :ok <- fresh(a) do
      if a.transform in @supported, do: supported_finding(a, ctx), else: unsupported_finding(a)
    end
  end

  defp check(%Applied{kind: :rename} = a, _ctx) do
    with :ok <- supported(a),
         :ok <- rename_identity(a),
         do: {:ok, {:rename, a, a.subject, a.params}}
  end

  defp check(%Applied{} = a, _ctx),
    do: error("unknown applied decision kind", %{key: a.key, kind: inspect(a.kind)})

  defp supported_finding(%Applied{transform: :add_indexes} = a, ctx), do: type_indexes(a, ctx)

  defp supported_finding(a, ctx) do
    with {:ok, subject, field} <- subject_field(a, ctx),
         :ok <- proposal_field(a, subject),
         do: transform(a, subject, field, ctx)
  end

  # A hint nobody decided is deferred until a later cut applies its
  # transform (reported, never silent); an owner's decision on an
  # unsupported transform is an error.
  defp unsupported_finding(%Applied{automatic: true} = a), do: {:ok, {:defer, a, a.subject, nil}}
  defp unsupported_finding(a), do: supported(a)

  defp known(%Applied{transform: transform} = a) do
    if transform in @supported or Map.has_key?(@later, transform),
      do: :ok,
      else: error("unknown transform", %{key: a.key, transform: inspect(transform)})
  end

  defp supported(%Applied{transform: transform}) when transform in @supported, do: :ok

  defp supported(%Applied{transform: transform} = a) do
    case Map.fetch(@later, transform) do
      {:ok, cut} ->
        error(
          "Target.Ash does not apply #{transform} yet (#{cut} of WTF-352); leave it out " <>
            "or record a reject",
          %{key: a.key, transform: transform}
        )

      :error ->
        error("unknown transform", %{key: a.key, transform: inspect(transform)})
    end
  end

  # The key, finding ID, kind, subject and transform agree.
  defp finding_identity(%Applied{finding_id: id} = a) when is_binary(id) do
    kind = finding_kind(id, a.subject)

    cond do
      a.key != "finding:" <> id ->
        error("the key does not name the finding", %{key: a.key, finding_id: id})

      kind == nil ->
        error("finding_id is not a finding about the subject", %{key: a.key, finding_id: id})

      a.transform not in elem(Kinds.fetch(kind), 1).transforms ->
        error("the finding kind cannot propose the transform", %{key: a.key})

      not is_map(a.proposal) or a.proposal[:transform] != a.transform ->
        error("the proposal does not match the transform", %{key: a.key})

      true ->
        :ok
    end
  end

  defp finding_identity(a), do: error("an applied finding needs its finding_id", %{key: a.key})

  # The registered kind whose finding about `subject` has ID `id`, or nil.
  defp finding_kind(id, subject) when is_map(subject) do
    with [name, _] <- String.split(id, ":", parts: 2),
         kind when kind != nil <- Enum.find(Kinds.all(), &(Atom.to_string(&1) == name)),
         ^id <- Finding.id(kind, subject) do
      kind
    else
      _ -> nil
    end
  end

  defp finding_kind(_id, _subject), do: nil

  # An active decision was recorded against the finding's current hashes;
  # a hint applied by default was recorded against nothing.
  defp fresh(%Applied{automatic: true} = a) do
    hint? =
      case Kinds.fetch(finding_kind(a.finding_id, a.subject)) do
        {:ok, %{category: :hint}} -> true
        _ -> false
      end

    if hint? and a.basis == nil and a.decision_id == nil and hash?(a.proposal_sha256),
      do: :ok,
      else: error("an automatic entry must be a hint nobody decided", %{key: a.key})
  end

  defp fresh(%Applied{} = a) do
    current = %{proposal_sha256: a.proposal_sha256, basis_sha256: a.basis_sha256}

    cond do
      not (hash?(a.proposal_sha256) and hash?(a.basis_sha256)) ->
        error("an applied finding needs the finding's proposal_sha256 and basis_sha256", %{
          key: a.key
        })

      a.basis != current ->
        error(
          "the decision is stale: it was recorded against another proposal or basis; " <>
            "resolve the decisions against this snapshot",
          %{key: a.key}
        )

      true ->
        :ok
    end
  end

  defp hash?(value), do: is_binary(value) and value =~ ~r/\A[0-9a-f]{64}\z/

  defp subject_field(%Applied{subject: %{type: t, field: f} = subject} = a, ctx)
       when map_size(subject) == 2 do
    case Map.fetch(ctx.fields, {t, f}) do
      {:ok, field} -> {:ok, {t, f}, field}
      :error -> missing(a)
    end
  end

  defp subject_field(a, _ctx),
    do: error("#{a.transform} needs a field subject", %{key: a.key, subject: a.subject})

  defp missing(a) do
    error(
      "the decision's subject is not in the Model (missing or deleted); resolve the " <>
        "decisions against this snapshot",
      %{key: a.key, subject: a.subject}
    )
  end

  defp proposal_field(a, {t, f}) do
    key = if a.transform == :derive_reverse_relationship, do: :drop_field, else: :field

    if a.proposal[key] == Symbol.id(:field, [t, f]),
      do: :ok,
      else: error("the proposal is about another field", %{key: a.key})
  end

  defp rename_identity(%Applied{target: "ash", params: %{slot: slot, name: name}} = a)
       when is_atom(slot) and is_binary(name) and is_map(a.subject) do
    decision = %Decision{
      key: "",
      kind: :rename,
      revision: 1,
      subject: a.subject,
      target: a.target,
      choice: :accept,
      params: a.params
    }

    if a.key == Decision.key(decision),
      do: :ok,
      else: error("the key does not match the rename", %{key: a.key})
  end

  defp rename_identity(%Applied{target: target} = a) when target != "ash",
    do: error("a rename for another target", %{key: a.key, target: target})

  defp rename_identity(a), do: error("a rename needs params slot and name", %{key: a.key})

  # --- field transforms ------------------------------------------------------------

  defp transform(%Applied{transform: :refine_number_type} = a, subject, field, _ctx) do
    to = a.proposal[:to]

    cond do
      to not in @number_types ->
        error("refine_number_type needs to: :integer or :decimal", %{key: a.key, to: inspect(to)})

      not match?(%Type{kind: :scalar, base: :number, cardinality: :one}, field.type) ->
        error("refine_number_type needs a number field; the decision is stale", %{key: a.key})

      to == :integer and is_float(field.default) and field.default != trunc(field.default) ->
        error("the field's default is not an integer", %{key: a.key, default: field.default})

      true ->
        {:ok, {:refine, a, subject, %{to: to}}}
    end
  end

  defp transform(%Applied{transform: :derive_from_related} = a, subject, field, ctx) do
    with {:ok, via, source} <- derivation(a),
         :ok <- derivable(a, field),
         {:ok, via, owner} <- walk(a, elem(subject, 0), via, ctx),
         {:ok, source, source_field} <- source(a, source, owner, ctx),
         :ok <- same_type(a, field, source_field) do
      {:ok, {:derive, a, subject, %{via: via, source: source}}}
    end
  end

  # derive_count: a number field that counts a list of the same record or
  # of a record reached through references (`via` may be empty).
  defp transform(%Applied{transform: :derive_count} = a, subject, field, ctx) do
    with {:ok, via, source} <- count_derivation(a),
         :ok <- countable(a, field),
         {:ok, via, owner} <- walk(a, elem(subject, 0), via, ctx),
         {:ok, source, source_field} <- source(a, source, owner, ctx),
         :ok <- list_source(a, source_field) do
      {:ok, {:count, a, subject, %{via: via, source: source}}}
    end
  end

  # text_to_reference: a text field (or list of texts) holding unique IDs
  # of one mapped data type.
  defp transform(%Applied{transform: :text_to_reference} = a, subject, field, ctx) do
    target = a.proposal[:target_type]
    cardinality = a.proposal[:cardinality]

    cond do
      field.system != nil or
          not match?(
            %Type{kind: :scalar, base: :text, cardinality: c} when c in [:one, :many],
            field.type
          ) ->
        error("text_to_reference needs a text field; the decision is stale", %{key: a.key})

      cardinality != field.type.cardinality ->
        error("the proposal's cardinality is not the field's; the decision is stale", %{
          key: a.key
        })

      target == nil ->
        error(
          "the finding names no target type: decide it with modify target_type " <>
            "(one of the finding's target types)",
          %{key: a.key}
        )

      true ->
        case target do
          "data_type:" <> t when is_map_key(ctx.types, t) ->
            {:ok, {:text_ref, a, subject, %{target: t, cardinality: cardinality}}}

          _ ->
            error("the target type is not a mapped data type; the decision is stale", %{
              key: a.key,
              target_type: target
            })
        end
    end
  end

  # derive_reverse_relationship: a list of A on B that mirrors A's scalar
  # reference to B becomes a has_many.
  defp transform(
         %Applied{transform: :derive_reverse_relationship} = a,
         {b, _} = subject,
         field,
         ctx
       ) do
    with %{source_type: "data_type:" <> from, via: via} when is_binary(via) <-
           a.proposal[:relationship] || :none,
         %Type{kind: :ref, cardinality: :many, target: ^from} <- field.type,
         true <- Map.has_key?(ctx.types, from),
         {:ok, {^from, r}} <- Map.fetch(ctx.symbols, via),
         %Type{kind: :ref, cardinality: :one, target: ^b} <- ctx.fields[{from, r}].type do
      {:ok, {:reverse, a, subject, %{via: {from, r}}}}
    else
      _ ->
        error(
          "derive_reverse_relationship needs a list of a mapped type whose reference points " <>
            "back to this one; the decision is stale",
          %{key: a.key}
        )
    end
  end

  defp derivation(%Applied{proposal: %{derivation: %{via: [_ | _] = via, source_field: s}}} = a)
       when is_binary(s) do
    if Enum.all?(via, &is_binary/1), do: {:ok, via, s}, else: no_derivation(a)
  end

  defp derivation(a), do: no_derivation(a)

  defp no_derivation(a),
    do:
      error(
        "derive_from_related needs a derivation through at least one reference",
        %{key: a.key}
      )

  # A scalar or option field, one value: what a calculation can replace.
  defp derivable(a, field) do
    case field.type do
      %Type{kind: kind, cardinality: :one} when kind in [:scalar, :option] -> :ok
      _ -> error("derive_from_related needs a single scalar or option field", %{key: a.key})
    end
  end

  # Each step is a scalar reference of the current type to a live type.
  defp walk(a, type, via, ctx) do
    Enum.reduce_while(via, {:ok, [], type}, fn symbol, {:ok, acc, current} ->
      with {:ok, {t, f}} <- Map.fetch(ctx.symbols, symbol),
           true <- t == current,
           %Type{kind: :ref, cardinality: :one, target: target} <- ctx.fields[{t, f}].type,
           true <- Map.has_key?(ctx.types, target) do
        {:cont, {:ok, [{t, f} | acc], target}}
      else
        _ ->
          {:halt,
           error(
             "the derivation is not a path of references between mapped types; the decision is stale",
             %{key: a.key, via: symbol}
           )}
      end
    end)
    |> case do
      {:ok, acc, owner} -> {:ok, Enum.reverse(acc), owner}
      error -> error
    end
  end

  defp source(a, symbol, owner, ctx) do
    case Map.fetch(ctx.symbols, symbol) do
      {:ok, {^owner, _} = source} ->
        {:ok, source, ctx.fields[source]}

      _ ->
        error(
          "the derivation's source is not a field of the related type; the decision is stale",
          %{
            key: a.key,
            source_field: symbol
          }
        )
    end
  end

  defp same_type(a, field, source) do
    if content(field.type) == content(source.type),
      do: :ok,
      else:
        error("the derived field and its source have different types; the decision is stale", %{
          key: a.key
        })
  end

  defp content(%Type{} = t), do: {t.kind, t.base, t.target, t.cardinality}

  defp count_derivation(%Applied{proposal: %{derivation: %{via: via, source_field: s}}} = a)
       when is_list(via) and is_binary(s) do
    if Enum.all?(via, &is_binary/1), do: {:ok, via, s}, else: no_count(a)
  end

  defp count_derivation(a), do: no_count(a)

  defp no_count(a),
    do: error("derive_count needs a derivation naming the counted list", %{key: a.key})

  defp countable(a, field) do
    case field.type do
      %Type{kind: :scalar, base: :number, cardinality: :one} ->
        :ok

      _ ->
        error("derive_count needs a number field; the decision is stale", %{key: a.key})
    end
  end

  defp list_source(a, source_field) do
    case source_field.type do
      %Type{cardinality: :many} ->
        :ok

      _ ->
        error("the counted field is not a list; the decision is stale", %{key: a.key})
    end
  end

  # --- indexes (add_indexes) -------------------------------------------------------

  # The type and its indexes' columns must be live fields of it; which
  # index is created is decided later, with every field transform known.
  defp type_indexes(%Applied{subject: %{type: t} = subject} = a, ctx)
       when map_size(subject) == 1 do
    with {:ok, _type} <- fetch_live(ctx.types, t, a),
         true <-
           a.proposal[:type] == "data_type:" <> t ||
             error("the proposal is about another data type", %{key: a.key}),
         {:ok, indexes} <- index_columns(a, t, ctx) do
      {:ok, {:indexes, a, subject, %{type: t, indexes: indexes}}}
    end
  end

  defp type_indexes(a, _ctx),
    do: error("add_indexes needs a data type subject", %{key: a.key, subject: a.subject})

  defp fetch_live(map, id, a) do
    case Map.fetch(map, id) do
      {:ok, item} -> {:ok, item}
      :error -> missing(a)
    end
  end

  defp index_columns(a, t, ctx) do
    a.proposal
    |> Map.get(:indexes, [])
    |> Enum.with_index()
    |> collect(fn {index, i} ->
      index
      |> Map.get(:columns, [])
      |> collect(&index_column(&1, t, a, i, ctx))
      |> case do
        {:ok, []} -> stale_index(a, i)
        {:ok, columns} -> {:ok, %{position: i, columns: columns}}
        error -> error
      end
    end)
  end

  defp index_column(%{field: symbol, access: access}, t, a, i, ctx) do
    case Map.fetch(ctx.symbols, symbol) do
      {:ok, {^t, _} = field} -> {:ok, %{field: field, access: access}}
      _ -> stale_index(a, i)
    end
  end

  defp index_column(_column, _t, a, i, _ctx), do: stale_index(a, i)

  defp stale_index(a, i),
    do:
      error(
        "an index names a field that is not in the Model (or not of its data type); the " <>
          "decision is stale",
        %{key: a.key, index: i}
      )

  # Each index's physical form, or why it is deferred: `{:ok, created,
  # deferred records, diagnostics}` where `created` maps each decision key
  # with at least one index to `%{type, indexes}`.
  defp indexes(checked, ctx) do
    derived = derived_fields(ctx)

    {created, deferred, diags} =
      for {:indexes, a, _, %{type: t, indexes: indexes}} <- checked,
          reduce: {%{}, [], []} do
        {created, deferred, diags} ->
          resolved = Enum.map(indexes, &{&1, index_method(&1, derived, ctx)})
          made = for {index, {:ok, method}} <- resolved, do: {index, method}
          skipped = for {index, {:defer, reason}} <- resolved, do: {index, reason}

          created =
            if made == [],
              do: created,
              else: Map.put(created, a.key, %{type: t, indexes: merge_indexes(made, a.key, t)})

          deferred =
            if skipped == [],
              do: deferred,
              else: [
                Map.put(record(a), :indexes, Enum.map(skipped, &elem(&1, 0).position))
                | deferred
              ]

          diags =
            diags ++
              index_applied_diag(a, made, ctx) ++
              index_deferred_diag(a, skipped, ctx)

          {created, deferred, diags}
      end

    {:ok, created, deferred, diags}
  end

  # The fields a decision of this set no longer stores.
  defp derived_fields(ctx),
    do: MapSet.new(Map.keys(ctx.derive) ++ Map.keys(ctx.count) ++ Map.keys(ctx.reverse))

  defp index_method(%{columns: columns}, derived, ctx) do
    types = Enum.map(columns, &ctx.fields[&1.field].type)
    access = Enum.map(columns, & &1.access)

    cond do
      Enum.any?(columns, &MapSet.member?(derived, &1.field)) ->
        {:defer, "a field it covers is derived by a decision and has no column"}

      Enum.all?(access, &(&1 in @btree_access)) ->
        {:ok, :btree}

      true ->
        single_method(access, types)
    end
  end

  # One column searched another way than by value.
  defp single_method([:substring], types) do
    if text?(types),
      do: {:ok, :trigram},
      else: {:defer, "substring search on a field that is not text"}
  end

  defp single_method([:full_text], types) do
    if text?(types),
      do: {:ok, :full_text},
      else: {:defer, "keyword search on a field that is not text"}
  end

  defp single_method([:membership], types) do
    if match?([%Type{cardinality: :many}], types),
      do: {:ok, :gin},
      else: {:defer, "membership in a field that is not a list"}
  end

  defp single_method([:geo], _types) do
    {:defer,
     "geographic search needs PostGIS; geographic addresses are stored as JSON and the " <>
       "generated project has no geographic index"}
  end

  defp single_method([_, _ | _] = access, _types),
    do: {:defer, "#{Enum.join(access, ", ")} cannot share one index"}

  defp single_method(access, _types), do: {:defer, "no index for the access #{inspect(access)}"}

  defp text?(types), do: match?([%Type{kind: :scalar, base: :text, cardinality: :one}], types)

  # Indexes with the same method and columns are one index, listing every
  # position it serves.
  defp merge_indexes(made, key, t) do
    made
    |> Enum.group_by(fn {index, method} -> {method, Enum.map(index.columns, & &1.field)} end)
    |> Enum.map(fn {{method, fields}, group} ->
      positions = group |> Enum.map(&elem(&1, 0).position) |> Enum.sort()
      %{key: key, type: t, method: method, fields: fields, positions: positions}
    end)
    |> Enum.sort_by(&hd(&1.positions))
  end

  # A field takes one finding transform.
  defp one_per_field(checked) do
    checked
    |> Enum.filter(&(elem(&1, 0) in @field_ops))
    |> Enum.frequencies_by(&elem(&1, 2))
    |> Enum.find(fn {_, n} -> n > 1 end)
    |> case do
      nil -> :ok
      {{t, f}, _} -> error("two decisions transform one field", %{subject: %{type: t, field: f}})
    end
  end

  # A calculation reads stored values: a derived field's source is not
  # derived itself (a count over a list derived as a has_many is an
  # aggregate, the one supported combination).
  defp stored_sources(ctx) do
    derived = MapSet.new(Map.keys(ctx.derive) ++ Map.keys(ctx.count))

    case Enum.find(ctx.derive, fn {_, d} -> MapSet.member?(derived, d.source) end) do
      nil ->
        :ok

      {{t, f}, d} ->
        error(
          "a derived field's source is derived too; deriving from a derived field is not " <>
            "supported",
          %{key: d.key, subject: %{type: t, field: f}}
        )
    end
  end

  # --- renames ---------------------------------------------------------------------

  defp renames(checked, names, ctx) do
    renames = for {:rename, a, _, _} <- checked, do: a

    Enum.reduce_while(renames, {:ok, names, []}, fn a, {:ok, names, diags} ->
      case rename(a.params.slot, a.subject, a.params.name, names, ctx) do
        {:ok, names, details, path} ->
          diag = rename_diag(a, details, path)
          {:cont, {:ok, names, [diag | diags]}}

        {:error, message, context} ->
          {:halt, error(message, Map.merge(%{key: a.key}, context))}
      end
    end)
    |> case do
      {:ok, names, diags} -> {:ok, names, Enum.reverse(diags)}
      error -> error
    end
  end

  defp rename(:module, %{type: t} = s, name, names, ctx) when map_size(s) == 1 do
    with {:ok, type} <- live(ctx.types, t),
         :ok <- module_name(name),
         :ok <- free_in_section(names, "resources", t, "module", name) do
      {:ok, put_name(names, ["resources", t, "module"], name), %{}, type.path}
    end
  end

  defp rename(:module, %{external_type: id} = s, name, names, ctx) when map_size(s) == 1 do
    with {:ok, type} <- live(ctx.externals, id),
         true <-
           ExternalType.known?(type) || {:error, "the external type has no known shape", %{}},
         :ok <- module_name(name),
         :ok <- free_in_section(names, "external_types", id, "module", name) do
      {:ok, put_name(names, ["external_types", id, "module"], name), %{}, type.path || ""}
    end
  end

  defp rename(:table, %{type: t} = s, name, names, ctx) when map_size(s) == 1 do
    locked = get_in(names, ["resources", t, "table"])

    with {:ok, type} <- live(ctx.types, t),
         :ok <- snake_name(name, :table),
         :ok <- post_lock_table(locked, name),
         :ok <- free_in_section(names, "resources", t, "table", name) do
      {:ok, put_name(names, ["resources", t, "table"], name), %{}, type.path}
    end
  end

  defp rename(:attribute, %{type: t, field: f} = s, name, names, ctx) when map_size(s) == 2 do
    entry = get_in(names, ["resources", t]) || %{}

    with {:ok, field} <- live(ctx.fields, {t, f}),
         :ok <- not_key(field),
         :ok <- stored(ctx, {t, f}),
         :ok <- snake_name(name, :attribute),
         :ok <- free_in_resource(entry, {"attributes", f}, name) do
      {entry, column} = attribute_rename(entry, f, name)
      details = if column, do: %{column: column}, else: %{}
      {:ok, put_in_resource(names, t, entry), details, field.path}
    end
  end

  defp rename(:attribute, %{option_set: set, field: f} = s, name, names, ctx)
       when map_size(s) == 2 do
    with {:ok, option_set} <- live(ctx.sets, set),
         {:ok, attribute} <- live(Map.new(option_set.attributes, &{&1.id, &1}), f),
         :ok <- snake_name(name, :field),
         :ok <- free_in_map(get_in(names, ["enums", set, "attributes"]) || %{}, f, name) do
      {:ok, put_name(names, ["enums", set, "attributes", f], name), %{}, attribute.path}
    end
  end

  defp rename(:relationship, %{type: t, field: f} = s, name, names, ctx)
       when map_size(s) == 2 do
    entry = get_in(names, ["resources", t]) || %{}

    with {:ok, field} <- live(ctx.fields, {t, f}),
         :ok <- reference(field, {t, f}, ctx),
         :ok <- snake_name(name, :attribute),
         :ok <- free_in_resource(entry, {"relationships", f}, name) do
      entry = put_member(entry, "relationships", f, name)
      {:ok, put_in_resource(names, t, entry), %{}, field.path}
    end
  end

  defp rename(:calculation, %{type: t, field: f} = s, name, names, ctx)
       when map_size(s) == 2 do
    entry = get_in(names, ["resources", t]) || %{}

    with {:ok, field} <- live(ctx.fields, {t, f}),
         true <-
           (Map.has_key?(ctx.derive, {t, f}) or Map.has_key?(ctx.count, {t, f})) ||
             {:error, "a calculation rename needs a field derived by a decision in this set", %{}},
         :ok <- snake_name(name, :attribute),
         :ok <- free_in_resource(entry, {"attributes", f}, name) do
      entry = put_member(entry, "attributes", f, name)
      {:ok, put_in_resource(names, t, entry), %{}, field.path}
    end
  end

  defp rename(:enum_module, %{option_set: set} = s, name, names, ctx) when map_size(s) == 1 do
    with {:ok, option_set} <- live(ctx.sets, set),
         :ok <- module_name(name),
         :ok <- free_in_section(names, "enums", set, "module", name) do
      {:ok, put_name(names, ["enums", set, "module"], name), %{}, option_set.path}
    end
  end

  defp rename(:endpoint_path, _subject, _name, _names, _ctx),
    do: {:error, "Target.Ash maps no endpoints; an endpoint_path rename does not apply", %{}}

  defp rename(slot, subject, _name, _names, _ctx),
    do: {:error, "a #{slot} rename does not fit its subject", %{subject: subject}}

  defp live(map, id) do
    case Map.fetch(map, id) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, "the rename's subject is not in the Model (missing or deleted)", %{}}
    end
  end

  defp not_key(%{system: :unique_id}),
    do: {:error, "the primary key (the Bubble unique ID) is not renamed", %{}}

  defp not_key(_field), do: :ok

  defp stored(ctx, subject) do
    cond do
      Map.has_key?(ctx.derive, subject) or Map.has_key?(ctx.count, subject) ->
        {:error, "the field is derived by a decision: rename its calculation", %{}}

      Map.has_key?(ctx.reverse, subject) ->
        {:error, "the list is derived as a has_many by a decision; renaming it is not supported",
         %{}}

      true ->
        :ok
    end
  end

  defp reference(field, {t, f}, ctx) do
    case field.type do
      %Type{kind: :ref, cardinality: :one, target: target} when is_map_key(ctx.types, target) ->
        :ok

      _ ->
        case ctx.text_ref[{t, f}] do
          %{cardinality: :one} ->
            :ok

          _ ->
            {:error,
             "a relationship rename needs a reference to a mapped data type (or a text field " <>
               "made one by a decision in this set)", %{}}
        end
    end
  end

  defp module_name(name) do
    cond do
      not Naming.valid?(:pascal, name) ->
        {:error, "a module name must be one PascalCase segment", %{name: name}}

      name in Naming.reserved(:module) or name in @generated_modules or
          Decision.reserved_module?(name) ->
        {:error, "the module name is reserved", %{name: name}}

      true ->
        :ok
    end
  end

  defp snake_name(name, scope) do
    cond do
      not Naming.valid?(:snake, name) -> {:error, "invalid #{scope} name", %{name: name}}
      name in Naming.reserved(scope) -> {:error, "the #{scope} name is reserved", %{name: name}}
      true -> :ok
    end
  end

  # D5: after the name lock the table keeps its name (no data migration).
  defp post_lock_table(nil, _name), do: :ok
  defp post_lock_table(name, name), do: :ok

  defp post_lock_table(locked, _name),
    do:
      {:error,
       "the table name is locked; after the lock a rename changes Elixir names only, " <>
         "and a table has none", %{locked: locked}}

  defp free_in_section(names, section, id, key, name) do
    taken =
      Enum.find(Map.get(names, section, %{}), fn {other, entry} ->
        other != id and entry[key] == name
      end)

    if taken,
      do: {:error, "the name is taken", %{name: name, by: elem(taken, 0)}},
      else: :ok
  end

  defp free_in_map(map, id, name) do
    case Enum.find(map, fn {other, taken} -> other != id and taken == name end) do
      nil -> :ok
      {other, _} -> {:error, "the name is taken", %{name: name, by: other}}
    end
  end

  # Every name and column of a resource's attribute scope, but `slot`'s own.
  defp free_in_resource(entry, {member, id} = slot, name) do
    taken =
      for key <- @resource_scope,
          {other, taken} <- Map.get(entry, key, %{}),
          {key, other} != slot,
          do: {taken, other}

    columns =
      for {other, column} <- Map.get(entry, "columns", %{}),
          not (member == "attributes" and other == id),
          do: {column, other}

    case List.keyfind(taken ++ columns, name, 0) do
      nil -> :ok
      {_, other} -> {:error, "the name is taken", %{name: name, by: other}}
    end
  end

  # D5: a locked attribute renamed keeps its column (`source:`); renamed
  # back to its column, it needs none.
  defp attribute_rename(entry, f, name) do
    locked = get_in(entry, ["attributes", f])
    column = get_in(entry, ["columns", f]) || if(locked != name, do: locked)
    entry = put_member(entry, "attributes", f, name)

    if column in [nil, name] do
      {Map.update(entry, "columns", %{}, &Map.delete(&1, f)) |> drop_empty("columns"), nil}
    else
      {put_member(entry, "columns", f, column), column}
    end
  end

  defp drop_empty(entry, key) do
    if Map.get(entry, key) == %{}, do: Map.delete(entry, key), else: entry
  end

  defp put_member(entry, member, id, name),
    do: Map.update(entry, member, %{id => name}, &Map.put(&1, id, name))

  defp put_in_resource(names, t, entry) do
    resources = Map.get(names, "resources", %{})
    Map.put(names, "resources", Map.put(resources, t, entry))
  end

  defp put_name(names, [section, id | rest], name) do
    entries = Map.get(names, section, %{})
    entry = Map.get(entries, id, %{})
    entry = put_path(entry, rest, name)
    Map.put(names, section, Map.put(entries, id, entry))
  end

  defp put_path(_map, [], name), do: name

  defp put_path(map, [key | rest], name),
    do: Map.put(map, key, put_path(Map.get(map, key, %{}), rest, name))

  # The name map entry a rename (and what follows from it: a module's
  # derived table, a relationship's `_id` attribute and privacy twin) owns.
  defp owner(slot, %{type: t}) when slot in [:module, :table], do: {"resources", t}
  defp owner(:module, %{external_type: id}), do: {"external_types", id}
  defp owner(:enum_module, %{option_set: s}), do: {"enums", s}
  defp owner(:attribute, %{option_set: s, field: f}), do: {"enums", s, f}
  defp owner(_slot, %{type: t, field: f}), do: {"resources", t, f}
  defp owner(_slot, subject), do: {:other, subject}

  @doc false
  # Before the lock a rename may take a name another definition would
  # have been given; that definition would silently get a suffixed name,
  # locked at first publish. `baseline` is the name map mapped without the
  # renames: every name that differs and is not the renames' own is an
  # error.
  @spec displaced(map(), map(), [tuple()]) :: :ok | {:error, Error.t()}
  def displaced(names, baseline, owners) do
    owners = MapSet.new(owners)
    final = flatten(names)

    moved =
      for {path, owner, from} <- baseline |> flatten() |> Map.values(),
          not MapSet.member?(owners, owner),
          (to = elem(Map.get(final, path, {nil, nil, nil}), 2)) != from,
          do: %{path: Enum.join(path, "/"), from: from, to: to}

    if moved == [],
      do: :ok,
      else:
        error(
          "a rename takes a name another definition is given; rename that one too, " <>
            "or choose another name",
          %{displaced: moved}
        )
  end

  defp flatten(names) do
    for section <- ~w(resources enums external_types),
        {id, entry} <- Map.get(names, section, %{}),
        {key, value} <- entry,
        {path, owner, name} <- members(section, id, key, value),
        into: %{},
        do: {path, {path, owner, name}}
  end

  defp members(section, id, key, name) when is_binary(name),
    do: [{[section, id, key], {section, id}, name}]

  defp members(section, id, key, map) when is_map(map),
    do: for({sub, name} <- map, do: {[section, id, key, sub], {section, id, sub}, name})

  # --- records and diagnostics -----------------------------------------------------

  defp record(%Applied{} = a) do
    %{
      key: a.key,
      kind: a.kind,
      transform: a.transform,
      subject: a.subject,
      target: a.target,
      finding_id: a.finding_id,
      automatic: a.automatic,
      params: a.params,
      proposal_sha256: a.proposal_sha256,
      basis_sha256: a.basis_sha256,
      rewrite_reads: rewrite_reads(a)
    }
  end

  defp rewrite_reads(%Applied{transform: :derive_reverse_relationship, proposal: p}),
    do: p |> Map.get(:rewrite_reads, []) |> Enum.sort()

  defp rewrite_reads(_a), do: []

  defp field_diag({:refine, {t, f}, a, %{to: to}}, ctx) do
    [
      Diagnostic.new(
        :ash_decision_applied,
        ctx.fields[{t, f}].path,
        "#{t}.#{f} is stored as #{to} (owner decision #{a.key}); Bubble stores a float",
        target: :ash,
        subject: %{type: t, field: f},
        details: %{key: a.key, transform: a.transform, to: to}
      )
    ]
  end

  defp field_diag({:derive, {t, f}, a, %{via: via, source: {st, sf}}}, ctx) do
    [
      Diagnostic.new(
        :ash_decision_applied,
        ctx.fields[{t, f}].path,
        "#{t}.#{f} is a calculation over #{st}.#{sf} (owner decision #{a.key}); " <>
          "it is not stored and cannot be written",
        target: :ash,
        subject: %{type: t, field: f},
        details: %{
          key: a.key,
          transform: a.transform,
          via: Enum.map(via, fn {vt, vf} -> Symbol.id(:field, [vt, vf]) end),
          source_field: Symbol.id(:field, [st, sf])
        }
      )
    ]
  end

  defp field_diag({:count, {t, f}, a, %{via: via, source: {st, sf}}}, ctx) do
    [
      Diagnostic.new(
        :ash_decision_applied,
        ctx.fields[{t, f}].path,
        "#{t}.#{f} counts #{st}.#{sf} (owner decision #{a.key}); it is not stored and " <>
          "cannot be written",
        target: :ash,
        subject: %{type: t, field: f},
        details: %{
          key: a.key,
          transform: a.transform,
          via: Enum.map(via, fn {vt, vf} -> Symbol.id(:field, [vt, vf]) end),
          source_field: Symbol.id(:field, [st, sf]),
          aggregate: Map.has_key?(ctx.reverse, {st, sf})
        }
      )
    ]
  end

  defp field_diag({:text_ref, {t, f}, a, %{target: target, cardinality: c}}, ctx) do
    what =
      if c == :one,
        do: "a belongs_to #{target} (no foreign key)",
        else: "a list of #{target} IDs"

    [
      Diagnostic.new(
        :ash_decision_applied,
        ctx.fields[{t, f}].path,
        "#{t}.#{f} holds #{target} IDs and is #{what} (owner decision #{a.key}); the loader " <>
          "must convert its text values to IDs",
        target: :ash,
        subject: %{type: t, field: f},
        details: %{key: a.key, transform: a.transform, target: target, cardinality: c}
      )
    ]
  end

  defp field_diag({:reverse, {t, f}, a, %{via: {vt, vf}}}, ctx) do
    [
      Diagnostic.new(
        :ash_decision_applied,
        ctx.fields[{t, f}].path,
        "#{t}.#{f} is a has_many of #{vt} through #{vt}.#{vf} (owner decision #{a.key}); " <>
          "the list is not stored, and its reads need rewriting",
        target: :ash,
        subject: %{type: t, field: f},
        details: %{
          key: a.key,
          transform: a.transform,
          via: Symbol.id(:field, [vt, vf]),
          rewrite_reads: rewrite_reads(a)
        }
      )
    ]
  end

  defp index_applied_diag(_a, [], _ctx), do: []

  defp index_applied_diag(a, made, ctx) do
    %{type: t} = a.subject

    [
      Diagnostic.new(
        :ash_decision_applied,
        ctx.types[t].path,
        "#{length(made)} index(es) of #{t} from #{a.key}" <>
          if(a.automatic, do: " (a hint, applied by default)", else: " (owner decision)"),
        target: :ash,
        subject: a.subject,
        details: %{
          key: a.key,
          transform: a.transform,
          automatic: a.automatic,
          indexes: Enum.map(made, &elem(&1, 0).position)
        }
      )
    ]
  end

  # One warning per decision (diagnostics are unique per subject and code).
  defp index_deferred_diag(_a, [], _ctx), do: []

  defp index_deferred_diag(a, skipped, ctx) do
    %{type: t} = a.subject

    why =
      Enum.map_join(skipped, "; ", fn {index, reason} -> "index #{index.position}: #{reason}" end)

    [
      Diagnostic.new(
        :ash_decision_deferred,
        ctx.types[t].path,
        "#{length(skipped)} index(es) of #{a.key} are not created (#{why}); deferred",
        target: :ash,
        subject: a.subject,
        details: %{
          key: a.key,
          transform: a.transform,
          indexes:
            Enum.map(skipped, fn {index, reason} ->
              %{
                index: index.position,
                access: Enum.map(index.columns, & &1.access),
                fields:
                  Enum.map(index.columns, fn %{field: {ft, ff}} -> Symbol.id(:field, [ft, ff]) end),
                reason: reason
              }
            end)
        }
      )
    ]
  end

  defp deferred_diag(a, ctx) do
    path =
      case Map.fetch(ctx.types, a.subject[:type]) do
        {:ok, type} -> type.path
        :error -> ""
      end

    Diagnostic.new(
      :ash_decision_deferred,
      path,
      "the #{a.transform} hint #{a.key} applies by default but Target.Ash does not apply " <>
        "#{a.transform} yet (#{Map.fetch!(@later, a.transform)} of WTF-352); deferred",
      target: :ash,
      subject: a.subject,
      details: %{key: a.key, transform: a.transform}
    )
  end

  defp rename_diag(a, details, path) do
    column =
      if details[:column],
        do: "; the column keeps its name #{inspect(details.column)}",
        else: ""

    Diagnostic.new(
      :ash_name_overridden,
      path,
      "the #{a.params.slot} name is #{inspect(a.params.name)} (owner decision #{a.key})" <>
        column,
      target: :ash,
      subject: a.subject,
      details: Map.merge(%{key: a.key, slot: a.params.slot, name: a.params.name}, details)
    )
  end

  # --- applying to the mapped resources --------------------------------------------

  @doc false
  # Refines number attributes; replaces derived attributes by calculations
  # (reading the related record, or counting a list), counts over a derived
  # has_many by aggregates, and reverse lists by has_many relationships;
  # then adds the indexes.
  @spec apply([Resource.t()], plan()) :: [Resource.t()]
  def apply(resources, plan) do
    resources = Enum.map(resources, &refine_resource(&1, plan.refine))
    by_type = Map.new(resources, &{&1.source.type, &1})

    resources
    |> Enum.map(&derive_resource(&1, plan, by_type))
    |> Enum.map(&index_resource(&1, Map.get(plan.indexes, &1.source.type, [])))
    |> unique_index_names()
  end

  defp refine_resource(%Resource{} = resource, refine) do
    attributes =
      Enum.map(resource.attributes, fn a ->
        case Map.fetch(refine, {resource.source.type, a.source[:field]}) do
          {:ok, %{to: to}} -> %{a | type: to, default: number_default(a.default, to)}
          :error -> a
        end
      end)

    %{resource | attributes: attributes}
  end

  defp number_default({:value, v}, :integer) when is_number(v), do: {:value, trunc(v)}

  defp number_default({:value, v}, :decimal) when is_number(v),
    do: {:value, {:decimal, v |> Kernel.*(1.0) |> Float.to_string()}}

  defp number_default(default, _to), do: default

  # Each attribute a decision derives becomes, in attribute order, a
  # calculation, an aggregate or a has_many.
  defp derive_resource(%Resource{} = resource, plan, by_type) do
    {items, kept} =
      Enum.reduce(resource.attributes, {[], []}, fn a, {items, kept} ->
        case derived_item(resource, a, plan, by_type) do
          nil -> {items, [a | kept]}
          item -> {[item | items], kept}
        end
      end)

    items = Enum.reverse(items)

    %{
      resource
      | attributes: Enum.reverse(kept),
        calculations: for(%Calculation{} = c <- items, do: c) ++ resource.calculations,
        aggregates: resource.aggregates ++ for(%Aggregate{} = g <- items, do: g),
        relationships: resource.relationships ++ for(%Relationship{} = r <- items, do: r)
    }
  end

  defp derived_item(resource, a, plan, by_type) do
    key = {resource.source.type, a.source[:field]}

    cond do
      Map.has_key?(plan.derive, key) ->
        derived_calculation(resource, a, plan.derive[key], by_type)

      Map.has_key?(plan.count, key) ->
        count(resource, a, plan.count[key], plan, by_type)

      Map.has_key?(plan.reverse, key) ->
        has_many(resource, a, plan.reverse[key], by_type)

      true ->
        nil
    end
  end

  defp derived_calculation(resource, a, d, by_type) do
    t = resource.source.type
    {path, owner} = relationship_path(d.via, by_type, t)
    {st, sf} = d.source
    ^owner = st
    source = attribute_of(by_type[st], sf)

    %Calculation{
      name: a.name,
      kind: :derived,
      type: source.type,
      constraints: source.constraints,
      public?: true,
      source: %{type: t, field: a.source.field},
      description:
        "Derived from #{Enum.join(path ++ [source.name], ".")} " <>
          "(owner decision #{d.key}); not stored",
      expr: %Expr{
        resource: resource.module,
        source: %{type: t, field: a.source.field},
        expr: {:ref, path, source.name}
      }
    }
  end

  # A count of a list derived as a has_many is an aggregate over it;
  # otherwise the length of the stored list (0 when it is empty or nil,
  # as Bubble counts).
  defp count(resource, a, d, plan, by_type) do
    t = resource.source.type
    {path, owner} = relationship_path(d.via, by_type, t)
    {st, sf} = d.source
    ^owner = st
    list = attribute_of(by_type[st], sf)
    field = %{type: t, field: a.source.field}
    what = Enum.join(path ++ [list.name], ".")

    if Map.has_key?(plan.reverse, d.source) do
      %Aggregate{
        name: a.name,
        path: path ++ [list.name],
        source: field,
        description: "The count of #{what} (owner decision #{d.key}); not stored"
      }
    else
      %Calculation{
        name: a.name,
        kind: :derived,
        type: :integer,
        public?: true,
        source: field,
        description: "The length of #{what} (owner decision #{d.key}); not stored",
        expr: %Expr{
          resource: resource.module,
          source: field,
          expr: {:call, "length", [{:op, "||", {:ref, path, list.name}, {:value, []}}]}
        }
      }
    end
  end

  # B's list of A becomes `has_many <list name>, A`, from B's primary key
  # to A's reference attribute.
  defp has_many(resource, a, %{via: {from, r}}, by_type) do
    destination = by_type[from]
    pk = Enum.find(resource.attributes, & &1.primary_key?)

    %Relationship{
      kind: :has_many,
      name: a.name,
      destination: destination.module,
      source_attribute: pk.name,
      destination_attribute: attribute_of(destination, r).name,
      source: %{type: resource.source.type, field: a.source.field}
    }
  end

  defp attribute_of(resource, field),
    do: Enum.find(resource.attributes, &(&1.source[:field] == field))

  defp relationship_path(via, by_type, from) do
    Enum.map_reduce(via, from, fn {vt, vf}, _ ->
      rel =
        Enum.find(by_type[vt].relationships, &(&1.kind == :belongs_to and &1.source.field == vf))

      target = Enum.find(Map.values(by_type), &(&1.module == rel.destination))
      {rel.name, target.source.type}
    end)
  end

  # --- indexes ---------------------------------------------------------------------

  defp index_resource(resource, []), do: resource

  defp index_resource(%Resource{} = resource, planned) do
    columns = Map.new(resource.attributes, &{&1.source[:field], &1.column || &1.name})

    indexes =
      planned
      |> Enum.map(fn index ->
        cols = Enum.map(index.fields, fn {_t, f} -> Map.fetch!(columns, f) end)
        physical(index.method, resource.table, cols, index)
      end)
      |> Enum.uniq_by(&{&1.method, &1.columns})

    %{resource | indexes: resource.indexes ++ indexes}
  end

  defp physical(:btree, table, cols, index),
    do: index_struct(index, table, cols, :btree, cols, nil, nil, "index")

  defp physical(:gin, table, cols, index),
    do: index_struct(index, table, cols, :gin, cols, "gin", nil, "gin_index")

  defp physical(:trigram, table, [col] = cols, index),
    do:
      index_struct(
        index,
        table,
        cols,
        :trigram,
        [quote_ident(col) <> " gin_trgm_ops"],
        "gin",
        nil,
        "trgm_index"
      )

  defp physical(:full_text, table, [col] = cols, index) do
    expression = "to_tsvector('simple'::regconfig, coalesce(#{quote_ident(col)}, ''))"
    index_struct(index, table, cols, :full_text, [expression], "gin", expression, "fts_index")
  end

  defp index_struct(index, table, cols, method, fields, using, expression, suffix) do
    %Index{
      name: index_name(table, cols, suffix),
      method: method,
      columns: cols,
      fields: fields,
      using: using,
      expression: expression,
      source: %{type: index.type, key: index.key, index: index.positions}
    }
  end

  # Index names are unique in a PostgreSQL schema, not per table: a name
  # two tables would share (`a_b` + `c`, `a` + `b_c`) gets a hash of its
  # table and definition.
  defp unique_index_names(resources) do
    taken =
      resources |> Enum.flat_map(& &1.indexes) |> Enum.frequencies_by(& &1.name)

    Enum.map(
      resources,
      &%{&1 | indexes: Enum.map(&1.indexes, fn i -> unshared(i, &1, taken) end)}
    )
  end

  defp unshared(index, resource, taken) do
    if taken[index.name] > 1,
      do: %{index | name: hashed_name(resource.table, index)},
      else: index
  end

  defp hashed_name(table, index) do
    seed = Enum.join([table, index.method | index.fields], "|")
    hash = :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    keep = @max_identifier - byte_size(hash) - byte_size("_index") - 2
    prefix = index.name |> binary_part(0, min(keep, byte_size(index.name))) |> valid_utf8()
    Enum.join([String.trim_trailing(prefix, "_"), hash, "index"], "_")
  end

  defp quote_ident(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""

  # `<table>_<columns>_<suffix>`, or cut with a hash of the whole name so it
  # stays unique within 63 bytes.
  defp index_name(table, cols, suffix) do
    name = Enum.join([table | cols] ++ [suffix], "_")

    if byte_size(name) <= @max_identifier do
      name
    else
      hash = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      keep = @max_identifier - byte_size(suffix) - byte_size(hash) - 2
      prefix = name |> binary_part(0, keep) |> String.trim_trailing("_") |> valid_utf8()
      Enum.join([prefix, hash, suffix], "_")
    end
  end

  # A cut in the middle of a character drops its bytes.
  defp valid_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_utf8(binary_part(binary, 0, byte_size(binary) - 1))
  end

  # --- the Model -------------------------------------------------------------------

  defp context(%Model{} = model) do
    types = for t <- model.data_types, live?(t), into: %{}, do: {t.id, t}

    fields =
      for {id, t} <- types,
          f <- t.system_fields ++ t.fields,
          live?(f),
          into: %{},
          do: {{id, f.id}, f}

    %{
      types: types,
      fields: fields,
      symbols: Map.new(fields, fn {{t, f}, _} -> {Symbol.id(:field, [t, f]), {t, f}} end),
      sets: for(s <- model.option_sets, live?(s), into: %{}, do: {s.id, s}),
      externals: Map.new(model.external_types, &{&1.id, &1}),
      derive: %{}
    }
  end

  defp live?(item), do: not Map.get(item, :deleted, false) and is_nil(Map.get(item, :raw))

  defp error(message, context), do: {:error, Error.new(:invalid_input, message, context)}
end
