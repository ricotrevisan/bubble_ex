defmodule BubbleEx.Target.Elixir.FrontendWorkflowsVisibilityTest do
  # An element's "is visible" in a page's workflow or step "Only when", or
  # "Do when" condition (WTF-588): the visibility the page computes for it
  # (`ElementVisibility`, WTF-578), folded up to the page.
  # test/support/target/phoenix/visibility.json, whose
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

  test "the clicked element is not taken as shown: its condition decides what holds it" do
    # bVisGT is inside bVisG. The server never checks that a click's
    # element is shown (a stale or forged click), so "Only when bVisG is
    # visible" reads bVisG's conditionals, for the click and its steps.
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
    assert binds(w.condition) == [:actor]
    [step] = w.steps
    assert binds(step.condition) == [:actor]
  end

  test "another event's condition reads it too" do
    spec =
      app()
      |> put_workflow(["pages", "index"], "wVisLoad", %{
        "type" => "PageLoaded",
        "properties" => %{"condition" => vis("bVisGT", "isnt_visible")},
        "actions" => %{"0" => set_seen("aVisLoad1", "bVis")}
      })
      |> spec()

    w = workflow(spec, "wVisLoad")
    assert residue(w) == []
    assert binds(w.condition) == [:actor]
  end

  test "a popup's open state, and a repeating group's is loading, stay residue" do
    spec =
      app()
      |> put_workflow(["pages", "index"], "wVisPop", %{
        "type" => "ButtonClicked",
        "properties" => %{"element_id" => "bVisOnly", "condition" => vis("bOvPop", "is_visible")},
        "actions" => %{"0" => set_seen("aVisPop1", "bVis")}
      })
      |> put_workflow(["pages", "index"], "wVisPopIn", %{
        "type" => "ButtonClicked",
        "properties" => %{"element_id" => "bVisOnly", "condition" => vis("bOvPopT", "is_visible")},
        "actions" => %{"0" => set_seen("aVisPopIn1", "bVis")}
      })
      # bLoading is shown while a repeating group "is loading": a constant
      # no on the page, not compiled for a workflow (WTF-588).
      |> put_workflow(["pages", "index"], "wVisLoading", %{
        "type" => "ButtonClicked",
        "properties" => %{
          "element_id" => "bVisOnly",
          "condition" => vis("bLoading", "is_visible")
        },
        "actions" => %{"0" => set_seen("aVisLoading1", "bVis")}
      })
      |> spec()

    for id <- ~w(wVisPop wVisPopIn wVisLoading) do
      w = workflow(spec, id)
      assert w.condition == nil

      assert [%{reason: :unavailable_input, detail: %{inputs: ["element_state:is_visible"]}}] =
               residue(w)
    end
  end

  defp card_workflows(app) do
    card = ["element_definitions", "card"]

    app
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
  end

  defp residue_inputs(w), do: w |> residue() |> Enum.flat_map(& &1.detail.inputs) |> Enum.uniq()

  describe "in a reusable element (WTF-605)" do
    test "a read goes through the instance's visibility, which the page computes", %{spec: spec} do
      # bSpotA shows once the page's flag is set, bSpotB always.
      w = workflow(spec, "wSpotDo")
      assert residue(w) == []
      assert binds(w.condition) == [{:instance_visible, %{data?: false}}]
      assert Spec.native?(w)

      assert %{host: "bVis", visible: %{bindings: [%{bind: {:state, key}}]}} =
               spec.visible["bSpotA"]

      assert key == %{path: [], element: "bVis", state: "custom.flag_"}
      assert %{host: "bVis", visible: %{source: "true", bindings: []}} = spec.visible["bSpotB"]
    end

    test "an element of it reads its own conditionals and the instance's", %{spec: spec} do
      w = workflow(spec, "wSpotClick")
      assert residue(w) == []
      assert binds(w.condition) == [:actor, {:instance_visible, %{data?: false}}]
    end

    test "the clicked element's instance is not taken as shown: the condition decides it" do
      # A click on bCardBtn names its instance; the condition still reads
      # the instance's visibility from the page, and bCardT's own.
      spec = app() |> card_workflows() |> spec()

      for id <- ~w(wCardClick wCardDo) do
        w = workflow(spec, id)
        assert residue(w) == []
        assert binds(w.condition) == [:actor, {:instance_visible, %{data?: false}}]
      end

      [step] = workflow(spec, "wCardClick").steps
      assert binds(step.condition) == [:actor, {:instance_visible, %{data?: false}}]
    end

    test "a reusable element two levels down reads its hosts' visibility too" do
      badge = ["element_definitions", "badge"]

      spec =
        app()
        |> update_in(badge, &Map.put(&1, "custom_states", %{"seen_" => %{"value" => "boolean"}}))
        |> put_workflow(badge, "wBadgeDo", %{
          "type" => "ConditionTrue",
          "properties" => %{
            "condition" => vis("bBadge", "is_visible"),
            "run_when" => "every_time"
          },
          "actions" => %{"0" => set_seen("aBadgeDo1", "bBadge")}
        })
        |> spec()

      w = workflow(spec, "wBadgeDo")
      assert residue(w) == []
      assert binds(w.condition) == [{:instance_visible, %{data?: false}}]
      # bCardBadge in the card, the card's instance on the page.
      assert %{host: "bCard"} = spec.visible["bCardBadge"]
      assert %{host: "bVis"} = spec.visible["bMember"]
    end

    test "an instance a step shows or hides keeps the reads residue" do
      spec =
        app()
        |> put_workflow(["pages", "index"], "wSpotHide", %{
          "type" => "ButtonClicked",
          "properties" => %{"element_id" => "bVisOnly"},
          "actions" => %{
            "0" => %{
              "id" => "aSpotHide1",
              "type" => "HideElement",
              "properties" => %{"element_id" => "bSpotB"}
            }
          }
        })
        |> spec()

      for id <- ~w(wSpotDo wSpotClick) do
        w = workflow(spec, id)
        assert w.condition == nil
        assert residue_inputs(w) == ["element_state:is_visible"]
      end

      refute Map.has_key?(spec.visible, "bSpotA")
    end

    test "a reusable element its own steps show or hide keeps the reads residue" do
      spot = ["element_definitions", "spot"]

      spec =
        app()
        |> put_workflow(spot, "wSpotHideSelf", %{
          "type" => "ButtonClicked",
          "properties" => %{"element_id" => "bSpotBtn"},
          "actions" => %{
            "0" => %{
              "id" => "aSpotHideSelf1",
              "type" => "HideElement",
              "properties" => %{"element_id" => "bSpot"}
            }
          }
        })
        |> spec()

      w = workflow(spec, "wSpotDo")
      assert w.condition == nil
      assert residue_inputs(w) == ["element_state:is_visible"]
    end

    test "an instance in a repeating group's cell keeps the reads residue" do
      spec =
        app()
        |> update_in(["pages", "index", "elements", "bTasks", "elements"], fn elements ->
          Map.put(elements, "bSpotC", %{
            "id" => "bSpotC",
            "type" => "CustomElement",
            "properties" => %{
              "custom_id" => "bSpot",
              "height" => 160,
              "width" => 300,
              "order" => 9
            }
          })
        end)
        |> spec()

      w = workflow(spec, "wSpotDo")
      assert w.condition == nil
      assert residue_inputs(w) == ["element_state:is_visible"]
    end

    test "an instance whose conditional does not bind for a workflow keeps the reads residue" do
      # "is hovered" is a state the page does not keep.
      hovered = %{
        "next" => %{"name" => "is_hovered", "type" => "Message"},
        "properties" => %{"element_id" => "bVisOnly"},
        "type" => "GetElement"
      }

      spec =
        app()
        |> put_in(["pages", "index", "elements", "bSpotB", "states"], %{
          "0" => %{
            "condition" => hovered,
            "properties" => %{"is_visible" => false},
            "type" => "State"
          }
        })
        |> spec()

      w = workflow(spec, "wSpotDo")
      assert w.condition == nil
      assert residue_inputs(w) == ["element_state:is_visible"]
    end

    test "a reusable element with no instance keeps the reads residue" do
      spec =
        app()
        |> update_in(["pages", "index", "elements"], &Map.drop(&1, ["bSpotA", "bSpotB"]))
        |> spec()

      w = workflow(spec, "wSpotDo")
      assert w.condition == nil
      assert residue_inputs(w) == ["element_state:is_visible"]
      assert spec.visible == %{}
    end

    test "without the visibility index, the reads are residue as before" do
      spec = spec(app(), false)

      for id <- ~w(wSpotDo wSpotClick) do
        assert spec |> workflow(id) |> residue_inputs() == ["element_state:is_visible"]
      end

      assert spec.visible == %{}
    end
  end

  test "deterministic", %{spec: spec} do
    assert spec(app()) == spec
  end
end
