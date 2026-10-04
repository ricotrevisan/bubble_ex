defmodule BubbleEx.Workflows.BackendTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, Plan}
  alias BubbleEx.Test.PermutedJson
  alias BubbleEx.Workflows.Backend
  alias BubbleEx.Workflows.Backend.{Step, Workflow}
  alias BubbleEx.Workflows.Lowering.{Change, Expr}

  @fixture "test/support/target/workflows/backend.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp build(app) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, backend} = Backend.build(app, model, index)
    backend
  end

  defp workflow(backend, id), do: Enum.find(backend.workflows, &(&1.bubble_id == id))

  defp put_workflow(app, id, workflow), do: put_in(app, ["api", id], workflow)

  defp api(actions, props \\ %{}) do
    %{
      "id" => "wX",
      "type" => "APIEvent",
      "properties" => Map.merge(%{"wf_name" => "x"}, props),
      "actions" => actions
    }
  end

  test "every backend workflow is lowered, in Bubble ID order" do
    backend = build(app())

    assert Enum.map(backend.workflows, & &1.bubble_id) ==
             ~w(wBlocked wClose wCreate wExternal wFanOut wNote wNotify wOnDone wPing wTick)

    assert Enum.map(backend.workflows, & &1.kind) ==
             [:api, :api, :api, :api, :api, :api, :custom_event, :database_trigger, :api, :api]
  end

  test "the entry point: exposure, authentication, parameters, returns" do
    backend = build(app())
    create = workflow(backend, "wCreate")

    assert create.id == "workflow:wCreate"
    assert create.name == "create task"
    assert create.folder == "fTasks"
    assert create.exposed? and create.auth == :none

    assert [
             %{id: "title", key: "title", type: "text"},
             %{id: "project", optional?: true},
             %{id: "name", optional?: true}
           ] = create.parameters

    assert workflow(backend, "wPing").method == :get
    assert workflow(backend, "wCreate").method == nil

    notify = workflow(backend, "wNotify")
    assert [%{id: "pTask", key: "task", type: "custom.task"}] = notify.parameters
    assert [%{id: "rTitle", name: "title", type: "text"}] = notify.returns
    assert workflow(backend, "wOnDone").trigger_type == "task"
    assert workflow(backend, "wTick").auth == :authenticated
  end

  test "only a workflow's own ignore-privacy setting is a bypass, and it is diagnosed" do
    backend = build(app())

    assert for(w <- backend.workflows, w.ignores_privacy?, do: w.bubble_id) == ["wClose"]
    assert for(w <- backend.workflows, w.inherits_privacy?, do: w.bubble_id) == ["wNotify"]

    assert [%{code: :workflow_privacy_bypass, subject: %{workflow: "wClose"}}] =
             Enum.filter(backend.diagnostics, &(&1.code == :workflow_privacy_bypass))
  end

  test "steps lower to operations with IR values" do
    backend = build(app())

    [%Step{op: :create, args: create}, %Step{op: :return, args: %{values: [returned, _name]}}] =
      workflow(backend, "wCreate").steps

    assert create.data_type == "task"

    assert [
             %Change{field: "title_text", op: :set, value: %Expr{ir: %{op: :input}}},
             %Change{field: "project_custom_project", op: :set},
             %Change{
               field: "watchers_list_user",
               op: :add,
               value: %Expr{ir: %{op: :current_user}}
             },
             %Change{
               field: "count_number",
               op: :set,
               value: %Expr{ir: %{op: :literal, args: [1]}}
             },
             %Change{field: "done_boolean", op: :set}
           ] = create.changes

    assert %{key: "task", value: %Expr{ir: %{op: :input, args: [:step_result, _]}}} = returned

    [update, call] = workflow(backend, "wClose").steps
    assert %Step{op: :update, condition: %Expr{ir: %{}}, args: %{data_type: "task"}} = update
    assert %Step{op: :call, args: %{workflow: "wNotify", params: [%{param: "pTask"}]}} = call

    [_, schedule] = workflow(backend, "wTick").steps

    assert %Step{
             op: :schedule,
             args: %{workflow: "wTick", at: %Expr{}, params: [%{param: "task"}]}
           } =
             schedule

    assert [%Step{op: :terminate, args: %{returns: [%{return: "rTitle"}]}}] =
             workflow(backend, "wNotify").steps
  end

  test "unsupported steps are residue with a diagnostic, never dropped" do
    backend = build(app())
    external = workflow(backend, "wExternal")

    assert [
             %Step{index: 1, op: nil, residue: [%{reason: :api_connector_action}]},
             %Step{index: 2, op: nil, residue: [%{reason: :unsupported_action}]}
           ] = external.steps

    refute Workflow.native?(external)

    assert Backend.residue(backend) == [
             %{subject: "action:aCall", reason: :api_connector_action, detail: %{call: "gA.cB"}},
             %{subject: "action:aMail", reason: :unsupported_action, detail: %{type: "SendEmail"}}
           ]

    assert Enum.count(backend.diagnostics, &(&1.code == :workflow_residue)) == 2
  end

  test "call cycles carry the plan's cycle task ID" do
    backend = build(app())

    assert [%{id: "cycle:wTick", workflows: ["workflow:wTick"], bubble_ids: ["wTick"]}] =
             backend.cycles

    assert workflow(backend, "wTick").cycle == "cycle:wTick"
  end

  test "coverage counts native workflows and steps" do
    coverage = Backend.coverage(build(app()))

    assert coverage["workflows"] == %{"total" => 10, "native" => 9, "residue" => 1}
    assert coverage["steps"] == %{"total" => 15, "native" => 13, "residue" => 2}
    assert coverage["privacy_bypasses"] == 1
    assert coverage["exposed"] == 2
    assert coverage["cycles"] == 1
  end

  test "residue feeds the plan" do
    app = app()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, backend} = Backend.build(app, model, index)

    assert {:ok, %Plan{}} = Plan.build(model, index, nil, [], residue: Backend.residue(backend))
  end

  test "an option without a lowering makes its event or step residue" do
    detected =
      api(%{}, %{
        "parameter_def" => "auto",
        "raw_data" => ~s({"headers": {"authorization": "Bearer s3cr3t-sample"}}),
        "include_headers" => true
      })

    backend = build(put_workflow(app(), "wX", detected))
    w = workflow(backend, "wX")

    assert [
             %{
               reason: :unsupported_option,
               detail: %{options: ["include_headers", "parameter_def"]}
             }
           ] =
             w.residue

    # The sample request is never read.
    refute inspect(backend, limit: :infinity) =~ "s3cr3t-sample"

    step =
      api(%{
        "0" => %{
          "id" => "aOdd",
          "type" => "DeleteThing",
          "properties" => %{"to_delete" => %{"type" => "CurrentUser"}, "novel" => 1}
        }
      })

    [%Step{residue: [%{reason: :unsupported_option, detail: %{options: ["novel"]}}]}] =
      build(put_workflow(app(), "wX", step)) |> workflow("wX") |> Map.fetch!(:steps)
  end

  test "unresolved callees, parameters and change operations are residue" do
    actions = %{
      "0" => %{
        "id" => "a1",
        "type" => "ScheduleAPIEvent",
        "properties" => %{"api_event" => "gone"}
      },
      "1" => %{
        "id" => "a2",
        "type" => "ScheduleAPIEvent",
        "properties" => %{"api_event" => "wTick", "_wf_param_nope" => "x"}
      },
      "2" => %{
        "id" => "a3",
        "type" => "NewThing",
        "properties" => %{
          "thing_type" => "custom.task",
          "initial_values" => %{
            "0" => %{"key" => "title_text", "action" => "shuffle", "value" => "x"}
          }
        }
      },
      "3" => %{
        "id" => "a4",
        "type" => "NewThing",
        "properties" => %{
          "thing_type" => "custom.task",
          "initial_values" => %{"0" => %{"key" => "no_such_field", "value" => "x"}}
        }
      }
    }

    steps = build(put_workflow(app(), "wX", api(actions))) |> workflow("wX") |> Map.fetch!(:steps)

    assert Enum.map(steps, fn s -> Enum.map(s.residue, &{&1.reason, &1.detail}) end) == [
             [{:unresolved_reference, %{reference: "workflow"}}],
             [{:unresolved_reference, %{reference: "parameter"}}],
             [{:unsupported_option, %{options: ["changes"]}}],
             [{:unresolved_reference, %{reference: "field"}}]
           ]
  end

  test "plugin, auth and unknown actions and events are residue" do
    actions = %{
      "0" => %{"id" => "p1", "type" => "1488796042609x768734193128308700-AAn"},
      "1" => %{"id" => "p2", "type" => "LogIn"},
      "2" => %{"id" => "p3", "type" => "Teleport"},
      "3" => "not an object"
    }

    backend = build(put_workflow(app(), "wX", api(actions)))

    assert [
             [:plugin_action],
             [:auth_action],
             [:unsupported_action],
             [:unsupported_action]
           ] =
             backend
             |> workflow("wX")
             |> Map.fetch!(:steps)
             |> Enum.map(&Enum.map(&1.residue, fn r -> r.reason end))

    odd = %{"id" => "wY", "type" => "Recurring", "properties" => %{}, "actions" => %{}}
    backend = build(put_workflow(app(), "wY", odd))
    assert [%{reason: :unsupported_event}] = workflow(backend, "wY").residue
  end

  test "uncompiled values are residue naming what stopped them" do
    actions = %{
      "0" => %{
        "id" => "aU",
        "type" => "DeleteThing",
        "properties" => %{"to_delete" => %{"type" => "NoSuchSource"}}
      }
    }

    [step] =
      build(put_workflow(app(), "wX", api(actions))) |> workflow("wX") |> Map.fetch!(:steps)

    assert %{reason: :uncompiled_expression, detail: %{expressions: 1, constructs: [_ | _]}} =
             Enum.find(step.residue, &(&1.reason == :uncompiled_expression))
  end

  # WTF-478, replayed on Bubble (2026-10-01): in a backend workflow an
  # empty constraint value matches nothing, and `ignore_empty_constraints:
  # true` has no effect.
  test "a search's empty constraint value matches nothing, whatever it states" do
    for options <- [
          %{},
          %{"ignore_empty_constraints" => false},
          %{"ignore_empty_constraints" => true}
        ] do
      search = %{
        "type" => "Search",
        "properties" =>
          Map.merge(options, %{
            "type_to_find" => "custom.task",
            "constraints" => %{
              "0" => %{
                "key" => "title_text",
                "constraint_type" => "equals",
                "value" => %{
                  "type" => "CurrentWorkflowItem",
                  "properties" => %{"btype_id" => "text", "param_id" => "pQ", "param_name" => "q"}
                }
              }
            }
          }),
        "next" => %{"type" => "Message", "name" => "first_element"}
      }

      actions = %{
        "0" => %{"id" => "aD", "type" => "DeleteThing", "properties" => %{"to_delete" => search}}
      }

      params = %{
        "parameters" => %{"0" => %{"btype_id" => "text", "param_id" => "pQ", "param_name" => "q"}}
      }

      [step] =
        build(put_workflow(app(), "wX", api(actions, params)))
        |> workflow("wX")
        |> Map.fetch!(:steps)

      assert step.residue == []

      assert %{target: %Expr{ir: %{op: :first, args: [%{op: :search, args: [_, pred]}]}}} =
               step.args

      assert %{op: :and, args: [%{op: :not, args: [%{op: :is_empty, args: [param]}]}, eq]} =
               BubbleEx.Expression.IR.strip_paths(pred)

      assert %{op: :input, args: [:parameter, %{"param_id" => "pQ"}]} = param
      assert %{op: :eq, args: [%{op: :field}, ^param]} = eq
    end
  end

  test "deterministic, whatever the JSON member order" do
    app = app()
    backend = build(app)
    assert build(app) == backend

    :rand.seed(:exsss, {1, 2, 3})
    permuted = app |> PermutedJson.encode() |> Jason.decode!()
    assert build(permuted) == backend
  end

  test "rejects input that is not an app with its Model and Index" do
    assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Backend.build(nil, nil, nil)
  end
end
