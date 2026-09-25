defmodule BubbleEx.Index do
  @moduledoc """
  A deterministic symbol and reference index over decoded Bubble app JSON.

      {:ok, index} = BubbleEx.Index.build(app)

      field = BubbleEx.Index.Symbol.id(:field, ["task", "title_text"])
      BubbleEx.Index.writers(index, field)                    # actions writing it
      BubbleEx.Index.readers(index, field)                    # expressions reading it
      BubbleEx.Index.privacy_rules_referencing(index, field)
      BubbleEx.Index.dependents(index, "data_type:task")
      BubbleEx.Index.callers(index, "workflow:bAbC")
      BubbleEx.Index.cycles(index)

  The index is a disposable derived cache: rebuild it from the app JSON
  whenever the app changes. Data types, fields, option sets, API Connector
  groups and calls and privacy rules are read through `BubbleEx.Model`; pass a
  Model already built from the same app as `model:` to build it only once.
  It is keyed purely by stable Bubble IDs (see
  `BubbleEx.Index.Symbol`), never by display names, and it is stack-neutral:
  it states what the Bubble app references, not how any target stack should
  represent it.

  Input is a decoded `.bubble` export (readable keys). Compact live-payload
  keys are read where the live payload carries the data (data types, pages,
  elements, workflows); privacy rules and API Connector settings exist only in
  exports. The index covers the supplied data only.

  ## Symbols

  Data types, fields, option sets, option values, option set attributes,
  pages (and mobile views), reusable elements, elements, workflows (frontend
  and backend), actions, API Connector groups and calls, and privacy rules.

  Every data type also has Bubble's built-in fields as field symbols
  (`_id` - unique id, `Created By`, `Created Date`, `Modified Date`, `Slug`,
  and `email` on User), with `attrs.builtin` naming them, so reads of them are
  ordinary `:reads_field` references.

  Workflow symbols carry, in `attrs`:

    * `event_type`, `backend` (defined in the backend `api` collection) and
      `public` (a backend workflow exposed as a public API endpoint)
    * `ignore_privacy_rules` - a backend workflow's own setting, as supplied;
      `runs_ignoring_privacy_rules: true` when it effectively runs ignoring
      privacy rules (see below)
    * `execution_class` - where the workflow's actions run, including the
      custom events it triggers: `:client_only`, `:server_backed` or
      `:mixed`. Backend workflows are always `:server_backed`. Plugin and
      unknown actions are unclassified and counted in `unclassified_actions`;
      a frontend workflow whose actions (including those of the custom events
      it triggers) are all unclassified is `:unknown`.
    * `invocation_modes` - how the workflow can start: `:direct` (triggered
      by another workflow), `:scheduled` (scheduled by another workflow, alone
      or on a list), `:public_http` (public API endpoint), `:recurring`
      (recurring schedule or `DoInterval` timer), `:event` (any page, element
      or plugin event: clicks, page load, input changes, a condition becoming
      true, log in/out, plugin events, …) and `:database_trigger`. An empty
      list means nothing in the supplied data invokes it.

  Recurring schedule actions are recognized by an explicit list of action
  types that no available export contains yet; treat `:recurring` calls as
  unverified until confirmed against one.

  ## References

  | kind              | from                          | to                         | attrs |
  |-------------------|-------------------------------|----------------------------|-------|
  | `:field_type`     | field / option attribute      | data type, option set, API call | `list`, `response_path` |
  | `:reads_field`    | any expression host           | field                      | `via`: `:expression`, `:constraint`, `:sort` |
  | `:reads_type`     | any expression host           | data type (searched)       | |
  | `:reads_option`   | any expression host           | option value / option set  | |
  | `:reads_element`  | any expression host           | element / page / reusable whose value it reads | |
  | `:writes_type`    | action                        | data type                  | `operation`: `:insert`, `:update`, `:delete`; `target: :inferred` |
  | `:writes_field`   | action                        | field                      | `operation`, `change` (`"set"`, `"add"`, `"remove"`, …); `target: :inferred` |
  | `:grants_view`    | privacy rule                  | field it lets users view   | |
  | `:grants_binding` | privacy rule                  | field it lets users auto-bind | |
  | `:calls_workflow` | action                        | workflow                   | `call`: `:direct`, `:scheduled`, `:list_scheduled`, `:recurring` |
  | `:calls_api`      | action / expression host      | API call                   | `via`: `:action`, `:data_source` |
  | `:listens_to`     | workflow                      | element / page / reusable / data type (database trigger) | |
  | `:targets_element`| action                        | element / page / reusable  | |
  | `:instance_of`    | element                       | reusable element           | |

  Expression hosts are pages, reusables, elements, workflows (their event and
  conditions), actions and privacy rules (their conditions).

  ## Privacy context

  A backend workflow whose own `ignore_privacy_rules` is true runs ignoring
  privacy rules, and so does a custom event triggered or scheduled from a
  workflow that does. Every reference made inside such a workflow (its event
  and actions) carries `ignore_privacy_rules: true`. A schedule action's own
  setting stays on the action symbol; its `:calls_workflow` edge records
  both `action_ignore_privacy_rules` (the action's setting, when supplied)
  and `callee_ignore_privacy_rules` (whether the callee runs ignoring privacy
  rules), because they can disagree. The action's parameter expressions are
  evaluated in the caller's context and are not flagged by the action's
  setting.

  ## Data write targets

  A data action's target type comes from its type setting, or from the typed
  expression of the thing it changes or deletes. The result of an earlier
  step (`Result of step N`) has that step's type when the step creates,
  copies or changes records. When the type is still unknown (element data,
  …) but exactly one data type that is not deleted has every changed field
  (deleted fields excluded), that type is the target and the edges carry
  `target: :inferred`. Otherwise the action gets an `:index_unresolved_reference`
  diagnostic and no write edges.

  In database-trigger workflows, `This Thing` sources without a type
  (`CurrentDataItem`, `OldDataItem`) are read as the trigger's data type.

  ## Determinism and hashes

  Symbols are sorted by ID and references by `(from, kind, to, path, attrs)`,
  so the same input always gives byte-identical `to_json/1`.

    * `source_sha256` - canonical-JSON hash of the input (as in the workflow
      inventory). Any change to the supplied JSON changes it, including data
      the index does not cover.
    * `content_sha256` - canonical-JSON hash of the whole `to_map/1` (minus
      the two index hashes). It includes `source_sha256`, source paths and
      diagnostics, so it identifies this exact index of this exact input.
    * `semantic_sha256` - hash of the reference graph only: symbols and
      references without source paths, and cycles. It is unchanged when
      definitions only move within the JSON (e.g. a collection supplied in
      another order or key form) or when data outside the index changes, and
      is what to compare to decide whether dependents need re-analysis.

  `schema_version` changes whenever the output format does.

  ## Diagnostics

  `diagnostics` are `BubbleEx.Diagnostic`s (stage `:model`) about the index
  itself, normalized: `:index_unresolved_reference` (a reference to a symbol
  absent from the supplied data, or a data action whose target type cannot
  be resolved) and `:index_duplicate_symbol` (two definitions with the same
  Bubble ID; the first by source path is kept, and references by that Bubble
  ID resolve to it). Their `subject` holds the Bubble IDs involved (for a
  reference, its source's plus its target's) and `details` the symbol IDs. Expression parse diagnostics stay with
  `BubbleEx.Expression`.
  """

  alias BubbleEx.{CanonicalJson, Diagnostic, Error, Model}

  alias BubbleEx.Index.{
    DataModel,
    Graph,
    PrivacyRules,
    Reads,
    Reference,
    Structure,
    Subject,
    Symbol
  }

  @schema_version 1

  @enforce_keys [:schema_version, :source_sha256, :content_sha256, :symbols, :references]
  defstruct [
    :schema_version,
    :source_sha256,
    :content_sha256,
    :semantic_sha256,
    :model,
    symbols: [],
    references: [],
    cycles: [],
    diagnostics: [],
    lookup: %{}
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          source_sha256: String.t(),
          content_sha256: String.t(),
          semantic_sha256: String.t() | nil,
          model: Model.t() | nil,
          symbols: [Symbol.t()],
          references: [Reference.t()],
          cycles: [cycle()],
          diagnostics: [Diagnostic.t()],
          lookup: map()
        }

  @type cycle :: %{
          workflows: [Symbol.id()],
          calls: [%{from: Symbol.id(), to: Symbol.id(), action: Symbol.id(), call: atom()}],
          call_kinds: [atom()],
          synchronous: boolean()
        }

  @type call :: %{workflow: Symbol.id(), action: Symbol.id(), call: atom(), attrs: map()}

  @doc "The index format version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Builds the index from decoded app JSON.

  ## Options

    * `:model` - a `BubbleEx.Model` already built from the same app (checked
      with `BubbleEx.Model.matches?/3` against the app's canonical hash, which
      the index computes once anyway; otherwise `:invalid_input`). Without
      it the Model is built here. Either way the index keeps it in `model`
      (not part of `to_map/1`), so `BubbleEx.Findings` reuses it.
  """
  @spec build(term(), [{:model, Model.t()}]) :: {:ok, t()} | {:error, Error.t()}
  def build(app, opts \\ []) do
    with {:ok, inventory, model} <-
           BubbleEx.Workflows.inventory_and_model(app, model: Keyword.get(opts, :model)) do
      structure = Structure.build(app)

      {model_symbols, model_refs} = DataModel.build(model)

      ctx = %{
        schema: Model.schema(model),
        owners: structure.owners,
        bubble_ids: structure.bubble_ids,
        live_fields: live_fields(model_symbols),
        attrs: %{}
      }

      host_refs = Enum.flat_map(structure.hosts, &Reads.scan(&1.value, &1.path, &1.symbol, ctx))
      {wf_symbols, wf_refs, wf_diags} = BubbleEx.Index.Workflows.build(inventory, ctx)
      {rule_symbols, rule_refs} = PrivacyRules.build(model, ctx)

      index =
        assemble(
          inventory.source_sha256,
          model_symbols ++ structure.symbols ++ wf_symbols ++ rule_symbols,
          model_refs ++ structure.references ++ host_refs ++ wf_refs ++ rule_refs,
          structure.diagnostics ++ wf_diags
        )

      {:ok, %{index | model: model}}
    end
  end

  # Fields of data types that are not deleted, excluding deleted fields.
  defp live_fields(model_symbols) do
    deleted =
      for %{kind: :data_type, attrs: %{deleted: true}} = s <- model_symbols,
          into: MapSet.new(),
          do: s.id

    for %{kind: :field, parent: "data_type:" <> type = parent} = f <- model_symbols,
        not MapSet.member?(deleted, parent),
        not Map.get(f.attrs, :deleted, false),
        reduce: %{} do
      acc -> Map.update(acc, type, MapSet.new([f.bubble_id]), &MapSet.put(&1, f.bubble_id))
    end
  end

  defp assemble(source_sha256, symbols, refs, diags) do
    {symbols, dup_diags} = unique_symbols(symbols)
    by_id = Map.new(symbols, &{&1.id, &1})
    refs = refs |> Enum.uniq() |> Enum.sort_by(&Reference.sort_key/1)

    workflow_of = &workflow_of(&1, by_id)

    # One diagnostic per identity (path and subject); every dangling
    # reference it stands for is listed in `details.references`.
    dangling =
      refs
      |> Enum.reject(&Map.has_key?(by_id, &1.to))
      |> Enum.group_by(&{&1.path, Subject.of_reference(&1.from, &1.to, workflow_of)})
      |> Enum.sort()
      |> Enum.map(fn {{path, subject}, group} ->
        Diagnostic.new(
          :index_unresolved_reference,
          path,
          Enum.map_join(group, "; ", &"#{&1.kind} reference to #{&1.to}") <>
            ", not in the supplied data",
          subject: subject,
          details: %{
            references: Enum.map(group, &%{reference: &1.kind, from: &1.from, to: &1.to})
          }
        )
      end)

    diagnostics = Diagnostic.normalize(dup_diags ++ diags ++ dangling)

    index = %__MODULE__{
      schema_version: @schema_version,
      source_sha256: source_sha256,
      content_sha256: "",
      symbols: symbols,
      references: refs,
      cycles: find_cycles(symbols, refs, by_id),
      diagnostics: diagnostics
    }

    hash =
      index |> to_map() |> Map.drop([:content_sha256, :semantic_sha256]) |> CanonicalJson.sha256()

    %{
      index
      | content_sha256: hash,
        semantic_sha256: semantic_sha256(index),
        lookup: lookup(symbols, refs, by_id)
    }
  end

  # The reference graph only: symbols and references without source paths,
  # and cycles. Unchanged by edits that only move definitions in the JSON
  # (e.g. collection order) or touch data the index does not cover.
  defp semantic_sha256(index) do
    %{
      schema_version: index.schema_version,
      symbols: Enum.map(index.symbols, &(&1 |> Map.from_struct() |> Map.delete(:path))),
      references:
        index.references
        |> Enum.sort_by(&{&1.from, &1.kind, &1.to, &1.attrs |> Enum.sort() |> inspect()})
        |> Enum.map(&(&1 |> Map.from_struct() |> Map.delete(:path))),
      cycles: index.cycles
    }
    |> CanonicalJson.sha256()
  end

  defp unique_symbols(symbols) do
    symbols
    |> Enum.sort_by(&{&1.id, &1.path})
    |> Enum.chunk_by(& &1.id)
    |> Enum.map_reduce([], fn [kept | dups], diags ->
      more =
        for d <- dups,
            do:
              Diagnostic.new(
                :index_duplicate_symbol,
                d.path,
                "#{d.id} is also defined at #{kept.path}; that definition is indexed",
                subject: Subject.of(d.id),
                details: %{symbol: d.id, indexed_path: kept.path}
              )

      {kept, diags ++ more}
    end)
  end

  # Workflow-to-workflow calls: `%{from, to, action, call}`.
  defp workflow_calls(symbols, refs, by_id) do
    workflows = for %{kind: :workflow} = s <- symbols, into: MapSet.new(), do: s.id

    for %{kind: :calls_workflow, from: action, to: to, attrs: attrs} <- refs,
        %{parent: caller} <- [by_id[action]],
        MapSet.member?(workflows, caller),
        do: %{from: caller, to: to, action: action, call: attrs.call}
  end

  defp find_cycles(symbols, refs, by_id) do
    calls = workflow_calls(symbols, refs, by_id)
    base = for %{kind: :workflow} = s <- symbols, into: %{}, do: {s.id, []}

    graph =
      Enum.reduce(calls, base, &Map.update(&2, &1.from, [&1.to], fn tos -> [&1.to | tos] end))

    for members <- Graph.cycles(graph) do
      set = MapSet.new(members)

      edges =
        calls
        |> Enum.filter(&(MapSet.member?(set, &1.from) and MapSet.member?(set, &1.to)))
        |> Enum.sort_by(&{&1.from, &1.to, &1.action, &1.call})

      direct =
        Enum.reduce(edges, %{}, fn
          %{call: :direct} = e, g -> Map.update(g, e.from, [e.to], &[e.to | &1])
          _, g -> g
        end)

      %{
        workflows: members,
        calls: edges,
        call_kinds: edges |> Enum.map(& &1.call) |> Enum.uniq() |> Enum.sort(),
        synchronous: Graph.cycles(direct) != []
      }
    end
  end

  defp lookup(symbols, refs, by_id) do
    %{
      symbols: by_id,
      from: Enum.group_by(refs, & &1.from),
      to: Enum.group_by(refs, & &1.to),
      children: symbols |> Enum.filter(& &1.parent) |> Enum.group_by(& &1.parent, & &1.id)
    }
  end

  # The Bubble ID of an action's workflow, for diagnostic subjects.
  defp workflow_of(id, by_id) do
    with %{parent: parent} when is_binary(parent) <- by_id[id],
         %{kind: :workflow, bubble_id: workflow} <- by_id[parent] do
      workflow
    else
      _ -> nil
    end
  end

  # --- serialization --------------------------------------------------------

  @doc "Plain-map form (no lookup tables), suitable for JSON."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = index) do
    %{
      schema_version: index.schema_version,
      source_sha256: index.source_sha256,
      content_sha256: index.content_sha256,
      semantic_sha256: index.semantic_sha256,
      symbols: Enum.map(index.symbols, &Map.from_struct/1),
      references: Enum.map(index.references, &Map.from_struct/1),
      cycles: index.cycles,
      diagnostics: Enum.map(index.diagnostics, &Diagnostic.to_map/1)
    }
  end

  @doc "Canonical JSON (sorted keys) of `to_map/1`."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = index), do: index |> to_map() |> CanonicalJson.encode()

  @doc "Counts of symbols and references by kind, cycles and diagnostics."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = index) do
    %{
      symbols: Enum.frequencies_by(index.symbols, & &1.kind),
      references: Enum.frequencies_by(index.references, & &1.kind),
      cycles: length(index.cycles),
      diagnostics: Enum.frequencies_by(index.diagnostics, & &1.code)
    }
  end

  # --- queries --------------------------------------------------------------

  @doc "The symbol with `id`, or nil."
  @spec symbol(t(), Symbol.id()) :: Symbol.t() | nil
  def symbol(%__MODULE__{lookup: lookup}, id), do: Map.get(lookup.symbols, id)

  @doc "All symbols of `kind`, sorted by ID."
  @spec symbols(t(), Symbol.kind()) :: [Symbol.t()]
  def symbols(%__MODULE__{symbols: symbols}, kind), do: Enum.filter(symbols, &(&1.kind == kind))

  @doc "Symbols whose `parent` is `id` (fields of a type, actions of a workflow, …)."
  @spec children(t(), Symbol.id()) :: [Symbol.t()]
  def children(%__MODULE__{lookup: lookup} = index, id),
    do: lookup.children |> Map.get(id, []) |> Enum.map(&symbol(index, &1))

  @doc "The nearest enclosing symbol of `kind` (e.g. the workflow of an action), or nil."
  @spec ancestor(t(), Symbol.id(), Symbol.kind()) :: Symbol.t() | nil
  def ancestor(index, id, kind) do
    case symbol(index, id) do
      nil -> nil
      %{parent: nil} -> nil
      %{parent: parent} -> ancestor_or_self(index, parent, kind)
    end
  end

  defp ancestor_or_self(index, id, kind) do
    case symbol(index, id) do
      %{kind: ^kind} = s -> s
      _ -> ancestor(index, id, kind)
    end
  end

  @doc "References made by `id`, optionally only of the given kinds."
  @spec references_from(t(), Symbol.id(), [Reference.kind()] | nil) :: [Reference.t()]
  def references_from(%__MODULE__{lookup: lookup}, id, kinds \\ nil),
    do: lookup.from |> Map.get(id, []) |> only(kinds)

  @doc "References to `id`, optionally only of the given kinds."
  @spec references_to(t(), Symbol.id(), [Reference.kind()] | nil) :: [Reference.t()]
  def references_to(%__MODULE__{lookup: lookup}, id, kinds \\ nil),
    do: lookup.to |> Map.get(id, []) |> only(kinds)

  defp only(refs, nil), do: refs
  defp only(refs, kinds), do: Enum.filter(refs, &(&1.kind in kinds))

  @doc "Expressions reading field `field_id` (`:reads_field` references to it)."
  @spec readers(t(), Symbol.id()) :: [Reference.t()]
  def readers(index, field_id), do: references_to(index, field_id, [:reads_field])

  @doc """
  Actions writing field `field_id` (`:writes_field` references to it). Use
  `ancestor(index, ref.from, :workflow)` for the workflow.
  """
  @spec writers(t(), Symbol.id()) :: [Reference.t()]
  def writers(index, field_id), do: references_to(index, field_id, [:writes_field])

  @doc "References from privacy rules to field `field_id` (condition reads and grants)."
  @spec privacy_rules_referencing(t(), Symbol.id()) :: [Reference.t()]
  def privacy_rules_referencing(index, field_id) do
    index
    |> references_to(field_id)
    |> Enum.filter(&match?(%{kind: :privacy_rule}, symbol(index, &1.from)))
  end

  @doc """
  Everything that depends on data type `type_id`: references to the type
  itself and to any of its fields.
  """
  @spec dependents(t(), Symbol.id()) :: [Reference.t()]
  def dependents(index, type_id) do
    fields = index |> children(type_id) |> Enum.filter(&(&1.kind == :field)) |> Enum.map(& &1.id)

    [type_id | fields]
    |> Enum.flat_map(&references_to(index, &1))
    |> Enum.sort_by(&Reference.sort_key/1)
  end

  @doc "Data writes (`:writes_type` and `:writes_field`) of the actions of workflow `workflow_id`."
  @spec workflow_writes(t(), Symbol.id()) :: [Reference.t()]
  def workflow_writes(index, workflow_id) do
    index
    |> children(workflow_id)
    |> Enum.flat_map(&references_from(index, &1.id, [:writes_type, :writes_field]))
  end

  @doc "Workflows calling `workflow_id`, with the calling action and call kind."
  @spec callers(t(), Symbol.id()) :: [call()]
  def callers(index, workflow_id) do
    index
    |> references_to(workflow_id, [:calls_workflow])
    |> Enum.map(fn r ->
      %{
        workflow: symbol(index, r.from).parent,
        action: r.from,
        call: r.attrs.call,
        attrs: r.attrs
      }
    end)
  end

  @doc "Workflows called by `workflow_id`, with the calling action and call kind."
  @spec callees(t(), Symbol.id()) :: [call()]
  def callees(index, workflow_id) do
    index
    |> children(workflow_id)
    |> Enum.flat_map(&references_from(index, &1.id, [:calls_workflow]))
    |> Enum.map(&%{workflow: &1.to, action: &1.from, call: &1.attrs.call, attrs: &1.attrs})
  end

  @doc """
  Workflow call cycles: strongly connected components (Tarjan) of the call
  graph with more than one workflow, or a workflow calling itself.

  Each cycle lists its `workflows`, the `calls` between them (caller,
  callee, calling action and call kind), their `call_kinds`, and whether
  `synchronous` is true: a loop made only of `:direct` calls exists, which
  would run without end. A cycle through scheduled calls is ordinary Bubble
  recursion (e.g. a backend workflow that schedules itself for the next
  item). Cycles are sorted.
  """
  @spec cycles(t()) :: [cycle()]
  def cycles(%__MODULE__{cycles: cycles}), do: cycles
end
