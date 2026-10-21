defmodule BubbleEx.Target.Phoenix.WorkaroundsTest do
  # A value holder lowered to page state (WTF-586) renders as its own empty
  # element: its contents go, its value stays the page's
  # (BubbleEx.Test.WorkaroundsFixture, all invented).
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Error, Findings, Index, Model, PageData}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Workflows.Frontend

  import BubbleEx.Test.WorkaroundsFixture, only: [app: 0]

  @now ~U[2026-10-21 00:00:00Z]

  defp render(decide \\ fn _findings -> [] end) do
    app = app()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)
    decisions = decide.(findings)
    {:ok, resolved} = Decision.resolve(decisions, findings, index: index, now: @now)
    applied = Decision.applicable(resolved, findings)

    {:ok, project} =
      BubbleEx.Target.Ash.map(model, applied,
        privacy: :omit,
        index: index,
        decisions_sha256: Decision.decisions_sha256(decisions)
      )

    # Read as editor JSON (a Buildprint v5 workspace), as Bubble sizes it.
    {:ok, frontend} =
      app |> BubbleEx.Frontend.EditorGeometry.mark() |> BubbleEx.Frontend.normalize()

    {:ok, page_data} = PageData.build(app, model)
    {:ok, lowered} = Frontend.build(app, model, index)

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        page_data: page_data
      )

    {:ok, backend} = BubbleEx.Workflows.Backend.build(app, model, index)
    {:ok, workflows} = BubbleEx.Target.Ash.Workflows.map(backend, project, namespace: "Shop")

    opts = [
      name: "Shop",
      frontend: frontend,
      workflows: workflows,
      frontend_workflows: spec,
      workarounds: Enum.filter(applied, &(&1.transform == :lower_workaround))
    ]

    {:ok, files} = Phoenix.render(project, opts)
    {:ok, report} = Phoenix.frontend_report(project, opts)
    {files["lib/shop_web/live/index_live.html.heex"], report}
  end

  defp tag(page, id) do
    [open] = Regex.run(~r/<div\s+data-bubble-id="#{id}"[^>]*>/s, page)
    open
  end

  test "a sure value holder renders as its own element, without its contents" do
    {page, report} = render()

    assert tag(page, "eVars") =~ ~s(data-bubble-workaround="page_state")
    refute page =~ ~s(data-bubble-id="eList")
    # …and eState, a hidden group holding a custom state.
    assert tag(page, "eState") =~ ~s(data-bubble-workaround="page_state")
    assert report["workaround_page_state"] == 2
  end

  test "an owner question keeps the markup until the owner answers" do
    {page, _report} = render()
    refute tag(page, "eHolder") =~ "data-bubble-workaround"
    assert page =~ ~s(data-bubble-id="eInside")

    answer = fn findings ->
      f = Enum.find(findings, &(&1.subject == %{element: "eHolder"}))
      {:ok, d} = Decision.for_finding(f, :modify, %{"option" => "page_state"})
      [d]
    end

    {page, report} = render(answer)
    assert tag(page, "eHolder") =~ ~s(data-bubble-workaround="page_state")
    refute page =~ ~s(data-bubble-id="eInside")
    assert report["workaround_page_state"] == 3
  end

  test "an owner's keep overrides the default" do
    keep = fn findings ->
      f = Enum.find(findings, &(&1.subject == %{element: "eVars"}))
      {:ok, d} = Decision.for_finding(f, :modify, %{"option" => "keep"})
      [d]
    end

    {page, _report} = render(keep)
    refute tag(page, "eVars") =~ "data-bubble-workaround"
    # eList, its contents, is a sure holder of its own: lowered, but empty anyway.
    assert tag(page, "eList") =~ ~s(data-bubble-workaround="page_state")
  end

  test "other lowerings keep the markup for now" do
    {page, _report} = render()
    refute tag(page, "eGap") =~ "data-bubble-workaround"
  end

  test "workarounds: takes applied lower_workaround decisions only" do
    {:ok, model} = Model.build(app())
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app())

    assert {:error, %Error{kind: :invalid_input}} =
             Phoenix.render(project, name: "Shop", frontend: frontend, workarounds: [:x])

    assert {:error, %Error{kind: :invalid_input}} =
             Phoenix.render(project, name: "Shop", frontend: frontend, workarounds: :x)
  end
end
