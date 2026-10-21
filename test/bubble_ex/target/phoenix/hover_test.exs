defmodule BubbleEx.Target.Phoenix.HoverTest do
  # "is hovered" conditionals lowered to the browser's hover (WTF-590):
  # the page's stylesheet applies them, the server never decides them
  # (synthetic app, all invented; scripts/hover_browser_check.sh hovers
  # the same app in a browser).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, PageData}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/hover.json"

  setup_all do
    app = @fixture |> File.read!() |> Jason.decode!()
    {:ok, model} = Model.build(app)
    {:ok, page_data} = PageData.build(app, model)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        page_data: page_data
      )

    {:ok, compiled} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
    {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

    {:ok, files} =
      Phoenix.render(project,
        name: "Shop",
        frontend: frontend,
        expressions: compiled,
        workflows: workflows,
        frontend_workflows: spec
      )

    %{
      page: files["lib/shop_web/live/index_live.html.heex"],
      css: files["assets/css/bubble_residue.css"]
    }
  end

  defp tag(page, id) do
    [open] = Regex.run(~r/<[a-z]+\s+data-bubble-id="#{id}"[^>]*>/s, page)
    open
  end

  test "an element's own hover paints it", %{css: css} do
    assert css =~
             ~s|[data-bubble-id="bCardTitle"]:where(:hover) {\n  color: rgba(200, 0, 0, 1);\n}|
  end

  test "a group's hover shows an element it holds, over its hidden attribute", %{
    css: css,
    page: page
  } do
    assert css =~
             ~s|:where([data-bubble-id="bCard"]:hover) [data-bubble-id="bCardTools"],\n| <>
               ~s|:where([data-bubble-id="bCard"]:hover) [data-bubble-id="bCardTools"][hidden] {\n| <>
               "  display: flex;\n  visibility: visible;\n}"

    # Hidden on page load, its contents rendered for the browser to show.
    assert tag(page, "bCardTools") =~ ~r/\shidden\b/
    assert page =~ ~s(data-bubble-id="bCardToolsText")
    refute page =~ "TODO(bubble:bCardTools)"

    # A Text has no display of its own: shown as a block, not `revert`
    # (the browser's `display: none` of a hidden element).
    assert css =~
             ~s|:where([data-bubble-id="bZero"]:hover) [data-bubble-id="bZeroShown"][hidden] {\n| <>
               "  display: block;"
  end

  test "a sibling's and a child's hover", %{css: css} do
    assert css =~
             ~s|:where([data-bubble-id="bCard"]:has([data-bubble-id="bCardTitle"]:hover)) | <>
               ~s|[data-bubble-id="bCardDot"] {\n  background: rgba(0, 0, 200, 1);\n}|

    assert css =~
             ~s|[data-bubble-id="bRow"]:where(:has([data-bubble-id="bRowIcon"]:hover)) {\n| <>
               "  background: rgba(0, 150, 0, 1);\n}"
  end

  test "nothing hover-lowered is kept on the server", %{page: page} do
    for id <- ~w(bcardtitle bcardtools bcarddot brow bzeroshown) do
      refute page =~ "element_state_#{id}_is_hovered", id
      refute page =~ "visible_#{id}", id
    end
  end

  test "a hover with another condition, or before a later visibility state, stays marked",
       %{page: page, css: css} do
    assert page =~
             "TODO(bubble:bComboVis) visibility: 1 conditional not lowered (it reads a value " <>
               "the page does not keep: element_state:is_hovered)"

    assert page =~
             "TODO(bubble:bOrder) visibility: 2 conditionals not lowered (it reads a value " <>
               "the page does not keep: element_state:is_hovered)"

    refute css =~ ~s([data-bubble-id="bComboVis"])
    refute css =~ ~s([data-bubble-id="bOrder"]:)
  end

  test "another element's \"is visible\" of an element a hover shows is not decided on the server",
       %{page: page} do
    assert page =~
             "TODO(bubble:bToolsEcho) visibility: 1 conditional not lowered (it reads a value " <>
               "the page does not keep: element_state:is_visible)"
  end
end
