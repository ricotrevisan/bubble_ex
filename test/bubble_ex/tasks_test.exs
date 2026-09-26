defmodule BubbleEx.TasksTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Error, Index, Model, Plan, SampleHelper, Tasks}
  alias BubbleEx.Plan.Content
  alias BubbleEx.Tasks.{State, Store}
  alias BubbleEx.Verify.Result

  # The invented plan app (test/support/samples/synthetic_plan_export.json;
  # see BubbleEx.PlanTest) as an owner's repository in a temporary
  # directory: .wtf/plan.json plus task states, with the code checks
  # replaced by `Pass` (or a scripted `mix`) so only task state is tested.
  @app SampleHelper.load_json_sample("synthetic_plan_export")
  @now ~U[2026-09-26 12:00:00Z]
  @key String.duplicate("k", 32)
  @plugin "1600000000000x100000000000000000"
  @generators ~w(generate:option_sets generate:schema generate:api_clients generate:policies
                 generate:routes generate:styles generate:surfaces generate:workflow_entry_points)

  defmodule Pass do
    @moduledoc false
    def run(_criterion, _ctx, cache),
      do: {%{status: :pass, binding: "fake", detail: nil, refs: [], output: nil}, cache}
  end

  defmodule Fail do
    @moduledoc false
    def run(%{check: :compiles}, _ctx, cache),
      do: {%{status: :fail, binding: "fake", detail: "boom", refs: [], output: "error"}, cache}

    def run(c, ctx, cache), do: Pass.run(c, ctx, cache)
  end

  defp plan(app \\ @app) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, content} = Content.digests(app, model, index, key: @key)
    {:ok, plan} = Plan.build(model, index, nil, [], fragment_threshold: 2, content: content)
    plan
  end

  setup_all do
    %{plan: plan()}
  end

  setup %{tmp_dir: dir, plan: plan} do
    :ok = Store.write_plan(dir, plan)
    %{root: dir}
  end

  @moduletag :tmp_dir

  defp board(root) do
    {:ok, board} = Tasks.load(root)
    board
  end

  # Records tasks as done by `agent` without running their checks.
  defp done!(root, ids, agent \\ "gen") do
    for id <- List.wrap(ids) do
      task = Plan.task(board(root).plan, id)

      state = %State{
        State.new(id)
        | status: :done,
          agents: [agent],
          completed_by: agent,
          completed_at: @now,
          basis: %{plan_sha256: "p", source_sha256: task.source_sha256}
      }

      :ok = Store.put(root, state)
    end
  end

  defp next_ids(root, opts \\ []),
    do:
      root
      |> board()
      |> Tasks.next(Keyword.merge([now: @now, n: 50], opts))
      |> Enum.map(& &1.task.id)

  defp complete(root, id, opts),
    do: Tasks.complete(board(root), id, [now: @now, checks: Pass] ++ opts)

  describe "next" do
    test "lists ready top-level tasks in plan order", %{root: root} do
      assert next_ids(root) ==
               ~w(generate:option_sets generate:styles) ++ ["decision:plugin/" <> @plugin]

      done!(root, ~w(generate:option_sets generate:schema))

      assert next_ids(root) ==
               ~w(generate:api_clients generate:policies generate:routes generate:styles) ++
                 ["decision:plugin/" <> @plugin, "data:dry_run"]

      assert next_ids(root, n: 1) == ["generate:api_clients"]
      assert next_ids(root, actor: :owner) == ["decision:plugin/" <> @plugin]
    end

    test "shows coordinate edges, which do not block", %{root: root} do
      done!(root, @generators ++ ["auth"])

      [entry] =
        root
        |> board()
        |> Tasks.next(now: @now, n: 50)
        |> Enum.filter(&(&1.task.id == "backend:fTwo"))

      assert entry.coordinate == [%{from: "workflow:wApiB", task: "workflow:wApiD", done: false}]
      refute "workflow:wApiB" in next_ids(root)
    end

    test "skips claimed and blocked tasks; a stale done task needs re-verifying", %{root: root} do
      assert {:ok, _} = Tasks.claim(board(root), "generate:option_sets", "a1", now: @now)

      assert {:ok, _} =
               Tasks.note(board(root), "generate:styles",
                 now: @now,
                 by: "a2",
                 kind: :needs_decision,
                 text: "which font?"
               )

      assert next_ids(root) == ["decision:plugin/" <> @plugin]
      assert "generate:option_sets" in next_ids(root, agent: "a1")

      later = DateTime.add(@now, 3, :hour)

      assert "generate:option_sets" in (root
                                        |> board()
                                        |> Tasks.next(now: later, n: 50)
                                        |> Enum.map(& &1.task.id))

      assert {:ok, _} =
               Tasks.resolve_note(board(root), "generate:styles", 1, now: @now, by: "owner")

      assert "generate:styles" in next_ids(root)

      :ok =
        Store.put(root, %{
          board(root).states["generate:option_sets"]
          | status: :done,
            basis: %{plan_sha256: "p", source_sha256: "old"}
        })

      b = board(root)
      assert Tasks.status(b, Plan.task(b.plan, "generate:option_sets"), @now) == :needs_reverify
      refute Tasks.done?(b, "generate:option_sets")
    end
  end

  describe "claim" do
    test "is time-limited and exclusive", %{root: root} do
      assert {:ok, %State{claim: %{agent: "a1", expires_at: expires}}} =
               Tasks.claim(board(root), "generate:option_sets", "a1", now: @now, ttl: 60)

      assert expires == DateTime.add(@now, 60, :second)

      assert {:error, %Error{message: m}} =
               Tasks.claim(board(root), "generate:option_sets", "a2", now: @now)

      assert m =~ "claimed by a1"

      assert {:ok, _} =
               Tasks.claim(board(root), "generate:option_sets", "a2", now: DateTime.add(@now, 61))

      assert board(root).states["generate:option_sets"].agents == ["a1", "a2"]
    end

    test "refuses waiting, closed-by-decision and unknown tasks", %{root: root} do
      assert {:error, %Error{message: m, context: %{waiting_on: ["generate:option_sets"]}}} =
               Tasks.claim(board(root), "generate:schema", "a1", now: @now)

      assert m =~ "waits on"

      assert {:error, %Error{message: "no task" <> _}} =
               Tasks.claim(board(root), "nope", "a1", now: @now)

      assert {:error, %Error{message: "agent must" <> _}} =
               Tasks.claim(board(root), "generate:styles", "a b", now: @now)
    end
  end

  describe "complete" do
    test "records evidence when every criterion passes", %{root: root} do
      assert {:ok, %{outcomes: outcomes}} = complete(root, "generate:option_sets", agent: "gen")
      assert Enum.map(outcomes, & &1.check) == [:generated_unchanged, :deterministic, :compiles]

      state = board(root).states["generate:option_sets"]
      assert %State{status: :done, completed_by: "gen", completed_at: @now, claim: nil} = state

      assert state.basis.source_sha256 ==
               Plan.task(board(root).plan, "generate:option_sets").source_sha256

      assert [%{"criterion" => 1, "check" => "generated_unchanged", "status" => "pass"} | _] =
               state.evidence

      refute Enum.any?(state.evidence, &Map.has_key?(&1, "output"))

      assert File.read!(Path.join(root, ".wtf/tasks/generate%3Aoption_sets.json")) ==
               State.to_json(state)
    end

    test "refuses and records nothing when a criterion fails", %{root: root} do
      assert {:error, %Error{context: %{report: %{outcomes: outcomes}}}} =
               Tasks.complete(board(root), "generate:option_sets",
                 now: @now,
                 agent: "gen",
                 checks: Fail
               )

      assert %{status: :fail, detail: "boom"} = Enum.find(outcomes, &(&1.check == :compiles))
      refute File.exists?(Path.join(root, State.path("generate:option_sets")))
    end

    test "verifies and closes a parent's automatic subtasks with it", %{root: root} do
      done!(root, @generators ++ ["auth"])
      assert {:ok, %{subtasks: subs}} = complete(root, "backend:fOne", agent: "a1")
      assert Enum.map(subs, & &1.task) == ~w(workflow:wApiA workflow:wApiD)
      b = board(root)
      assert Enum.all?(~w(backend:fOne workflow:wApiA workflow:wApiD), &Tasks.done?(b, &1))
    end

    test "an open subtask blocks its parent (subtasks_done)", %{root: root} do
      done!(root, @generators ++ ["auth", "decision:plugin/" <> @plugin])

      done!(root, [
        "plugin:" <> @plugin,
        "surface:reusable/rCard",
        "acceptance:reusable/rCard",
        "fragment:eBig"
      ])

      assert {:error, %Error{context: %{report: %{outcomes: outcomes}}}} =
               complete(root, "surface:page/pHome", agent: "a1")

      assert %{status: :fail, detail: "not done: workflow:wLogin, workflow:wPlug"} =
               Enum.find(outcomes, &(&1.check == :subtasks_done))
    end

    test "attested criteria need an attestation or a waiver with a reason", %{root: root} do
      done!(root, ["generate:api_clients", "generate:option_sets", "generate:schema"])

      assert {:error, %Error{context: %{report: %{outcomes: [o]}}}} =
               complete(root, "setup:secrets", agent: "owner")

      assert o.detail =~ "--attest 1="

      assert {:error, _} = complete(root, "setup:secrets", agent: "owner", attest: %{1 => "done"})

      assert {:error, %Error{message: m}} =
               complete(root, "generate:styles",
                 agent: "gen",
                 waive: %{1 => "no manifest needed here"}
               )

      assert m =~ "only attested"

      assert {:ok, %{outcomes: [%{status: :waived}]}} =
               complete(root, "setup:secrets",
                 agent: "owner",
                 waive: %{1 => "the owner sets secrets in production only"}
               )

      assert [%{"status" => "waived", "detail" => "the owner sets secrets" <> _}] =
               board(root).states["setup:secrets"].evidence
    end

    test "an undecided plugin's decision task cannot be completed", %{root: root} do
      assert {:error, %Error{context: %{report: %{outcomes: [o]}}}} =
               complete(root, "decision:plugin/" <> @plugin, agent: "owner")

      assert o.check == :decision_recorded and o.detail =~ "not in effect"
    end

    test "a needs-decision note blocks completion", %{root: root} do
      {:ok, _} =
        Tasks.note(board(root), "generate:option_sets",
          now: @now,
          by: "a1",
          kind: :needs_decision,
          text: "keep the Bubble sort order?"
        )

      assert {:error, %Error{message: m}} = complete(root, "generate:option_sets", agent: "a1")
      assert m =~ "needs-decision"

      assert {:error, _} =
               Tasks.resolve_note(board(root), "generate:option_sets", 2, now: @now, by: "o")
    end
  end

  describe "independent review" do
    setup %{root: root} do
      done!(root, @generators ++ ["auth"])
      {:ok, _} = Tasks.claim(board(root), "surface:reusable/rCard", "impl", now: @now)
      {:ok, _} = complete(root, "surface:reusable/rCard", agent: "impl")
      :ok
    end

    @summary "Compared the card at 320, 768 and 1280 px against Bubble."

    test "the implementer can neither review nor complete the acceptance", %{root: root} do
      assert {:error, %Error{message: m}} =
               Tasks.review(board(root), "acceptance:reusable/rCard", "impl", @summary, now: @now)

      assert m =~ "must be independent"

      assert {:error, %Error{message: m}} =
               complete(root, "acceptance:reusable/rCard", agent: "impl")

      assert m =~ "independent reviewer"
    end

    test "an independent review completes it", %{root: root} do
      assert {:error, %Error{context: %{report: %{outcomes: outcomes}}}} =
               complete(root, "acceptance:reusable/rCard", agent: "rev")

      assert %{status: :fail, detail: "no review recorded" <> _} =
               Enum.find(outcomes, &(&1.check == :independent_review))

      assert {:error, _} =
               Tasks.review(board(root), "acceptance:reusable/rCard", "rev", "ok", now: @now)

      assert {:ok, _} =
               Tasks.review(board(root), "acceptance:reusable/rCard", "rev", @summary, now: @now)

      assert {:ok, %{outcomes: outcomes}} =
               complete(root, "acceptance:reusable/rCard", agent: "rev")

      assert %{status: :pass, detail: "reviewed by rev"} =
               Enum.find(outcomes, &(&1.check == :independent_review))

      assert %{status: :pass, detail: @summary} = Enum.find(outcomes, &(&1.check == :attested))
      assert Tasks.implementers(board(root), "surface:reusable/rCard") == ["impl"]
    end
  end

  describe "audit" do
    test "flips done tasks whose checks now fail, or whose source changed", %{root: root} do
      {:ok, _} = complete(root, "generate:option_sets", agent: "gen")
      {:ok, _} = complete(root, "generate:styles", agent: "gen")

      assert {:ok, %{checked: checked, flipped: []}} =
               Tasks.audit(board(root), now: @now, checks: Pass)

      assert checked == ~w(generate:option_sets generate:styles)

      assert {:ok, %{flipped: ["generate:option_sets"]}} =
               Tasks.audit(board(root), now: @now, checks: Fail, tasks: ["generate:option_sets"])

      assert %State{status: :needs_reverify, reverify: %{"source" => "audit", "failed" => [3]}} =
               board(root).states["generate:option_sets"]

      state = board(root).states["generate:styles"]
      :ok = Store.put(root, %{state | basis: %{state.basis | source_sha256: "old"}})

      assert {:ok, %{flipped: ["generate:styles"]}} =
               Tasks.audit(board(root), now: @now, checks: Pass, tasks: ["generate:styles"])

      assert %{"reasons" => ["source_changed"]} = board(root).states["generate:styles"].reverify
    end

    test "keeps recorded attestations", %{root: root} do
      done!(root, ["generate:api_clients", "generate:option_sets", "generate:schema"])

      {:ok, _} =
        complete(root, "setup:secrets",
          agent: "owner",
          attest: %{all: "Secrets are set in the staging vault."}
        )

      assert {:ok, %{flipped: []}} =
               Tasks.audit(board(root), now: @now, checks: Pass, tasks: ["setup:secrets"])
    end
  end

  describe "sync" do
    test "marks what a plan change touches, never owned code", %{root: root, plan: old} do
      done!(root, @generators ++ ~w(auth backend:fOne backend:fTwo workflow:wApiC workflow:wApiB))
      :ok = Store.put(root, %{State.new("gone:task") | status: :done})
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/owned.ex"), "owned")

      new =
        @app
        |> put_in(["api", "wfApiC", "actions", "0", "properties", "condition"], %{
          "type" => "LiteralBoolean",
          "properties" => %{"value" => false}
        })
        |> plan()

      new_path = Path.join(root, "new_plan.json")
      File.write!(new_path, Plan.to_json(new))
      {:ok, decoded} = Store.read_plan_file(new_path)

      assert {:ok, result} = Tasks.sync(board(root), old, decoded, now: @now, write_plan: true)
      assert "workflow:wApiC" in result.reverify
      assert "backend:fTwo" in result.reverify
      refute "generate:schema" in result.reverify
      assert result.removed == []

      b = board(root)
      assert b.plan.plan_sha256 == new.plan_sha256

      assert %State{
               status: :needs_reverify,
               reverify: %{"source" => "sync", "reasons" => [_ | _]}
             } = b.states["workflow:wApiC"]

      assert b.states["backend:fTwo"].status == :needs_reverify
      # It is re-verified after what it depends on that changed.
      assert Tasks.waiting_on(b, Plan.task(b.plan, "backend:fTwo")) != []
      assert File.read!(Path.join(root, "lib/owned.ex")) == "owned"
    end

    test "a removed task's state is kept as removed", %{root: root, plan: plan} do
      done!(root, "workflow:wApiE")
      smaller = %{plan | tasks: Enum.reject(plan.tasks, &(&1.id in ~w(workflow:wApiE)))}

      assert {:ok, %{removed: ["workflow:wApiE"]}} =
               Tasks.sync(board(root), plan, smaller, now: @now)

      assert board(root).states["workflow:wApiE"].status == :removed

      assert {:ok, %{reopened: ["workflow:wApiE"]}} =
               Tasks.sync(board(root), smaller, plan, now: @now)
    end
  end

  describe "evidence" do
    test "reads results (latest per id) and records other files as artifacts", %{root: root} do
      dir = Path.join(root, ".wtf/verification/results")
      File.mkdir_p!(dir)

      for {name, at, status} <- [
            {"old", ~U[2026-09-26 09:00:00Z], :fail},
            {"new", ~U[2026-09-26 10:00:00Z], :pass}
          ] do
        {:ok, r} =
          Result.new(%{
            id: "det",
            app: "app1",
            check: "deterministic",
            status: status,
            actor: "ci",
            ran_at: at,
            tasks: ["generate:option_sets"]
          })

        File.write!(Path.join(dir, name <> ".json"), Result.to_json(r))
      end

      shot = Path.join(root, "shot.png")
      File.write!(shot, "png")

      assert {:ok, %{results: [{ref, sha, %Result{status: :pass}}], artifacts: [artifact]}} =
               Tasks.evidence(root, [shot])

      assert ref == ".wtf/verification/results/new.json"

      assert sha ==
               :sha256
               |> :crypto.hash(File.read!(Path.join(dir, "new.json")))
               |> Base.encode16(case: :lower)

      assert artifact.ref == "shot.png"

      assert {:error, %Error{message: "no evidence at" <> _}} =
               Tasks.evidence(root, [Path.join(root, "missing")])
    end
  end

  describe "state files" do
    test "round-trip canonically, one per task, named by the task ID" do
      state = %State{
        State.new("surface:page/pHome")
        | status: :done,
          claim: %{agent: "a", claimed_at: @now, expires_at: @now},
          agents: ["a"],
          notes: [
            %{
              n: 1,
              kind: :info,
              text: "hi",
              by: "a",
              at: @now,
              resolved_by: nil,
              resolved_at: nil
            }
          ],
          review: %{reviewer: "r", at: @now, summary: "s"}
      }

      assert State.filename("surface:page/pHome") == "surface%3Apage%2FpHome.json"
      json = State.to_json(state)
      assert {:ok, decoded} = State.decode(json)
      assert State.to_json(decoded) == json
      assert decoded.notes == state.notes

      assert {:error, _} =
               State.decode(%{
                 "format" => "bubble_ex.task_state",
                 "schema_version" => 1,
                 "task" => "x",
                 "status" => "weird"
               })
    end

    test "a state in another task's file is refused", %{root: root} do
      :ok = Store.put(root, State.new("auth"))
      File.rename!(Path.join(root, State.path("auth")), Path.join(root, ".wtf/tasks/other.json"))
      assert {:error, %Error{message: m}} = Tasks.load(root)
      assert m =~ "another task"
    end
  end
end
