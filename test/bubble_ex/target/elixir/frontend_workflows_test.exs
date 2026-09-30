defmodule BubbleEx.Target.Elixir.FrontendWorkflowsTest do
  # Binding lowered page and reusable-element workflows to LiveView
  # (WTF-372): compiled values, where each read comes from, what the page
  # tracks, browser-run and data workflows, and this target's residue.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Workflows.Frontend

  @fixture "test/support/target/phoenix/frontend_workflows.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp spec(app, backend? \\ true) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, lowered} = Frontend.build(app, model, index)
    {:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

    {:ok, backend} =
      BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "Shop")

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        backend: if(backend?, do: backend)
      )

    spec
  end

  defp workflow(spec, id), do: spec |> Spec.workflows() |> Enum.find(&(&1.workflow == id))

  defp residue(w), do: w.residue ++ Enum.flat_map(w.steps, & &1.residue)

  defp edit(app, id, fun), do: update_in(app, ["pages", "home", "workflows", id], fun)

  setup_all do
    %{spec: spec(app())}
  end

  test "options are required" do
    {:ok, model} = Model.build(app())
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)

    assert {:error, %{message: "the :namespace option is required"}} =
             FrontendWorkflows.map(%Frontend{}, project, [])

    assert {:error, %{message: "the :frontend option" <> _}} =
             FrontendWorkflows.map(%Frontend{}, project, namespace: "Shop")
  end

  test "surfaces, functions and states", %{spec: spec} do
    assert %{kind: :page} = spec.surfaces["bHome"]
    assert %{kind: :reusable} = spec.surfaces["bCard"]
    assert %{kind: :page, workflows: []} = spec.surfaces["bOther"]

    assert %{fun: "wf_shout"} = workflow(spec, "wEvt")
    assert %{fun: "wf_w_state"} = workflow(spec, "wState")

    assert %{element: "bHome", state: "custom.label_", default: ~s("start")} in spec.surfaces[
             "bHome"
           ].states

    assert %{element: "bCard", state: "custom.count_", default: "0"} in spec.surfaces["bCard"].states
  end

  test "the page tracks its native inputs with a static first value", %{spec: spec} do
    assert spec.surfaces["bHome"].inputs == %{
             "bIn" => :text,
             "bNum" => :number,
             "bCheck" => :boolean
           }

    assert spec.surfaces["bCard"].inputs == %{"bCardNote" => :text}
  end

  test "values read what the page keeps", %{spec: spec} do
    [set, show] = workflow(spec, "wState").steps

    assert [%{key: %{path: [], element: "bHome", state: "custom.label_"}, value: value}] =
             set.args.states

    assert [%{bind: {:input, %{path: [], element: "bIn"}}, loads: []}] = value.bindings
    assert %{op: :show, args: %{target: %{path: [], element: "bFocus"}}} = show
    assert [%{bind: {:input, %{element: "bCheck"}}}] = show.condition.bindings

    cond = workflow(spec, "wCond")
    assert cond.run_when == :every_time

    assert [%{bind: {:state, %{element: "bHome", state: "custom.count_"}}}] =
             cond.condition.bindings

    [terminate] = workflow(spec, "wEvt").steps
    assert [%{value: %{bindings: [%{bind: {:param, "pWord"}}]}}] = terminate.args.returns
  end

  test "reusable workflows address their instance; the page calls into one", %{spec: spec} do
    [inc] = workflow(spec, "wCardInc").steps

    assert [%{key: %{path: [], element: "bCard", state: "custom.count_"}}] = inc.args.states

    [reset] = workflow(spec, "wReset").steps

    assert %{
             op: :call_reusable,
             args: %{instance: "bInst1", callee: %{surface: "bCard", workflow: "wCardZero"}}
           } = reset

    assert workflow(spec, "wReset").callees == [%{surface: "bCard", workflow: "wCardZero"}]

    # A page reading an instance's state reads its reusable's, one level down.
    assert {:state, %{path: ["bInst1"], element: "bCard", state: "custom.count_"}} =
             Spec.read(
               spec,
               "bHome",
               {:element_state, %{"element" => "bInst1", "state" => "custom.count_"}}
             )

    assert nil ==
             Spec.read(
               spec,
               "bHome",
               {:element_state, %{"element" => "bIn", "state" => "is_visible"}}
             )
  end

  test "browser-run, data and native workflows", %{spec: spec} do
    assert workflow(spec, "wOpen").client?
    assert workflow(spec, "wClose").client?
    assert workflow(spec, "wCardOpen").client?
    refute workflow(spec, "wState").client?
    # Disabled: generated, never triggered, never browser-run.
    refute workflow(spec, "wOpenOff").client?
    refute Spec.wired?(workflow(spec, "wOpenOff"))

    assert workflow(spec, "wData").data?
    refute workflow(spec, "wState").data?

    assert Spec.native?(workflow(spec, "wCall"))
    # Its own body is native, but its custom event is not: blocked, as the
    # backend's blocked_by.
    assert Spec.native_own_body?(workflow(spec, "wCallee"))
    assert workflow(spec, "wCallee").blocked_by == ["workflow:wEvtResidue"]
    refute Spec.native?(workflow(spec, "wCallee"))
  end

  test "a load in a step's condition alone makes the workflow a data workflow (review H1)" do
    relation = %{
      "type" => "CurrentUser",
      "next" => %{
        "type" => "Message",
        "name" => "fav_custom_note",
        "next" => %{
          "type" => "Message",
          "name" => "title_text",
          "next" => %{"type" => "Message", "name" => "is_not_empty"}
        }
      }
    }

    spec =
      app()
      |> put_in(["user_types", "user", "fields", "fav_custom_note"], %{
        "display" => "Favorite",
        "value" => "custom.note"
      })
      |> edit("wNav", &put_in(&1, ["actions", "0", "properties", "condition"], relation))
      |> spec()

    w = workflow(spec, "wNav")
    [%{condition: %{bindings: [%{loads: [["favorite"]]}]}}] = w.steps
    assert w.data?
    # A caller of a data custom event is a data workflow too.
    refute workflow(spec, "wCall").data?
  end

  test "what the page does not provide is residue, not a silent nil" do
    page_thing = %{"type" => "CurrentPageItem"}

    hidden = %{
      "type" => "GetElement",
      "properties" => %{"element_id" => "bPop"},
      "next" => %{"type" => "Message", "name" => "is_visible"}
    }

    spec =
      app()
      |> edit("wState", &put_in(&1, ["actions", "0", "properties", "value"], hidden))
      |> edit("wNav", fn w ->
        put_in(w, ["actions", "0"], %{
          "id" => "aNav1",
          "type" => "ScheduleAPIEvent",
          "properties" => %{"api_event" => "nope"}
        })
      end)
      |> edit("wLoad", &Map.put(&1, "type", "PopupOpened"))
      |> put_in(["pages", "home", "properties", "page_item_type"], "custom.note")
      |> edit("wData", &put_in(&1, ["actions", "1", "properties", "value"], page_thing))
      |> spec()

    reasons = fn id -> spec |> workflow(id) |> residue() |> Enum.map(&{&1.reason, &1.detail}) end

    assert {:unavailable_input, %{inputs: ["element_state:is_visible"]}} in reasons.("wState")
    assert {:unsupported_event, %{type: "PopupOpened", target: "phoenix"}} in reasons.("wLoad")

    assert Enum.any?(
             reasons.("wData"),
             &match?({:unavailable_input, %{inputs: ["page_thing"]}}, &1)
           )

    # A scheduled backend workflow waits for WTF-373 (and here, does not resolve).
    assert Enum.any?(reasons.("wNav"), &match?({:unresolved_reference, _}, &1))
  end

  test "scheduling a backend workflow runs on the backend runtime; without it, it waits" do
    assert [%{args: %{backend: "wApiNote", params: [%{param: "note"}]}}] =
             app() |> spec() |> workflow("wSchedule") |> Map.fetch!(:steps)

    assert %{data?: true, blocked_by: []} = app() |> spec() |> workflow("wSchedule")

    assert [%{reason: :backend_workflow, detail: %{workflow: "workflow:wApiNote"}}] =
             app() |> spec(false) |> workflow("wSchedule") |> residue()

    # A scheduled backend workflow that is not lowered blocks the page's.
    blocked =
      app()
      |> put_in(["api", "wApiNote", "actions", "0", "type"], "SendEmail")
      |> spec()
      |> workflow("wSchedule")

    assert blocked.blocked_by == ["workflow:wApiNote"]
    refute Spec.native?(blocked)
  end

  test "coverage measures generated code", %{spec: spec} do
    coverage = FrontendWorkflows.coverage(spec)

    assert coverage["workflows"] == %{
             "total" => 27,
             "native" => 24,
             "native_own_body" => 25,
             "wired" => 19,
             "residue" => 3,
             "client" => 3
           }

    assert coverage["data"] == 3
    assert coverage["residue_reasons"] == %{"unsupported_action" => 2}
    assert coverage["by_surface"]["reusable"] == %{"total" => 3, "native" => 3}
  end

  test "deterministic", %{spec: spec} do
    assert spec(app()) == spec
  end
end
