defmodule BubbleEx.PlanCodecTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Error, Index, Model, Plan, SampleHelper}
  alias BubbleEx.Plan.Task

  @app SampleHelper.load_json_sample("synthetic_plan_export")

  setup_all do
    {:ok, model} = Model.build(@app)
    {:ok, index} = Index.build(@app, model: model)
    {:ok, plan} = Plan.build(model, index, nil, [], fragment_threshold: 2)
    %{plan: plan, json: Plan.to_json(plan)}
  end

  # The decoded JSON with `fun` applied and plan_sha256 recomputed.
  defp edited(json, fun) do
    map = json |> Jason.decode!() |> fun.()
    Map.put(map, "plan_sha256", map |> Map.delete("plan_sha256") |> CanonicalJson.sha256())
  end

  defp edit_task(json, id, fun),
    do:
      edited(json, fn map ->
        Map.update!(map, "tasks", &Enum.map(&1, fn t -> edit(t, id, fun) end))
      end)

  defp edit(%{"id" => id} = task, id, fun), do: fun.(task)
  defp edit(task, _id, _fun), do: task

  defp rejected(input, pattern) do
    assert {:error, %Error{kind: :invalid_input, message: message}} = Plan.decode(input)
    assert message =~ pattern
  end

  test "decodes what to_json wrote, byte for byte", %{plan: plan, json: json} do
    assert {:ok, decoded} = Plan.decode(json)
    assert Plan.to_json(decoded) == json
    assert decoded.plan_sha256 == plan.plan_sha256
    assert {:ok, ^decoded} = json |> Jason.decode!() |> Plan.decode()

    assert %Task{kind: :surface, actor: :agent, status: :open} =
             Plan.task(decoded, "surface:page/pHome")

    [%{kind: :coordinate, task: "workflow:wApiD"}] =
      Enum.filter(Plan.task(decoded, "workflow:wApiB").depends_on, &(&1.kind == :coordinate))

    assert %{check: :traceability, waiver: :forbidden, args: %{"elements" => [_ | _]}} =
             hd(Plan.task(decoded, "acceptance:page/pHome").criteria)

    assert [%{reason: :plugin_element, detail: %{"plugin" => _}}] =
             Plan.task(decoded, "surface:page/pHome").residue

    {:ok, diff} = Plan.diff(decoded, plan)
    assert diff.counts.unchanged == length(plan.tasks)
  end

  test "refuses another schema version, a tampered plan and unknown members", %{json: json} do
    rejected(edited(json, &Map.put(&1, "schema_version", 2)), "rebuild it")
    rejected(String.replace(json, "\"auth\"", "\"authx\"", global: false), "plan_sha256")
    rejected(edited(json, &Map.put(&1, "extra", 1)), "unknown members")
    rejected("{", "not JSON")
    rejected(%{"tasks" => []}, "not a plan")
  end

  test "refuses tasks outside the vocabulary or the graph", %{json: json} do
    rejected(edit_task(json, "auth", &Map.put(&1, "kind", "vibes")), "unknown kind")
    rejected(edit_task(json, "auth", &Map.put(&1, "actor", "robot")), "unknown actor")

    rejected(
      edit_task(
        json,
        "auth",
        &Map.put(&1, "depends_on", [%{"task" => "nope", "kind" => "calls", "via" => []}])
      ),
      "not in the plan"
    )

    rejected(edit_task(json, "workflow:wApiA", &Map.put(&1, "parent", "backend:nope")), "parent")

    rejected(
      edit_task(json, "auth", fn t ->
        Map.update!(t, "criteria", fn [c | rest] -> [%{c | "waiver" => "allowed"} | rest] end)
      end),
      "only attested"
    )

    rejected(
      edit_task(json, "auth", fn t ->
        Map.update!(t, "criteria", fn [c | rest] -> [%{c | "check" => "rm_rf"} | rest] end)
      end),
      "unknown check"
    )

    rejected(
      edited(json, fn m -> Map.update!(m, "tasks", &(&1 ++ [hd(&1)])) end),
      "share an id"
    )
  end
end
