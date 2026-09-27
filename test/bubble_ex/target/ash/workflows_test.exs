defmodule BubbleEx.Target.Ash.WorkflowsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.Workflows
  alias BubbleEx.Target.Ash.Workflows.Spec
  alias BubbleEx.Workflows.Backend

  @fixture "test/support/target/workflows/backend.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp spec(app, opts \\ []) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, backend} = Backend.build(app, model, index)
    {:ok, project} = Ash.map(model, [], privacy: :omit)
    {:ok, spec} = Workflows.map(backend, project, Keyword.put_new(opts, :namespace, "Acme"))
    spec
  end

  defp action(spec, id), do: spec |> Spec.actions() |> Enum.find(&(&1.workflow == id))

  test "one resource per backend folder, one action per workflow" do
    spec = spec(app())

    assert Enum.map(spec.resources, &{&1.module, Enum.map(&1.actions, fn a -> a.name end)}) == [
             {"Workflows.FolderFLoop", ["blocked", "fan_out", "note", "ping", "sync", "tick"]},
             {"Workflows.FolderFTasks", ["close_task", "create_task", "notify"]},
             {"Workflows.Unfiled", ["task_done"]}
           ]
  end

  test "authorization: bypassed only for a workflow that ignores privacy rules" do
    spec = spec(app())

    assert Map.new(Spec.actions(spec), &{&1.workflow, &1.authorize}) == %{
             "wBlocked" => true,
             "wClose" => false,
             "wCreate" => true,
             "wExternal" => true,
             "wFanOut" => true,
             "wNote" => true,
             "wNotify" => :inherit,
             "wOnDone" => true,
             "wPing" => true,
             "wTick" => true
           }

    assert spec.privacy_bypasses == ["wClose"]
  end

  test "arguments: a thing is its Bubble ID, loaded from its resource" do
    create = action(spec(app()), "wCreate")

    assert [
             %{name: "title", param: "title", kind: :value, type: :string},
             %{
               name: "project",
               param: "project",
               kind: :record,
               type: :string,
               resource: "Project",
               optional?: true
             },
             %{name: "name", param: "name", kind: :value}
           ] = create.arguments

    assert %{endpoint: "create task", auth: :none} = create.exposed
  end

  test "values compile to Elixir with their bindings" do
    [create, _] = action(spec(app()), "wCreate").steps

    assert %{resource: "Task", changes: changes} = create.args

    assert [
             %{
               attribute: "title",
               op: :set,
               value: %{source: "parameter_title", bindings: [%{bind: {:param, "title"}}]}
             },
             %{attribute: "project_id", op: :set, ref: :one},
             %{
               attribute: "watchers",
               op: :add,
               ref: :many,
               value: %{bindings: [%{bind: :actor}]}
             },
             %{attribute: "count", op: :set, value: %{source: "1"}},
             %{attribute: "done", op: :set, value: %{source: "false"}}
           ] = changes

    [proj] = action(spec(app()), "wOnDone").steps
    assert %{bindings: [%{bind: {:trigger, :now}, loads: [["project"]]}]} = proj.args.target
  end

  test "database triggers, stamps and cycles" do
    spec = spec(app())

    assert spec.triggers == [
             %{
               resource: "Task",
               data_type: "task",
               workflows: ["wOnDone"],
               fields: ["done", "project_id"]
             }
           ]

    assert spec.stamps["Task"] == %{
             created: "created_date",
             modified: "modified_date",
             creator: "creator_id"
           }

    assert [%{id: "cycle:wTick"}] = spec.cycles
    assert action(spec, "wTick").cycle == "cycle:wTick"
    assert action(spec, "wTick").scheduled?
  end

  test "coverage counts generated code" do
    coverage = Spec.coverage(spec(app()))
    assert coverage["entry_points"] == 10
    # wBlocked's own body lowers, but it schedules wExternal, which does not.
    assert coverage["workflows"] == %{"total" => 10, "native" => 8, "residue" => 2}
    assert coverage["native_own_body"] == 9
    assert coverage["steps"]["native"] == 13

    assert coverage["residue_reasons"] == %{
             "api_connector_action" => 1,
             "unsupported_action" => 1
           }

    assert coverage["triggers"] == 1
  end

  test "a context input a backend workflow lacks is the binding's residue" do
    app =
      put_in(app(), ["api", "wX"], %{
        "id" => "wX",
        "type" => "APIEvent",
        "properties" => %{"wf_name" => "x"},
        "actions" => %{
          "0" => %{
            "id" => "aW",
            "type" => "NewThing",
            "properties" => %{
              "thing_type" => "custom.task",
              "initial_values" => %{
                "0" => %{
                  "key" => "count_number",
                  "value" => %{
                    "type" => "PageData",
                    "properties" => %{"name" => "Current Page Width"}
                  }
                }
              }
            }
          }
        }
      })

    [step] = action(spec(app), "wX").steps

    assert [
             %{
               reason: :uncompiled_expression,
               detail: %{constructs: ["elixir:unbound_input:page_data"]}
             }
           ] =
             step.residue

    refute Spec.native?(action(spec(app), "wX"))
  end

  test "names avoid Kernel and keywords, and are kept by the name map" do
    app =
      update_in(app(), ["api"], fn api ->
        api
        |> put_in(["wCreate", "properties", "wf_name"], "if")
        |> put_in(["wClose", "properties", "wf_name"], "create task")
      end)

    spec = spec(app)
    assert action(spec, "wCreate").name == "if_workflow"
    assert action(spec, "wClose").name == "create_task"

    # Renaming in Bubble does not rename code once names are locked.
    renamed = put_in(app, ["api", "wClose", "properties", "wf_name"], "shut")
    assert action(spec(renamed, names: spec.names), "wClose").name == "create_task"
    assert action(spec(renamed), "wClose").name == "shut"
    assert spec.names |> Jason.encode!() |> Jason.decode!() == spec.names
  end

  test "blocking propagates through a call cycle, and only along calls" do
    call = fn id, callee ->
      %{"id" => id, "type" => "TriggerCustomEvent", "properties" => %{"custom_event" => callee}}
    end

    event = fn id, actions ->
      %{
        "id" => id,
        "type" => "CustomEvent",
        "properties" => %{"event_name" => id},
        "actions" => actions
      }
    end

    app =
      update_in(app(), ["api"], fn api ->
        Map.merge(api, %{
          # cA <-> cB is a cycle; cB also schedules wExternal (residue).
          "cA" => event.("cA", %{"0" => call.("aAB", "cB")}),
          "cB" =>
            event.("cB", %{
              "0" => call.("aBA", "cA"),
              "1" => %{
                "id" => "aBX",
                "type" => "ScheduleAPIEvent",
                "properties" => %{"api_event" => "wExternal"}
              }
            }),
          # cC calls into the cycle; cD <-> cE is a clean cycle.
          "cC" => event.("cC", %{"0" => call.("aCA", "cA")}),
          "cD" => event.("cD", %{"0" => call.("aDE", "cE")}),
          "cE" => event.("cE", %{"0" => call.("aED", "cD")})
        })
      end)

    spec = spec(app)

    assert action(spec, "cA").blocked_by == ["workflow:cB"]
    assert action(spec, "cB").blocked_by == ["workflow:cA", "workflow:wExternal"]
    assert action(spec, "cC").blocked_by == ["workflow:cA"]
    refute Enum.any?(~w(cA cB cC), &Spec.native?(action(spec, &1)))

    assert action(spec, "cD").blocked_by == []
    assert Spec.native?(action(spec, "cD")) and Spec.native?(action(spec, "cE"))
  end

  test "a trigger's job snapshot is limited to the fields its workflows read" do
    assert [%{resource: "Task", fields: ["done", "project_id"]}] = spec(app()).triggers
  end

  test "a trigger reading an email is diagnosed" do
    app =
      put_in(app(), ["api", "wMail"], %{
        "id" => "wMail",
        "type" => "DatabaseTriggerEvent",
        "properties" => %{
          "data_trigger_type" => "user",
          "condition" => %{
            "type" => "CurrentDataItem",
            "next" => %{
              "type" => "Message",
              "name" => "email",
              "next" => %{"type" => "Message", "name" => "is_not_empty"}
            }
          }
        },
        "actions" => %{}
      })

    spec = spec(app)
    assert %{fields: ["email"]} = Enum.find(spec.triggers, &(&1.data_type == "user"))

    assert [%{subject: %{type: "user"}, details: %{attribute: "email"}}] =
             Enum.filter(spec.diagnostics, &(&1.code == :workflow_trigger_sensitive_field))
  end

  test "the namespace is required and must be a module name" do
    {:ok, model} = Model.build(app())
    {:ok, index} = Index.build(app(), model: model)
    {:ok, backend} = Backend.build(app(), model, index)
    {:ok, project} = Ash.map(model)

    assert {:error, %BubbleEx.Error{}} = Workflows.map(backend, project, [])
    assert {:error, %BubbleEx.Error{}} = Workflows.map(backend, project, namespace: "acme; x")
    assert {:error, %BubbleEx.Error{}} = Workflows.map(nil, project, namespace: "Acme")
  end

  test "deterministic" do
    assert spec(app()) == spec(app())
  end
end
