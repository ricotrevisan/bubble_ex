defmodule BubbleEx.Target.Elixir.FrontendWorkflowsVisibilityTest do
  # An element's "is visible" in a workflow's or a step's "Only when", or a
  # "Do when" condition (WTF-588): the visibility the page computes for it
  # (`ElementVisibility`, WTF-578), from what holds the condition when it
  # is tested. test/support/target/phoenix/visibility.json, whose
  # visibility_behavior.exs runs the same workflows in a generated project.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Target.Elixir.Frontend, as: ElixirFrontend
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/visibility.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp spec(app, visibility? \\ true) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)

    visibility =
      if visibility?,
        do: [
          element_visibility: ElixirFrontend.visibility_index(app, model, frontend)
        ],
        else: []

    {:ok, spec} =
      FrontendWorkflows.map(
        lowered,
        project,
        [namespace: "PhxCheck", frontend: frontend] ++ visibility
      )

    spec
  end

  defp workflow(spec, id), do: spec |> Spec.workflows() |> Enum.find(&(&1.workflow == id))

  defp residue(w), do: w.residue ++ Enum.flat_map(w.steps, & &1.residue)

  defp binds(%{bindings: bindings}), do: bindings |> Enum.map(& &1.bind) |> Enum.uniq()

  defp vis(element, state),
    do: %{
      "type" => "GetElement",
      "properties" => %{"element_id" => element},
      "next" => %{"type" => "Message", "name" => state}
    }

  # Sets custom state "seen_" of `element` (the page, or the reusable
  # element) to yes.
  defp set_seen(id, element, condition \\ nil) do
    props = %{"custom_state" => "custom.seen_", "element_id" => element, "value" => true}
    props = if condition, do: Map.put(props, "condition", condition), else: props
    %{"id" => id, "type" => "SetCustomState", "properties" => props}
  end

  defp put_workflow(app, path, id, workflow),
    do:
      update_in(app, path ++ ["workflows"], &Map.put(&1 || %{}, id, Map.put(workflow, "id", id)))

  setup_all do
    %{spec: spec(app())}
  end

  test "a click's condition reads the group's visibility from its conditionals", %{spec: spec} do
    w = workflow(spec, "wVisOnly")
    assert residue(w) == []
    # bVisG is shown for a signed-in user: the condition reads the user.
    assert binds(w.condition) == [:actor]
    assert Spec.native?(w)
  end

  test "a step's condition reads a child's visibility through its group", %{spec: spec} do
    w = workflow(spec, "wVisStep")
    assert residue(w) == []
    [step] = w.steps
    assert binds(step.condition) == [:actor]
  end

  test "a Do when condition reads it too", %{spec: spec} do
    w = workflow(spec, "wVisDo")
    assert residue(w) == []
    assert binds(w.condition) == [:actor]
  end

  test "an element a step shows stays the browser's", %{spec: spec} do
    w = workflow(spec, "wVisTouched")
    assert w.condition == nil

    assert [%{reason: :unavailable_input, detail: %{inputs: ["element_state:is_visible"]}}] =
             residue(w)

    refute Spec.native?(w)
  end

  test "without the visibility index, the read is residue as before" do
    spec = spec(app(), false)

    for id <- ~w(wVisOnly wVisStep wVisDo) do
      assert [%{reason: :unavailable_input, detail: %{inputs: [input]}}] =
               spec |> workflow(id) |> residue()

      assert input in ["element_state:is_visible", "element_state:isnt_visible"]
    end
  end

  test "what holds the clicked element is visible for its condition, not for its steps" do
    # bVisGT is inside bVisG: as it is clicked, bVisG is shown. A step runs
    # later (an earlier step may hide it): the page holds it.
    spec =
      app()
      |> put_workflow(["pages", "index"], "wVisHeld", %{
        "type" => "ButtonClicked",
        "properties" => %{"element_id" => "bVisGT", "condition" => vis("bVisG", "is_visible")},
        "actions" => %{"0" => set_seen("aVisHeld1", "bVis", vis("bVisG", "is_visible"))}
      })
      |> spec()

    w = workflow(spec, "wVisHeld")
    assert residue(w) == []
    assert w.condition.bindings == []
    assert w.condition.source =~ "true"
    [step] = w.steps
    assert binds(step.condition) == [:actor]
  end

  test "in a reusable element, only a click's own condition reads it" do
    card = ["element_definitions", "card"]

    spec =
      app()
      |> update_in(card ++ ["elements"], fn elements ->
        Map.put(elements, "bCardBtn", %{
          "id" => "bCardBtn",
          "type" => "Button",
          "properties" => %{"height" => 40, "width" => 300, "order" => 4}
        })
      end)
      |> update_in(card, &Map.put(&1, "custom_states", %{"seen_" => %{"value" => "boolean"}}))
      |> put_workflow(card, "wCardClick", %{
        "type" => "ButtonClicked",
        "properties" => %{"element_id" => "bCardBtn", "condition" => vis("bCardT", "is_visible")},
        "actions" => %{"0" => set_seen("aCardClick1", "bCard", vis("bCardT", "is_visible"))}
      })
      |> put_workflow(card, "wCardDo", %{
        "type" => "ConditionTrue",
        "properties" => %{"condition" => vis("bCardT", "is_visible"), "run_when" => "every_time"},
        "actions" => %{"0" => set_seen("aCardDo1", "bCard")}
      })
      |> spec()

    click = workflow(spec, "wCardClick")
    # The instance holds the button and bCardT: shown as it is clicked.
    assert click.condition != nil
    assert binds(click.condition) == [:actor]
    # Its step: the instance's own visibility is its host page's.
    assert [%{reason: :unavailable_input, detail: %{inputs: ["element_state:is_visible"]}}] =
             residue(click)

    assert [%{reason: :unavailable_input, detail: %{inputs: ["element_state:is_visible"]}}] =
             spec |> workflow("wCardDo") |> residue()
  end

  test "deterministic", %{spec: spec} do
    assert spec(app()) == spec
  end
end
