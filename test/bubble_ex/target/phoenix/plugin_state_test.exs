defmodule BubbleEx.Target.Phoenix.PluginStateTest do
  # A plugin element is not migrated (a placeholder, WTF-520), so nothing on
  # the page holds its states. What reads one is typed from the plugin's
  # definition and left out with that reason, never read as empty
  # (synthetic app and plugin, all invented).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, PageData}
  alias BubbleEx.Plugins.States
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/plugin_states.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()
  defp without_definitions(app), do: States.delete(app)

  defp files(app) do
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

    opts = [
      name: "Shop",
      frontend: frontend,
      expressions: compiled,
      workflows: workflows,
      frontend_workflows: spec
    ]

    {:ok, files} = Phoenix.render(project, opts)
    {:ok, report} = Phoenix.frontend_report(project, opts)

    {files["lib/shop_web/live/index_live.html.heex"], report, spec}
  end

  test "a conditional reading a plugin element's state is not lowered, with that reason" do
    {page, report, _spec} = files(app())

    assert page =~
             "TODO(bubble:bTimerShown) visibility: 1 conditional not lowered (it reads the " <>
               "state of a plugin element, which is not migrated: element_state:get_AAB); " <>
               "shown as on page load"

    refute page =~ ~r/visible_btimershown/

    # A state the plugin does not declare stays untyped: it does not compile.
    assert page =~
             "TODO(bubble:bTimerUndeclared) visibility: 1 conditional not lowered (it does not compile)"

    assert %{"visibility_conditions_plugin_state" => 1} = report
  end

  test "an \"isn't clickable\" conditional reading a plugin element's state stays disabled" do
    {page, _report, _spec} = files(app())

    assert page =~
             "TODO(bubble:bTimerStop) isn't clickable: 1 conditional not lowered (it reads the " <>
               "state of a plugin element, which is not migrated: element_state:get_AAB); disabled"

    [open] = Regex.run(~r/<button\s+data-bubble-id="bTimerStop"[^>]*>/s, page)
    assert open =~ ~r/\sdisabled\b/
  end

  test "a conditional that only sets the page-load visibility is dropped, whatever it reads" do
    {page, report, _spec} = files(app())

    refute page =~ "TODO(bubble:bTimerAlways) visibility"
    refute page =~ ~r/visible_btimeralways/
    [open] = Regex.run(~r/<p\s+data-bubble-id="bTimerAlways"[^>]*>/s, page)
    refute open =~ "hidden"
    # bTimerShown is marked; bTimerAlways is compiled (constant), not marked.
    assert %{"visibility_conditions_plugin_state" => 1} = report
  end

  test "a value reading a plugin element's state is left out, never empty" do
    {page, report, _spec} = files(app())

    # Its type comes from the element's own type field (`custom_data_AAF`).
    assert page =~
             "TODO(bubble:bTimerStatus) text: reads the state of a plugin element, which is " <>
               "not migrated (element_state:get_AAD)"

    assert page =~ "Text not migrated: reads the state of a plugin element, which is not migrated"
    assert report["bindings_marked"] == 1
  end

  test "a workflow whose condition reads a plugin element's state is refused" do
    {_page, _report, spec} = files(app())

    assert [%{reason: :unavailable_input}] =
             spec |> Spec.residue() |> Enum.filter(&String.ends_with?(&1.subject, "wGo"))
  end

  test "without the plugin's definition, the reads do not compile, as before" do
    {page, report, spec} = files(without_definitions(app()))

    assert page =~
             "TODO(bubble:bTimerShown) visibility: 1 conditional not lowered (it does not compile)"

    assert page =~ "Text not migrated: expression does not compile"
    assert %{"visibility_conditions_plugin_state" => 0} = report

    assert [%{reason: :uncompiled_expression}] =
             spec |> Spec.residue() |> Enum.filter(&String.ends_with?(&1.subject, "wGo"))
  end
end
