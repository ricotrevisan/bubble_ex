# Renders one fixture through BubbleEx.Target.Phoenix (privacy: :omit, what
# an owner downloads; with the API clients of BubbleEx.Target.ApiClients
# when the fixture has a Model) into a scratch Phoenix project directory, replacing
# the previous fixture's files. Every fixture renders with the same name
# (module PhxCheck, app :phx_check), so the dependencies, configured the
# same way, compile once for all of them (scripts/phoenix_compile_check.sh).
#
#     MIX_ENV=test mix run scripts/phoenix_compile_check/render.exs list
#     MIX_ENV=test mix run scripts/phoenix_compile_check/render.exs <dir> <fixture>
#     MIX_ENV=test mix run scripts/phoenix_compile_check/render.exs plan <dir> <fixture> <app id>
#
# `list` prints the fixture names: every BubbleEx.Model fixture
# (test/support/model/*.json), every target fixture
# (test/support/target/ash/*.json), the Phoenix fixtures
# (test/support/target/phoenix/*.json, e.g. API clients), the expression
# fixture, every frozen fidelity case's payload (`fidelity_<case>`, with its
# pages) and the owner decision fixtures (BubbleEx.Test.DecidedFixture), three
# frontends with hostile Bubble IDs (`hostile_ids`, `hostile_overlays`,
# `hostile_workflows`, `hostile_drop`: owner drops, WTF-422), plus `private_app` and `private_cut3` (every cut-2
# and cut-3 finding accepted) when BUBBLE_EX_PRIVATE_EXPORT is set (never
# committed). An
# app with a frontend renders its pages (WTF-370), with the bindings the
# expression compiler lowers; an app with a Model its API Connector clients
# (WTF-374).
#
# The committed scripts/phoenix_compile_check/mix.lock replaces the stub
# lock, and with PHOENIX_COMPILE_CHECK_DB (a PostgreSQL URL without a
# database) config/test.exs is pointed at that server. Both render twice
# to check the output is deterministic, and check that the manifest finds
# the written files clean and a hand edit.

alias BubbleEx.Target.Phoenix

# The privacy mode: `:omit` (what an owner downloads by default), or
# `:enforced` for a fixture named `enforced_<fixture>` (WTF-423: the
# generated policies enforced, set before the fixture is built).
privacy = fn -> Process.get(:phoenix_check_privacy, :omit) end

# The app's frontend (pages, reusable elements, styles), its compiled
# bindings (WTF-370) and its page and reusable-element workflows (WTF-372,
# which schedule the backend workflows of `backend`), when the app JSON has
# one.
frontend = fn app, model, project, backend ->
  case BubbleEx.Frontend.normalize(app) do
    {:ok, frontend} ->
      {:ok, expressions} =
        BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
          runtime: "PhxCheck.Bubble.Runtime",
          namespace: "PhxCheck"
        )

      {:ok, index} = BubbleEx.Index.build(app, model: model)
      {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
      # The pages' data sources (WTF-420).
      {:ok, page_data} = BubbleEx.PageData.build(app, model)

      {:ok, workflows} =
        BubbleEx.Target.Elixir.FrontendWorkflows.map(lowered, project,
          namespace: "PhxCheck",
          frontend: frontend,
          backend: backend,
          page_data: page_data
        )

      [frontend: frontend, expressions: expressions, frontend_workflows: workflows]

    {:error, _} ->
      []
  end
end

# A frozen fidelity case's images and icons, from its committed files (the
# URL -> file map of its case.json; never downloaded): served by the app
# from priv/bubble_images.
with_case_assets = fn {:ok, project, opts}, case_dir ->
  files =
    for asset <-
          Jason.decode!(File.read!(Path.join(case_dir, "case.json")))["public_assets"] || [],
        into: %{},
        do: {asset["url"], Path.join(case_dir, asset["path"])}

  nodes =
    case opts[:frontend] do
      nil -> []
      frontend -> frontend.pages ++ frontend.reusables
    end

  {assets, _findings} = BubbleEx.Frontend.Export.Assets.collect(nodes, asset_files: files)
  {:ok, project, Keyword.put(opts, :assets, assets)}
end

# The backend workflows of an app (WTF-373), bound to its project for the
# PhxCheck module; nil when the app has none, unless `always` (its frontend
# workflows run their data steps on the backend workflow runtime, WTF-372).
workflows = fn app, model, project, always ->
  with {:ok, index} <- BubbleEx.Index.build(app, model: model),
       {:ok, backend} <- BubbleEx.Workflows.Backend.build(app, model, index),
       true <- always or backend.workflows != [],
       {:ok, spec} <- BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "PhxCheck") do
    spec
  else
    _ -> nil
  end
