defmodule BubbleEx.Target.Ash.Decisions do
  @moduledoc false

  # Owner decisions applied by `BubbleEx.Target.Ash.map/3` (WTF-352 §4, cut
  # 1). `plan/3` validates the applicable decisions against the Model and
  # the name map and returns the name map with the rename overrides, the
  # field transforms, the `project.applied` records and the diagnostics;
  # `apply/2` rewrites the mapped resources. The input contract and the
  # semantics are documented in `BubbleEx.Target.Ash` ("Decisions").

  alias BubbleEx.{Decision, Diagnostic, Error, Finding, Model}
  alias BubbleEx.Decision.Applied
  alias BubbleEx.Finding.Kinds
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Model.{ExternalType, Type}
  alias BubbleEx.Target.Ash.{Calculation, Expr, Naming, Resource}

  @supported [:refine_number_type, :derive_from_related, :rename]

  # Transforms a later cut of Target.Ash will apply (WTF-352 §4.2).
  @later %{
    derive_count: "cut 2",
    text_to_reference: "cut 2",
    derive_reverse_relationship: "cut 2",
    add_indexes: "cut 2",
    normalize_list_to_join: "cut 3",
    membership_policy: "cut 3"
  }

  @number_types [:integer, :decimal]

  # Resource name map members holding names in one attribute scope.
  @resource_scope ~w(attributes relationships privacy_rules privacy_relationships)

  # The generated `<namespace>.Privacy` module (privacy: :unverified).
  @generated_modules ~w(Privacy)

  @type plan :: %{
          names: map(),
          refine: %{{String.t(), String.t()} => map()},
          derive: %{{String.t(), String.t()} => map()},
          applied: [map()],
          diagnostics: [Diagnostic.t()]
        }

  @doc false
  @spec plan(Model.t(), list(), map()) :: {:ok, plan()} | {:error, Error.t()}
  def plan(%Model{} = model, decisions, names) when is_list(decisions) do
    ctx = context(model)

    with :ok <- all_applied(decisions),
         :ok <- unique_keys(decisions),
         decisions = Enum.sort_by(decisions, & &1.key),
         {:ok, checked} <- collect(decisions, &check(&1, ctx)),
         :ok <- one_per_field(checked),
         fields =
           for({op, a, subject, data} <- checked, op != :rename, do: {op, subject, a, data}),
         refine =
           for({:refine, s, a, data} <- fields, into: %{}, do: {s, Map.put(data, :key, a.key)}),
         derive =
           for({:derive, s, a, data} <- fields, into: %{}, do: {s, Map.put(data, :key, a.key)}),
         :ok <- stored_sources(derive),
         ctx = Map.put(ctx, :derive, derive),
         {:ok, names, rename_diags} <- renames(checked, names, ctx) do
      {:ok,
       %{
         names: names,
         refine: refine,
         derive: derive,
         applied: Enum.map(decisions, &record/1),
         diagnostics: Enum.flat_map(fields, &field_diag(&1, ctx)) ++ rename_diags
       }}
    end
  end

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
    with :ok <- supported(a),
         :ok <- finding_identity(a),
         :ok <- fresh(a),
         {:ok, subject, field} <- subject_field(a, ctx),
         :ok <- proposal_field(a, subject) do
      transform(a, subject, field, ctx)
    end
  end

  defp check(%Applied{kind: :rename} = a, _ctx) do
    with :ok <- supported(a),
         :ok <- rename_identity(a),
         do: {:ok, {:rename, a, a.subject, a.params}}
  end

  defp check(%Applied{} = a, _ctx),
    do: error("unknown applied decision kind", %{key: a.key, kind: inspect(a.kind)})

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
    if a.basis == nil and a.decision_id == nil and hash?(a.proposal_sha256),
      do: :ok,
      else: error("an automatic entry is a hint nobody decided", %{key: a.key})
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
    if a.proposal[:field] == Symbol.id(:field, [t, f]),
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

  # A field takes one finding transform.
  defp one_per_field(checked) do
    checked
    |> Enum.filter(&(elem(&1, 0) != :rename))
    |> Enum.frequencies_by(&elem(&1, 2))
    |> Enum.find(fn {_, n} -> n > 1 end)
    |> case do
      nil -> :ok
      {{t, f}, _} -> error("two decisions transform one field", %{subject: %{type: t, field: f}})
    end
  end

  # A calculation reads stored values: a derived field's source is not
  # derived itself.
  defp stored_sources(derive) do
    case Enum.find(derive, fn {_, d} -> Map.has_key?(derive, d.source) end) do
      nil ->
        :ok

      {{t, f}, d} ->
        error("a derived field's source is derived too", %{
          key: d.key,
          subject: %{type: t, field: f}
        })
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
         :ok <- reference(field, ctx),
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
           Map.has_key?(ctx.derive, {t, f}) ||
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
    if Map.has_key?(ctx.derive, subject),
      do: {:error, "the field is derived by a decision: rename its calculation", %{}},
      else: :ok
  end

  defp reference(field, ctx) do
    case field.type do
      %Type{kind: :ref, cardinality: :one, target: target} when is_map_key(ctx.types, target) ->
        :ok

      _ ->
        {:error, "a relationship rename needs a reference to a mapped data type", %{}}
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

  # --- records and diagnostics -----------------------------------------------------

  defp record(%Applied{} = a) do
    %{
      key: a.key,
      kind: a.kind,
      transform: a.transform,
      subject: a.subject,
      target: a.target,
      decision_id: a.decision_id,
      finding_id: a.finding_id,
      automatic: a.automatic,
      params: a.params,
      proposal_sha256: a.proposal_sha256,
      basis_sha256: a.basis_sha256
    }
  end

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
  # Refines number attributes, then replaces derived attributes by
  # calculations reading the related record.
  @spec apply([Resource.t()], plan()) :: [Resource.t()]
  def apply(resources, %{refine: refine, derive: derive}) do
    resources = Enum.map(resources, &refine_resource(&1, refine))
    by_type = Map.new(resources, &{&1.source.type, &1})
    Enum.map(resources, &derive_resource(&1, derive, by_type))
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

  defp derive_resource(%Resource{} = resource, derive, by_type) do
    t = resource.source.type

    {derived, kept} =
      Enum.split_with(resource.attributes, &Map.has_key?(derive, {t, &1.source[:field]}))

    calculations =
      Enum.map(derived, fn a ->
        d = Map.fetch!(derive, {t, a.source.field})
        {path, owner} = relationship_path(d.via, by_type)
        {st, sf} = d.source
        ^owner = st
        source = Enum.find(by_type[st].attributes, &(&1.source[:field] == sf))

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
      end)

    %{resource | attributes: kept, calculations: calculations ++ resource.calculations}
  end

  defp relationship_path(via, by_type) do
    Enum.map_reduce(via, nil, fn {vt, vf}, _ ->
      rel = Enum.find(by_type[vt].relationships, &(&1.source.field == vf))
      target = Enum.find(Map.values(by_type), &(&1.module == rel.destination))
      {rel.name, target.source.type}
    end)
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
