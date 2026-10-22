defmodule BubbleEx.Target.Phoenix.AnimateHookTest do
  # WTF-603: the generated page hook runs Bubble's "Animate an element"
  # (transitions as show and hide, Velocity UI's motion), in the pinned
  # browser (test/support/fidelity/animate-hook.mjs).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/animate.json"

  @tag :fidelity
  @tag :tmp_dir
  test "the hook shows, hides and moves an animated element", %{tmp_dir: tmp} do
    app = @fixture |> File.read!() |> Jason.decode!()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)
    {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
    {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        backend: workflows
      )

    {:ok, files} =
      BubbleEx.Target.Phoenix.render(project,
        name: "Shop",
        frontend: frontend,
        workflows: workflows,
        frontend_workflows: spec
      )

    [_, script] =
      String.split(files["lib/shop_web/components/bubble.ex"], ~s(name=".BubbleRuntime">))

    [hook | _] = String.split(script, "</script>")
    path = Path.join(tmp, "hook.js")
    File.write!(path, hook)

    {output, status} =
      System.cmd("node", ["test/support/fidelity/animate-hook.mjs", Path.expand(path)],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "PASS animate hook"
  end
end
