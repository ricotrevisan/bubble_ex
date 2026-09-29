defmodule BubbleEx.Buildprint.V5PrivateFixtureTest do
  # Acceptance for BubbleEx.Buildprint.V5 against a real Buildprint v5
  # workspace (a `buildprint project clone` directory). Real-app captures stay
  # private, so this reads the workspace named by BUBBLE_EX_PRIVATE_EXPORT and
  # is excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/workspace mix test --only private_fixture
  #
  # With a split export or `.bubble` file there it does nothing. It checks
  # that the Model built from the workspace matches the workspace's own
  # `symbols` index and stays close to the counts recorded from the private
  # fixture app's last split (v4) export, which predates later app changes.
  # It prints aggregates only, never names or IDs.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Model}
  alias BubbleEx.Buildprint.V5

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @v4_counts "test/support/model/counts/private-app.json"
  # The v4 counts predate app changes; each kind stays within this share.
  @v4_tolerance 0.1
  # Where Bubble's JSON holds entries the index leaves out (e.g. a call entry
  # without a name, a workflow entry without an event type).
  @index_tolerance 0.005

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    if V5.workspace?(path) do
      dir =
        if Path.basename(path) == ".buildprint", do: path, else: Path.join(path, ".buildprint")

      index = Path.join(dir, "index.sqlite")
      before = index_state(index)
      {micros, {:ok, result}} = :timer.tc(fn -> V5.load(path) end)
      # The Model is built from the app on its own, as other readers build it.
      {:ok, model} = Model.build(result.app)
      assert Model.to_json(model) == Model.to_json(result.model)

      %{
        result: result,
        model: model,
        load_ms: div(micros, 1000),
        index: index,
        before: before
      }
    else
      IO.puts("\nBUBBLE_EX_PRIVATE_EXPORT is not a Buildprint v5 workspace; skipping")
      %{result: nil}
    end
  end

  test "the Model matches the Buildprint symbol index", %{result: result} = context do
    if result do
      summary = Model.summary(context.model)

      IO.puts("""

      buildprint v5: loaded in #{context.load_ms} ms (#{result.format_version}, schema #{result.schema_version})
      loaded:  #{encode(result.counts)}
      symbols: #{encode(result.symbol_counts)}
      diagnostics: #{encode(Enum.frequencies_by(result.diagnostics, &Atom.to_string(&1.code)))}
      snapshot hash reproduced: #{result.snapshot.reproduced}
      """)

      # The loader counts what the Model reads.
      for kind <- ~w(data_types fields option_sets api_calls),
          do: assert(result.counts[kind] == summary[kind], kind)

      mismatched =
        for %{code: :buildprint_count_mismatch, details: %{kind: kind}} <- result.diagnostics,
            do: kind

      for {kind, symbols} <- result.symbol_counts do
        loaded = result.counts[kind]

        if kind in ~w(data_types fields option_sets pages) do
          assert loaded == symbols, "#{kind}: #{loaded} loaded, #{symbols} indexed"
        else
          assert loaded == symbols or
                   (kind in mismatched and abs(loaded - symbols) <= symbols * @index_tolerance),
                 "#{kind}: #{loaded} loaded, #{symbols} indexed"
        end
      end

      refute inspect(result.diagnostics) =~ "$bp"
    end
  end

  test "the Model stays close to the split export's counts", %{result: result} = context do
    if result do
      summary = Model.summary(context.model)
      v4 = @v4_counts |> File.read!() |> Jason.decode!() |> Map.fetch!("counts")

      # Option values and privacy rules are printed only: app edits since the
      # split export changed them by more than the tolerance (a new option
      # set with hundreds of values, new and edited rules).
      asserted = ~w(data_types fields option_sets api_connectors api_calls)
      kinds = asserted ++ ~w(option_values privacy_rules)

      IO.puts("""

      v4 split export -> v5 workspace:
      #{Enum.map_join(kinds, "\n", &"  #{&1}: #{v4[&1]} -> #{summary[&1]}")}
      """)

      for kind <- asserted do
        assert abs(summary[kind] - v4[kind]) <= v4[kind] * @v4_tolerance,
               "#{kind}: #{v4[kind]} (v4) vs #{summary[kind]} (v5)"
      end
    end
  end

  test "leaves the index untouched", %{result: result} = context do
    if result do
      assert index_state(context.index) == context.before

      for suffix <- ["-wal", "-shm", "-journal"],
          do: refute(File.exists?(context.index <> suffix))
    end
  end

  defp index_state(index) do
    stat = File.stat!(index)

    {stat.size, stat.mtime,
     File.stream!(index, 1_048_576)
     |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
     |> :crypto.hash_final()}
  end

  defp encode(map), do: map |> CanonicalJson.ordered() |> Jason.encode!()
end
