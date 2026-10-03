defmodule BubbleEx.Target.Phoenix.FrontendWorkflowsTest do
  # Printing page and reusable-element workflows with the pages (WTF-372).
  # scripts/phoenix_compile_check.sh compiles the output, runs its tests,
  # the behavior tests of test/support/target/phoenix/
  # frontend_workflows_behavior.exs and `mix wtf.task complete` of the
  # workflow tasks.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, Plan}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Test.HostileIds
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/frontend_workflows.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp render(app, opts \\ []) do
    {page_data?, opts} = Keyword.pop(opts, :page_data, false)
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, lowered} = Frontend.build(app, model, index)
    {:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

    {:ok, backend} =
      BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "Shop")

    page_data =
      if page_data? do
        {:ok, page_data} = BubbleEx.PageData.build(app, model)
        [page_data: page_data]
      else
        []
      end

    {:ok, spec} =
      FrontendWorkflows.map(
        lowered,
        project,
        [namespace: "Shop", frontend: frontend, backend: backend] ++ page_data
      )

    opts =
      [
        module: "Shop",
        frontend: frontend,
        expressions: expressions,
        workflows: backend,
        frontend_workflows: spec
      ] ++ opts

    {:ok, files} = Phoenix.render(project, opts)
    {:ok, ^files} = Phoenix.render(project, opts)
    %{files: files, spec: spec, model: model, index: index, frontend: frontend, lowered: lowered}
  end

  setup_all do
    render(app())
  end

  # workflow ID => [{n, type}], from the `# bubble:` comments of lib/, as
  # the task CLI's step_order check reads them.
  defp markers(files) do
    for {path, content} <- files,
        String.starts_with?(path, "lib/") and Path.extname(path) == ".ex",
        {:ok, _, comments} = Code.string_to_quoted_with_comments(content),
        {id, steps} <- blocks(comments),
        reduce: %{} do
      acc -> Map.update(acc, id, [steps], &[steps | &1])
    end
  end

  defp blocks(comments) do
    comments
    |> Enum.map(&String.trim(String.trim_leading(&1.text, "#")))
    |> Enum.reduce([], &block/2)
  end

  defp block(text, blocks) do
    case {Regex.run(~r/\Abubble:workflow\s+(\S+)/, text),
          Regex.run(~r/\Abubble:step\s+(\d+)\s+(\S+)/, text), blocks} do
      {[_, id], _, blocks} ->
        [{id, []} | blocks]

      {_, [_, n, type], [{id, steps} | rest]} ->
        [{id, steps ++ [{String.to_integer(n), type}]} | rest]

      _ ->
        blocks
    end
  end

  test "workflow modules are owned, the runtime is generated", %{files: files} do
    manifest = Jason.decode!(files[".wtf/generated.json"])

    for path <-
          ~w(lib/shop_web/live/index_live/workflows.ex lib/shop_web/live/other_live/workflows.ex
                   lib/shop_web/components/reusables/card/workflows.ex
                   test/shop_web/bubble_frontend_workflows_test.exs),
        do: assert(Map.has_key?(manifest["owned"], path), path)

    assert Map.has_key?(manifest["generated"], "lib/shop_web/bubble_workflows.ex")
    runtime = files["lib/shop_web/bubble_workflows.ex"]
    assert runtime =~ "defmodule ShopWeb.BubbleWorkflows do"
    assert runtime =~ "config :shop, ShopWeb.BubbleWorkflows, data_access: true"
    assert {:ok, _} = Code.string_to_quoted(runtime)
  end

  test "every workflow of the plan is marked once, with its steps in order", %{
    files: files,
    model: model,
    index: index,
    frontend: frontend,
    lowered: lowered
  } do
    {:ok, plan} = Plan.build(model, index, frontend, [], residue: Frontend.residue(lowered))
    markers = markers(files)

    for task <- plan.tasks, task.kind == :workflow do
      "workflow:" <> id = task.id
      [%{args: %{steps: steps}}] = Enum.filter(task.criteria, &(&1.check == :step_order))
      expected = steps |> Enum.with_index(1) |> Enum.map(fn {type, n} -> {n, type} end)
      assert markers[id] == [expected], task.id
    end
  end

  test "the page lists what a browser may trigger", %{files: files} do
    module = files["lib/shop_web/live/index_live/workflows.ex"]
    assert module =~ ~s("bBtnState" => ["wState"])
    assert module =~ ~s|changes: %{"bNum" => ["wChanged"]}|
    assert module =~ ~s("bIn" => {:text, nil})
    assert module =~ ~s("bNum" => {:number, 3})
    assert module =~ ~s|loaded: ["wLoad"]|
    assert module =~ ~s|conditions: [{"wCond", :every_time}, {"wFlip", :every_time}]|
    # Browser-run and disabled workflows are not in the click list.
    refute module =~ ~s("bBtnOpen" =>)
    assert module =~ ~s({"bInst1", ShopWeb.Reusables.Card.Workflows})
    assert module =~ ~s|blocked: ["action:aRes2"]|
    # Blocked through the custom event it calls, as the backend's blocked_by.
    assert module =~ ~s|blocked: ["workflow:wEvtResidue"]|
    assert module =~ ~s|"wData" => %{run: :wf_w_data, condition: nil, blocked: [], data: true}|
    # Scheduling a backend workflow runs on the backend runtime.
    assert module =~ "page_data_current_date_time = ctx.now"

    assert module =~
             ~s|Runtime.schedule(run, "aSchedule1", "wApiNote", page_data_current_date_time|

    assert module =~ ~s|BubbleWorkflows.backend(ctx, fn run ->|
  end

  describe "Go to page with data to send (WTF-378)" do
    # Page `other` with a type of content, and wNav sending it the current user.
    defp with_thing(app, page_type) do
      app
      |> put_in(["pages", "other", "properties", "page_item_type"], page_type)
      |> put_in(
        ["pages", "home", "workflows", "wNav", "actions", "0", "properties", "data_to_send"],
        %{"type" => "CurrentUser"}
      )
    end

    test "sends the thing as the path segment the page reads it from" do
      %{files: files, spec: spec} = render(with_thing(app(), "user"), page_data: true)
      nav = FrontendWorkflows.Spec.workflow(spec, "bHome", "wNav")
      assert nav.residue == [] and FrontendWorkflows.Spec.native?(nav)

      module = files["lib/shop_web/live/index_live/workflows.ex"]

      assert module =~
               ~s|BubbleWorkflows.navigate(ctx, "/other", [{"q", "hello"}], false, false, false, current_user)|

      routes = files["lib/shop_web/bubble_routes.ex"]
      assert routes =~ ~s(live "/other/:bubble_thing", ShopWeb.OtherLive)

      runtime = files["lib/shop_web/bubble_workflows.ex"]

      assert runtime =~
               "def navigate(ctx, to, params, keep?, replace?, new_tab?, thing \\\\ :none)"

      assert runtime =~ ~s|case String.trim_trailing(page, "/") do|
    end

    test "sends it to the index page under /index (WTF-454)" do
      app =
        app()
        |> with_thing("user")
        |> put_in(["pages", "other", "name"], "index")
        |> put_in(["pages", "home", "name"], "home")

      %{files: files, spec: spec} = render(app, page_data: true)
      nav = FrontendWorkflows.Spec.workflow(spec, "bHome", "wNav")
      assert nav.residue == [] and FrontendWorkflows.Spec.native?(nav)

      assert files["lib/shop_web/live/home_live/workflows.ex"] =~
               ~s|BubbleWorkflows.navigate(ctx, "/", [{"q", "hello"}], false, false, false, current_user)|

      routes = files["lib/shop_web/bubble_routes.ex"]
      assert routes =~ ~s(live "/", ShopWeb.IndexLive)
      assert routes =~ ~s(live "/index/:bubble_thing", ShopWeb.IndexLive)
      refute routes =~ ~s(live "/:bubble_thing")
    end

    test "sends it to the current page (WTF-454)" do
      current = fn app ->
        put_in(
          app,
          ["pages", "home", "workflows", "wUrl", "actions", "0", "properties", "data_to_send"],
          %{"type" => "CurrentUser"}
        )
      end

      typed =
        app() |> current.() |> put_in(["pages", "home", "properties", "page_item_type"], "user")

      %{files: files, spec: spec} = render(typed, page_data: true)
      url = FrontendWorkflows.Spec.workflow(spec, "bHome", "wUrl")
      assert url.residue == [] and FrontendWorkflows.Spec.native?(url)

      assert files["lib/shop_web/live/index_live/workflows.ex"] =~
               ~s|BubbleWorkflows.navigate(ctx, :current, [{"tab", "two"}], true, false, false, current_user)|

      # The page does not load its thing without page data: residue.
      %{spec: spec} = render(typed)

      assert [%{reason: :unsupported_option, detail: %{options: ["data_to_send"]}}] =
               FrontendWorkflows.Spec.workflow(spec, "bHome", "wUrl").steps
               |> hd()
               |> Map.fetch!(:residue)

      # A reusable element's current page is checked at run time.
      card =
        put_in(
          app(),
          ["element_definitions", "card", "workflows", "wCardOpen", "actions", "0"],
          %{
            "id" => "aCardNav",
            "properties" => %{
              "element_id" => "Current page",
              "data_to_send" => %{"type" => "CurrentUser"}
            },
            "type" => "ChangePage"
          }
        )

      %{files: files, spec: spec} = render(card, page_data: true)

      assert FrontendWorkflows.Spec.native?(
               FrontendWorkflows.Spec.workflow(spec, "bCard", "wCardOpen")
             )

      assert files["lib/shop_web/components/reusables/card/workflows.ex"] =~
               ~s|BubbleWorkflows.navigate(ctx, :current, [], false, false, false, current_user)|
    end

    test "is residue while the page does not load its thing" do
      %{spec: spec} = render(with_thing(app(), "user"))
      nav = FrontendWorkflows.Spec.workflow(spec, "bHome", "wNav")

      assert %{reason: :unsupported_option, detail: %{options: ["data_to_send"]}} =
               nav.steps |> hd() |> Map.fetch!(:residue) |> hd()
    end

    test "goes to a page with no type of content as a path segment (WTF-466)" do
      app =
        app()
        |> with_thing("user")
        |> update_in(["pages", "other", "properties"], &Map.delete(&1, "page_item_type"))

      # Bubble appends the data all the same and the page loads (replay):
      # the step runs, its data an encoded segment the page ignores.
      %{files: files, spec: spec} = render(app, page_data: true)
      nav = FrontendWorkflows.Spec.workflow(spec, "bHome", "wNav")
      assert nav.residue == [] and FrontendWorkflows.Spec.native?(nav)

      assert files["lib/shop_web/live/index_live/workflows.ex"] =~
               ~r/BubbleWorkflows.navigate\(\s*ctx,\s*"\/other",[^)]*\{:segment, current_user\}\s*\)/

      # Without page data too: the page reads nothing from it.
      %{spec: spec} = render(app)

      assert FrontendWorkflows.Spec.native?(
               FrontendWorkflows.Spec.workflow(spec, "bHome", "wNav")
             )

      # Every page's route takes the segment, the index page's under /index.
      routes = files["lib/shop_web/bubble_routes.ex"]
      assert routes =~ ~s(live "/index/:bubble_thing", ShopWeb.IndexLive)
      assert routes =~ ~s(live "/other/:bubble_thing", ShopWeb.OtherLive)
      refute routes =~ ~s(live "/:bubble_thing")
    end
  end

  test "a pause is a step of the runtime, never a sleep (WTF-451)", %{files: files} do
    module = files["lib/shop_web/live/index_live/workflows.ex"]
    assert module =~ ~s|BubbleWorkflows.pause(ctx, "aPause2", 30)|

    assert module =~
             ~s|"wPauseCall" => %{run: :wf_w_pause_call, condition: nil, blocked: [], data: false}|

    runtime = files["lib/shop_web/bubble_workflows.ex"]
    assert runtime =~ "def pause(ctx, step, length) do"
    assert runtime =~ "Process.send_after(self(), {:bubble, :resume, frames, now, budget}, delay)"
    refute runtime =~ "Process.sleep"
    refute runtime =~ ":timer.sleep"
  end

  test "a refused click or input change shows a notice without internals (WTF-453)", %{
    files: files
  } do
    runtime = files["lib/shop_web/bubble_workflows.ex"]
    assert runtime =~ ~s|@refused_notice "This action isn't available yet."|
    assert runtime =~ ~s|push_event("bubble:notice", %{text: @refused_notice})|

    hook = files["lib/shop_web/components/bubble.ex"]
    assert hook =~ ~s(id="bubble-notice")
    assert hook =~ ~s(role="status")
    assert hook =~ ~s(aria-live="polite")
    assert hook =~ "message.textContent = text"
    refute hook =~ "innerHTML"
  end

  test "BBCode around dynamic text renders its own tags, values escaped (WTF-450)", %{
    files: files
  } do
    live = files["lib/shop_web/live/index_live.ex"]

    # The literal tags are data around the values; the URL tag stays text.
    assert live =~ ~s|{:b, ["Typed: ", Shop.Bubble.Runtime.display(element_state_bin_get_data)]}|
    assert live =~ ~s|{:i, [Shop.Bubble.Runtime.display(element_state_bhome_custom_label)]}|
    assert live =~ ~s|" [url=https://example.com]u[/url]"|

    template = files["lib/shop_web/live/index_live.html.heex"]
    assert template =~ "<Bubble.bbcode nodes={text_bbold("

    assert template =~
             "TODO(bubble:bBold) text: BBCode [url] around dynamic text is shown as text"

    helpers = files["lib/shop_web/components/bubble.ex"]
    assert helpers =~ "def bbcode(assigns) do"
    refute helpers =~ "raw("
    refute live =~ "raw("
  end

  test "bodies call the runtime; browser-run workflows are JS commands", %{files: files} do
    module = files["lib/shop_web/live/index_live/workflows.ex"]
    assert module =~ "def wf_w_open(js \\\\ %JS{}, scope) do"
    assert module =~ ~s[|> Bubble.show(scope, "bPop")]

    assert module =~
             ~s|BubbleWorkflows.navigate(ctx, "/other", [{"q", "hello"}], false, false, false)|

    assert module =~
             ~s|BubbleWorkflows.set_state(ctx, "aState1", [\n      {[], "bHome", "custom.label_", element_state_bin_get_data}|

    assert module =~
             ~s|defp wf_w_residue__step(2, ctx),\n    do: BubbleWorkflows.not_lowered(ctx, "aRes2", "SendEmail")|

    assert module =~ "# TODO(bubble:action:aRes2) not lowered: unsupported_action"

    card = files["lib/shop_web/components/reusables/card/workflows.ex"]
    assert card =~ "@instances []"
    assert card =~ ~s|BubbleWorkflows.reset(ctx, [], nil, [])|
  end

  test "templates wire clicks, inputs and state reads", %{files: files} do
    page = files["lib/shop_web/live/index_live.html.heex"]
    assert page =~ ~s|phx-click={Workflows.wf_w_open("")}|
    assert page =~ ~s|phx-click={Bubble.push("click", "", "bBtnState")}|

    assert page =~
             ~r/<form\s+id="bubble-input-bIn"\s+phx-change="bubble:change"\s+phx-submit="bubble:change"/

    assert page =~
             ~r/<input\s+type="hidden"\s+name="bubble\[value\]"\s+value="false"\s*\/><label\s+data-bubble-id="bCheck"/

    assert page =~ ~s|{text_blabel(Bubble.state(@bubble_states, "", "bHome", "custom.label_"))}|
    assert page =~ ~r/<\.card\s+data-bubble-id="bInst1"/

    assert page =~
             ~r/scope="bInst1"\s+bubble_states=\{@bubble_states\}\s+bubble_inputs=\{@bubble_inputs\}/

    assert page =~ "<Bubble.runtime />"

    card = files["lib/shop_web/components/reusables/card.html.heex"]
    assert card =~ ~s|<div class={@class} data-bubble-scope={@scope} {@rest}>|
    assert card =~ ~s|phx-click={Bubble.push("click", @scope, "bCardInc")}|
    assert card =~ ~s|phx-click={Workflows.wf_w_card_open(@scope)}|
    assert card =~ ~s|Bubble.state(@bubble_states, @scope, "bCard", "custom.count_")|
    assert card =~ ~r/<input\s+type="hidden"\s+name="bubble\[scope\]"\s+value=\{@scope\}/

    live = files["lib/shop_web/live/index_live.ex"]
    assert live =~ "|> BubbleWorkflows.mount(Workflows)"
    assert live =~ ~s|def handle_event("bubble:" <> _ = event, params, socket)|
    assert live =~ "def handle_info(message, socket) when elem(message, 0) == :bubble"
  end

  test "generated tests carry the plan's workflow subjects", %{
    files: files,
    model: model,
    index: index,
    spec: spec
  } do
    {:ok, plan} = Plan.build(model, index)
    tasks = for t <- plan.tasks, t.kind == :workflow, into: MapSet.new(), do: t.id

    {:ok, quoted} =
      Code.string_to_quoted(files["test/shop_web/bubble_frontend_workflows_test.exs"])

    {_, tags} =
      Macro.prewalk(quoted, [], fn
        {:@, _, [{:tag, _, [[bubble_smoke: tag]]}]} = node, acc -> {node, [tag | acc]}
        node, acc -> {node, acc}
      end)

    native =
      for w <- FrontendWorkflows.Spec.workflows(spec),
          FrontendWorkflows.Spec.native?(w),
          do: w.symbol

    assert Enum.sort(tags) == Enum.sort(native)
    assert Enum.all?(tags, &MapSet.member?(tasks, &1))
  end

  test "without frontend workflows the pages are T5's" do
    app = app()
    {:ok, model} = Model.build(app)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, files} = Phoenix.render(project, module: "Shop", frontend: frontend)

    refute Map.has_key?(files, "lib/shop_web/bubble_workflows.ex")
    refute files["lib/shop_web/live/index_live.ex"] =~ "BubbleWorkflows"
    refute files["lib/shop_web/live/index_live.html.heex"] =~ "phx-click={"
  end

  test "hostile IDs are quoted in generated source, never spliced in" do
    app = app()
    # Two workflow IDs that differ only by a newline and a space.
    app =
      put_in(
        app,
        ["pages", "home", "workflows", "wUrl", "id"],
        HostileIds.hostile("wNav") |> String.replace("\n", " ")
      )

    ids = HostileIds.ids(app)
    %{files: files} = render(HostileIds.rename(app, ids))

    for {path, content} <- files, Path.extname(path) in [".ex", ".exs"] do
      assert {:ok, quoted} = Code.string_to_quoted(content), path

      {_, calls} =
        Macro.prewalk(quoted, [], fn
          {:raise, _, ["injected"]} = node, acc -> {node, [path | acc]}
          node, acc -> {node, acc}
        end)

      assert calls == [], path
    end

    for {path, content} <- files, String.ends_with?(path, ".heex") do
      # Markers are HEEx comments (`comment_safe/1` keeps them closed):
      # what they quote renders nothing.
      code = String.replace(content, ~r/<%!-- TODO\(bubble:.*?--%>/s, "")
      refute code =~ ~s("\#{raise), path
      refute content =~ ~r/<%(?!!-- TODO\(bubble:)/, path
    end

    # Markers are one word each and never collide (review L4): control
    # characters and spaces are percent-encoded, not replaced.
    workflows = markers(files)
    # The page and reusable-element workflows and the backend workflow they schedule.
    assert map_size(workflows) == 30
    assert Enum.all?(Map.values(workflows), &match?([_], &1))

    # The test tags are the plan's subjects, as data.
    {:ok, quoted} =
      Code.string_to_quoted(files["test/shop_web/bubble_frontend_workflows_test.exs"])

    {_, tags} =
      Macro.prewalk(quoted, [], fn
        {:@, _, [{:tag, _, [[bubble_smoke: tag]]}]} = node, acc -> {node, [tag | acc]}
        node, acc -> {node, acc}
      end)

    assert BubbleEx.Index.Symbol.id(:workflow, HostileIds.hostile("wState")) in tags

    # A page ID with a space and a newline is still that page, never the
    # current one (WTF-429): wNav goes to /other, only wUrl to :current.
    module = files["lib/shop_web/live/index_live/workflows.ex"]
    assert module =~ ~s|BubbleWorkflows.navigate(ctx, "/other", [{"q", "hello"}]|
    assert length(String.split(module, "BubbleWorkflows.navigate(ctx, :current")) == 2
  end

  test "go to a page that is gone is residue: the workflow refuses to run (WTF-429)", %{
    files: files,
    spec: spec
  } do
    gone = FrontendWorkflows.Spec.workflow(spec, "bHome", "wNavGone")
    refute FrontendWorkflows.Spec.native?(gone)

    assert [%{residue: []}, %{residue: [%{reason: :unresolved_reference}]}] = gone.steps

    # Only wUrl goes to the current page; wNavGone goes nowhere.
    module = files["lib/shop_web/live/index_live/workflows.ex"]
    assert length(String.split(module, "BubbleWorkflows.navigate(ctx, :current")) == 2
  end
end
