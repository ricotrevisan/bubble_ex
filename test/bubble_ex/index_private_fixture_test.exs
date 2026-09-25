defmodule BubbleEx.IndexPrivateFixtureTest do
  # Acceptance of the symbol index against a real app. Real-app captures stay
  # private (see docs/workflows.md), so this reads a local export named by
  # BUBBLE_EX_PRIVATE_EXPORT and is excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # The path is a decoded `.bubble` app JSON file or a split export directory
  # (see `BubbleEx.Test.SplitExport`). Only aggregate counts are printed.
  use ExUnit.Case, async: true

  alias BubbleEx.Index
  alias BubbleEx.Index.{Reference, Symbol}
  alias BubbleEx.Test.SplitExport

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  # Build-time budget for one index build of a large app.
  @budget_ms 60_000

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {micros, {:ok, index}} = :timer.tc(fn -> Index.build(app) end)
    %{app: app, index: index, build_ms: div(micros, 1000)}
  end

  test "indexes within the time budget and reports counts", %{index: index, build_ms: ms} do
    summary = Index.summary(index)

    IO.puts("""

    index: built in #{ms} ms (budget #{@budget_ms} ms)
      symbols #{length(index.symbols)} #{inspect(sorted(summary.symbols))}
      references #{length(index.references)} #{inspect(sorted(summary.references))}
      cycles #{summary.cycles} (#{Enum.count(index.cycles, &(length(&1) > 1))} multi-workflow)
      diagnostics #{inspect(sorted(summary.diagnostics))}
      execution classes #{inspect(workflow_attr(index, :execution_class))}
      invocation modes #{inspect(workflow_attr(index, :invocation_modes))}
    """)

    assert ms <= @budget_ms
    assert Enum.all?(Symbol.kinds() -- [:privacy_rule], &Map.has_key?(summary.symbols, &1))
  end

  test "is deterministic", %{app: app, index: index} do
    {:ok, again} = Index.build(app)
    assert again.content_sha256 == index.content_sha256
    assert Index.to_json(again) == Index.to_json(index)
  end

  test "is internally consistent", %{index: index} do
    ids = MapSet.new(index.symbols, & &1.id)
    assert MapSet.size(ids) == length(index.symbols)
    assert Enum.all?(index.references, &MapSet.member?(ids, &1.from))
    assert Enum.all?(index.symbols, &(is_nil(&1.parent) or MapSet.member?(ids, &1.parent)))
    assert Enum.sort_by(index.references, &Reference.sort_key/1) == index.references

    for s <- Index.symbols(index, :workflow) do
      assert s.attrs.execution_class in [:client_only, :server_backed, :mixed, :unknown]
      assert is_list(s.attrs.invocation_modes)
    end

    for cycle <- index.cycles, id <- cycle, do: assert(MapSet.member?(ids, id))
  end

  test "answers the acceptance queries", %{index: index} do
    written =
      index.references |> Enum.filter(&(&1.kind == :writes_field)) |> Enum.frequencies_by(& &1.to)

    {field, writes} = Enum.max_by(written, fn {id, n} -> {n, id} end)

    {micros, results} =
      :timer.tc(fn ->
        %{
          writers: Index.writers(index, field),
          readers: Index.readers(index, field),
          rules: Index.privacy_rules_referencing(index, field),
          dependents:
            Index.dependents(index, index |> Index.symbol(field) |> Map.fetch!(:parent)),
          workflows:
            Index.writers(index, field)
            |> Enum.map(&Index.ancestor(index, &1.from, :workflow))
            |> Enum.uniq()
        }
      end)

    assert length(results.writers) == writes

    IO.puts(
      "\nqueries (most-written field): #{writes} writes from #{length(results.workflows)} workflows, " <>
        "#{length(results.readers)} reads, #{length(results.rules)} privacy-rule references, " <>
        "#{length(results.dependents)} references to its data type or fields; #{micros} µs"
    )
  end

  defp sorted(counts), do: Enum.sort_by(counts, fn {k, n} -> {-n, k} end)

  defp workflow_attr(index, key),
    do: index |> Index.symbols(:workflow) |> Enum.frequencies_by(& &1.attrs[key]) |> sorted()
end