end

# {project, render options} of an app JSON.
app_fixture = fn app ->
  {:ok, model} = BubbleEx.Model.build(app)
  # The privacy matrix of an enforced render reads it (below).
  Process.put(:phoenix_check_model, model)
  {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: privacy.())
  # The API client Spec of its API Connector calls (WTF-374).
  {:ok, clients} = BubbleEx.Target.ApiClients.map(model)

  frontend? = match?({:ok, _}, BubbleEx.Frontend.normalize(app))
  backend = workflows.(app, model, project, frontend?)

  {:ok, project,
   [api_clients: clients, workflows: backend] ++ frontend.(app, model, project, backend)}
end

fixtures =
  for {pattern, prefix} <- [
        {"test/support/model/*.json", ""},
        {"test/support/target/ash/*.json", "target_"},
        {"test/support/target/phoenix/*.json", "phoenix_"},
        {"test/support/expression/*.json", "expr_"},
        {"test/support/fidelity/cases/*/source/payload.json", "fidelity_"},
        {"test/support/target/workflows/*.json", "workflows_"}
      ],
      path <- pattern |> Path.wildcard() |> Enum.sort(),
      into: %{} do
    name =
      if prefix == "fidelity_",
        do: prefix <> (path |> Path.dirname() |> Path.dirname() |> Path.basename()),
        else: prefix <> Path.basename(path, ".json")

    fixture = fn -> path |> File.read!() |> Jason.decode!() |> app_fixture.() end

    # A fixture's downloaded static assets (WTF-447), when it has a
    # committed store next to it (<fixture>.store/, never fetched here).
    store = String.replace_suffix(path, ".json", ".store")

    fixture =
      if File.dir?(store) do
        fn ->
          {:ok, project, opts} = fixture.()
          {:ok, loaded} = BubbleEx.Frontend.StaticAssets.load_store(store)
          [] = loaded.errors
          {:ok, project, Keyword.put(opts, :asset_store, loaded)}
        end
      else
        fixture
      end

    if prefix == "fidelity_",
      do: {name, fn -> with_case_assets.(fixture.(), Path.dirname(Path.dirname(path))) end},
      else: {name, fixture}
  end
  |> Map.merge(%{
    # Hostile Bubble IDs (quotes, `#{`, a newline, `*/`, `--%>`, an EEx tag,
    # braces) on a page, a reusable, an instance inside a reusable, a Text,
    # a modal Popup and a Group Focus: the generated code must compile and
    # its test find them (WTF-370).
    "hostile_ids" => fn ->
      "test/support/fidelity/cases/bpgwgmpz/source/payload.json"
      |> File.read!()
      |> Jason.decode!()
      |> BubbleEx.Test.HostileIds.rename(~w(bpgwgmpz bpmvuzce bpcjyrzt bpcjyrzr))
      |> app_fixture.()
    end,
    "hostile_overlays" => fn ->
      "test/support/fidelity/cases/bptvorpv/source/payload.json"
      |> File.read!()
      |> Jason.decode!()
      |> BubbleEx.Test.HostileIds.rename(~w(bptvorpv bptvorpw bptvorqc))
      |> app_fixture.()
    end,
    # The frontend workflows fixture (WTF-372) with every page, element,
    # workflow, action, parameter and return ID hostile: the workflow
    # modules, markers, event lists, JS commands and tests must quote them.
    "hostile_workflows" => fn ->
      app =
        "test/support/target/phoenix/frontend_workflows.json"
        |> File.read!()
        |> Jason.decode!()

      app
      |> BubbleEx.Test.HostileIds.rename(BubbleEx.Test.HostileIds.ids(app))
      |> app_fixture.()
    end,
    # The page data fixture (WTF-420) with every ID hostile: its routes,
    # data functions, filters, template keys and tests must quote them.
    "hostile_page_data" => fn ->
      app =
        "test/support/target/phoenix/page_data.json"
        |> File.read!()
        |> Jason.decode!()

      app
      |> BubbleEx.Test.HostileIds.rename(BubbleEx.Test.HostileIds.ids(app))
      |> app_fixture.()
    end,
    # Owner drops (WTF-422) over the cut-1 export: a dropped type, fields
    # and a backend workflow its caller can no longer run (residue).
    "decided_drop" => fn ->
      app = BubbleEx.Test.DecidedFixture.app(:drop)
      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, project} = BubbleEx.Test.DecidedFixture.project(:drop, privacy: privacy.())
      backend = workflows.(app, model, project, true)
      {:ok, project, [workflows: backend] ++ frontend.(app, model, project, backend)}
    end,
    # The frontend workflows fixture with every ID hostile and a page, a
    # page workflow (a custom event another one triggers) and a backend
    # workflow (a page schedules it) dropped: omitted, their callers residue.
    "hostile_drop" => fn ->
      app =
        "test/support/target/phoenix/frontend_workflows.json"
        |> File.read!()
        |> Jason.decode!()

      hostile = &BubbleEx.Test.HostileIds.hostile/1
      app = BubbleEx.Test.HostileIds.rename(app, BubbleEx.Test.HostileIds.ids(app))

      %{model: model, project: project} =
        BubbleEx.Test.DecidedFixture.dropped(app, [
          BubbleEx.Index.Symbol.id(:page, hostile.("bOther")),
          BubbleEx.Index.Symbol.id(:workflow, hostile.("wEvt")),
          BubbleEx.Index.Symbol.id(:workflow, hostile.("wApiNote"))
        ], privacy: privacy.())

      backend = workflows.(app, model, project, true)
      {:ok, project, [workflows: backend] ++ frontend.(app, model, project, backend)}
    end,
    "decided_combined" => fn ->
      {:ok, project} = BubbleEx.Test.DecidedFixture.project(:combined, privacy: privacy.())
      {:ok, project, []}
    end,
    "decided_locked" => fn ->
      {:ok, project} = BubbleEx.Test.DecidedFixture.locked_project(privacy: privacy.())
      {:ok, project, []}
    end,
    # lists normalized to join resources (WTF-406)
    "decided_cut3" => fn ->
      app = BubbleEx.Test.DecidedFixture.app(:cut3)
      app = put_in(app, ["pages", "pgHome", "properties", "page_item_type"], "custom.project")

      app =
        put_in(app, ["pages", "pgHome", "elements", "rgJoinedTasks"], %{
          "id" => "rgJoinedTasks",
          "type" => "RepeatingGroup",
          "properties" => %{
            "group_type" => "custom.task",
            "data_source" => %{
              "type" => "CurrentPageItem",
              "next" => %{"type" => "Message", "name" => "tasks_list_custom_task"}
            }
          }
        })

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, project} = BubbleEx.Test.DecidedFixture.project(:cut3, privacy: privacy.())
      backend = workflows.(app, model, project, true)
      {:ok, project, [workflows: backend] ++ frontend.(app, model, project, backend)}
    end
  })
  |> Map.merge(
    case System.get_env("BUBBLE_EX_PRIVATE_EXPORT") do
      blank when blank in [nil, ""] ->
        %{}

      path ->
        %{
          "private_app" => fn -> path |> BubbleEx.Test.SplitExport.load() |> app_fixture.() end,
          # every cut-2 and cut-3 finding accepted (WTF-406)
          "private_cut3" => fn ->
            app = BubbleEx.Test.SplitExport.load(path)
            {:ok, model} = BubbleEx.Model.build(app)
            {:ok, index} = BubbleEx.Index.build(app, model: model)

            {:ok, %{findings: findings}} =
              BubbleEx.Findings.analyze(app, model: model, index: index)

            {_records, applied, sha} =
              BubbleEx.Test.DecidedFixture.accept_cut3(findings, [], index)

            {:ok, project} =
              BubbleEx.Target.Ash.map(model, applied, privacy: privacy.(), decisions_sha256: sha)

            {:ok, project, []}
          end
        }
    end
  )

