defmodule BubbleEx.FindingsPrivateFixtureTest do
  # Acceptance of the model-refinement analyzers against a real app. Real-app
  # captures stay private (see docs/workflows.md), so this reads a local
  # export named by BUBBLE_EX_PRIVATE_EXPORT and is excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # Only aggregate counts are printed. To hand-check specific findings
  # without committing the app's IDs, list them in BUBBLE_EX_FINDINGS_EXPECT
  # as comma-separated `kind:type/field` Bubble IDs; each must be found, and
  # its proposal, confidence and maintaining workflows are printed.
  use ExUnit.Case, async: true

  alias BubbleEx.{Finding, Findings, Index}
  alias BubbleEx.Test.SplitExport

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  # Budget for one analysis of a large app, given its index.
  @budget_ms 30_000

  setup_all do
    # The index is built once for the counts; determinism rebuilds it.
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, index} = Index.build(app)
    {micros, {:ok, result}} = :timer.tc(fn -> Findings.analyze(app, index: index) end)
    %{app: app, index: index, result: result, ms: div(micros, 1000)}
  end

  test "analyzes within the time budget and reports counts", %{result: result, ms: ms} do
    summary = Findings.summary(result)

    lines =
      Enum.map_join(BubbleEx.Finding.Kinds.all(), "\n", fn kind ->
        counts = Map.get(summary, kind, %{})
        total = counts |> Map.values() |> Enum.sum()
        {:ok, %{category: category}} = BubbleEx.Finding.Kinds.fetch(kind)
        "  #{kind} (#{category}): #{total} #{inspect(Enum.sort_by(counts, fn {c, _} -> c end))}"
      end)

    IO.puts("""

    findings: #{length(result.findings)} in #{ms} ms (budget #{@budget_ms} ms), #{length(result.diagnostics)} index diagnostics
    #{lines}
    """)

    assert ms <= @budget_ms
  end

  test "is deterministic, from a rebuilt index", %{app: app, result: result} do
    {:ok, rebuilt} = Index.build(app)
    {:ok, again} = Findings.analyze(app, index: rebuilt)
    assert Jason.encode!(Findings.to_map(again)) == Jason.encode!(Findings.to_map(result))
  end

  test "references only indexed symbols and edges", %{index: index, result: result} do
    ids = MapSet.new(index.symbols, & &1.id)
    refs = MapSet.new(index.references)

    assert Finding.normalize(result.findings) == result.findings
    assert result.findings |> Enum.uniq_by(& &1.id) |> length() == length(result.findings)

    for f <- result.findings do
      assert Enum.all?(f.evidence.symbols, &MapSet.member?(ids, &1)), f.id
      assert Enum.all?(f.evidence.references, &MapSet.member?(refs, &1)), f.id
      affected = for {_, group} <- f.affects, {_, list} <- group, id <- list, do: id
      assert Enum.all?(affected, &MapSet.member?(ids, &1)), f.id
      assert Enum.all?(f.related, &(&1 in Enum.map(result.findings, fn g -> g.id end))), f.id
    end
  end

  test "an accept of every finding round-trips and resolves active", %{
    index: index,
    result: result
  } do
    decisions =
      for f <- result.findings do
        {:ok, d} = BubbleEx.Decision.for_finding(f, :accept)
        assert {:ok, ^d} = d |> BubbleEx.Decision.to_json() |> BubbleEx.Decision.from_json()
        d
      end

    {:ok, resolved} =
      BubbleEx.Decision.resolve(decisions, result.findings, index: index, now: DateTime.utc_now())

    assert Enum.all?(resolved.entries, &(&1.state == :active))
    assert resolved.undecided == []
    assert BubbleEx.Decision.Resolved.blocking(resolved) == []

    # Hint bases cover only the type and its indexed columns.
    for %{category: :hint} = f <- result.findings,
        do:
          assert(
            Enum.all?(
              Finding.basis_symbols(f),
              &String.starts_with?(&1, ["data_type:", "field:"])
            )
          )
  end

  test "finds the expected findings", %{result: result} do
    expected =
      "BUBBLE_EX_FINDINGS_EXPECT"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    for spec <- expected do
      [kind, type, field] = String.split(spec, [":", "/"], parts: 3)

      f =
        Enum.find(result.findings, fn f ->
          Atom.to_string(f.kind) == kind and f.subject == %{type: type, field: field}
        end)

      assert f, "expected finding #{spec}"

      IO.puts("""

      #{spec} (#{f.confidence}: #{f.confidence_reason})
        proposal #{inspect(Map.drop(f.proposal, [:checks]), limit: :infinity)}
        maintainers #{inspect(f.affects.maintainers.workflows)}; related #{inspect(f.related)}
      """)
    end
  end
end
