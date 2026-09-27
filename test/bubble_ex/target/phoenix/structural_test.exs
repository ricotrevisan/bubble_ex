defmodule BubbleEx.Target.Phoenix.StructuralTest do
  # The structural verification pack (WTF-386): symbol and policy
  # coverage, the bypass inventory, the manifest and determinism at
  # generation (`run/2`), and the owner-repository checks (`project/2`).
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Index, Model, Plan, SampleHelper}
  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Target.{ApiClients, Ash, Phoenix}
  alias BubbleEx.Target.Ash.Workflows
  alias BubbleEx.Target.Elixir.FrontendWorkflows
  alias BubbleEx.Target.Phoenix.Structural
  alias BubbleEx.Target.Phoenix.Structural.Bypasses
  alias BubbleEx.Verify.Result
  alias BubbleEx.Workflows.Backend

  @now ~U[2026-09-27 12:00:00Z]
  @opts [app: "acme", now: @now]
  @backend "test/support/target/workflows/backend.json"

  defp load(path), do: path |> File.read!() |> Jason.decode!()

  defp build(app, render? \\ true) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)

    frontend =
      case BubbleEx.Frontend.normalize(app) do
        {:ok, frontend} -> frontend
        _ -> nil
      end

    {:ok, project} = Ash.map(model, [], privacy: :omit)
    {:ok, backend} = Backend.build(app, model, index)
    {:ok, workflows} = Workflows.map(backend, project, namespace: "Acme")
    {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
    # The pages' data (WTF-420): its loader adds no bypass.
    {:ok, page_data} = BubbleEx.PageData.build(app, model)

    frontend_workflows =
      frontend &&
        elem(
          FrontendWorkflows.map(lowered, project,
            namespace: "Acme",
            frontend: frontend,
            backend: workflows,
            page_data: page_data
          ),
          1
        )

    residue =
      Workflows.Spec.residue(workflows) ++
        if(frontend_workflows, do: FrontendWorkflows.Spec.residue(frontend_workflows), else: [])

    {:ok, plan} = Plan.build(model, index, frontend, [], residue: residue)
    {:ok, api_clients} = ApiClients.map(model)

    inputs = %{
      model: model,
      index: index,
      plan: plan,
      project: project,
      workflows: workflows,
      frontend_workflows: frontend_workflows,
      api_clients: api_clients
    }

    if render? do
      opts =
        [name: "Acme", module: "Acme", workflows: workflows, api_clients: api_clients] ++
          if(frontend,
            do: [frontend: frontend, frontend_workflows: frontend_workflows],
            else: []
          )

      {:ok, files} = Phoenix.render(project, opts)
      {:ok, rerender} = Phoenix.render(project, opts)
      Map.merge(inputs, %{files: files, rerender: rerender})
    else
      inputs
    end
  end

  defp run!(inputs) do
    {:ok, report} = Structural.run(inputs, @opts)
    report
  end

  defp result(report, id), do: Enum.find(report.results, &(&1.id == id))
  defp status(report, id), do: result(report, id).status
  defp diff(report, id), do: result(report, id).diff
  defp statuses(report), do: Map.new(report.results, &{&1.id, &1.status})
  defp symbols(report, category), do: report.counts["symbols"][category]

  test "cut3 normalized fields are rendered and covered" do
    %{model: model, index: index, applied: applied} = BubbleEx.Test.DecidedFixture.build(:cut3)
    {:ok, project} = BubbleEx.Test.DecidedFixture.project(:cut3)
    {:ok, plan} = Plan.build(model, index, nil, applied)
    {:ok, files} = Phoenix.render(project, name: "Acme", module: "Acme")
    report = run!(%{model: model, index: index, project: project, plan: plan, files: files})

    assert status(report, "structural.symbol_coverage.fields") == :pass
    assert symbols(report, "fields")["uncovered"] == 0

    accounted =
      Structural.Coverage.account(%{
        model: model,
        index: index,
        project: project,
        plan: plan,
        files: files
      })

    for {type, field} <- [
          {"project", "tasks_list_custom_task"},
          {"project", "viewers_list_user"},
          {"user", "favorites_list_custom_project"},
          {"workspace", "members_list_user"}
        ] do
      assert %{bucket: :decision} =
               Enum.find(accounted.fields, &(&1.subjects == %{type: type, field: field}))
    end
  end

  describe "run/2 on the plan sample" do
    setup do
      %{inputs: build(SampleHelper.load_json_sample("synthetic_plan_export"))}
    end

    test "everything is generated or accounted for; policy coverage is blocked on WTF-356",
         %{inputs: inputs} do
      report = run!(inputs)

      for {id, status} <- statuses(report),
          do: assert(status == if(id =~ "policy_coverage", do: :skipped, else: :pass), id)

      assert symbols(report, "workflows")["generated"] == 8
      assert symbols(report, "workflows")["residue"] == 4
      assert result(report, "structural.policy_coverage").reason =~ "blocked on WTF-356"
    end

    test "without the page workflow Spec, page and reusable workflows are uncovered",
         %{inputs: inputs} do
      report = run!(%{inputs | frontend_workflows: nil})
      assert status(report, "structural.symbol_coverage.workflows") == :fail
      assert symbols(report, "workflows")["reasons"]["uncovered:not_emitted"] == 3

      assert %{
               op: "symbol_uncovered",
               workflow: "wLoopA",
               detail: "workflow:wLoopA (not_emitted)"
             } in diff(
               report,
               "structural.symbol_coverage.workflows"
             )
    end

    test "results are structural Verify results that round-trip and name generator tasks",
         %{inputs: inputs} do
      report = run!(inputs)
      generators = for %{kind: :generate, id: id} <- inputs.plan.tasks, do: id

      for r <- report.results do
        assert {r.level, r.class} == {:l0, :structural}
        assert r.app == "acme" and r.actor == "bubble_ex" and r.ran_at == @now
        assert {:ok, ^r} = r |> Result.to_json() |> Result.from_json()
      end

      assert Enum.sort(result(report, "structural.deterministic").tasks) == Enum.sort(generators)
      assert result(report, "structural.symbol_coverage.fields").tasks == ["generate:schema"]

      # A structural pass counts without evidence; skipped never does.
      evaluate = [app: "acme", now: @now]
      assert Result.passing?(result(report, "structural.deterministic"), %Resolved{}, evaluate)
      refute Result.passing?(result(report, "structural.policy_coverage"), %Resolved{}, evaluate)
    end

    test "counts every symbol once, per bucket", %{inputs: inputs} do
      report = run!(inputs)

      for {_category, counts} <- report.counts["symbols"] do
        buckets = Map.drop(counts, ["total", "reasons", "unreadable_parents"])
        assert Enum.sum(Map.values(buckets)) == counts["total"]
      end

      assert symbols(report, "pages")["generated"] == 1
      assert symbols(report, "pages")["reasons"] == %{"excluded:mobile_view" => 1}
      assert symbols(report, "reusables")["generated"] == 3
      assert symbols(report, "api_calls")["generated"] == 2
      assert symbols(report, "workflows")["generated"] == 8
      assert symbols(report, "fields")["unreadable_parents"] == 0
    end

    test "the summary says it is structural, lists what it did not run, holds no Bubble ID",
         %{inputs: inputs} do
      report = run!(inputs)
      summary = Structural.summary(report)
      assert summary["statement"] =~ "not behavioural"
      assert summary["passing"] == false
      not_run = Enum.map(summary["not_run"], & &1["check"])

      for check <-
            ~w(boundary secrets_absent traceability.source traceability.rendered compiles lint),
          do: assert(check in not_run)

      json = Structural.summary_json(report)
      refute json =~ "pHome"
      refute json =~ "wApiA"
      assert {:ok, _} = Jason.decode(json)
    end

    # H1: a symbol its generator did not emit is uncovered unless an open
    # task that is not a generator node carries its residue.
    test "without any generator output, what was not emitted is uncovered", %{inputs: inputs} do
      inputs =
        %{inputs | files: nil, workflows: nil, frontend_workflows: nil, api_clients: nil}
        |> Map.delete(:rerender)

      report = run!(inputs)

      # The generator emits every surface: a missing one is never residue,
      # even when its surface task is open with residue (pHome's is).
      assert symbols(report, "pages")["reasons"] == %{
               "excluded:mobile_view" => 1,
               "uncovered:not_emitted" => 1
             }

      assert status(report, "structural.symbol_coverage.pages") == :fail
      assert symbols(report, "reusables")["reasons"] == %{"uncovered:not_emitted" => 3}
      assert symbols(report, "api_calls")["reasons"] == %{"uncovered:not_emitted" => 2}
      assert symbols(report, "workflows")["reasons"]["uncovered:not_emitted"] == 8

      for category <- ~w(reusables api_calls workflows),
          do: assert(status(report, "structural.symbol_coverage.#{category}") == :fail)

      not_run = Enum.map(report.not_run, & &1.check)
      assert "generated_unchanged" in not_run and "deterministic" in not_run
      assert "symbol_coverage (rendered source)" in not_run
    end

    test "an empty surfaces map leaves pages and reusables uncovered", %{inputs: inputs} do
      files =
        Map.put(inputs.files, ".wtf/surfaces.json", ~s({"pages": {}, "reusables": {}}))

      report = run!(%{inputs | files: files})

      assert diff(report, "structural.symbol_coverage.pages") == [
               %{op: "symbol_uncovered", page: "pHome", detail: "page:pHome (not_emitted)"}
             ]

      assert length(diff(report, "structural.symbol_coverage.reusables")) == 3

      assert %{op: "symbol_uncovered", element: "rA", detail: "reusable:rA (not_emitted)"} in diff(
               report,
               "structural.symbol_coverage.reusables"
             )
    end

    test "a type or field in the Project but not in the rendered source is uncovered",
         %{inputs: inputs} do
      files =
        inputs.files
        |> Map.update!(
          "lib/acme/task.ex",
          &String.replace(&1, "attribute :title,", "attribute :renamed,")
        )
        |> Map.delete("lib/acme/user.ex")

      report = run!(%{inputs | files: files})

      assert %{
               op: "symbol_uncovered",
               type: "task",
               field: "title_text",
               detail: "field:task/title_text (not_rendered)"
             } in diff(report, "structural.symbol_coverage.fields")

      assert %{op: "symbol_uncovered", type: "user", detail: "data_type:user (not_rendered)"} in diff(
               report,
               "structural.symbol_coverage.data_types"
             )
    end

    test "a type or field missing from the Project is uncovered", %{inputs: inputs} do
      [task | rest] = inputs.project.resources

      stripped = %{
        task
        | attributes: Enum.reject(task.attributes, &(&1.source[:field] == "title_text"))
      }

      report = run!(%{inputs | project: %{inputs.project | resources: [stripped | rest]}})

      assert diff(report, "structural.symbol_coverage.fields") == [
               %{
                 op: "symbol_uncovered",
                 type: "task",
                 field: "title_text",
                 detail: "field:task/title_text (not_emitted)"
               }
             ]

      report = run!(%{inputs | project: %{inputs.project | resources: rest}})

      assert %{op: "symbol_uncovered", type: "task", detail: "data_type:task (not_emitted)"} in diff(
               report,
               "structural.symbol_coverage.data_types"
             )
    end

    test "a hand-edited generated file and a non-deterministic rendering fail",
         %{inputs: inputs} do
      files = Map.update!(inputs.files, "lib/acme/task.ex", &(&1 <> "\n# edited\n"))
      report = run!(%{inputs | files: files})

      assert diff(report, "structural.generated_unchanged") == [
               %{op: "file_changed", path: "lib/acme/task.ex", detail: "modified"}
             ]

      assert diff(report, "structural.deterministic") == [
               %{op: "not_deterministic", path: "lib/acme/task.ex", detail: "content differs"}
             ]
    end

    test "inputs and options are required", %{inputs: inputs} do
      assert {:error, %{kind: :invalid_input}} = Structural.run(Map.delete(inputs, :model), @opts)
      assert {:error, %{kind: :invalid_input}} = Structural.run(inputs, now: @now)

      assert {:error, %{kind: :invalid_input}} =
               Structural.run(inputs, app: "Not An App", now: @now)
    end
  end

  describe "option sets" do
    test "an enum or value missing from the Project or the rendered source is uncovered" do
      inputs = build(load("test/support/model/option_sets.json"))
      report = run!(inputs)
      assert status(report, "structural.symbol_coverage.option_values") == :pass
      assert symbols(report, "option_values")["reasons"]["diagnosed:duplicate_key"] == 1

      [enum | rest] = inputs.project.enums
      report = run!(%{inputs | project: %{inputs.project | enums: rest}})

      set = enum.source.option_set

      assert %{op: "symbol_uncovered", option_set: ^set} =
               hd(diff(report, "structural.symbol_coverage.option_sets"))

      [value | _] = enum.values
      path = "lib/acme/" <> Macro.underscore(enum.module) <> ".ex"

      files =
        Map.update!(inputs.files, path, &String.replace(&1, inspect(value.value), ~s("gone")))

      report = run!(%{inputs | files: files})
      assert [%{detail: detail}] = diff(report, "structural.symbol_coverage.option_values")
      assert detail =~ "(not_rendered)"
    end

    test "malformed parents are diagnosed and counted as unreadable" do
      report = run!(build(load("test/support/model/hostile_malformed.json")))
      assert symbols(report, "fields")["unreadable_parents"] == 2
      assert symbols(report, "option_values")["unreadable_parents"] == 1
      assert symbols(report, "data_types")["diagnosed"] == 2
    end
  end

  describe "policy coverage" do
    setup do
      inputs = build(SampleHelper.load_json_sample("synthetic_privacy_export"), false)
      {:ok, unverified} = Ash.map(inputs.model, [], privacy: :unverified)
      %{inputs: %{inputs | project: unverified}}
    end

    test "every rule of an :unverified project is compiled, denied or the everyone rule",
         %{inputs: inputs} do
      report = run!(inputs)
      assert status(report, "structural.policy_coverage") == :pass

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
      [r | rest] = Enum.sort_by(inputs.project.resources, &(&1.privacy.compiled_rules == []))
      [dropped | kept] = r.privacy.compiled_rules
      r = put_in(r.privacy.compiled_rules, kept)
      report = run!(put_in(inputs.project.resources, [r | rest]))

      assert status(report, "structural.policy_coverage") == :fail

      assert diff(report, "structural.policy_coverage") == [
               %{op: "rule_uncovered", type: r.source.type, rule: dropped}
             ]
    end
  end

  describe "page data (WTF-420)" do
    test "the loader and data functions add no bypass site" do
      inputs = build(load("test/support/target/phoenix/page_data.json"))
      report = run!(inputs)
      assert status(report, "structural.bypass_inventory") == :pass
      assert inputs.files["lib/acme_web/bubble_data.ex"] =~ "authorize?: true"
      refute inputs.files["lib/acme_web/bubble_data.ex"] =~ "authorize?: false"
    end

    test "a failed ID-list read logs the error and falls back to an empty lookup" do
      inputs = build(load("test/support/target/phoenix/page_data.json"))
      loader = inputs.files["lib/acme_web/bubble_data.ex"]

      assert loader =~
               ~r/\{:error, error\} ->\s+failed\(Ash\.Query\.new\(resource\), error\)\s+%\{\}/
    end
  end

  describe "bypass inventory at generation" do
    setup do
      %{inputs: build(load(@backend))}
    end

    test "the lowering, the rendered bodies and the scaffold agree", %{inputs: inputs} do
      report = run!(inputs)
      assert status(report, "structural.bypass_inventory") == :pass
      assert symbols(report, "workflows")["reasons"]["residue:blocked_by_callee"] == 1

      assert report.counts["bypasses"] == %{
               "expected" => 1,
               "lowered" => 1,
               "sites" => %{
                 "authorize_false:scaffold" => 2,
                 "authorize_unverifiable:scaffold" => 7,
                 "runtime_start:listed" => 1
               }
             }

      assert inputs.files[".wtf/bypasses.json"] =~ ~s("purpose": "confirm_email")
    end

    # H2: nothing checked is not a pass.
    test "without a workflow Spec it is skipped; without files the bodies are not checked",
         %{inputs: inputs} do
      report = run!(%{inputs | workflows: nil})
      assert status(report, "structural.bypass_inventory") == :skipped
      assert result(report, "structural.bypass_inventory").reason =~ "nothing was checked"
      assert "bypass_inventory" in Enum.map(report.not_run, & &1.check)

      report = run!(inputs |> Map.put(:files, nil) |> Map.delete(:rerender))
      assert "bypass_inventory (rendered code)" in Enum.map(report.not_run, & &1.check)
    end

    test "an extra bypass, a missing one and a silent one in the bodies fail",
         %{inputs: inputs} do
      [listed] = inputs.workflows.privacy_bypasses
      extra = %{inputs.workflows | privacy_bypasses: [listed, "wOther"]}
      report = run!(%{inputs | workflows: extra})

      assert %{op: "bypass_unlisted", workflow: "wOther", expected: false, actual: true} in diff(
               report,
               "structural.bypass_inventory"
             )

      missing = %{inputs.workflows | privacy_bypasses: []}
      d = diff(report = run!(%{inputs | workflows: missing}), "structural.bypass_inventory")
      assert %{op: "bypass_unlisted", workflow: listed, expected: true, actual: false} in d
      assert Enum.any?(d, &(&1[:workflow] == listed and (&1[:detail] || "") =~ "runtime_start"))
      assert status(report, "structural.bypass_inventory") == :fail
    end

    # M2: a generator change that adds a bypass fails, marked or not.
    test "a new bypass in the rendered code fails, and so does a stale allowlist",
         %{inputs: inputs} do
      runtime = "lib/acme/workflows/runtime.ex"

      for extra <- [
            "  def extra(r), do: Ash.read!(r, authorize?: false)\n",
            "  # bubble:ignores_privacy scaffold:job_actor\n  def extra(r), do: Ash.read!(r, authorize?: false)\n",
            "  # bubble:ignores_privacy scaffold:made_up\n  def extra(r), do: Ash.read!(r, authorize?: false)\n"
          ] do
        files =
          Map.update!(
            inputs.files,
            runtime,
            &String.replace(&1, ~r/\nend\s*\z/, "\n" <> extra <> "end\n")
          )

        d = diff(run!(%{inputs | files: files}), "structural.bypass_inventory")
        assert Enum.any?(d, &(&1[:path] =~ runtime)), inspect(d)
      end

      files = Map.put(inputs.files, ".wtf/bypasses.json", ~s({"version": 1, "scaffold": []}))
      d = diff(run!(%{inputs | files: files}), "structural.bypass_inventory")
      assert Enum.any?(d, &(&1[:path] == ".wtf/bypasses.json"))
    end
  end

  describe "Bypasses.sites/1" do
    test "finds every authorize? that is not literally true, wherever it is" do
      source = ~S"""
      defmodule X do
        @opts [authorize?: false]
        defp opts, do: [authorize?: false]
        def a(q), do: Ash.read!(q, authorize?: false)
        def b(q), do: {:ok, [authorize?: false]}
        def c(o), do: Keyword.put(o, :authorize?, false)
        def d(flag), do: %{authorize?: flag}
        def e(q), do: Ash.read!(q, authorize?: @flag, other: [authorize?: !true])
        def f(q), do: Ash.read!(q, authorize?: true)
        def g(i, c), do: Acme.Workflows.Runtime.start(i, c, "wClose", false)
        def h(i, c), do: Runtime.start(i, c, "wOpen", true)
        def i(i, c, x), do: Runtime.start(i, c, "wOpen", x)
        # authorize?: false in a comment is none
        def j, do: "authorize?: false"
      end
      """

      assert {:ok, sites} = Bypasses.sites(source)

      assert Enum.map(sites, &{&1.line, &1.kind}) == [
               {2, :authorize_false},
               {3, :authorize_false},
               {4, :authorize_false},
               {5, :authorize_false},
               {6, :authorize_false},
               {7, :authorize_unverifiable},
               {8, :authorize_unverifiable},
               {8, :authorize_unverifiable},
               {10, :runtime_start},
               {12, :runtime_unverifiable}
             ]

      assert Bypasses.sites("defmodule (") == :error
    end

    test "finds bypass policies, authorize modes, empty authorizers and Repo calls" do
      source = """
      defmodule Y do
        use Ash.Resource, authorizers: []
        policies do
          bypass always() do
            authorize_if always()
          end
        end
        resource do
          authorize :never
        end
        aggregates do
          count :n, [:items], authorize? false
        end
        def all, do: Acme.Repo.all(Acme.Thing)
        def raw, do: Ecto.Adapters.SQL.query(Acme.Repo, "select 1", [])
        domain do
          authorize :by_default
        end
      end
      """

      assert {:ok, sites} = Bypasses.sites(source)

      assert Enum.map(sites, &{&1.line, &1.kind}) == [
               {2, :no_authorizers},
               {4, :policy_bypass},
               {9, :authorize_mode},
               {12, :authorize_false},
               {14, :repo_call},
               {15, :repo_call}
             ]
    end

    test "classifies listed, marked, scaffold and unlisted sites" do
      body = """
      # bubble:workflow wClose
      def run(i, c) do
        Runtime.start(i, c, "wClose", false)
        # bubble:ignores_privacy wClose
        Ash.read!(q, authorize?: false)
      end
      # bubble:workflow wOther
      def other(q) do
        # bubble:ignores_privacy wClose
        Ash.read!(q, authorize?: false)
        Runtime.start(i, c, "wClose", false)
      end
      """

      scaffold = """
      # bubble:ignores_privacy scaffold:confirm_email
      Ash.update!(u, authorize?: false)
      # bubble:ignores_privacy scaffold:confirm_email
      Ash.update!(u, authorize?: false)
      # bubble:ignores_privacy scaffold:made_up
      Ash.update!(u, authorize?: false)
      """

      decided = """
      # bubble:ignores_privacy decision:parity_exception:ok
      Ash.read!(q, authorize?: false)
      # bubble:ignores_privacy decision:parity_exception:unknown
      Ash.read!(q, authorize?: false)
      """

      # A slot covers one site kind in one function.
      anchored = """
      def c do
        # bubble:ignores_privacy scaffold:confirm_email
        Acme.Repo.query!("delete from users")
        # bubble:ignores_privacy scaffold:confirm_email
        Ash.update!(u, authorize?: false)
      end
      def d do
        # bubble:ignores_privacy scaffold:confirm_email
        Ash.update!(u, authorize?: false)
      end
      """

      inventory =
        Bypasses.inventory(
          %{
            "a.ex" => body,
            "b.ex" => scaffold,
            "c.ex" => decided,
            "d.txt" => scaffold,
            "e.ex" => anchored
          },
          workflows: ["wClose"],
          scaffold: %{{"b.ex", "confirm_email", nil} => 1, {"e.ex", "confirm_email", "c/0"} => 1},
          decisions: ["parity_exception:ok"]
        )

      assert Enum.map(inventory.sites, &{&1.path, &1.line, &1.kind, &1.class}) == [
               {"a.ex", 3, :runtime_start, :listed},
               {"a.ex", 5, :authorize_false, :marked},
               {"a.ex", 10, :authorize_false, :unlisted},
               {"a.ex", 11, :runtime_start, :unlisted},
               {"b.ex", 2, :authorize_false, :scaffold},
               {"b.ex", 4, :authorize_false, :unlisted},
               {"b.ex", 6, :authorize_false, :unlisted},
               {"c.ex", 2, :authorize_false, :marked},
               {"c.ex", 4, :authorize_false, :unlisted},
               {"e.ex", 3, :repo_call, :unlisted},
               {"e.ex", 5, :authorize_false, :scaffold},
               {"e.ex", 9, :authorize_false, :unlisted}
             ]

      assert Enum.find(inventory.sites, &(&1.path == "e.ex" and &1.line == 3)).detail =~
               "covers authorize_false sites only"
    end
  end

  describe "project/2 in the owner's repository" do
    @describetag :tmp_dir

    setup %{tmp_dir: root} do
      inputs = build(load(@backend))

      for {path, content} <- inputs.files do
        File.mkdir_p!(Path.dirname(Path.join(root, path)))
        File.write!(Path.join(root, path), content)
      end

      :ok = BubbleEx.Tasks.Store.write_plan(root, inputs.plan)
      %{root: root, workflows: inputs.workflows}
    end

    defp pass(_args, _env), do: {"", 0}

    defp project(root, cmd \\ &pass/2, opts \\ []),
      do:
        Structural.project(
          root,
          [app: "acme", now: @now, cmd: cmd, git_sha: "0a1b2c3"] ++ opts
        )

    defp owned!(root, source), do: File.write!(Path.join(root, "lib/acme/owned.ex"), source)

    test "a freshly generated project passes; what is not run is listed", %{root: root} do
      {:ok, report} = project(root)

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

      assert report.counts["bypasses"]["sites"] == %{
               "authorize_false:scaffold" => 1,
               "runtime_start:listed" => 1
             }

      checks = Enum.map(report.not_run, & &1.check)

      for c <- ~w(symbol_coverage policy_coverage boundary secrets_absent traceability.rendered),
          do: assert(c in checks)

      assert "bypass_inventory (decision markers)" in checks
      assert report.known == []
    end

    test "edits, failing commands and silent bypasses fail", %{root: root, workflows: w} do
      File.write!(Path.join(root, "lib/acme/task.ex"), "defmodule Acme.Task do\nend\n")
      [listed] = w.privacy_bypasses

      owned!(root, """
      defmodule Acme.Owned do
        def silent(q), do: Ash.read!(q, authorize?: false)

        # bubble:ignores_privacy #{listed}
        def outside_the_body(q), do: Ash.read!(q, authorize?: false)

        # bubble:ignores_privacy scaffold:confirm_email
        def copied_scaffold(q), do: Ash.read!(q, authorize?: false)

        def repo, do: Acme.Repo.all(Acme.Task)
      end
      """)

      cmd = fn
        ["ash.codegen" | _], _ -> {"pending migrations", 1}
        _, _ -> {"", 0}
      end

      {:ok, report} = project(root, cmd)

      assert diff(report, "structural.generated_unchanged") == [
               %{op: "file_changed", path: "lib/acme/task.ex", detail: "modified"}
             ]

      assert status(report, "structural.migrations_in_sync") == :fail
      assert report.outputs["structural.migrations_in_sync"] == "pending migrations"

      assert Enum.map(diff(report, "structural.bypass_inventory"), &{&1.path, &1.detail}) == [
               {"lib/acme/owned.ex:2", "authorize_false"},
               {"lib/acme/owned.ex:5",
                "authorize_false: the workflow marker is outside that workflow's body"},
               {"lib/acme/owned.ex:8",
                "authorize_false: more scaffold:confirm_email sites in copied_scaffold/1 than the generator wrote"},
               {"lib/acme/owned.ex:10", "repo_call"}
             ]
    end

    test "a decision marker counts only for an active owner decision", %{root: root} do
      owned!(root, """
      defmodule Acme.Owned do
        # bubble:ignores_privacy decision:parity_exception:abc
        def decided(q), do: Ash.read!(q, authorize?: false)
      end
      """)

      {:ok, report} = project(root)
      assert status(report, "structural.bypass_inventory") == :fail

      decision = %Decision{
        key: "parity_exception:abc",
        kind: :parity_exception,
        revision: 1,
        subject: %{},
        choice: :accept,
        author: %{kind: :owner, id: "o", via: :form}
      }

      resolved = %Resolved{entries: [%{decision: decision, state: :active}]}
      {:ok, report} = project(root, &pass/2, resolved: resolved)
      assert status(report, "structural.bypass_inventory") == :pass
      refute "bypass_inventory (decision markers)" in Enum.map(report.not_run, & &1.check)

      agent = %Resolved{
        entries: [%{decision: %{decision | author: %{kind: :agent}}, state: :active}]
      }

      {:ok, report} = project(root, &pass/2, resolved: agent)
      assert status(report, "structural.bypass_inventory") == :fail
    end

    test "a lint failure is reported without treating it as a known generator failure", %{
      root: root
    } do
      cmd = fn
        ["format" | _], _ -> {"not formatted", 1}
        _, _ -> {"", 0}
      end

      {:ok, report} = project(root, cmd)
      assert status(report, "structural.lint") == :fail
      assert [%{detail: detail}] = diff(report, "structural.lint")
      assert detail =~ "format"
      assert report.known == []
      assert Structural.summary(report)["known_failures"] == []
    end

    test "a project without a manifest is refused", %{tmp_dir: root} do
      File.rm!(Path.join(root, ".wtf/generated.json"))
      assert {:error, %{kind: :invalid_input}} = project(root)
    end
  end
end
