defmodule BubbleEx.PlanTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Error, Findings, Index, Model, Plan, SampleHelper}
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.{Node, Source}
  alias BubbleEx.Plan.{Criteria, Residue, Task}
  alias BubbleEx.Test.DecidedFixture

  # Invented app (test/support/samples/synthetic_plan_export.json): a home
  # page with a large group, a reusable card instance, a plugin element and
  # six workflows (a custom-event pair calling each other, a plugin action,
  # a log-in); a card reusable, two reusables containing each other; a
  # mobile view; five backend workflows in two folders and none, one
  # scheduling itself and two calling across folders both ways; one API
  # Connector group with a private header and a used and an unused call.
  @app SampleHelper.load_json_sample("synthetic_plan_export")
  @plugin "1600000000000x100000000000000000"

  setup_all do
    {:ok, model} = Model.build(@app)
    {:ok, index} = Index.build(@app, model: model)
    {:ok, plan} = Plan.build(model, index, nil, [], fragment_threshold: 2)
    %{model: model, index: index, plan: plan}
  end

  defp task!(plan, id), do: Plan.task(plan, id) || flunk("no task #{id}")
  defp deps(task), do: Enum.map(task.depends_on, &{&1.task, &1.kind})
  defp ids(tasks), do: tasks |> Enum.map(& &1.id) |> Enum.sort()

  describe "tasks" do
    test "one per surface and backend folder, workflows as subtasks", %{plan: plan} do
      assert plan |> Plan.top_level() |> ids() ==
               Enum.sort(
                 ~w(generate:schema generate:option_sets generate:policies generate:styles
                    generate:api_clients generate:routes generate:surfaces
                    generate:workflow_entry_points setup:secrets auth
                    surface:page/pHome surface:reusable/rCard fragment:eBig
                    cycle:reusable/rA+rB cycle:wLoopA+wLoopB
                    acceptance:page/pHome acceptance:reusable/rCard acceptance:reusable/rA
                    acceptance:reusable/rB backend:fOne backend:fTwo backend:unfiled
                    api_group:grpMail data:dry_run data:full_load replay:app
                    delivery:staging delivery:callers delivery:production) ++
                   ["plugin:" <> @plugin, "decision:plugin/" <> @plugin] ++
                   Enum.map(
                     ~w(rehearsal runbook communications freeze final_delta switch verify sign_off),
                     &("cutover:" <> &1)
                   )
               )

      assert plan |> Plan.subtasks("surface:page/pHome") |> ids() ==
               ~w(workflow:wClick workflow:wLogin workflow:wNotify workflow:wPlug)

      assert plan |> Plan.subtasks("backend:fOne") |> ids() == ~w(workflow:wApiA workflow:wApiD)
      assert plan |> Plan.subtasks("backend:fTwo") |> ids() == ~w(workflow:wApiB workflow:wApiC)
      assert plan |> Plan.subtasks("backend:unfiled") |> ids() == ~w(workflow:wApiE)
      assert plan |> Plan.subtasks("api_group:grpMail") |> ids() == ~w(api_call:grpMail/callSend)
      assert %Task{kind: :workflow, actor: :agent} = task!(plan, "workflow:wCard")
    end

    test "leave out mobile views and unused API calls", %{plan: plan} do
      refute Plan.task(plan, "workflow:wMob")
      refute Plan.task(plan, "surface:page/mOne")
      refute Plan.task(plan, "api_call:grpMail/callUnused")
      assert plan.coverage["excluded"] == %{"mobile_views" => 1, "mobile_view_workflows" => 1}
    end

    test "auto-close what has no residue; residue opens the task and its parent", %{plan: plan} do
      assert %Task{status: :auto, actor: :generator} = task!(plan, "generate:schema")
      assert %Task{status: :auto} = task!(plan, "workflow:wClick")
      assert %Task{status: :auto} = task!(plan, "surface:reusable/rCard")
      assert %Task{status: :auto} = task!(plan, "backend:fOne")
      assert %Task{status: :auto} = task!(plan, "api_group:grpMail")

      assert %Task{status: :open, residue: [%{subject: "action:aPlug", reason: :plugin_action}]} =
               task!(plan, "workflow:wPlug")

      assert %Task{status: :open, residue: [%{subject: "action:aLogin", reason: :auth_action}]} =
               task!(plan, "workflow:wLogin")

      assert %Task{status: :open, residue: [%{subject: "element:ePlug", reason: :plugin_element}]} =
               task!(plan, "surface:page/pHome")

      assert %Task{status: :open, actor: :reviewer} = task!(plan, "acceptance:reusable/rCard")
      assert %Task{status: :open, subjects: ["workflow:wLogin"]} = task!(plan, "auth")

      assert %Task{status: :open, actor: :owner, subjects: ["api_group:grpMail"]} =
               task!(plan, "setup:secrets")

      assert %Task{subjects: ["action:aPlug", "element:ePlug", "plugin:" <> @plugin]} =
               task!(plan, "plugin:" <> @plugin)
    end

    test "a large top-level container is a fragment with its own residue", ctx do
      assert %Task{kind: :fragment, subjects: ["element:eBig"], batch: "surface:page/pHome"} =
               task!(ctx.plan, "fragment:eBig")

      {:ok, plan} = Plan.build(ctx.model, ctx.index)
      refute Plan.task(plan, "fragment:eBig")
    end
  end

  describe "dependencies" do
    test "generate first, reusables before consumers, then acceptance", %{plan: plan} do
      home = task!(plan, "surface:page/pHome")

      assert {"surface:reusable/rCard", :reusable} in deps(home)
      assert {"acceptance:reusable/rCard", :reusable} in deps(home)
      assert {"fragment:eBig", :fragment} in deps(home)
      assert {"auth", :early} in deps(home)
      assert {"generate:surfaces", :generate} in deps(home)
      assert {"plugin:" <> @plugin, :plugin} in deps(home)

      assert %{via: ["element:eCard"]} =
               Enum.find(home.depends_on, &(&1.task == "surface:reusable/rCard"))

      assert Enum.sort(deps(task!(plan, "acceptance:page/pHome"))) ==
               Enum.sort([
                 {"surface:page/pHome", :acceptance},
                 {"fragment:eBig", :acceptance},
                 {"acceptance:reusable/rCard", :acceptance},
                 {"cycle:wLoopA+wLoopB", :acceptance}
               ])
    end

    test "callees, API groups and plugins before the workflows using them", %{plan: plan} do
      assert Enum.sort(deps(task!(plan, "workflow:wClick"))) == [
               {"api_group:grpMail", :api},
               {"workflow:wApiA", :calls},
               {"workflow:wNotify", :calls}
             ]

      assert deps(task!(plan, "workflow:wPlug")) == [{"plugin:" <> @plugin, :plugin}]
      assert {"setup:secrets", :secrets} in deps(task!(plan, "api_group:grpMail"))
    end

    test "a workflow cycle is one task with no edges inside", %{plan: plan} do
      assert %Task{kind: :cycle, subjects: ["workflow:wLoopA", "workflow:wLoopB"]} =
               task!(plan, "cycle:wLoopA+wLoopB")

      assert %Task{parent: "cycle:wLoopA+wLoopB", depends_on: []} = task!(plan, "workflow:wLoopA")
      assert %Task{parent: "cycle:wLoopA+wLoopB", depends_on: []} = task!(plan, "workflow:wLoopB")
      assert {"generate:surfaces", :generate} in deps(task!(plan, "cycle:wLoopA+wLoopB"))

      # A workflow scheduling itself stays in its folder.
      assert %Task{parent: "backend:fOne", depends_on: []} = task!(plan, "workflow:wApiD")

      assert plan.coverage["units"]["cycles"] == %{
               "workflow" => 1,
               "self_recursive" => 1,
               "reusable" => 1
             }
    end

    test "reusables containing each other are one task", %{plan: plan} do
      assert %Task{kind: :cycle, subjects: ["reusable:rA", "reusable:rB"]} =
               task!(plan, "cycle:reusable/rA+rB")

      refute Plan.task(plan, "surface:reusable/rA")

      assert deps(task!(plan, "acceptance:reusable/rA")) == [
               {"cycle:reusable/rA+rB", :acceptance}
             ]

      assert plan.skipped |> Enum.filter(&(&1.kind != :calls)) == []
    end

    test "an edge that would close a cycle between top-level tasks is kept non-blocking",
         %{plan: plan} do
      # fOne's wApiA calls fTwo's wApiC first (by ID), so fTwo's wApiB -> fOne's
      # wApiD would make the folders wait on each other.
      assert {"workflow:wApiC", :calls} in deps(task!(plan, "workflow:wApiA"))

      caller = task!(plan, "workflow:wApiB")
      assert deps(caller) == [{"workflow:wApiD", :coordinate}]
      assert [%{via: ["action:aToD"]}] = caller.depends_on

      assert %{args: %{workflows: ["workflow:wApiB"], rerun_after: ["workflow:wApiD"]}} =
               Enum.find(caller.criteria, &(&1.check == :unit_test))

      assert plan.skipped == [
               %{
                 from: "workflow:wApiB",
                 to: "workflow:wApiD",
                 kind: :calls,
                 via: ["action:aToD"],
                 reason: :would_cycle,
                 kept_as: :coordinate
               }
             ]
    end

    test "the order respects every dependency", %{plan: plan} do
      order = Map.new(plan.tasks, &{&1.id, &1.order})
      root = fn id -> root(plan, id) end

      assert Enum.map(plan.tasks, & &1.order) == Enum.to_list(0..(length(plan.tasks) - 1))

      for t <- plan.tasks, d <- t.depends_on, d.kind != :coordinate do
        if root.(t.id) == root.(d.task),
          do: assert(order[d.task] < order[t.id], "#{t.id} before #{d.task}"),
          else: assert(order[root.(d.task)] < order[root.(t.id)], "#{t.id} before #{d.task}")
      end

      for t <- plan.tasks, t.parent, do: assert(order[t.parent] < order[t.id])

      assert hd(plan.tasks).kind == :generate
      assert List.last(plan.tasks).id == "cutover:sign_off"
      assert order["surface:reusable/rCard"] < order["surface:page/pHome"]
      assert order["backend:fTwo"] < order["backend:fOne"]
      assert order["fragment:eBig"] < order["surface:page/pHome"]
    end
  end

  defp root(plan, id) do
    case Plan.task(plan, id) do
      %Task{parent: nil} -> id
      %Task{parent: parent} -> root(plan, parent)
    end
  end

  describe "criteria" do
    test "are abstract checks; only attested ones can be waived", %{plan: plan} do
      for t <- plan.tasks, c <- t.criteria do
        assert c.check in Criteria.checks()
        assert c.waiver == if(c.check == :attested, do: :allowed, else: :forbidden)
      end

      for t <- plan.tasks,
          do: assert(Enum.map(t.criteria, & &1.id) == Enum.to_list(1..length(t.criteria)//1))
    end

    test "trace the surface's own elements and order the workflow's steps", %{plan: plan} do
      home = task!(plan, "surface:page/pHome")

      assert %{args: %{elements: elements}} =
               Enum.find(home.criteria, &(&1.check == :traceability))

      assert elements ==
               ~w(page:pHome element:eCard element:eLogin element:ePlug)

      assert Enum.any?(home.criteria, &(&1.check == :subtasks_done))

      assert %{args: %{workflow: "workflow:wClick", steps: steps}} =
               Enum.find(task!(plan, "workflow:wClick").criteria, &(&1.check == :step_order))

      assert steps == ["TriggerCustomEvent", "ScheduleAPIEvent", "apiconnector2-grpMail.callSend"]

      assert Enum.any?(task!(plan, "workflow:wApiC").criteria, &(&1.check == :unit_test))

      assert %{args: %{of: "surface:page/pHome"}} =
               Enum.find(
                 task!(plan, "acceptance:page/pHome").criteria,
                 &(&1.check == :independent_review)
               )
    end
  end

  describe "decisions" do
    setup do
      %{model: model, index: index, applied: applied} = fixture = DecidedFixture.build(:derive)

      {:ok, decided} =
        Plan.build(model, index, nil, applied, decisions_sha256: fixture.decisions_sha256)

      {:ok, faithful} = Plan.build(model, index)

      derive =
        Enum.find(
          applied,
          &(&1.transform == :derive_from_related and not &1.automatic and
              &1.proposal.delete_workflows != [])
        )

      %{index: index, decided: decided, faithful: faithful, derive: derive, fixture: fixture}
    end

    test "removed writes and deleted workflows become nodes the decision closes", ctx do
      %{decided: plan, derive: derive} = ctx

      assert %Task{
               kind: :remove_writes,
               status: :closed,
               actor: :generator,
               closed_by: key,
               subjects: writes
             } = task!(plan, "remove_writes:" <> derive.finding_id)

      assert key == derive.key

      assert writes ==
               derive.proposal.remove_writes
               |> Enum.map(& &1.action)
               |> Enum.uniq()
               |> Enum.sort()

      assert %Task{kind: :delete_workflows, status: :closed, closed_by: ^key, subjects: deleted} =
               task!(plan, "delete_workflows:" <> derive.finding_id)

      assert deleted ==
               Enum.sort(derive.proposal.delete_workflows ++ derive.proposal.remove_calls)

      assert Enum.any?(
               task!(plan, "remove_writes:" <> derive.finding_id).criteria,
               &(&1.check == :decision_recorded)
             )

      # The deleted workflow has no task; it has one without the decision.
      for w <- derive.proposal.delete_workflows do
        refute Plan.task(plan, w)
        assert Plan.task(ctx.faithful, w)
      end

      removing =
        Enum.count(
          ctx.fixture.applied,
          &(not &1.automatic and Map.get(&1.proposal, :remove_writes, []) != [])
        )

      assert plan.coverage["tasks"]["remove_writes"]["closed"] == removing
      assert plan.inputs.decisions_sha256 == ctx.fixture.decisions_sha256
    end

    test "workflows keeping a removed write wait for it and hash the decision", ctx do
      %{decided: plan, faithful: faithful, derive: derive, index: index} = ctx
      node = "remove_writes:" <> derive.finding_id

      kept =
        for %{action: a} <- derive.proposal.remove_writes,
            w = Index.ancestor(index, a, :workflow).id,
            w not in derive.proposal.delete_workflows,
            uniq: true,
            do: w

      assert kept != []

      for w <- kept do
        task = task!(plan, w)
        assert {node, :decision} in deps(task)
        assert derive.key in task.decisions
        assert task.source_sha256 != task!(faithful, w).source_sha256
      end

      # A dropped action is not a step.
      for %{action: a} <- derive.proposal.remove_writes,
          w = Index.ancestor(index, a, :workflow).id,
          w in kept do
        steps = Enum.find(task!(plan, w).criteria, &(&1.check == :step_order)).args.steps

        faithful_steps =
          Enum.find(task!(faithful, w).criteria, &(&1.check == :step_order)).args.steps

        assert length(steps) <= length(faithful_steps)
      end

      assert derive.key in task!(plan, "generate:schema").decisions
    end

    test "a hint applied by default that removes writes gets its node too", ctx do
      hint = %{ctx.derive | automatic: true, basis: nil, decision_id: nil}
      %{model: model, index: index} = ctx.fixture
      {:ok, plan} = Plan.build(model, index, nil, [hint])

      assert %Task{status: :closed, closed_by: key} =
               task!(plan, "remove_writes:" <> hint.finding_id)

      assert key == hint.key
    end

    test "a task no decision touches keeps its hash", ctx do
      untouched =
        for t <- ctx.decided.tasks, t.decisions == [], t.kind == :workflow, do: t

      assert untouched != []

      for t <- untouched,
          do: assert(t.source_sha256 == task!(ctx.faithful, t.id).source_sha256)
    end
  end

  describe "plugins" do
    # The plugin (not installed, no known equivalent) has an element on the
    # home page and an action in wPlug; wPlugEvent (added here) runs on one
    # of its events.
    setup ctx do
      app =
        put_in(@app, ["pages", "pgHome", "workflows", "wfPlugEvent"], %{
          "id" => "wPlugEvent",
          "type" => @plugin <> "-AAC",
          "properties" => %{"element_id" => "ePlug"},
          "actions" => %{"0" => %{"id" => "aAfterEvent", "type" => "RefreshPage"}}
        })

      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)
      {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)
      finding = Enum.find(findings, &(&1.kind == :plugin))
      {:ok, undecided} = Plan.build(model, index)

      decide = fn choice, params ->
        {:ok, record} = Decision.for_finding(finding, choice, params)

        {:ok, resolved} =
          Decision.resolve([record], findings, index: index, now: ~U[2026-09-26 00:00:00Z])

        applied = Decision.applicable(resolved, findings)
        {:ok, plan} = Plan.build(model, index, nil, applied, resolved: resolved)
        {plan, "finding:" <> finding.id}
      end

      Map.merge(ctx, %{finding: finding, undecided: undecided, decide: decide})
    end

    test "an undecided plugin blocks its task on the owner's decision", ctx do
      %{undecided: plan, finding: finding} = ctx
      key = "finding:" <> finding.id
      id = "decision:plugin/" <> @plugin

      assert %Task{kind: :decision, actor: :owner, status: :open, subjects: [sym]} =
               decision = task!(plan, id)

      assert sym == "plugin:" <> @plugin
      assert [%{check: :decision_recorded, args: %{key: ^key}}] = decision.criteria

      plugin = task!(plan, "plugin:" <> @plugin)
      assert {id, :decision} in deps(plugin)
      assert Enum.find(plugin.criteria, &(&1.check == :decision_recorded)).args.key == key

      for user <- ~w(surface:page/pHome workflow:wPlug workflow:wPlugEvent),
          do: assert({"plugin:" <> @plugin, :plugin} in deps(task!(plan, user)), user)

      order = Map.new(plan.tasks, &{&1.id, &1.order})
      assert order[id] < order["plugin:" <> @plugin]

      assert plan.coverage["units"]["plugins"] == %{
               "tasks" => 1,
               "undecided" => 1,
               "dropped" => 0
             }
    end

    test "a decided rebuild unblocks the plugin and is part of its users' hashes", ctx do
      assert ctx.finding.proposal.option == :rebuild
      {plan, key} = ctx.decide.(:accept, %{})

      refute Plan.task(plan, "decision:plugin/" <> @plugin)
      plugin = task!(plan, "plugin:" <> @plugin)
      assert %Task{status: :open, actor: :agent} = plugin
      assert key in plugin.decisions
      refute Enum.any?(plugin.depends_on, &(&1.kind == :decision))

      for user <- ~w(surface:page/pHome workflow:wPlug workflow:wPlugEvent) do
        task = task!(plan, user)
        assert {"plugin:" <> @plugin, :plugin} in deps(task)
        assert key in task.decisions
        assert task.source_sha256 != task!(ctx.undecided, user).source_sha256
      end

      untouched = task!(plan, "workflow:wClick")
      assert untouched.decisions == []
      assert untouched.source_sha256 == task!(ctx.undecided, "workflow:wClick").source_sha256
    end

    test "a decided drop removes the plugin, its uses and the dependency", ctx do
      {plan, key} = ctx.decide.(:modify, %{"option" => "drop"})

      assert %Task{kind: :plugin, status: :closed, actor: :generator, closed_by: ^key} =
               plugin = task!(plan, "plugin:" <> @plugin)

      assert [%{check: :decision_recorded, args: %{key: ^key}}] = plugin.criteria
      refute Plan.task(plan, "decision:plugin/" <> @plugin)
      refute Enum.any?(plan.tasks, fn t -> Enum.any?(t.depends_on, &(&1.kind == :plugin)) end)

      # Its element renders nothing, its action is skipped and the workflow
      # its event triggers never runs.
      home = task!(plan, "surface:page/pHome")
      refute Enum.any?(home.residue, &(&1.subject == "element:ePlug"))
      assert key in home.decisions
      assert %Task{residue: [], status: :auto} = wplug = task!(plan, "workflow:wPlug")
      assert Enum.find(wplug.criteria, &(&1.check == :step_order)).args.steps == []
      refute Plan.task(plan, "workflow:wPlugEvent")
      assert Plan.task(ctx.undecided, "workflow:wPlugEvent")

      assert plan.coverage["units"]["plugins"] == %{
               "tasks" => 0,
               "undecided" => 0,
               "dropped" => 1
             }

      assert plan.coverage["units"]["workflows_removed"] == 1
    end

    test "a plugin decision cannot be a reject", ctx do
      assert {:error, %Error{kind: :invalid_input}} = Decision.for_finding(ctx.finding, :reject)

      assert {:error, %Error{kind: :invalid_input}} =
               Decision.for_finding(ctx.finding, :modify, %{"option" => "replace_native"})
    end
  end

  describe "determinism" do
    test "the same inputs give the same JSON", ctx do
      {:ok, again} = Plan.build(ctx.model, ctx.index, nil, [], fragment_threshold: 2)
      assert Plan.to_json(again) == Plan.to_json(ctx.plan)
      assert again.plan_sha256 == ctx.plan.plan_sha256

      decoded = ctx.plan |> Plan.to_json() |> Jason.decode!()
      assert decoded["schema_version"] == Plan.schema_version()
      assert length(decoded["tasks"]) == length(ctx.plan.tasks)

      assert %{"id" => "workflow:wClick", "kind" => "workflow", "status" => "auto"} =
               Enum.find(decoded["tasks"], &(&1["id"] == "workflow:wClick"))
    end

    test "IDs and task hashes ignore JSON placement and display names", ctx do
      moved =
        @app
        |> update_in(["pages"], fn pages ->
          %{"pgMoved" => rename_all(pages["pgHome"])}
        end)
        |> update_in(["api"], fn api -> Map.new(api, fn {k, v} -> {"moved_" <> k, v} end) end)

      {:ok, model} = Model.build(moved)
      {:ok, index} = Index.build(moved, model: model)
      {:ok, plan} = Plan.build(model, index, nil, [], fragment_threshold: 2)

      assert ids(plan.tasks) == ids(ctx.plan.tasks)

      for t <- plan.tasks,
          do: assert(t.source_sha256 == task!(ctx.plan, t.id).source_sha256, t.id)

      refute task!(plan, "surface:page/pHome").label ==
               task!(ctx.plan, "surface:page/pHome").label

      refute Plan.to_json(plan) == Plan.to_json(ctx.plan)
    end

    test "a content change changes the covering tasks' hashes only", ctx do
      changed =
        put_in(@app, ["api", "wfApiC", "actions", "0", "type"], "DeleteThing")

      {:ok, model} = Model.build(changed)
      {:ok, index} = Index.build(changed, model: model)
      {:ok, plan} = Plan.build(model, index, nil, [], fragment_threshold: 2)

      changed_ids =
        for t <- plan.tasks,
            t.source_sha256 != task!(ctx.plan, t.id).source_sha256,
            do: t.id

      assert "workflow:wApiC" in changed_ids
      assert "backend:fTwo" in changed_ids
      assert "generate:workflow_entry_points" in changed_ids
      refute "workflow:wApiA" in changed_ids
      refute "surface:page/pHome" in changed_ids
    end
  end

  # Every display name in a page tree, changed.
  defp rename_all(%{} = map) do
    Map.new(map, fn
      {k, v} when k in ["name", "default_name", "event_name"] and is_binary(v) ->
        {k, v <> " (renamed)"}

      {k, v} ->
        {k, rename_all(v)}
    end)
  end

  defp rename_all(other), do: other

  describe "residue" do
    test "frontend placeholders are element residue; unreached triggers keep workflows open",
         ctx do
      node = fn id, kind, children ->
        %Node{
          exporter_id: id,
          kind: kind,
          map_key: id,
          source: %Source{bubble_id: id},
          children: children
        }
      end

      placeholder = fn id, variant ->
        %{node.(id, :placeholder, []) | variant: variant, placeholder?: true}
      end

      # eBig is a runtime container: its content (eT1, eT2, eBtn) is not normalized.
      frontend = %Normalized{
        pages: [
          node.("pHome", :page, [
            placeholder.("eBig", :runtime_overlay),
            placeholder.("ePlug", :unsupported_kind),
            node.("eCard", :reusable_instance, []),
            node.("eLogin", :button, [])
          ])
        ],
        reusables: [node.("rCard", :reusable_definition, [node.("eCardText", :text, [])])],
        styles: []
      }

      # The plugin element stays the index's plugin residue.
      assert Residue.frontend(frontend, ctx.index) == [
               %{subject: "element:eBig", reason: :runtime_container, detail: %{}},
               %{
                 subject: "workflow:wClick",
                 reason: :trigger_not_normalized,
                 detail: %{element: "element:eBtn"}
               }
             ]

      {:ok, plan} = Plan.build(ctx.model, ctx.index, frontend)
      assert %Task{status: :open} = task!(plan, "surface:page/pHome")
      assert %Task{status: :open} = task!(plan, "workflow:wClick")
      assert %Task{status: :auto} = task!(plan, "workflow:wCard")

      # Only normalized elements without residue count as generated.
      assert plan.coverage["units"]["elements"] == %{
               "total" => 10,
               "generated" => 3,
               "residue" => 2,
               "not_normalized" => 5,
               "not_normalized_with_residue" => 0
             }

      assert plan.coverage["units"]["workflows_trigger_not_normalized"] == 1
    end

    test "expressions that do not compile are residue of their owner" do
      app = SampleHelper.load_json_sample("synthetic_index_export")
      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)

      {:ok, entries} = Residue.expressions(app, model, index)

      for e <- entries do
        assert %{reason: :uncompiled_expression, detail: %{expressions: n, constructs: [_ | _]}} =
                 e

        assert n > 0
        assert Index.symbol(index, e.subject)
      end

      # A target check makes compiled expressions residue too.
      {:ok, all} = Residue.expressions(app, model, index, check: fn _ir, _site -> ["target"] end)
      assert length(all) > length(entries)
      assert Enum.all?(all, &(Index.symbol(index, &1.subject) != nil))

      {:ok, plan} = Plan.build(model, index, nil, [], residue: all)
      assert Enum.any?(plan.tasks, &(&1.status == :open and &1.kind == :workflow))
    end

    test "styles: conditional states and plugin styles" do
      hover = %{
        "type" => "State",
        "condition" => %{
          "type" => "ThisElement",
          "next" => %{"type" => "Message", "name" => "is_hovered"}
        }
      }

      custom = %{
        "type" => "State",
        "condition" => %{"type" => "CurrentUser", "next" => %{"name" => "logged_in"}}
      }

      app = %{
        "styles" => %{
          "Button_plain_" => %{"properties" => %{}, "states" => %{"a" => hover}},
          "Button_user_" => %{"properties" => %{}, "states" => %{"a" => hover, "b" => custom}},
          (@plugin <> "-AAC_default_") => %{"properties" => %{}}
        }
      }

      assert Residue.styles(app) == [
               %{
                 subject: "style:#{@plugin}-AAC_default_",
                 reason: :plugin_style,
                 detail: %{plugin: @plugin}
               },
               %{subject: "style:Button_user_", reason: :style_condition, detail: %{states: 1}}
             ]
    end

    test "plugin IDs ignore version suffixes" do
      assert Residue.plugin("1667491822004x826705920831258600_current-AAD") ==
               "1667491822004x826705920831258600"

      assert Residue.plugin("apiconnector2-grp.call") == nil
      assert Residue.plugin("Button") == nil
    end
  end

  describe "backend folders" do
    test "without folder membership every backend workflow is in backend:unfiled" do
      # Live payloads carry no backend workflows; `wf_folder` comes from
      # `.bubble` exports (the split-export loader restores it).
      app =
        update_in(@app, ["api"], fn api ->
          Map.new(api, fn {k, wf} ->
            {k, update_in(wf, ["properties"], &Map.delete(&1, "wf_folder"))}
          end)
        end)

      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)
      {:ok, plan} = Plan.build(model, index)

      assert plan |> Plan.top_level() |> Enum.filter(&(&1.kind == :backend)) |> ids() ==
               ["backend:unfiled"]

      assert plan |> Plan.subtasks("backend:unfiled") |> ids() ==
               ~w(workflow:wApiA workflow:wApiB workflow:wApiC workflow:wApiD workflow:wApiE)

      # One task, so no calls between folders to coordinate.
      assert plan.skipped == []
    end
  end

  describe "input" do
    test "rejects stale decisions" do
      %{model: model, index: index, applied: applied} = DecidedFixture.build(:derive)
      [decided | _] = for a <- applied, not a.automatic, do: a

      stale = %{decided | basis: %{decided.basis | basis_sha256: String.duplicate("0", 64)}}

      assert {:error, %Error{kind: :invalid_input, context: %{key: key}}} =
               Plan.build(model, index, nil, [stale | List.delete(applied, decided)])

      assert key == decided.key

      forged = %{decided | automatic: true}
      assert {:error, %Error{}} = Plan.build(model, index, nil, [forged])
    end

    test "rejects what is not a plan input", ctx do
      assert {:error, %Error{kind: :invalid_input}} = Plan.build(%{}, ctx.index)
      assert {:error, %Error{kind: :invalid_input}} = Plan.build(ctx.model, ctx.index, nil, [%{}])

      assert {:error, %Error{kind: :invalid_input}} =
               Plan.build(ctx.model, ctx.index, nil, [],
                 residue: [%{subject: "x", reason: :nope, detail: %{}}]
               )

      assert {:error, %Error{kind: :invalid_input}} =
               Plan.build(ctx.model, ctx.index, nil, [], fragment_threshold: 0)
    end
  end
end
