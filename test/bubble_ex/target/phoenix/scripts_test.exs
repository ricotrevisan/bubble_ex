defmodule BubbleEx.Target.Phoenix.ScriptsTest do
  # WTF-608: Toolbox scripts. A page-only "Run javascript" runs in the
  # page's scripts hook with its inputs computed on the server; one that
  # fetches is residue with a rewrite brief; a "Javascript to Bubble"
  # element's event is a workflow the page runs when the hook publishes.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix.BlockedWorkflows
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/scripts.json"

  setup_all do
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

    %{lowered: lowered, spec: spec, files: files, frontend: frontend}
  end

  defp step(lowered, id),
    do: lowered.workflows |> Enum.flat_map(& &1.steps) |> Enum.find(&(&1.bubble_id == id))

  test "a page-only script lowers; one that fetches is residue with a brief", %{lowered: l} do
    js = step(l, "aJs")
    assert %{op: :run_js, residue: []} = js
    assert js.args.publishes == ["picked"]
    assert [%{name: "param1"}] = js.args.params
    assert js.args.source =~ "bubble_fn_picked(picked)"

    net = step(l, "aNet")
    assert [%{reason: :script_action, detail: detail}] = net.residue
    assert ["it makes a network request (fetch)"] = detail.why
    assert detail.brief.shape =~ "Make the request on the server"
    assert [%{name: "param1", type: "text"}] = detail.brief.inputs
  end

  test "the publisher's event is a workflow reading what it published", %{lowered: l, spec: spec} do
    pick = Enum.find(l.workflows, &(&1.bubble_id == "wPick"))
    assert %{kind: :js_publish, element: "bPub", residue: []} = pick

    assert %{"bPub" => %{suffix: "picked", outputs: [%{name: "value", state: "get_AAV"}]}} =
             l.publishers

    surface = spec.surfaces["bHome"]

    assert %{"bPub" => %{outputs: [%{kind: :text, state: "get_AAV"}], workflows: ["wPick"]}} =
             surface.publishers

    bound = Enum.find(surface.workflows, &(&1.workflow == "wPick"))
    assert Spec.native?(bound)

    assert %{"bHtml" => %{scripts: [%{source: "document.body.dataset.html = 'shown'"}]}} =
             spec.element_scripts

    refute Map.has_key?(spec.element_scripts, "bLib")
    assert Spec.scripts?(spec)
    assert [%{script: "aJs"}] = Spec.scripts(spec)
  end

  test "the generated hook holds only the page-only script", %{files: files} do
    hook = files["lib/shop_web/components/bubble_scripts.ex"]
    assert hook =~ ~s|"aJs": function (properties) {|
    assert hook =~ "bubble_fn_picked(picked);"
    refute hook =~ "fetch("
    assert hook =~ ~s|"bHtml": [|
    refute hook =~ "jQuery"

    # Formatting the generated module again changes nothing.
    path = "lib/shop_web/components/bubble_scripts.ex"
    assert BubbleEx.Target.Phoenix.Formatter.format(path, hook) == hook
    assert files["lib/shop_web/components/bubble.ex"] =~ "<ShopWeb.BubbleScripts.scripts />"
    assert files["lib/shop_web/components/bubble.ex"] =~ ~s|op.op === "script"|

    module = files["lib/shop_web/live/index_live/workflows.ex"]
    assert module =~ ~s|BubbleWorkflows.script(ctx, "aJs", "aJs", [{"param1", "blue"}])|
    assert module =~ ~s|suffix: "picked",|
    assert module =~ ~s|outputs: [{"value", "get_AAV", :text, false, nil}],|
    assert module =~ ~s|BubbleWorkflows.state(ctx, [], "bPub", "get_AAV")|
  end

  test "the owner reads why a workflow does not run", %{spec: spec, frontend: frontend} do
    notes = BlockedWorkflows.notes(spec, nil, frontend: frontend)
    assert [%{workflow: "wNet", reason: :script_action, detail: detail}] = notes
    assert "it makes a network request (fetch)" in detail
    assert BlockedWorkflows.markdown(notes) =~ "A step runs JavaScript a developer has to port"
  end

  @tag :fidelity
  @tag :tmp_dir
  test "the hook runs the script with its inputs and publishes as data", %{
    files: files,
    tmp_dir: tmp
  } do
    [_, script] =
      String.split(files["lib/shop_web/components/bubble_scripts.ex"], ~s(name=".BubbleScripts">))

    [hook | _] = String.split(script, "</script>")
    path = Path.join(tmp, "hook.mjs")
    File.write!(path, hook)

    {output, status} =
      System.cmd("node", ["test/support/fidelity/scripts-hook.mjs", Path.expand(path)],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "PASS scripts hook"
  end
end
