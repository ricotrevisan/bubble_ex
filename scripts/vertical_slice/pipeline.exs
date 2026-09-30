# The generation pipeline of a vertical slice (WTF-378): what an owner
# downloads, from an app export and the owner's decision records. Shared by
# the slice commands (scripts/vertical_slice/slice.exs); nothing here reads
# a customer name or ID, everything comes from the arguments.
#
#     app JSON ─► Model, Index, Findings
#     decisions + findings + index ─► Decision.resolve ─► applicable
#     Target.Ash.map (privacy: :omit) ─► backend workflows, API clients
#     Frontend.normalize ─► bindings, frontend workflows, page data
#     ─► Target.Phoenix.render ─► files; Plan.build ─► .wtf/plan.json
defmodule VerticalSlice.Pipeline do
  @moduledoc false

  alias BubbleEx.{Decision, Findings, Index, Model, PageData, Plan}
  alias BubbleEx.Target.{ApiClients, Phoenix}
  alias BubbleEx.Target.Ash, as: AshTarget
  alias BubbleEx.Target.Elixir.{Frontend, FrontendWorkflows}
  alias BubbleEx.Workflows.Backend
  alias BubbleEx.Workflows.Frontend, as: FrontendLowering

  @doc "The app JSON of a Buildprint v5 workspace or a `.bubble` JSON file."
  def load_app(path) do
    cond do
      BubbleEx.Buildprint.V5.workspace?(path) ->
        {:ok, %{app: app}} = BubbleEx.Buildprint.V5.load(path)
        app

      # A `.bubble` export is Bubble editor JSON, like a v5 workspace.
      File.regular?(path) ->
        {:ok, app} = BubbleEx.Frontend.read_bubble_export(path)
        app

      true ->
        raise ArgumentError, "not a Buildprint v5 workspace or a JSON file: #{path}"
    end
  end

  @doc "Decision records from a JSON file (a list of decision envelopes), or []."
  def load_decisions(nil), do: []

  def load_decisions(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn map ->
      {:ok, d} = Decision.from_map(map)
      d
    end)
  end

  @doc """
  Everything the render and the plan need, from the app and its decisions.
  Returns a map with the intermediate products (for page statistics and
  the findings report).
  """
  def build(app, decisions, opts) do
    module = Keyword.fetch!(opts, :module)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)
    {:ok, resolved} = Decision.resolve(decisions, findings, index: index, now: now)
    applied = Decision.applicable(resolved, findings)
    sha = Decision.decisions_sha256(decisions)

    {:ok, project} =
      AshTarget.map(model, applied, privacy: :omit, index: index, decisions_sha256: sha)

    {:ok, clients} = ApiClients.map(model)
    {:ok, backend_lowered} = Backend.build(app, model, index)
    {:ok, backend} = AshTarget.Workflows.map(backend_lowered, project, namespace: module)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      Frontend.compile(app, model, project, frontend,
        runtime: "#{module}.Bubble.Runtime",
        namespace: module
      )

    {:ok, lowered} = FrontendLowering.build(app, model, index)
    {:ok, page_data} = PageData.build(app, model)

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: module,
        frontend: frontend,
        backend: backend,
        page_data: page_data
      )

    # The plan knows what the lowerings and their bindings left.
    {:ok, expression_residue} = Plan.Residue.expressions(app, model, index)

    residue =
      expression_residue ++
        Plan.Residue.styles(app) ++
        AshTarget.Workflows.Spec.residue(backend) ++
        FrontendWorkflows.Spec.residue(spec)

    {:ok, plan} =
      Plan.build(model, index, frontend, applied,
        residue: residue,
        decisions_sha256: sha,
        resolved: resolved
      )

    %{
      app: app,
      model: model,
      index: index,
      findings: findings,
      resolved: resolved,
      applied: applied,
      project: project,
      clients: clients,
      backend: backend,
      frontend: frontend,
      expressions: expressions,
      lowered: lowered,
      page_data: page_data,
      spec: spec,
      plan: plan
    }
  end

  @doc """
  The structural checks that need the model (`Structural.run/2`), over the
  rendered files and a second rendering: its summary (counts and statuses).
  """
  def structural(built, files, rerender) do
    {:ok, report} =
      BubbleEx.Target.Phoenix.Structural.run(
        %{
          model: built.model,
          index: built.index,
          plan: built.plan,
          project: built.project,
          files: files,
          rerender: rerender,
          workflows: built.backend,
          frontend_workflows: built.spec,
          api_clients: built.clients
        },
        app: "slice",
        now: DateTime.utc_now() |> DateTime.truncate(:second)
      )

    BubbleEx.Target.Phoenix.Structural.summary(report)
  end

  @doc """
  The rendered file map. With `SLICE_ASSET_STORE` (a store written by
  `mix bubble.fetch_assets`, WTF-447) the pages serve its images; without
  it Bubble-hosted images render without a source. Never fetches.
  """
  def render(built, opts) do
    Phoenix.render(built.project,
      name: Keyword.fetch!(opts, :name),
      module: Keyword.fetch!(opts, :module),
      api_clients: built.clients,
      workflows: built.backend,
      frontend: built.frontend,
      expressions: built.expressions,
      frontend_workflows: built.spec,
      asset_store: asset_store()
    )
  end

  defp asset_store do
    case System.get_env("SLICE_ASSET_STORE") do
      blank when blank in [nil, ""] ->
        nil

      dir ->
        {:ok, store} = BubbleEx.Frontend.StaticAssets.load_store(dir)
        store
    end
  end
end
