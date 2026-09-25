defmodule BubbleEx.ModelPrivateFixtureTest do
  # Regression anchor for BubbleEx.Model against a real app (WTF-342).
  # Real-app captures stay private (see docs/workflows.md), so this reads a
  # local export named by BUBBLE_EX_PRIVATE_EXPORT and is excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # The path is a decoded `.bubble` app JSON file or a split export directory
  # (see `BubbleEx.Test.SplitExport`). The Model's aggregate counts
  # (`BubbleEx.Model.summary/1`) are compared with a committed count snapshot,
  # by default the mm-137 test version's. The snapshot holds counts only,
  # never names or IDs. It is not a zero-diagnostic target: a changed count
  # means updating the snapshot, with the reason in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_MODEL_COUNTS names another snapshot file (for another app).
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Model}
  alias BubbleEx.Test.{PermutedJson, SplitExport}

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/model/counts/mm-137.json"
  # Build-time budget for one Model build of a large app.
  @budget_ms 10_000

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {micros, {:ok, model}} = :timer.tc(fn -> Model.build(app) end)
    %{app: app, model: model, build_ms: div(micros, 1000)}
  end

  test "matches the recorded count snapshot", %{model: model, build_ms: ms} do
    snapshot = System.get_env("BUBBLE_EX_MODEL_COUNTS") || @default_snapshot
    counts = Model.summary(model)

    IO.puts("""

    model: built in #{ms} ms (budget #{@budget_ms} ms)
    #{counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)}
    """)

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      document = %{"schema_version" => Model.schema_version(), "counts" => counts}
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (document |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    recorded = snapshot |> File.read!() |> Jason.decode!()
    assert recorded["schema_version"] == Model.schema_version()
    assert counts == recorded["counts"], "counts changed; update #{snapshot} with a reason"
    assert ms <= @budget_ms
  end

  test "is deterministic across builds and permuted input", %{app: app, model: model} do
    {:ok, again} = Model.build(app)
    assert Model.to_json(again) == Model.to_json(model)

    # The same export as text with every object's members shuffled.
    :rand.seed(:exsss, {1, 2, 3})
    text = PermutedJson.encode(app)
    refute text == Jason.encode!(app)
    {:ok, permuted} = text |> Jason.decode!() |> Model.build()
    assert Model.to_json(permuted) == Model.to_json(model)
  end

  test "keeps every field and value of the source", %{app: app, model: model} do
    source_fields =
      for {_, type} <- app["user_types"] || %{},
          is_map(type),
          fields = type["fields"] || type["%f3"],
          is_map(fields),
          reduce: 0,
          do: (n -> n + map_size(fields))

    source_values =
      for {_, set} <- app["option_sets"] || %{},
          is_map(set),
          is_map(set["values"]),
          reduce: 0,
          do: (n -> n + map_size(set["values"]))

    assert Model.summary(model)["fields"] == source_fields
    assert Model.summary(model)["option_values"] == source_values
  end
end
