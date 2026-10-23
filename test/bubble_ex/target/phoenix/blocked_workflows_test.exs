defmodule BubbleEx.Target.Phoenix.BlockedWorkflowsTest do
  # The owner's report of the workflows that cannot run (WTF-607), from the
  # synthetic test/support/target/phoenix/frontend_workflows.json. That a
  # blocked workflow runs no step at all, not even those before the one
  # that blocks it, is frontend_workflows_behavior.exs's ("a workflow with
  # a step that was not lowered runs no step at all").
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Target.Phoenix.BlockedWorkflows

  @fixture "test/support/target/phoenix/frontend_workflows.json"

  setup_all do
    app = @fixture |> File.read!() |> Jason.decode!()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
    {:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

    {:ok, backend} =
      BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "Shop")

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        backend: backend
      )

    {:ok, files} =
      Phoenix.render(project,
        module: "Shop",
        frontend: frontend,
        expressions: expressions,
        workflows: backend,
        frontend_workflows: spec
      )

    notes = BlockedWorkflows.notes(spec, backend, frontend: frontend)
    %{files: files, spec: spec, notes: notes, by_id: Map.new(notes, &{&1.workflow, &1})}
  end

  test "one note per workflow the runtime refuses, none for a native or disabled one",
       %{spec: spec, notes: notes} do
    refused =
      for w <- Spec.workflows(spec), not w.disabled?, not Spec.native?(w), do: w.workflow

    assert refused != []

    assert notes |> Enum.map(& &1.workflow) |> Enum.filter(&(&1 in refused)) |> Enum.sort() ==
             Enum.sort(refused)

    for w <- Spec.workflows(spec),
        w.disabled? or Spec.native?(w),
        do: refute(Enum.any?(notes, &(&1.workflow == w.workflow)), w.workflow)

    assert length(Enum.uniq_by(notes, & &1.workflow)) == length(notes)
  end

  test "a step that was not converted: the workflow, its event, the step and why", %{by_id: by_id} do
    # wResidue: step 1 sets a state (converted), step 2 shows an alert (not).
    assert %{
             where: {:page, "index"},
             event: "when \"bBtnResidue\" is clicked",
             blocker: {:step, 2, "AlertShowMessage"},
             reason: :unsupported_action
           } = by_id["wResidue"]
  end

  test "a workflow refused through the custom event it triggers names that event (step 1 converted)",
       %{
         by_id: by_id
       } do
    # wCallee: step 1 sets a state, step 2 triggers the custom event.
    assert %{blocker: {:calls, 2, "TriggerCustomEvent", [callee]}, reason: :calls_blocked} =
             by_id["wCallee"]

    assert callee == ~s("broken")
  end

  test "the report groups the notes by reason, in plain words", %{files: files, notes: notes} do
    md = files[".wtf/blocked_workflows.md"]
    assert md == BlockedWorkflows.markdown(notes)
    assert md =~ "#{length(notes)} workflows of this app cannot run"
    assert md =~ "not even the steps before that part"
    assert md =~ "| A step uses an action that is not converted yet | "
    assert md =~ "## It runs another workflow that cannot run (1 workflow)"

    assert md =~
             ~s{- Page "index", when "bBtnResidue" is clicked: step 2, Show message in an alert [AlertShowMessage] (`workflow:wResidue`)}

    # What the owner can do: change it in Bubble, or drop it in the decisions file.
    assert md =~ "**change it in Bubble**"
    assert md =~ "record a drop decision for its ID"
    # One line per workflow.
    assert md |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "- Page ")) ==
             Enum.count(notes, &match?({:page, _}, &1.where))
  end

  test "the report is a generated file, rendered the same each time", %{files: files} do
    {:ok, %{"generated" => generated}} = Jason.decode(files[".wtf/generated.json"])
    assert Map.has_key?(generated, BlockedWorkflows.path())
  end

  describe "synthetic specs" do
    defp step(index, type, opts \\ []) do
      %{
        index: index,
        type: type,
        args: Keyword.get(opts, :args, %{}),
        residue: Keyword.get(opts, :residue, [])
      }
    end

    defp residue(subject, reason, detail),
      do: %{subject: subject, reason: reason, detail: detail}

    defp flow(id, opts) do
      Map.merge(
        %{
          workflow: id,
          surface: "bPage",
          kind: :click,
          element: "bBtn",
          run_when: nil,
          name: nil,
          disabled?: false,
          residue: [],
          steps: [],
          blocked_by: []
        },
        Map.new(opts)
      )
    end

    setup do
      plugin_step =
        step(1, "1488796042609x768734193128308700-AAC",
          residue: [
            residue("action:a", :plugin_action, %{plugin: "1488796042609x768734193128308700"})
          ]
        )

      frontend = %Spec{
        surfaces: %{
          "bPage" => %{
            kind: :page,
            workflows: [
              # Its condition reads a value the page does not keep.
              flow("wCond",
                residue: [
                  residue("workflow:wCond", :unavailable_input, %{inputs: ["cell_thing"]})
                ],
                blocked_by: ["workflow:wCond"]
              ),
              flow("wPlugin", steps: [plugin_step], blocked_by: ["action:a"]),
              # Step 1 schedules a backend workflow that cannot run, step 2 is not converted.
              flow("wSched",
                steps: [
                  step(1, "ScheduleAPIEvent", args: %{backend: "wApi"}),
                  step(2, "ListClear",
                    residue: [residue("action:b", :unsupported_action, %{type: "ListClear"})]
                  )
                ],
                blocked_by: ["action:b", "workflow:wApi"]
              ),
              flow("wOff", disabled?: true, steps: [plugin_step], blocked_by: ["action:a"]),
              flow("wFine", steps: [step(1, "ShowElement")])
            ]
          }
        }
      }

      backend = %BubbleEx.Target.Ash.Workflows.Spec{
        resources: [
          %{
            module: "Workflows.Folder",
            folder: nil,
            actions: [
              %{
                workflow: "wApi",
                kind: :api,
                bubble_name: "send-it",
                residue: [],
                blocked_by: ["action:c"],
                steps: [
                  step(1, "SendEmail",
                    residue: [
                      residue("action:c", :unsupported_option, %{options: ["sender_name"]})
                    ]
                  )
                ]
              },
              %{
                workflow: "wOk",
                kind: :api,
                bubble_name: "ok",
                residue: [],
                blocked_by: [],
                steps: []
              }
            ]
          }
        ]
      }

      notes = BlockedWorkflows.notes(frontend, backend)
      %{notes: notes, by_id: Map.new(notes, &{&1.workflow, &1})}
    end

    test "every refused workflow, page and backend, nothing else", %{notes: notes} do
      assert notes |> Enum.map(& &1.workflow) |> Enum.sort() == ~w(wApi wCond wPlugin wSched)
    end

    test "the first blocker in Bubble order", %{by_id: by_id} do
      assert %{blocker: :event, reason: :unavailable_input, detail: ["cell_thing"]} =
               by_id["wCond"]

      assert %{blocker: {:calls, 1, "ScheduleAPIEvent", [~s(backend workflow "send-it")]}} =
               by_id["wSched"]

      assert %{
               where: {:backend, nil},
               event: "API workflow",
               name: "send-it",
               blocker: {:step, 1, "SendEmail"},
               reason: :unsupported_option
             } = by_id["wApi"]

      assert %{reason: :plugin_action, plugin: %{id: "1488796042609x768734193128308700"}} =
               by_id["wPlugin"]
    end

    test "the lines say it in Bubble's words", %{notes: notes} do
      md = BlockedWorkflows.markdown(notes)

      assert md =~
               ~s{- Page "bPage", when element bBtn is clicked: its "Only when" condition or its event's settings [cell_thing] (`workflow:wCond`)}

      assert md =~
               ~s{step 1, Schedule API Workflow, runs backend workflow "send-it" (`workflow:wSched`)}

      assert md =~
               ~s{- Backend, API workflow ("send-it"): step 1, Send email [sender_name] (`workflow:wApi`)}

      assert md =~ "[plugin 1488796042609x768734193128308700] (`workflow:wPlugin`)"
      assert md =~ "decision:plugin/<plugin ID>"
    end
  end

  test "with nothing blocked the report says so" do
    assert BlockedWorkflows.markdown([]) =~ "none is refused"
  end

  test "an owner's name cannot break a line or a table" do
    note = %{
      workflow: "wX",
      symbol: "workflow:wX",
      where: {:page, "a|b\nc"},
      event: "when the page is loaded",
      name: "x`y",
      blocker: {:step, 1, "Nope"},
      reason: :unsupported_action,
      detail: ["Nope"],
      plugin: nil
    }

    md = BlockedWorkflows.markdown([note])

    assert md =~
             ~s{- Page "a b c", when the page is loaded ("x y"): step 1, "Nope" [Nope] (`workflow:wX`)}
  end
end
