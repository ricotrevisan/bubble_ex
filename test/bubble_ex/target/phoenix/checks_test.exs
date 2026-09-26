defmodule BubbleEx.Target.Phoenix.ChecksTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Plan.Task
  alias BubbleEx.Target.Phoenix.{Checks, Manifest}
  alias BubbleEx.Verify.Result

  @moduletag :tmp_dir
  @now ~U[2026-09-26 12:00:00Z]
  @sha String.duplicate("a", 64)

  defp ctx(root, opts \\ []) do
    test = self()

    Map.merge(
      %{
        root: root,
        task: %Task{id: "surface:page/pHome", kind: :surface, actor: :agent},
        results: [],
        app: "app1",
        now: @now,
        reviewers: [],
        resolved: nil,
        cmd: fn args, env ->
          send(test, {:mix, args, env})
          Process.get(:mix_result, {"1 test, 0 failures", 0})
        end
      },
      Map.new(opts)
    )
  end

  defp run(check, args, ctx) do
    {outcome, _cache} = Checks.run(%{check: check, args: args}, ctx, %{})
    outcome
  end

  defp write(root, path, content) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)
  end

  describe "structural" do
    test "generated_unchanged reads .wtf/generated.json", %{tmp_dir: root} do
      assert %{status: :fail, detail: "no .wtf/generated.json"} =
               run(:generated_unchanged, %{}, ctx(root))

      write(root, "lib/gen.ex", "generated")

      write(
        root,
        Manifest.path(),
        Manifest.encode(%{
          "version" => 1,
          "generated" => %{"lib/gen.ex" => Manifest.sha256("generated")}
        })
      )

      assert %{status: :pass} = run(:generated_unchanged, %{}, ctx(root))
      write(root, "lib/gen.ex", "hand edited")

      assert %{status: :fail, detail: "modified lib/gen.ex"} =
               run(:generated_unchanged, %{}, ctx(root))
    end

    test "compiles and lint run mix; credo only when the project has it", %{tmp_dir: root} do
      assert %{status: :pass, binding: "mix compile --warnings-as-errors"} =
               run(:compiles, %{}, ctx(root))

      assert_received {:mix, ["compile", "--warnings-as-errors"], []}

      assert %{status: :pass, detail: "credo is not a dependency" <> _} =
               run(:lint, %{}, ctx(root))

      assert_received {:mix, ["format", "--check-formatted"], []}
      refute_received {:mix, ["credo" | _], _}

      File.mkdir_p!(Path.join(root, "deps/credo"))
      assert %{status: :pass} = run(:lint, %{}, ctx(root))
      assert_received {:mix, ["credo", "--strict"], []}

      Process.put(:mix_result, {"** (CompileError) lib/a.ex:1", 1})

      assert %{status: :fail, detail: "exit status 1", output: "** (CompileError)" <> _} =
               run(:compiles, %{}, ctx(root))
    end

    test "project-wide checks run once per cache", %{tmp_dir: root} do
      {_, cache} = Checks.run(%{check: :compiles, args: %{}}, ctx(root), %{})
      {_, _} = Checks.run(%{check: :compiles, args: %{}}, ctx(root), cache)
      assert_received {:mix, ["compile" | _], _}
      refute_received {:mix, ["compile" | _], _}
    end
  end

  describe "traceability and markers" do
    setup %{tmp_dir: root} do
      write(root, "lib/app_web/live/home_live.html.heex", """
      <div data-bubble-id="pHome"><div data-bubble-id="eA"><p data-bubble-id='eB'>Hi</p></div></div>
      <%!-- <span data-bubble-id="eC"></span> --%>
      <%# <span data-bubble-id="eF"></span> %>
      """)

      write(root, "lib/app_web/live/card.ex", """
      defmodule Card do
        # data-bubble-id="eD"
        def render(assigns), do: ~H(<b data-bubble-id="eE"></b>) # <i data-bubble-id="eG"></i>
      end
      """)

      :ok
    end

    test "elements are data-bubble-id attributes outside comments", %{tmp_dir: root} do
      assert %{status: :pass, source_only: true} =
               run(
                 :traceability,
                 %{"elements" => ~w(element:eA element:eB element:eE)},
                 ctx(root)
               )

      assert %{
               status: :fail,
               detail: "not traced: element:eC, element:eD, element:eF, element:eG"
             } =
               run(
                 :traceability,
                 %{"elements" => ~w(element:eA element:eC element:eD element:eF element:eG)},
                 ctx(root)
               )
    end

    test "surfaces are rendered by their tagged tests", %{tmp_dir: root} do
      args = %{"elements" => ~w(page:pHome element:eA)}

      assert %{status: :fail, detail: "no test tagged bubble: page:pHome"} =
               run(:traceability, args, ctx(root))

      # A tag in a comment is no tag.
      write(root, "test/home_test.exs", ~s(# @moduletag bubble: "page:pHome"\n))
      assert %{status: :fail} = run(:traceability, args, ctx(root))

      write(
        root,
        "test/home_test.exs",
        ~s(defmodule T do\n  @moduletag bubble: "page:pHome"\nend\n)
      )

      assert %{status: :pass, source_only: false, detail: detail} =
               run(:traceability, args, ctx(root))

      assert detail =~ "rendered by the tests of page:pHome"
      assert_received {:mix, ["test", "--only", "bubble:page:pHome"], [{"MIX_ENV", "test"}]}
    end

    test "render_smoke refuses placeholders, then runs the tagged tests", %{tmp_dir: root} do
      write(root, "lib/app_web/live/home_live.ex", "# TODO(bubble:eX) lower this\n")

      write(
        root,
        "lib/app_web/live/home_live.html.heex",
        ~s{<div data-bubble-id="pHome"></div>\n<%!-- TODO(bubble:eA) --%>\n}
      )

      assert %{status: :fail, detail: "left in lib/app_web/live/home_live.html.heex"} =
               run(:render_smoke, %{"surfaces" => ["page:pHome"]}, ctx(root))

      write(
        root,
        "lib/app_web/live/home_live.html.heex",
        ~s(<div data-bubble-id="pHome"></div>\n)
      )

      assert %{status: :fail, detail: "no test tagged bubble: page:pHome"} =
               run(:render_smoke, %{"surfaces" => ["page:pHome"]}, ctx(root))

      write(root, "test/home_test.exs", ~s(@moduletag bubble: "page:pHome"\n))
      assert %{status: :pass} = run(:render_smoke, %{"surfaces" => ["page:pHome"]}, ctx(root))

      assert %{status: :fail} = run(:render_smoke, %{"elements" => ["element:eX"]}, ctx(root))
    end

    test "every subject needs its own passing tests", %{tmp_dir: root} do
      write(root, "test/auth_test.exs", ~s(@tag bubble: "surface:page/pHome"\n))
      assert %{status: :pass} = run(:unit_test, %{"workflows" => []}, ctx(root))
      assert_received {:mix, ["test", "--only", "bubble:surface:page/pHome"], _}
      assert %{status: :fail} = run(:request_shape, %{"calls" => ["api_call:g/c"]}, ctx(root))

      write(
        root,
        "test/wf_test.exs",
        ~s(@tag bubble: "workflow:wA"\n@tag bubble: "workflow:wB"\n)
      )

      # Only the exit status counts (mix exits 1 when no test ran), never
      # the summary line the tests print.
      Process.put(:mix_result, {"99 tests, 0 failures", 1})

      assert %{status: :fail, detail: "workflow:wA: exit status 1 (a test failed or none ran)"} =
               run(:unit_test, %{"workflows" => ~w(workflow:wA workflow:wB)}, ctx(root))

      Process.put(:mix_result, {"Result: 0 passed", 0})

      assert %{status: :pass} =
               run(:unit_test, %{"workflows" => ~w(workflow:wA workflow:wB)}, ctx(root))

      assert_received {:mix, ["test", "--only", "bubble:workflow:wA"], _}
      assert_received {:mix, ["test", "--only", "bubble:workflow:wB"], _}
    end

    test "step_order reads the workflow's step markers in order", %{tmp_dir: root} do
      write(root, "lib/app/workflows.ex", """
      defmodule App.Workflows do
        # bubble:workflow wA
        def a(x) do
          # bubble:step 1 ChangeThing
          x = x + 1
          # bubble:step 2 SendEmail
          x
        end

        # bubble:workflow wB
        # bubble:step 1 SendEmail
        # bubble:step 2 ChangeThing
        def b, do: "# bubble:step 3 NotAComment"
      end
      """)

      args = &%{"workflow" => &1, "steps" => &2}

      assert %{status: :pass, source_only: true} =
               run(:step_order, args.("workflow:wA", ~w(ChangeThing SendEmail)), ctx(root))

      assert %{
               status: :fail,
               detail:
                 "expected steps 1 ChangeThing, 2 SendEmail, found 1 SendEmail, 2 ChangeThing"
             } =
               run(:step_order, args.("workflow:wB", ~w(ChangeThing SendEmail)), ctx(root))

      assert %{status: :fail, detail: "no # bubble:workflow wC marker"} =
               run(:step_order, args.("workflow:wC", []), ctx(root))

      write(root, "lib/app/other.ex", "# bubble:workflow wA\n")

      assert %{status: :fail, detail: "the workflow is marked in 2 places"} =
               run(:step_order, args.("workflow:wA", ~w(ChangeThing SendEmail)), ctx(root))
    end
  end

  describe "results" do
    defp result(attrs) do
      {:ok, r} =
        %{
          id: "r1",
          app: "app1",
          check: "deterministic",
          status: :pass,
          actor: "ci",
          ran_at: @now,
          tasks: ["surface:page/pHome"]
        }
        |> Map.merge(Map.new(attrs))
        |> Result.new()

      {"results/#{r.id}.json", @sha, r}
    end

    test "count only through Result.evaluate/3", %{tmp_dir: root} do
      assert %{status: :fail, detail: "no result names" <> _} =
               run(:deterministic, %{}, ctx(root))

      assert %{status: :pass, refs: [%{ref: "results/r1.json"}]} =
               run(:deterministic, %{}, ctx(root, results: [result([])]))

      assert %{status: :fail, detail: "no result names" <> _} =
               run(:deterministic, %{}, ctx(root, results: [result(tasks: ["other"])]))

      assert %{status: :fail, detail: "evaluating results needs" <> _} =
               run(:deterministic, %{}, ctx(root, results: [result([])], app: nil))

      assert %{status: :fail, detail: "results/r1.json: the result is for another app"} =
               run(:deterministic, %{}, ctx(root, results: [result(app: "app2")]))

      assert %{status: :fail, detail: "results/r1.json: status skipped does not count"} =
               run(
                 :deterministic,
                 %{},
                 ctx(root, results: [result(status: :skipped, reason: "not run")])
               )
    end

    test "replay results must be Bubble-verified", %{tmp_dir: root} do
      behaviour = [
        check: "workflow_side_effects",
        scenario: %{id: "s1", sha256: @sha, source_sha256: @sha, seed_sha256: @sha},
        evidence: [%{kind: :recording, ref: "rec.json", sha256: @sha}]
      ]

      model = result(behaviour ++ [oracle: %{kind: :model, sha256: @sha}])

      assert %{status: :fail, detail: "results/r1.json: not Bubble-verified"} =
               run(:replay, %{}, ctx(root, results: [model]))

      assert %{status: :pass} =
               run(
                 :visual_parity,
                 %{},
                 ctx(root,
                   results: [
                     result(
                       Keyword.put(behaviour, :check, "visual_parity") ++
                         [oracle: %{kind: :model, sha256: @sha}]
                     )
                   ]
                 )
               )
    end
  end
end
