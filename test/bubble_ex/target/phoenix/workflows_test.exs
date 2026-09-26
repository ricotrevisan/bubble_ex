defmodule BubbleEx.Target.Phoenix.WorkflowsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, Plan}
  alias BubbleEx.Target.{Ash, Phoenix}
  alias BubbleEx.Target.Ash.Workflows
  alias BubbleEx.Workflows.Backend

  @backend "test/support/target/workflows/backend.json"
  @hostile "test/support/target/workflows/hostile_ids.json"

  defp build(path) do
    app = path |> File.read!() |> Jason.decode!()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, backend} = Backend.build(app, model, index)
    {:ok, project} = Ash.map(model, [], privacy: :omit)
    {:ok, spec} = Workflows.map(backend, project, namespace: "Acme")
    %{model: model, index: index, backend: backend, project: project, spec: spec}
  end

  defp render(%{project: project, spec: spec}),
    do: Phoenix.render(project, name: "Acme", module: "Acme", workflows: spec)

  setup_all do
    built = build(@backend)
    {:ok, files} = render(built)
    Map.put(built, :files, files)
  end

  test "entry points are generated and hash-guarded, bodies and tests owned", %{files: files} do
    manifest = Jason.decode!(files[".wtf/generated.json"])
    generated = Map.keys(manifest["generated"])
    owned = Phoenix.owned_paths(files)

    for path <- ~w(lib/acme/workflows/folder_f_tasks.ex lib/acme/workflows/folder_f_loop.ex
                   lib/acme/workflows/unfiled.ex lib/acme/workflows/registry.ex
                   lib/acme/workflows/runtime.ex lib/acme/workflows/scheduler.ex
                   lib/acme/workflows/triggers.ex lib/acme_web/controllers/workflow_api_controller.ex
                   .wtf/workflows.json),
        do: assert(path in generated, path)

    for path <-
          ~w(lib/acme/workflows/folder_f_tasks/bodies.ex lib/acme/bubble/runtime.ex
                   test/acme/bubble_workflows_test.exs test/acme_web/bubble_workflow_api_test.exs),
        do: assert(path in owned, path)

    assert manifest["inputs"]["workflows_sha256"] ==
             :sha256 |> :crypto.hash(files[".wtf/workflows.json"]) |> Base.encode16(case: :lower)

    assert {:ok, %{clean?: true}} = Phoenix.check_manifest(files[".wtf/generated.json"], files)
  end

  test "the folder resources are in the domain; a trigger resource gets the outbox change",
       %{files: files} do
    assert files["lib/acme/domain.ex"] =~ "resource Acme.Workflows.FolderFTasks"

    assert files["lib/acme/task.ex"] =~
             "change Acme.Workflows.Triggers, on: [:create, :update, :destroy]"

    refute files["lib/acme/project.ex"] =~ "Workflows.Triggers"
    assert files["lib/acme/user.ex"] =~ "Acme.Accounts.UserAuthentication"
  end

  test "the workflow API dispatches to the lowered workflows", %{files: files} do
    controller = files["lib/acme_web/controllers/workflow_api_controller.ex"]
    assert controller =~ "Runtime.call_endpoint"

    assert files["lib/acme/workflows/registry.ex"] =~
             ~s("create task" => %{workflow: "wCreate", auth: :none)

    {:ok, without} = Phoenix.render(context().project, name: "Acme", module: "Acme")
    refute without["lib/acme_web/controllers/workflow_api_controller.ex"] =~ "Runtime"
    refute Map.has_key?(without, "lib/acme/workflows/runtime.ex")
  end

  test "a bypass is loud in the code", %{files: files} do
    bodies = files["lib/acme/workflows/folder_f_tasks/bodies.ex"]
    assert bodies =~ ~s|Runtime.start(input, context, "wClose", false)|
    assert bodies =~ "IGNORES PRIVACY RULES"
    assert bodies =~ ~s|Runtime.start(input, context, "wCreate", true)|
    assert bodies =~ ~s|Runtime.start(input, context, "wNotify", :inherit)|
    assert files["lib/acme/workflows/registry.ex"] =~ ~s|def privacy_bypasses, do: ["wClose"]|
  end

  test "a workflow that reaches residue fails before its first step", %{files: files} do
    bodies = files["lib/acme/workflows/folder_f_loop/bodies.ex"]

    assert bodies =~ ~s|"action:aCall",\n      "action:aMail"\n    ])|

    assert bodies =~ ~s|["workflow:wExternal"])|
    assert bodies =~ ~s|Runtime.steps(ctx, nil, [&tick__step(1, &1), &tick__step(2, &1)], [])|
  end

  test "the workflow API is off by default, loudly", %{files: files, spec: spec} do
    assert files["lib/acme/workflows/runtime.ex"] =~ "config(:serve_workflow_api, false)"
    assert files["test/acme_web/smoke_test.exs"] =~ "NOT_SERVED"

    assert [_, _] = Enum.filter(spec.diagnostics, &(&1.code == :workflow_endpoint_not_served))
  end

  test "residue steps fail loudly and are marked", %{files: files} do
    bodies = files["lib/acme/workflows/folder_f_loop/bodies.ex"]
    assert bodies =~ "# TODO(bubble:action:aCall) not lowered: api_connector_action"
    assert bodies =~ ~s|Runtime.not_lowered(ctx, "aCall", "apiconnector2-gA.cB")|
  end

  test "step markers are the plan's step order; tests are tagged for native workflows only",
       %{files: files, model: model, index: index, backend: backend, spec: spec} do
    {:ok, plan} = Plan.build(model, index, nil, [], residue: Backend.residue(backend))

    markers =
      for {path, source} <- files, String.ends_with?(path, "bodies.ex"), reduce: %{} do
        acc -> Map.merge(acc, markers(source))
      end

    step_orders =
      for task <- plan.tasks, c <- task.criteria, c.check == :step_order, do: c.args

    assert step_orders != []

    for %{workflow: workflow, steps: steps} <- step_orders do
      id = String.replace_prefix(workflow, "workflow:", "")
      assert markers[id] == Enum.with_index(steps, 1) |> Enum.map(fn {t, n} -> {n, t} end), id
    end

    # Smoke tests are tagged bubble_smoke: they do not satisfy unit_test.
    assert files["test/acme/bubble_workflows_test.exs"] |> tags(:bubble) == []
    smoke = files["test/acme/bubble_workflows_test.exs"] |> tags(:bubble_smoke)

    native = for a <- Workflows.actions(spec), Workflows.native?(a), do: a.symbol
    assert Enum.sort(Enum.uniq(smoke)) == Enum.sort(native)
    refute "workflow:wExternal" in smoke
    refute "workflow:wBlocked" in smoke

    assert files["test/acme_web/bubble_workflow_api_test.exs"] |> tags(:bubble_smoke) ==
             ["workflow:wCreate", "workflow:wPing"]
  end

  test "deterministic", %{files: files} = built do
    assert render(built) == {:ok, files}
  end

  test "a spec mapped for another namespace is refused" do
    built = build(@backend)
    {:ok, other} = Workflows.map(built.backend, built.project, namespace: "Other")

    assert {:error, %BubbleEx.Error{}} =
             Phoenix.render(built.project, name: "Acme", module: "Acme", workflows: other)

    assert {:error, %BubbleEx.Error{}} =
             Phoenix.render(built.project, name: "Acme", module: "Acme", workflows: :nope)
  end

  describe "hostile IDs and names" do
    setup do
      built = build(@hostile)
      {:ok, files} = render(built)
      %{files: files}
    end

    test "every generated Elixir file parses and splices no app text into code", %{files: files} do
      sources =
        for {path, source} <- files,
            String.contains?(path, "workflow") or String.contains?(path, "bubble"),
            Path.extname(path) in [".ex", ".exs"],
            do: {path, source}

      assert length(sources) >= 8

      for {path, source} <- sources do
        {:ok, ast, _comments} = Code.string_to_quoted_with_comments(source, file: path)

        {_, calls} =
          Macro.prewalk(ast, [], fn
            {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
              {node, [name | acc]}

            node, acc ->
              {node, acc}
          end)

        # The hostile text holds `raise "injected"` and an EEx `raise`.
        refute :raise in calls, "#{path} calls raise"

        {_, modules} =
          Macro.prewalk(ast, [], fn
            {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc -> {node, [parts | acc]}
            node, acc -> {node, acc}
          end)

        assert length(modules) == 1, "#{path} defines #{inspect(modules)}"
      end
    end

    test "hostile text is quoted, and comments stay on one line", %{files: files} do
      registry = files["lib/acme/workflows/registry.ex"]
      assert registry =~ ~s|\\\#{raise \\"injected\\"}|

      bodies =
        for {path, source} <- files, String.ends_with?(path, "bodies.ex"), into: "", do: source

      for line <- String.split(bodies, "\n"),
          String.trim_leading(line) |> String.starts_with?("# bubble:") do
        refute line =~ "\u2028"
      end
    end
  end

  defp context, do: build(@backend)

  # `# bubble:workflow` / `# bubble:step` markers, as the task CLI reads them.
  defp markers(source) do
    {:ok, _, comments} = Code.string_to_quoted_with_comments(source)

    comments
    |> Enum.map(&String.trim(String.trim_leading(&1.text, "#")))
    |> Enum.reduce([], fn text, acc ->
      case {Regex.run(~r/\Abubble:workflow\s+(\S+)/, text),
            Regex.run(~r/\Abubble:step\s+(\d+)\s+(\S+)/, text), acc} do
        {[_, id], _, acc} ->
          [{id, []} | acc]

        {_, [_, n, type], [{id, steps} | rest]} ->
          [{id, steps ++ [{String.to_integer(n), type}]} | rest]

        _ ->
          acc
      end
    end)
    |> Map.new()
  end

  defp tags(source, key) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_, tags} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:tag, _, [[{^key, tag}]]}]} = node, acc -> {node, [tag | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(tags)
  end
end
