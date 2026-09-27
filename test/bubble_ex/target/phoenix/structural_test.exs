defmodule BubbleEx.Target.Phoenix.StructuralTest do
  # The structural verification pack (WTF-386): symbol and policy
  # coverage, the bypass inventory, the manifest and determinism at
  # generation (`run/2`), and the owner-repository checks (`project/2`).
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, Plan, SampleHelper}
  alias BubbleEx.Target.{ApiClients, Ash, Phoenix}
  alias BubbleEx.Target.Ash.Workflows
  alias BubbleEx.Target.Phoenix.Structural
  alias BubbleEx.Target.Phoenix.Structural.Bypasses
  alias BubbleEx.Verify.Result
  alias BubbleEx.Workflows.Backend

  @now ~U[2026-09-27 12:00:00Z]
  @opts [app: "acme", now: @now]

  defp build(app, render? \\ true) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    {:ok, plan} = Plan.build(model, index, frontend, [])
    {:ok, project} = Ash.map(model, [], privacy: :omit)
    {:ok, backend} = Backend.build(app, model, index)
    {:ok, workflows} = Workflows.map(backend, project, namespace: "Acme")
    {:ok, api_clients} = ApiClients.map(model)

    inputs = %{
      model: model,
      index: index,
      plan: plan,
      project: project,
      workflows: workflows,
      api_clients: api_clients
    }

    if render? do
      opts = [
        name: "Acme",
        module: "Acme",
        frontend: frontend,
        workflows: workflows,
        api_clients: api_clients
      ]

      {:ok, files} = Phoenix.render(project, opts)
      {:ok, rerender} = Phoenix.render(project, opts)
      Map.merge(inputs, %{files: files, rerender: rerender})
    else
      inputs
    end
  end

  defp result(report, id), do: Enum.find(report.results, &(&1.id == id))

  defp statuses(report), do: Map.new(report.results, &{&1.id, &1.status})

  describe "run/2 on the plan sample" do
    setup do
      inputs = build(SampleHelper.load_json_sample("synthetic_plan_export"))
      {:ok, report} = Structural.run(inputs, @opts)
      %{inputs: inputs, report: report}
    end

    test "every structural check passes, except policy coverage, skipped with privacy omitted",
         %{report: report} do
      assert statuses(report) == %{
               "structural.bypass_inventory" => :pass,
               "structural.deterministic" => :pass,
               "structural.generated_unchanged" => :pass,
               "structural.policy_coverage" => :skipped,
               "structural.symbol_coverage.api_calls" => :pass,
               "structural.symbol_coverage.data_types" => :pass,
               "structural.symbol_coverage.fields" => :pass,
               "structural.symbol_coverage.option_sets" => :pass,
               "structural.symbol_coverage.option_values" => :pass,
               "structural.symbol_coverage.pages" => :pass,
               "structural.symbol_coverage.reusables" => :pass,
               "structural.symbol_coverage.workflows" => :pass
             }

      policy = result(report, "structural.policy_coverage")
      assert policy.reason =~ "privacy: :omit - no policy is generated"
    end

    test "results are structural Verify results that round-trip and name generator tasks",
         %{report: report, inputs: inputs} do
      generators = for %{kind: :generate, id: id} <- inputs.plan.tasks, do: id

      for r <- report.results do
        assert {r.level, r.class} == {:l0, :structural}
        assert r.app == "acme" and r.actor == "bubble_ex" and r.ran_at == @now
        assert {:ok, ^r} = r |> Result.to_json() |> Result.from_json()
      end

      assert Enum.sort(result(report, "structural.deterministic").tasks) == Enum.sort(generators)
      assert result(report, "structural.symbol_coverage.fields").tasks == ["generate:schema"]

      # A structural pass counts without evidence; skipped never does.
      resolved = %BubbleEx.Decision.Resolved{}
      evaluate = [app: "acme", now: @now]
      assert Result.passing?(result(report, "structural.deterministic"), resolved, evaluate)
      refute Result.passing?(result(report, "structural.policy_coverage"), resolved, evaluate)
    end

    test "counts every symbol once, per bucket", %{report: report} do
      symbols = report.counts["symbols"]

      for {_category, counts} <- symbols do
        buckets = Map.drop(counts, ["total", "reasons"])
        assert Enum.sum(Map.values(buckets)) == counts["total"]
      end

      assert symbols["pages"]["generated"] == 1
      assert symbols["pages"]["reasons"] == %{"excluded:mobile_view" => 1}
      assert symbols["reusables"]["generated"] == 3
      assert symbols["api_calls"]["generated"] == 2
      # Backend workflows are generated; frontend ones are plan tasks or residue.
      assert symbols["workflows"]["generated"] == 5
      assert symbols["workflows"]["excluded"] == 1
      assert symbols["workflows"]["reasons"]["residue:plugin_action"] == 1
      assert symbols["workflows"]["task"] == 5
    end

    test "the summary says it is structural, not behavioural, and holds no Bubble ID",
         %{report: report} do
      summary = Structural.summary(report)
      assert summary["statement"] =~ "not behavioural"
      assert summary["passing"] == false

      json = Structural.summary_json(report)
      refute json =~ "pHome"
      refute json =~ "wApiA"
      assert {:ok, _} = Jason.decode(json)
    end

    test "a type, field or page nothing accounts for is uncovered", %{inputs: inputs} do
      [task | rest] = inputs.project.resources

      stripped = %{
        task
        | attributes: Enum.reject(task.attributes, &(&1.source[:field] == "title_text"))
      }

      files =
        Map.update!(inputs.files, ".wtf/surfaces.json", fn json ->
          json |> Jason.decode!() |> put_in(["pages"], %{}) |> Jason.encode!()
        end)

      plan = %{
        inputs.plan
        | tasks: Enum.reject(inputs.plan.tasks, &("page:pHome" in &1.subjects))
      }

      inputs = %{
        inputs
        | project: %{inputs.project | resources: [stripped | rest]},
          files: files,
          plan: plan
      }

      {:ok, report} = Structural.run(Map.delete(inputs, :rerender), @opts)

      assert result(report, "structural.symbol_coverage.fields").diff == [
               %{
                 op: "symbol_uncovered",
                 type: "task",
                 field: "title_text",
                 detail: "field:task/title_text"
               }
             ]

      assert result(report, "structural.symbol_coverage.pages").diff == [
               %{op: "symbol_uncovered", detail: "page:pHome"}
             ]

      assert result(report, "structural.symbol_coverage.fields").status == :fail

      # The surfaces map is a generated file: editing it is a hand edit.
      assert result(report, "structural.generated_unchanged").status == :fail

      {:ok, report} =
        Structural.run(%{inputs | project: %{inputs.project | resources: rest}}, @opts)

      assert result(report, "structural.symbol_coverage.data_types").diff == [
               %{op: "symbol_uncovered", type: "task", detail: "data_type:task"}
             ]
    end

    test "a hand-edited generated file and a non-deterministic rendering fail",
         %{inputs: inputs} do
      files = Map.update!(inputs.files, "lib/acme/task.ex", &(&1 <> "\n# edited\n"))
      {:ok, report} = Structural.run(%{inputs | files: files}, @opts)

      assert result(report, "structural.generated_unchanged").diff == [
               %{op: "file_changed", path: "lib/acme/task.ex", detail: "modified"}
             ]

      assert result(report, "structural.deterministic").diff == [
               %{op: "not_deterministic", path: "lib/acme/task.ex", detail: "content differs"}
             ]
    end

    test "without rendered files, surfaces are plan tasks and file checks are not run",
         %{inputs: inputs} do
      {:ok, report} = Structural.run(Map.drop(inputs, [:files, :rerender]), @opts)

      # The page's plan task is open with residue; the reusables are plan tasks.
      assert report.counts["symbols"]["pages"]["residue"] == 1
      assert report.counts["symbols"]["reusables"]["task"] == 3
      refute result(report, "structural.generated_unchanged")
      not_run = Enum.map(report.not_run, & &1.check)
      assert "generated_unchanged" in not_run and "deterministic" in not_run
    end

    test "inputs and options are required", %{inputs: inputs} do
      assert {:error, %{kind: :invalid_input}} = Structural.run(Map.delete(inputs, :model), @opts)
      assert {:error, %{kind: :invalid_input}} = Structural.run(inputs, now: @now)

      assert {:error, %{kind: :invalid_input}} =
               Structural.run(inputs, app: "Not An App", now: @now)
    end
  end

  describe "policy coverage" do
    setup do
      app = SampleHelper.load_json_sample("synthetic_privacy_export")
      inputs = build(app, false)
      {:ok, unverified} = Ash.map(inputs.model, [], privacy: :unverified)
      %{inputs: %{inputs | project: unverified}}
    end

    test "every rule of an :unverified project is compiled, denied or the everyone rule",
         %{inputs: inputs} do
      {:ok, report} = Structural.run(inputs, @opts)
      assert result(report, "structural.policy_coverage").status == :pass

      assert report.counts["privacy_rules"] == %{
               "compiled" => 6,
               "denied" => 1,
               "everyone" => 3,
               "privacy" => "unverified",
               "rules" => 10,
               "types" => %{"none" => 1, "present" => 3},
               "uncovered" => 0
             }
    end

    test "a rule missing from the policies is uncovered", %{inputs: inputs} do
      [r | rest] =
        Enum.sort_by(inputs.project.resources, &(&1.privacy.compiled_rules == []))

      [dropped | _] = r.privacy.compiled_rules
      r = put_in(r.privacy.compiled_rules, tl(r.privacy.compiled_rules))
      inputs = put_in(inputs.project.resources, [r | rest])

      {:ok, report} = Structural.run(inputs, @opts)
      policy = result(report, "structural.policy_coverage")
      assert policy.status == :fail
      assert policy.diff == [%{op: "rule_uncovered", type: r.source.type, rule: dropped}]
    end
  end

  describe "bypass inventory" do
    setup do
      app = "test/support/target/workflows/backend.json" |> File.read!() |> Jason.decode!()
      %{inputs: build(app)}
    end

    test "the lowering bypasses exactly the workflows that ignore privacy rules",
         %{inputs: inputs} do
      {:ok, report} = Structural.run(inputs, @opts)
      assert result(report, "structural.bypass_inventory").status == :pass

      assert report.counts["bypasses"] == %{
               "expected" => 1,
               "lowered" => 1,
               "sites" => %{"authorize_false:scaffold" => 4, "runtime_start:listed" => 1}
             }
    end

    test "an extra bypass, a missing one and a silent one in the bodies fail",
         %{inputs: inputs} do
      [listed] = inputs.workflows.privacy_bypasses
      extra = %{inputs.workflows | privacy_bypasses: [listed, "wOther"]}
      {:ok, report} = Structural.run(%{inputs | workflows: extra}, @opts)

      assert %{op: "bypass_unlisted", workflow: "wOther", expected: false, actual: true} in result(
               report,
               "structural.bypass_inventory"
             ).diff

      missing = %{inputs.workflows | privacy_bypasses: []}
      {:ok, report} = Structural.run(%{inputs | workflows: missing}, @opts)
      diff = result(report, "structural.bypass_inventory").diff
      assert %{op: "bypass_unlisted", workflow: listed, expected: true, actual: false} in diff
      # The rendered body still bypasses: now unlisted.
      assert Enum.any?(diff, &(&1[:detail] == "runtime_start" and &1[:workflow] == listed))
    end
  end

  describe "Bypasses.sites/1" do
    test "finds literal bypasses in calls, keyword lists, maps and Keyword.put" do
      source = """
      defmodule X do
        @opts [authorize?: false]
        def a(q), do: Ash.read!(q, authorize?: false)
        # bubble:ignores_privacy wClose
        def b(q), do: Ash.read!(q, actor: nil, authorize?: false)
        def c(o), do: Keyword.put(o, :authorize?, false)
        def d, do: %{authorize?: false}
        def e(q), do: Ash.read!(q, authorize?: true)
        def f(i, c), do: Acme.Workflows.Runtime.start(i, c, "wClose", false)
        def g(i, c), do: Runtime.start(i, c, "wOpen", true)
        # authorize?: false in a comment is none
        def h, do: "authorize?: false"
      end
      """

      assert {:ok, sites} = Bypasses.sites(source)

      assert Enum.map(sites, &{&1.line, &1.kind, &1[:workflow], &1.marker}) == [
               {2, :authorize_false, nil, nil},
               {3, :authorize_false, nil, nil},
               {5, :authorize_false, nil, "wClose"},
               {6, :authorize_false, nil, nil},
               {7, :authorize_false, nil, nil},
               {9, :runtime_start, "wClose", nil}
             ]

      assert Bypasses.sites("defmodule (") == :error
    end

    test "classifies listed, marked, scaffold and unlisted sites" do
      marked = "# bubble:ignores_privacy workflow:wClose\nAsh.read!(q, authorize?: false)\n"
      silent = "Ash.read!(q, authorize?: false)\n"
      start = "Runtime.start(i, c, \"wOpen\", false)\n"

      inventory =
        Bypasses.inventory(
          %{
            "a.ex" => marked,
            "b.ex" => silent,
            "c.ex" => silent,
            "d.ex" => start,
            "e.txt" => silent
          },
          allowed: ["wClose"],
          scaffold: ["c.ex", "d.ex"]
        )

      assert Enum.map(inventory.sites, &{&1.path, &1.class, &1.workflow}) == [
               {"a.ex", :marked, "wClose"},
               {"b.ex", :unlisted, nil},
               {"c.ex", :scaffold, nil},
               {"d.ex", :unlisted, "wOpen"}
             ]
    end
  end

  describe "project/2 in the owner's repository" do
    @describetag :tmp_dir

    setup %{tmp_dir: root} do
      app = "test/support/target/workflows/backend.json" |> File.read!() |> Jason.decode!()
      inputs = build(app)

      for {path, content} <- inputs.files do
        File.mkdir_p!(Path.dirname(Path.join(root, path)))
        File.write!(Path.join(root, path), content)
      end

      :ok = BubbleEx.Tasks.Store.write_plan(root, inputs.plan)
      pass = fn _args, _env -> {"", 0} end
      %{root: root, pass: pass, workflows: inputs.workflows}
    end

    defp project(root, cmd),
      do: Structural.project(root, app: "acme", now: @now, cmd: cmd, git_sha: "0a1b2c3")

    test "a freshly generated project passes; the model checks are listed as not run",
         %{root: root, pass: pass} do
      {:ok, report} = project(root, pass)

      assert statuses(report) == %{
               "structural.generated_unchanged" => :pass,
               "structural.compiles" => :pass,
               "structural.lint" => :pass,
               "structural.migrations_in_sync" => :pass,
               "structural.bypass_inventory" => :pass
             }

      for r <- report.results do
        assert r.actor == "mix wtf.verify"
        assert r.subject_build.git_sha == "0a1b2c3"
        assert r.subject_build.generated_manifest_sha256 =~ ~r/\A[0-9a-f]{64}\z/
      end

      assert report.counts["bypasses"]["sites"]["runtime_start:listed"] == 1
      checks = Enum.map(report.not_run, & &1.check)
      assert "symbol_coverage" in checks and "policy_coverage" in checks
    end

    test "edits, failing commands and silent bypasses fail", %{root: root, workflows: w} do
      File.write!(Path.join(root, "lib/acme/task.ex"), "defmodule Acme.Task do\nend\n")

      File.write!(Path.join(root, "lib/acme/owned.ex"), """
      defmodule Acme.Owned do
        def silent(q), do: Ash.read!(q, authorize?: false)

        # bubble:ignores_privacy #{hd(w.privacy_bypasses)}
        def marked(q), do: Ash.read!(q, authorize?: false)
      end
      """)

      cmd = fn
        ["ash.codegen" | _], _ -> {"pending migrations", 1}
        _, _ -> {"", 0}
      end

      {:ok, report} = project(root, cmd)

      assert result(report, "structural.generated_unchanged").diff == [
               %{op: "file_changed", path: "lib/acme/task.ex", detail: "modified"}
             ]

      assert result(report, "structural.migrations_in_sync").status == :fail
      assert report.outputs["structural.migrations_in_sync"] == "pending migrations"

      assert result(report, "structural.bypass_inventory").diff == [
               %{op: "bypass_unlisted", path: "lib/acme/owned.ex:2", detail: "authorize_false"}
             ]

      assert report.counts["bypasses"]["sites"]["authorize_false:marked"] == 1
    end

    test "a project without a manifest is refused", %{tmp_dir: root} do
      File.rm!(Path.join(root, ".wtf/generated.json"))
      assert {:error, %{kind: :invalid_input}} = project(root, fn _, _ -> {"", 0} end)
    end
  end
end
