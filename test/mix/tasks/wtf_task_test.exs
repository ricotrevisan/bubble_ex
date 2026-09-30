defmodule Mix.Tasks.Wtf.TaskTest do
  # Mix.shell/1 is global.
  use ExUnit.Case, async: false

  alias BubbleEx.{Index, Model, Plan, SampleHelper}
  alias BubbleEx.Tasks.{State, Store}

  @moduletag :tmp_dir
  @app SampleHelper.load_json_sample("synthetic_plan_export")

  setup %{tmp_dir: root} do
    {:ok, model} = Model.build(@app)
    {:ok, index} = Index.build(@app, model: model)
    {:ok, plan} = Plan.build(model, index, nil, [], fragment_threshold: 2)
    :ok = Store.write_plan(root, plan)

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    %{plan: plan}
  end

  defp wtf(root, args), do: Mix.Tasks.Wtf.Task.run(args ++ ["--root", root])

  defp output do
    receive_all([]) |> Enum.reverse() |> Enum.join("\n")
  end

  defp receive_all(acc) do
    receive do
      {:mix_shell, :info, [line]} -> receive_all([line | acc])
    after
      0 -> acc
    end
  end

  defp done!(root, plan, ids) do
    for id <- ids do
      task = Plan.task(plan, id)

      :ok =
        Store.put(root, %State{
          State.new(id)
          | status: :done,
            agents: ["gen"],
            basis: %{plan_sha256: "p", source_sha256: task.source_sha256}
        })
    end
  end

  test "next, show, claim and notes", %{tmp_dir: root} do
    wtf(root, ["next", "--n", "2"])

    assert output() ==
             "generate:option_sets  [generate, generator]\ngenerate:styles  [generate, generator]"

    wtf(root, ["claim", "generate:option_sets", "--agent", "a1", "--ttl", "30m"])
    assert output() =~ "claimed by a1 until"

    wtf(root, [
      "note",
      "generate:styles",
      "--agent",
      "a1",
      "--needs-decision",
      "Which font stack?"
    ])

    assert output() =~ "blocked until it is resolved"

    wtf(root, ["show", "generate:styles"])
    shown = output()
    assert shown =~ "status blocked"
    assert shown =~ "note 1 [needs_decision] a1: Which font stack?"
    assert shown =~ "1. generated_unchanged"

    wtf(root, ["next", "--json"])

    assert [%{"task" => %{"id" => "decision:plugin/" <> _}, "status" => "ready"}] =
             Jason.decode!(output())

    assert_raise Mix.Error, ~r/claimed by a1/, fn ->
      wtf(root, ["claim", "generate:option_sets", "--agent", "a2"])
    end
  end

  test "complete refuses without an attestation, then records it", %{tmp_dir: root, plan: plan} do
    done!(root, plan, ~w(generate:option_sets generate:schema generate:api_clients))

    assert_raise Mix.Error, ~r/not complete/, fn ->
      wtf(root, ["complete", "setup:secrets", "--agent", "owner"])
    end

    assert output() =~ "FAIL   1. attested (attestation)"

    wtf(root, [
      "complete",
      "setup:secrets",
      "--agent",
      "owner",
      "--attest",
      "1=Every private value is set in the vault."
    ])

    assert output() =~ "setup:secrets done"

    assert {:ok, %State{status: :done}} =
             root |> Path.join(State.path("setup:secrets")) |> File.read!() |> State.decode()

    wtf(root, ["audit", "setup:secrets"])
    assert output() =~ "audited 1 done tasks; 0 need re-verifying"
  end

  test "sync applies a new plan", %{tmp_dir: root, plan: plan} do
    done!(root, plan, ["workflow:wApiE"])
    smaller = %{plan | tasks: Enum.reject(plan.tasks, &(&1.id == "workflow:wApiE"))}

    smaller = %{
      smaller
      | plan_sha256:
          smaller |> Plan.to_map() |> Map.delete("plan_sha256") |> BubbleEx.CanonicalJson.sha256()
    }

    path = Path.join(root, "next_plan.json")
    File.write!(path, Plan.to_json(smaller))

    wtf(root, ["sync", path])
    out = output()
    assert out =~ "1 removed"
    assert out =~ "removed workflow:wApiE"
    assert {:ok, %Plan{plan_sha256: sha}} = Store.read_plan(root)
    assert sha == smaller.plan_sha256
  end

  test "every verdict is advisory; --attest names its criterion", %{tmp_dir: root, plan: plan} do
    done!(root, plan, ~w(generate:option_sets generate:schema generate:api_clients))

    assert_raise Mix.Error, ~r/name the criterion/, fn ->
      wtf(root, [
        "complete",
        "setup:secrets",
        "--agent",
        "o",
        "--attest",
        "Every private value is set."
      ])
    end

    wtf(root, [
      "complete",
      "setup:secrets",
      "--agent",
      "o",
      "--attest",
      "1=Every private value is set."
    ])

    out = output()
    assert out =~ "setup:secrets (advisory verdict):"
    assert out =~ "setup:secrets done (advisory: not verified"

    wtf(root, ["audit", "setup:secrets", "--json"])
    assert %{"mode" => "advisory", "flipped" => []} = Jason.decode!(output())

    assert_raise Mix.Error, ~r/unknown options/, fn -> wtf(root, ["audit", "--trusted"]) end

    assert_raise Mix.Error, ~r/renamed --reviewer-waivers/, fn ->
      wtf(root, ["audit", "--trusted-reviewer", "r1"])
    end
  end

  describe "test database (WTF-448)" do
    setup %{tmp_dir: root, plan: plan} do
      for var <- ~w(WTF_TASK_TEST_DB WTF_TASK_ALLOW_5432) do
        previous = System.get_env(var)
        System.delete_env(var)

        on_exit(fn ->
          if previous, do: System.put_env(var, previous), else: System.delete_env(var)
        end)
      end

      done!(root, plan, ~w(generate:option_sets generate:schema generate:api_clients
                           generate:policies generate:routes generate:styles generate:surfaces
                           generate:workflow_entry_points))

      :ok
    end

    test "complete and audit refuse mix test on a database nobody named", %{
      tmp_dir: root,
      plan: plan
    } do
      assert_raise Mix.Error, ~r/auth run mix test .*--test-db URL/, fn ->
        wtf(root, ["complete", "auth", "--agent", "a1"])
      end

      refute File.exists?(Path.join(root, State.path("auth")))

      done!(root, plan, ["auth"])

      assert_raise Mix.Error, ~r/auth run mix test/, fn ->
        wtf(root, ["audit", "auth"])
      end

      assert {:ok, %State{status: :done}} =
               root |> Path.join(State.path("auth")) |> File.read!() |> State.decode()
    end

    test "--test-db refuses port 5432 and non-test databases", %{tmp_dir: root} do
      on_5432 = "ecto://postgres:postgres@127.0.0.1:5432/app_test"

      assert_raise Mix.Error, ~r/port 5432/, fn ->
        wtf(root, ["complete", "auth", "--agent", "a1", "--test-db", on_5432])
      end

      # Checked before anything runs, even for tasks needing no database.
      assert_raise Mix.Error, ~r/port 5432/, fn ->
        wtf(root, ["audit", "--test-db", on_5432])
      end

      assert_raise Mix.Error, ~r/ending in _test/, fn ->
        wtf(root, [
          "complete",
          "auth",
          "--agent",
          "a1",
          "--test-db",
          "ecto://postgres:postgres@127.0.0.1:55432/app_dev"
        ])
      end

      System.put_env("WTF_TASK_ALLOW_5432", "1")

      # Allowed, the URL is used: this project's config/test.exs does not read it.
      assert_raise Mix.Error, ~r/does not read TEST_DATABASE_URL/, fn ->
        wtf(root, ["complete", "auth", "--agent", "a1", "--test-db", on_5432])
      end
    end

    test "WTF_TASK_TEST_DB, and the flags that exclude each other", %{tmp_dir: root} do
      System.put_env("WTF_TASK_TEST_DB", "ecto://postgres:postgres@127.0.0.1/app_test")

      assert_raise Mix.Error, ~r/port explicitly/, fn ->
        wtf(root, ["complete", "auth", "--agent", "a1"])
      end

      assert_raise Mix.Error, ~r/exclude each other/, fn ->
        wtf(root, [
          "complete",
          "auth",
          "--agent",
          "a1",
          "--use-project-test-config",
          "--test-db",
          "ecto://postgres:postgres@127.0.0.1:55432/app_test"
        ])
      end
    end

    test "tasks needing no database run without one", %{tmp_dir: root} do
      wtf(root, [
        "complete",
        "setup:secrets",
        "--agent",
        "o",
        "--attest",
        "1=Every private value is set in the vault."
      ])

      assert output() =~ "setup:secrets done"
      wtf(root, ["audit", "setup:secrets"])
      assert output() =~ "audited 1 done tasks; 0 need re-verifying"
    end
  end

  test "is a development tool", %{tmp_dir: root} do
    Mix.env(:prod)
    on_exit(fn -> Mix.env(:test) end)
    assert_raise Mix.Error, ~r/development tool/, fn -> wtf(root, ["next"]) end
  end
end
