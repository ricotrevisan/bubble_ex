defmodule BubbleEx.Target.Phoenix.VisibilityTest do
  # Visibility conditionals (WTF-477), from the synthetic
  # test/support/target/phoenix/visibility.json.
  # scripts/phoenix_compile_check.sh compiles the output and runs
  # test/support/target/phoenix/visibility_behavior.exs against it.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, Plan}
  alias BubbleEx.Target.Elixir.{Frontend, FrontendWorkflows}
  alias BubbleEx.Target.Phoenix

  @fixture "test/support/target/phoenix/visibility.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp build(app) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
    {:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

    {:ok, backend} =
      BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "Shop")

    {:ok, page_data} = BubbleEx.PageData.build(app, model)

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        backend: backend,
        page_data: page_data
      )

    opts = [
      module: "Shop",
      frontend: frontend,
      expressions: expressions,
      workflows: backend,
      frontend_workflows: spec
    ]

    {:ok, files} = Phoenix.render(project, opts)
    {:ok, ^files} = Phoenix.render(project, opts)

    %{
      files: files,
      model: model,
      index: index,
      project: project,
      frontend: frontend,
      expressions: expressions,
      opts: opts
    }
  end

  setup_all do
    build(app())
  end

  # The opening tag of the element with Bubble ID `id`.
  defp tag(template, id) do
    [tag] = Regex.run(~r/<[.a-z_]+\s[^>]*data-bubble-id="#{id}"[^>]*>/s, template)
    tag
  end

  test "a conditional sets the hidden attribute from a helper, last true state winning", %{
    files: files
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]
    live = files["lib/shop_web/live/index_live.ex"]

    assert tag(template, "bOut") =~ "hidden={!visible_bout(@bubble_viewer)}"
    assert tag(template, "bIn") =~ "hidden={!visible_bin(@bubble_viewer)}"
    # Never a fixed `hidden` class.
    refute tag(template, "bOut") =~ ~r/class="[^"]*\bhidden\b/

    assert live =~ """
             defp visible_bout(current_user) do
               cond do
                 is_nil(current_user) == true -> true
                 true -> false
               end
             end
           """

    # Bubble's order: the last state listed decides, so the clauses are
    # tried from the last; none true keeps the visibility on page load.
    assert live =~ """
             defp visible_border(current_user) do
               cond do
                 not is_nil(current_user) == true -> false
                 is_nil(current_user) == true -> true
                 is_nil(current_user) == true -> false
                 true -> true
               end
             end
           """
  end

  test "a condition reads a custom state through the page's state map", %{files: files} do
    template = files["lib/shop_web/live/index_live.html.heex"]

    # bStyle's one visibility state sets what it has on page load: nothing
    # to evaluate (Elixir 1.20 warns on a constant helper).
    refute tag(template, "bStyle") =~ "hidden"
    refute files["lib/shop_web/live/index_live.ex"] =~ "visible_bstyle"

    assert tag(template, "bFlagged") =~
             ~s|hidden={!visible_bflagged(Bubble.state(@bubble_states, "", "bVis", "custom.flag_"))}|
  end

  test "in a reusable element, the condition's inputs are attributes", %{files: files} do
    card = files["lib/shop_web/components/reusables/card.ex"]
    assert card =~ "attr :bubble_viewer, :any, default: nil"
    assert card =~ "defp visible_bcardt(current_user) do"

    assert files["lib/shop_web/components/reusables/card.html.heex"] =~
             "hidden={!visible_bcardt(@bubble_viewer)}"

    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bMember") =~
             "bubble_viewer={@bubble_viewer}"
  end

  test "a URL parameter read as text is read from the URL the page keeps", %{files: files} do
    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bTabOpen") =~
             ~s|hidden={!visible_btabopen(Map.get(@bubble_url, "tab"))}|

    assert files["lib/shop_web/live/index_live.ex"] =~ ~s|url_parameter_tab == "open"|

    # In a reusable element, from the map its caller passes down.
    assert files["lib/shop_web/components/reusables/card.ex"] =~
             "attr :bubble_url, :any, default: %{}"

    assert files["lib/shop_web/components/reusables/card.html.heex"] =~
             ~s|hidden={!visible_bcardtab(Map.get(@bubble_url, "tab"))}|

    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bMember") =~
             "bubble_url={@bubble_url}"

    # Two levels down: the outer component passes it on.
    assert tag(files["lib/shop_web/components/reusables/card.html.heex"], "bCardBadge") =~
             "bubble_url={@bubble_url}"

    assert files["lib/shop_web/components/reusables/badge.html.heex"] =~
             ~s|hidden={!visible_bbadgetab(Map.get(@bubble_url, "tab"))}|
  end

  test "a text shows a URL parameter as its type; a list one is not compiled", %{
    files: files
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]
    assert template =~ ~s|{text_btabtext(Map.get(@bubble_url, "tab"))}|

    # A number (WTF-508), read as Bubble reads one.
    assert template =~
             ~s|{text_btabcount(Bubble.url_value(@bubble_url, @bubble_segments, {:query, "n"}, "number"))}|

    assert template =~ "TODO(bubble:bTabMany) text: dynamic value not compiled"
    refute template =~ ~s|Map.get(@bubble_url, "tags")|
  end

  test "a URL parameter read as a list stays marked; a yes/no one compiles", %{} do
    list = %{
      "type" => "GetParamFromUrl",
      "properties" => %{
        "parameter_name" => %{"type" => "TextExpression", "entries" => %{"0" => "tab"}},
        "is_list" => true
      },
      "next" => %{
        "type" => "Message",
        "name" => "is_not_empty"
      }
    }

    template =
      app()
      |> put_in(["pages", "index", "elements", "bTabOpen", "states", "0", "condition"], list)
      |> build()
      |> Map.fetch!(:files)
      |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

    assert template =~
             "TODO(bubble:bTabOpen) visibility: 1 conditional not lowered (it does not compile)"

    condition = %{
      "type" => "GetParamFromUrl",
      "properties" => %{
        "parameter_name" => %{"type" => "TextExpression", "entries" => %{"0" => "on"}},
        "value" => "boolean"
      },
      "next" => %{"type" => "Message", "name" => "is_true"}
    }

    template =
      app()
      |> put_in(["pages", "index", "elements", "bTabOpen", "states", "0", "condition"], condition)
      |> build()
      |> Map.fetch!(:files)
      |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

    assert tag(template, "bTabOpen") =~
             ~s|Bubble.url_value(@bubble_url, @bubble_segments, {:query, "on"}, "boolean")|
  end

  test "not visible on page load is the hidden attribute, which workflow steps change", %{
    files: files
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]
    assert tag(template, "bWf") =~ ~r/\shidden[\s>]/
    refute tag(template, "bWf") =~ ~r/class="[^"]*\bhidden\b/

    css = files["assets/css/bubble.css"]
    assert css =~ "[data-bubble-id][hidden] { display: none; }"

    # A step on an element (not an overlay) is kept even when it changes
    # nothing now: from then on it, not the conditionals, decides.
    helpers = files["lib/shop_web/components/bubble.ex"]
    assert helpers =~ ~s|if (!overlay) this.js().removeAttribute(el, "hidden")|

    assert helpers =~
             ~s|if (!el.getAttribute("data-overlay")) this.js().setAttribute(el, "hidden", "")|
  end

  test "a conditional that does not compile is marked and residue, never dropped", %{
    files: files,
    frontend: frontend,
    expressions: expressions,
    model: model,
    index: index
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]

    for id <- ~w(bBad bWidth) do
      assert template =~
               "<%!-- TODO(bubble:#{id}) visibility: 1 conditional not lowered " <>
                 "(it does not compile); shown as on page load --%>"
    end

    # As on page load: bBad hidden, bWidth (Current Page Width) shown.
    assert tag(template, "bBad") =~ ~r/\shidden[\s>]/
    refute tag(template, "bWidth") =~ "hidden"

    residue = Frontend.residue(frontend, expressions)

    assert residue == [
             %{subject: "element:bWidth", reason: :element_condition, detail: %{states: 1}},
             %{subject: "element:bBad", reason: :element_condition, detail: %{states: 1}}
           ]

    {:ok, plan} = Plan.build(model, index, frontend, [], residue: residue)
    page = Enum.find(plan.tasks, &(&1.id == "surface:page/bVis"))
    assert Enum.any?(page.residue, &(&1.reason == :element_condition))
  end

  test "the report counts compiled, marked and other conditional properties", %{
    project: project,
    opts: opts
  } do
    {:ok, report} = Phoenix.frontend_report(project, Keyword.delete(opts, :frontend_workflows))

    # Without the workflows the page keeps no custom state, input value or
    # URL and loads no data: bFlagged's, bOpen's, bCellNoProject's,
    # bHasProject's, bTabOpen's, bCardTab's and bBadgeTab's conditionals
    # are marked too.
    assert %{
             "visibility_conditions_compiled" => 8,
             "visibility_conditions_marked" => 9,
             "conditions_other_properties" => 2
           } = report
  end

  test "a condition reading what the page does not keep is marked", %{files: files} do
    template =
      app()
      |> put_in(
        ["pages", "index", "elements", "bIn", "states", "0", "condition"],
        %{"type" => "GetParamFromUrl", "properties" => %{"parameter_name" => "tab"}}
      )
      |> build()
      |> Map.fetch!(:files)
      |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

    assert template =~
             "TODO(bubble:bIn) visibility: 1 conditional not lowered (it does not compile)"

    assert tag(template, "bIn") =~ ~r/\shidden[\s>]/
    refute files["lib/shop_web/live/index_live.ex"] =~ "defp visible_bin(url_parameter"

    # An element's built-in state compiles, but no page keeps it.
    template =
      app()
      |> put_in(
        ["pages", "index", "elements", "bIn", "states", "0", "condition"],
        %{
          "type" => "GetElement",
          "properties" => %{"element_id" => "bSetFlag"},
          "next" => %{"type" => "Message", "name" => "is_hovered"}
        }
      )
      |> build()
      |> Map.fetch!(:files)
      |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

    assert template =~
             "TODO(bubble:bIn) visibility: 1 conditional not lowered (it reads a value " <>
               "the page does not keep: element_state:is_hovered)"

    assert tag(template, "bIn") =~ ~r/\shidden[\s>]/
  end

  test "overlays keep their workflow model", %{} do
    app =
      put_in(app(), ["pages", "index", "elements", "bPop"], %{
        "id" => "bPop",
        "type" => "Popup",
        "properties" => %{"height" => 100, "width" => 200, "order" => 20},
        "states" => %{
          "0" => %{
            "condition" => %{
              "type" => "CurrentUser",
              "next" => %{"type" => "Message", "name" => "logged_in"}
            },
            "properties" => %{"is_visible" => true}
          }
        }
      })

    %{files: files, frontend: frontend, expressions: expressions} = build(app)
    template = files["lib/shop_web/live/index_live.html.heex"]

    assert template =~
             "TODO(bubble:bPop) visibility: 1 conditional not lowered (an overlay: workflows"

    refute template =~ "visible_bpop"
    assert Enum.any?(Frontend.residue(frontend, expressions), &(&1.subject == "element:bPop"))
  end

  test "an element a breakpoint shows keeps its hidden class; its conditionals are marked", %{
    project: project,
    frontend: frontend,
    expressions: expressions
  } do
    rule = %{"media" => %{"operator" => "<", "width" => 600}, "paint" => %{"display" => "revert"}}

    put_rule = fn
      %{source: %{bubble_id: id}} = node when id in ["bOut", "bWf"] ->
        %{node | responsive: [rule]}

      node ->
        node
    end

    pages =
      Enum.map(frontend.pages, fn page ->
        %{page | children: Enum.map(page.children, put_rule)}
      end)

    {:ok, files} =
      Phoenix.render(project,
        module: "Shop",
        frontend: %{frontend | pages: pages},
        expressions: expressions
      )

    template = files["lib/shop_web/live/index_live.html.heex"]

    for id <- ~w(bOut bWf) do
      assert tag(template, id) =~ ~r/class="[^"]*\bhidden\b/
      refute String.replace(tag(template, id), ~r/class="[^"]*"/, "") =~ "hidden"
    end

    assert template =~
             "TODO(bubble:bOut) visibility: 1 conditional not lowered (a breakpoint also shows it)"
  end

  test "a condition reads the current user as the runtime refreshes it", %{files: files} do
    template = files["lib/shop_web/live/index_live.html.heex"]
    assert tag(template, "bAdmin") =~ "hidden={!visible_badmin(@bubble_viewer)}"
    refute files["lib/shop_web/live/index_live.ex"] =~ "assign(:bubble_viewer"

    helpers = files["lib/shop_web/components/bubble.ex"]
    assert helpers =~ "def viewer_loads, do: []"

    runtime = files["lib/shop_web/bubble_workflows.ex"]
    assert runtime =~ "def refresh_viewer(socket)"
    assert runtime =~ "Ash.get(resource, id, actor: actor, not_found_error?: false)"
    assert runtime =~ "defp unforbidden(%Ash.ForbiddenField{}), do: nil"
  end

  test "the relationships a condition reads are loaded with the page data", %{files: files} do
    index = files["lib/shop_web/live/index_live/workflows.ex"]
    assert index =~ ~r/element: "bTasks",.*?loads: \[\["project"\]\]/s

    task = files["lib/shop_web/live/task_live/workflows.ex"]
    assert task =~ ~r/element: "bTaskGroup",.*?loads: \[\["project"\]\]/s

    # ... and a condition helper refuses a relationship that was not.
    live = files["lib/shop_web/live/index_live.ex"]
    assert live =~ ~s|Bubble.loaded!(cell_thing_btasks, [["project"]])|

    assert files["lib/shop_web/live/task_live.ex"] =~
             ~s|Bubble.loaded!(element_state_btaskgroup_get_group_data, [["project"]])|

    assert files["lib/shop_web/components/bubble.ex"] =~
             "defp loaded_path!(%Ash.NotLoaded{}, _rest, path)"
  end

  test "a condition reads an input's value from the page's input map", %{files: files} do
    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bOpen") =~
             ~s|hidden={!visible_bopen(Bubble.input(@bubble_inputs, "", "bName"))}|
  end

  test "repeating group cells are keyed by their item", %{files: files} do
    assert files["lib/shop_web/live/index_live.html.heex"] =~
             ~s|id={Bubble.cell_id("", "bTasks", cell_btasks, cell_btasks_i)}|
  end
end
