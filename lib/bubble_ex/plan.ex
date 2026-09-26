defmodule BubbleEx.Plan do
  @moduledoc """
  A stack-neutral migration task graph (WTF-366): what has to happen to move
  a Bubble app to another stack, derived from the `BubbleEx.Model`, the
  `BubbleEx.Index`, the normalized frontend (`BubbleEx.Frontend.normalize/2`)
  and the owner's decisions (`BubbleEx.Decision.applicable/2`).

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, index} = BubbleEx.Index.build(app, model: model)
      {:ok, frontend} = BubbleEx.Frontend.normalize(app)
      {:ok, expressions} = BubbleEx.Plan.Residue.expressions(app, model, index)
      residue = expressions ++ BubbleEx.Plan.Residue.styles(app)

      {:ok, plan} = BubbleEx.Plan.build(model, index, frontend, applied, residue: residue)
      File.write!(".wtf/plan.json", BubbleEx.Plan.to_json(plan))

  The generator runs first and is not a task: its output groups appear as
  `generate` nodes that close by themselves. Everything else is one task per
  surface (page or reusable) and per backend folder, with workflows as
  subtasks that close automatically when nothing in them is residue
  (`BubbleEx.Plan.Residue`); a workflow call cycle is one task (WTF-359 Q2).
  The plan names no target stack: a target adapter binds its abstract
  criteria (`BubbleEx.Plan.Criteria`) to commands and its tasks to files.

  ## Task kinds

  | kind | one per | actor | status |
  |------|---------|-------|--------|
  | `:generate` | generator output group: `schema`, `option_sets`, `policies`, `styles`, `api_clients`, `routes`, `surfaces`, `workflow_entry_points` | generator | auto |
  | `:remove_writes`, `:delete_workflows` | applied finding (accepted, or a hint applied by default) that removes writes or workflows | generator | closed by the decision |
  | `:setup_secrets` | app, when an API Connector value is private | owner | open |
  | `:auth` | app; subjects are the log-in, sign-up and credential workflows | agent | open |
  | `:styles_residue` | app, when a named style is residue | agent | open |
  | `:decision` | plugin used by kept code with no applicable owner decision (`decision:plugin/<id>`) | owner | open |
  | `:plugin` | plugin used by a kept element, action or event; subjects are the plugin symbol and its uses | agent (generator when dropped) | open (closed by a `drop` decision) |
  | `:surface` | page (mobile views excluded) or reusable | agent | auto unless it or a subtask has residue |
  | `:fragment` | top-level container of a surface with more than `fragment_threshold` elements | agent | as surface |
  | `:workflow` (subtask) | workflow; parent is its surface, backend folder or cycle | agent | auto unless residue |
  | `:backend` | backend workflow folder (`backend:unfiled` for workflows in none) | agent | as surface |
  | `:cycle` | workflow call cycle with more than one member (`Index.cycles/1`), or reusables containing each other | agent | as surface |
  | `:api_group` / `:api_call` (subtask) | API Connector group / call used by kept code | agent | as surface / auto unless residue |
  | `:acceptance` | page or reusable | reviewer (not the implementer) | open |
  | `:data` | `data:dry_run`, `data:full_load` | loader | open |
  | `:replay` | `replay:app` | harness | open |
  | `:delivery` | `delivery:staging`, `delivery:callers` (when workflows are public), `delivery:production` | agent / owner | open |
  | `:cutover` | ladder step: `rehearsal`, `runbook`, `communications`, `freeze`, `final_delta`, `switch`, `verify`, `sign_off` | owner | open |

  ## Plugins

  Each plugin has a `:plugin` finding (WTF-376) that the owner decides
  (`BubbleEx.Decision`, `replace_plugin` with the chosen `option`); nothing
  is guessed while it is undecided:

    * undecided (no applicable decision: none recorded, or stale; plugin
      findings cannot be rejected or acknowledged) - the plugin task
      depends on a `decision:plugin/<id>` task for the owner, so the plugin
      and every surface, fragment and workflow using it wait for the
      decision
    * `replace_native` or `rebuild` - the plugin task is open (its
      criteria cite the decision) and its users wait for it
    * `drop` - the plugin goes, not the logic around it: its elements are
      no residue (they render nothing) and its actions are dropped like
      `remove_calls`. A workflow one of its events triggers is removed only
      when the plugin's actions are all it runs, or when the decision lists
      it in `delete_workflows`; otherwise it keeps its body with
      `:trigger_dropped` residue (an agent gives it a new trigger). Every
      symbol reading a dropped element's states, a dropped action's result
      (`Result of step N`) or naming a dropped plugin data type gets
      `:reads_dropped_plugin` residue, so its task stays open. The plugin
      task is closed by the decision (`closed_by`, actor `generator`), its
      subjects list everything the drop removed, and tasks that lost a use
      or must rewrite one have a `:decision` edge to it; no `:plugin` edge
      remains

  A plugin decision is part of the `decisions` and `decisions_sha256` of
  every task covering the plugin, one of its uses or a read of one, so deciding (or
  changing the decision) changes those tasks' `source_sha256`.

  A workflow that calls itself stays in its owner's task. Workflows removed
  by an accepted `delete_workflows` get no subtask, and actions an accepted
  decision drops (`remove_calls`, or every field write in `remove_writes`)
  are neither steps nor residue.

  ## Dependencies

  `depends_on` edges are typed (`kind`) and name the symbols that justify
  them (`via`):

    * `:generate` - generator groups in order (option sets, schema,
      policies, API clients, routes, styles, then surfaces and workflow
      entry points); every task on its group
    * `:early` - surfaces, fragments, backend folders and cycles on `auth`
      and `styles:residue`
    * `:secrets` - an API group with a private value on `setup:secrets`
    * `:decision` - a workflow on the decision node removing its actions;
      a plugin task on its plugin's `decision:plugin/<id>` task; a task that
      lost a use to a plugin `drop` on the closed plugin task
    * `:reusable` - a host surface (or fragment) on the surface and
      acceptance of every reusable it instances
    * `:fragment` - a surface on its fragments
    * `:acceptance` - acceptance on its surface, fragments, the cycles
      holding its workflows and the acceptance of the reusables it uses
    * `:plugin` - a surface, fragment or workflow on the plugins it uses
    * `:api` - a workflow or surface on the API group it calls
    * `:calls` - a workflow on the workflows it triggers or schedules
      (callees first)
    * `:coordinate` - non-blocking: a call edge that would close a cycle
      between top-level tasks (see below)
    * `:release` - data dry run, full load, replay (after every acceptance
      and implementation task), delivery and the cutover ladder, in a chain

  A subtask is done with its parent, so cycles are checked between
  top-level tasks. Candidate edges are added by rule priority: `generate`,
  `release`, `early` and `secrets`, `decision`, `reusable` and
  `acceptance`, `fragment`, `plugin`, `api`, then `calls` last. An edge
  that would close a cycle with those already added (on mm-137, only
  `calls` edges between backend folders that call each other both ways) is
  kept as a non-blocking `:coordinate` edge instead: ordering ignores it,
  the calling task's `unit_test` criterion lists the callee in
  `rerun_after`, and `skipped` reports it (`reason: :would_cycle`). Tasks
  are ordered topologically, preferring the batch just started, then by
  kind, then by ID; subtasks follow their parent.

  ## Semantic hashes

  A task's `source_sha256` hashes its subgraph: every symbol it covers
  (its subjects and their descendants), its residue, its
  `decisions_sha256` and, for style tasks, the normalized named styles.
  Each covered symbol contributes its digest, which is in `symbols` as
  `%{parent, sha256}` (128 bits, hex):

    * its own content: `BubbleEx.Index.subject_sha256/2` (kind, Bubble ID,
      parent and attributes, without source path, display name or position
      among its siblings) and its `BubbleEx.Plan.Content` digest, passed as
      `content:` (keyed digests of the raw text of its expressions,
      conditions and settings, field defaults, option values and API call
      definitions, without captions, editor state and canvas positions)
    * every reference it makes (kind, target, attributes) with the own
      content of the target, so a field whose type changes or a workflow
      whose parameters change changes the tasks that use them

  So renaming an element or moving it on the canvas changes nothing;
  editing its dynamic text, a condition, its named style, a field default,
  an option value or an API call changes every task covering it. Without
  `content:` only what the index records is compared (raw expression text
  is not). Every task also hashes how content was digested (algorithm and
  key ID): a plan built with another key, or none, differs in every task.

  ## Re-verification

  `diff/2` compares two plans of the same app (`BubbleEx.Plan.Diff`): each
  task is `:unchanged`, `:changed` (its `source_sha256` differs), `:added`
  or `:removed`. A changed task needs re-verifying, and so does, along
  `depends_on` edges of every kind but `:generate` and `:early` (both only
  order work; including non-blocking
  `:coordinate` ones, whose `rerun_after` names the callee), every task
  depending on a changed, added or removed one, transitively, and the
  parent of a subtask that needs it. It only reports: owned code is never
  touched (WTF-359 Q1). Each changed task carries a stack-neutral diff of
  its covered symbols (added, removed, changed, by symbol ID).

  ## JSON

  `to_json/1` is canonical JSON (`schema_version` 3), the
  `.wtf/plan.json` of the owner's project: the same inputs give the same
  bytes. Task IDs and `source_sha256` depend only on Bubble IDs and content,
  not on JSON order, source paths or display names. `coverage` holds
  aggregate counts (generated vs residue per unit and task kind); it names
  nothing. `symbols` holds symbol IDs and hashes only.
  """

  alias BubbleEx.{CanonicalJson, Error, Index, Model}
  alias BubbleEx.Decision.{Applied, Resolved}
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Plan.{Builder, Content, Diff, Residue, Task}

  @schema_version 3
  @fragment_threshold 150

  @enforce_keys [:schema_version, :inputs, :tasks]
  defstruct [
    :schema_version,
    :inputs,
    :plan_sha256,
    tasks: [],
    skipped: [],
    coverage: %{},
    symbols: %{}
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          inputs: map(),
          plan_sha256: String.t() | nil,
          tasks: [Task.t()],
          skipped: [map()],
          coverage: map(),
          symbols: %{String.t() => %{parent: String.t() | nil, sha256: String.t()}}
        }

  @doc "The plan JSON format version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Builds the plan.

    * `frontend` - a `BubbleEx.Frontend.Normalized` of the same app, or nil
      (element placeholders are then not residue)
    * `applied` - `BubbleEx.Decision.Applied` entries, exactly as
      `BubbleEx.Decision.applicable/2` returns them; a stale entry (its
      recorded basis differs from the finding's current hashes) is
      `:invalid_input`

  Options:

    * `:residue` - more `BubbleEx.Plan.Residue` entries: from
      `Residue.expressions/4` and `Residue.styles/1` (they need the app
      JSON) or from a target adapter
    * `:decisions_sha256` - `BubbleEx.Decision.decisions_sha256/1` of the
      decision records, recorded in `inputs`
    * `:content` - `BubbleEx.Plan.Content.digests/4` of the same app, keyed
      with the project's key: raw expression text, settings, defaults and
      option values the index does not record, part of each symbol's
      digest. Its algorithm and key ID are recorded in `inputs.content` and
      hashed into every task
    * `:resolved` - the `BubbleEx.Decision.Resolved` the `applied` entries
      come from: every current record naming a covered symbol (parity
      exceptions, rejections and acknowledgements included) and its state
      are part of the task's `decisions_sha256`
    * `:fragment_threshold` - elements under a top-level container above
      which it becomes a fragment task (default #{@fragment_threshold})
  """
  @spec build(Model.t(), Index.t(), Normalized.t() | nil, [Applied.t()], keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def build(model, index, frontend \\ nil, applied \\ [], opts \\ [])

  def build(%Model{} = model, %Index{} = index, frontend, applied, opts)
      when (is_nil(frontend) or is_struct(frontend, Normalized)) and is_list(applied) and
             is_list(opts) do
    threshold = Keyword.get(opts, :fragment_threshold, @fragment_threshold)

    with :ok <- check_applied(applied),
         {:ok, extra} <- check_residue(Keyword.get(opts, :residue, [])),
         {:ok, content} <- check_content(Keyword.get(opts, :content)),
         {:ok, resolved} <- check_resolved(Keyword.get(opts, :resolved)),
         :ok <- check_threshold(threshold) do
      result =
        Builder.run(%{
          model: model,
          index: index,
          frontend: frontend,
          applied: Enum.sort_by(applied, & &1.key),
          extra: extra,
          threshold: threshold,
          content: (content && content.digests) || %{},
          content_id: content_id(content),
          resolved: resolved
        })

      plan = %__MODULE__{
        schema_version: @schema_version,
        inputs: inputs(index, frontend, applied, extra, content, opts, threshold),
        tasks: result.tasks,
        skipped: result.skipped,
        coverage: result.coverage,
        symbols: result.symbols
      }

      {:ok,
       %{
         plan
         | plan_sha256: plan |> to_map() |> Map.delete("plan_sha256") |> CanonicalJson.sha256()
       }}
    end
  end

  def build(_model, _index, _frontend, _applied, _opts),
    do:
      {:error,
       Error.new(
         :invalid_input,
         "expected a Model, its Index, a normalized frontend or nil, a list of applied decisions and options"
       )}

  defp check_applied(applied) do
    cond do
      not Enum.all?(applied, &is_struct(&1, Applied)) ->
        error("applied must be BubbleEx.Decision.Applied entries from Decision.applicable/2")

      stale = Enum.find(applied, &stale?/1) ->
        {:error,
         Error.new(
           :invalid_input,
           "the decision is stale: it was recorded against another proposal or basis; " <>
             "resolve the decisions against this snapshot",
           %{key: stale.key}
         )}

      true ->
        :ok
    end
  end

  # Like `BubbleEx.Target.Ash`: an owner's finding decision must carry the
  # finding's current hashes as its basis; a hint applied by default has
  # no basis and no record.
  defp stale?(%Applied{kind: :finding, automatic: true} = a),
    do: a.basis != nil or a.decision_id != nil or not hash?(a.proposal_sha256)

  defp stale?(%Applied{kind: :finding} = a),
    do:
      not (hash?(a.proposal_sha256) and hash?(a.basis_sha256)) or
        a.basis != %{proposal_sha256: a.proposal_sha256, basis_sha256: a.basis_sha256}

  defp stale?(_rename), do: false

  defp hash?(value), do: is_binary(value) and value =~ ~r/\A[0-9a-f]{64}\z/

  defp check_residue(entries) when is_list(entries) do
    if Enum.all?(entries, &residue_entry?/1),
      do: {:ok, entries},
      else: error("residue entries must be %{subject, reason, detail} with a known reason")
  end

  defp check_residue(_), do: error("residue must be a list")

  defp residue_entry?(%{subject: s, reason: r, detail: d}) when is_binary(s) and is_map(d),
    do: r in Residue.reasons()

  defp residue_entry?(_), do: false

  defp check_content(nil), do: {:ok, nil}

  defp check_content(%Content{algorithm: algorithm, key_id: key_id, digests: digests} = content)
       when is_binary(algorithm) and is_binary(key_id) and is_map(digests) do
    if Enum.all?(digests, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: {:ok, content},
      else: error("content digests must map symbol IDs to digests (Plan.Content.digests/4)")
  end

  defp check_content(_),
    do: error("content must be a BubbleEx.Plan.Content from Plan.Content.digests/4")

  # How content was digested, part of every task's hash: another key or
  # algorithm, or none, changes every task.
  defp content_id(nil), do: nil
  defp content_id(%Content{algorithm: a, key_id: k}), do: %{algorithm: a, key_id: k}

  defp check_resolved(nil), do: {:ok, []}
  defp check_resolved(%Resolved{entries: entries}), do: {:ok, entries}
  defp check_resolved(_), do: error("resolved must be a BubbleEx.Decision.Resolved")

  defp check_threshold(n) when is_integer(n) and n > 0, do: :ok
  defp check_threshold(_), do: error("fragment_threshold must be a positive integer")

  defp inputs(index, frontend, applied, extra, content, opts, threshold) do
    %{
      index_schema_version: index.schema_version,
      index_semantic_sha256: index.semantic_sha256,
      source_sha256: index.source_sha256,
      frontend_schema_version: frontend && frontend.normalized_schema_version,
      decisions_sha256: Keyword.get(opts, :decisions_sha256),
      applied_sha256:
        applied
        |> Enum.sort_by(& &1.key)
        |> Enum.map(&Builder.generation_inputs/1)
        |> json()
        |> CanonicalJson.sha256(),
      residue_sha256: extra |> Residue.sort() |> json() |> CanonicalJson.sha256(),
      content: content_id(content),
      content_sha256: content && CanonicalJson.sha256(content.digests),
      fragment_threshold: threshold
    }
  end

  # --- queries ----------------------------------------------------------------

  @doc "The task with `id`, or nil."
  @spec task(t(), String.t()) :: Task.t() | nil
  def task(%__MODULE__{tasks: tasks}, id), do: Enum.find(tasks, &(&1.id == id))

  @doc "The subtasks of task `id`, in plan order."
  @spec subtasks(t(), String.t()) :: [Task.t()]
  def subtasks(%__MODULE__{tasks: tasks}, id), do: Enum.filter(tasks, &(&1.parent == id))

  @doc "The top-level tasks, in plan order."
  @spec top_level(t()) :: [Task.t()]
  def top_level(%__MODULE__{tasks: tasks}), do: Enum.filter(tasks, &is_nil(&1.parent))

  # --- re-verification --------------------------------------------------------

  @doc """
  What changed between two plans of the same app, and which tasks need
  re-verifying: see `BubbleEx.Plan.Diff`. Each plan is a `t()` or its
  decoded JSON (`to_map/1`, or `.wtf/plan.json` decoded).
  """
  @spec diff(t() | map(), t() | map()) :: {:ok, Diff.t()} | {:error, Error.t()}
  defdelegate diff(old, new), to: Diff

  # --- serialization ----------------------------------------------------------

  @doc "JSON form: string keys and JSON primitives."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = plan) do
    %{
      "schema_version" => plan.schema_version,
      "plan_sha256" => plan.plan_sha256,
      "inputs" => json(plan.inputs),
      "tasks" => Enum.map(plan.tasks, &task_map/1),
      "skipped" => json(plan.skipped),
      "coverage" => json(plan.coverage),
      "symbols" => json(plan.symbols)
    }
  end

  defp task_map(%Task{} = t), do: t |> Map.from_struct() |> json()

  @doc """
  Reads a plan back from its JSON text (or the decoded map), checking its
  schema and its `plan_sha256`: see `BubbleEx.Plan.Codec`. `to_json/1` of
  the result gives back the same bytes.
  """
  @spec decode(String.t() | map()) :: {:ok, t()} | {:error, Error.t()}
  defdelegate decode(json), to: BubbleEx.Plan.Codec

  @doc "Canonical JSON text of `to_map/1` (the `.wtf/plan.json` content)."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = plan), do: plan |> to_map() |> CanonicalJson.encode()

  defp json(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)

  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(value) when value in [true, false, nil], do: value
  defp json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json(value), do: value

  defp error(message), do: {:error, Error.new(:invalid_input, message)}
end
