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

  test "is a development tool", %{tmp_dir: root} do
    Mix.env(:prod)
    on_exit(fn -> Mix.env(:test) end)
    assert_raise Mix.Error, ~r/development tool/, fn -> wtf(root, ["next"]) end
  end
end