# The app JSON of a fixture rendered from one (not the decision fixtures).
app_json = fn name ->
  [
    {"test/support/model/", ""},
    {"test/support/target/ash/", "target_"},
    {"test/support/target/phoenix/", "phoenix_"},
    {"test/support/expression/", "expr_"},
    {"test/support/target/workflows/", "workflows_"}
  ]
  |> Enum.find_value(fn {dir, prefix} ->
    path = dir <> String.replace_prefix(name, prefix, "") <> ".json"
    if String.starts_with?(name, prefix) and File.exists?(path), do: path
  end)
  |> File.read!()
  |> Jason.decode!()
end

case System.argv() do
  # The migration plan of a rendered fixture, as .wtf/plan.json, and the
  # generator's determinism result (the fixture renders twice, byte for
  # byte), for the task CLI check (scripts/phoenix_compile_check/task_cli.sh).
  ["plan", dir, name, bubble_app] ->
    app = app_json.(name)
    {:ok, model} = BubbleEx.Model.build(app)
    {:ok, index} = BubbleEx.Index.build(app, model: model)
    {:ok, plan} = BubbleEx.Plan.build(model, index)
    :ok = BubbleEx.Tasks.Store.write_plan(dir, plan)

    {:ok, project, frontend_opts} = Map.fetch!(fixtures, name).()
    opts = [name: "Phx Check #{name}", module: "PhxCheck"] ++ frontend_opts
    {:ok, files} = Phoenix.render(project, opts)
    {:ok, ^files} = Phoenix.render(project, opts)

    {:ok, result} =
      BubbleEx.Verify.Result.new(%{
        id: "deterministic.generate",
        app: bubble_app,
        check: "deterministic",
        status: :pass,
        actor: "ci",
        ran_at: DateTime.utc_now() |> DateTime.truncate(:second),
        tasks: for(t <- plan.tasks, t.kind == :generate, do: t.id)
      })

    path = Path.join(dir, ".wtf/verification/results/deterministic.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, BubbleEx.Verify.Result.to_json(result))

    IO.puts("planned #{name}: #{length(plan.tasks)} tasks")

  ["list"] ->
    fixtures |> Map.keys() |> Enum.sort() |> Enum.each(&IO.puts/1)

  [dir, name] ->
    name =
      case name do
        "enforced_" <> base ->
          Process.put(:phoenix_check_privacy, :enforced)
          base

        name ->
          name
      end

    {:ok, project, frontend_opts} = Map.fetch!(fixtures, name).()

    opts =
      [name: "Phx Check #{name}", module: "PhxCheck"] ++ frontend_opts

    {:ok, files} = Phoenix.render(project, opts)
    {:ok, ^files} = Phoenix.render(project, opts)

    # The previous fixture's files (the scratch keeps deps and _build).
    for entry <- ~w(lib test priv config assets .wtf),
        do: File.rm_rf!(Path.join(dir, entry))

    for {path, content} <- files do
      file = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end

    File.cp!("scripts/phoenix_compile_check/mix.lock", Path.join(dir, "mix.lock"))

    # The privacy matrix (BubbleEx.Verify.Matrix, WTF-383) against the
    # enforced app (WTF-423): its ExUnit module (BubbleEx.Target.Ash.
    # MatrixTests, on the app's Repo) in test/matrix/, the owner-repo files
    # in matrix/<name>/ and matrix_index.json for
    # scripts/ash_compile_check/matrix_results.exs, which scores the
    # observations the tests write (WTF_VERIFY_OBSERVATIONS).
    for entry <- ~w(matrix matrix_index.json observations), do: File.rm_rf!(Path.join(dir, entry))

    with :enforced <- project.privacy,
         %BubbleEx.Model{} = model <- Process.get(:phoenix_check_model),
         true <- model.data_types |> Enum.flat_map(& &1.rules) |> Enum.any?() do
      app_id = if String.starts_with?(name, "private_"), do: "private-app", else: "fixture-app"
      {:ok, synthesized} = BubbleEx.Verify.Matrix.synthesize(model, app: app_id)
      matrix_files = BubbleEx.Verify.Matrix.files(synthesized)
      root = Path.join([dir, "matrix", name])

      for {path, json} <- matrix_files do
        File.mkdir_p!(Path.dirname(Path.join(root, path)))
        File.write!(Path.join(root, path), json)
      end

      {:ok, plan} = BubbleEx.Target.Ash.MatrixTests.plan(matrix_files)

      {:ok, out} =
        BubbleEx.Target.Ash.MatrixTests.render(project, plan,
          namespace: "PhxCheck",
          repo: "PhxCheck.Repo",
          module: "PhxCheck.PrivacyMatrixTest"
        )

      File.mkdir_p!(Path.join(dir, "test/matrix"))
      File.write!(Path.join(dir, "test/matrix/privacy_matrix_test.exs"), out.source)

      File.write!(
        Path.join(dir, "matrix_index.json"),
        Jason.encode!(
          [
            %{
              name: name,
              app: app_id,
              repo: "PhxCheck.Repo",
              module: out.module,
              counts: out.counts,
              skipped: synthesized.report.skipped
            }
          ],
          pretty: true
        )
      )

      IO.puts(
        "rendered #{name}'s privacy-matrix tests: #{out.counts["scenarios"]} scenarios, " <>
          "#{out.counts["ops"]} ops over #{out.counts["records"]} seed records"
      )
    end

    # Behavior tests of a workflow fixture's generated app (WTF-373).
    behavior =
      "test/support/target/workflows/#{String.replace_prefix(name, "workflows_", "")}_behavior.exs"

    if String.starts_with?(name, "workflows_") and File.exists?(behavior),
      do: File.cp!(behavior, Path.join(dir, "test/phx_check/workflows_behavior_test.exs"))

    {:ok, %{clean?: true, modified: [], missing: []}} =
      Phoenix.check_manifest(files[".wtf/generated.json"], dir)

    domain = "lib/phx_check/domain.ex"

    {:ok, %{clean?: false, modified: [^domain]}} =
      Phoenix.check_manifest(
        files[".wtf/generated.json"],
        Map.update!(files, domain, &(&1 <> "# edited\n"))
      )

    case System.get_env("PHOENIX_COMPILE_CHECK_DB") do
      blank when blank in [nil, ""] ->
        # Fail closed: without a database URL the smoke tests do not run,
        # and the scaffolded test config (localhost:5432) must not be
        # usable by accident, so it points at a host that cannot resolve.
        File.write!(
          Path.join(dir, "config/test.exs"),
          """

          # PHOENIX_COMPILE_CHECK_DB is not set: no database (fail closed).
          config :phx_check, PhxCheck.Repo,
            hostname: "phoenix-compile-check-db-unset.invalid",
            port: 1,
            database: "phx_check_test"
          """,
          [:append]
        )

      _url ->
        # Fail closed (scripts/check_db.exs): an explicit port, never 5432
        # unless PHOENIX_COMPILE_CHECK_ALLOW_5432=1, and a check database
        # (the smoke tests drop and create it).
        Code.require_file("scripts/check_db.exs")
        uri = URI.parse(CheckDb.url!("PHOENIX_COMPILE_CHECK_DB", "PHOENIX_COMPILE_CHECK_ALLOW_5432"))
        [user, password] = String.split(uri.userinfo || "postgres:postgres", ":", parts: 2)

        File.write!(
          Path.join(dir, "config/test.exs"),
          """

          config :phx_check, PhxCheck.Repo,
            hostname: #{inspect(uri.host)},
            port: #{uri.port},
            username: #{inspect(user)},
            password: #{inspect(password)},
            database: #{inspect(CheckDb.database!("phx_check_test"))}
          """,
          [:append]
        )
    end

    generated = files[".wtf/generated.json"] |> Jason.decode!() |> Map.fetch!("generated")

    IO.puts(
      "rendered #{name}: #{map_size(files)} files " <>
        "(#{map_size(generated)} generated, #{length(Phoenix.owned_paths(files))} owned)"
    )
end
