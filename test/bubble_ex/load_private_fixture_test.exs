defmodule BubbleEx.LoadPrivateFixtureTest do
  # The data loader's plan over a real app's schema (WTF-357), like the
  # other private fixture tests: it reads a local export named by
  # BUBBLE_EX_PRIVATE_EXPORT and is excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # The export holds the app's definition, not its data rows, so this is a
  # schema-level check: the Ash adapter's plan covers every live field of
  # every mapped type (a column, a derivation, or the primary key), its
  # derivations name live fields, and a dry run over an export with no rows
  # completes. It asserts and prints counts only, never names or IDs.
  # (scripts/ash_compile_check/load.exs checks the same plans against the
  # PostgreSQL schema AshPostgres migrates.)
  use ExUnit.Case, async: true

  alias BubbleEx.{Findings, Index, Load, Model}
  alias BubbleEx.Load.{Export, Plan}
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.Loader
  alias BubbleEx.Test.{DecidedFixture, LoadMemoryTarget, SplitExport}

  @moduletag :private_fixture
  @moduletag :tmp_dir
  @moduletag timeout: :infinity

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)
    {_records, applied, sha} = DecidedFixture.accept_cut2(findings, [], index)
    {_records, applied3, sha3} = DecidedFixture.accept_cut3(findings, [], index)
    {:ok, faithful} = Ash.map(model)
    {:ok, cut2} = Ash.map(model, applied, decisions_sha256: sha)
    {:ok, cut3} = Ash.map(model, applied3, decisions_sha256: sha3)
    %{model: model, projects: [faithful: faithful, cut2: cut2, cut3: cut3]}
  end

  defp plan(project, model) do
    {Loader, config} = Loader.target(project, query: fn _, _ -> {:ok, %{rows: []}} end)
    {:ok, plan} = Loader.plan(config, model)
    plan
  end

  test "the plan covers every live field of every mapped type", %{
    model: model,
    projects: projects
  } do
    for {name, project} <- projects do
      plan = plan(project, model)
      assert length(plan.tables) == length(project.resources)

      uncovered =
        for table <- plan.tables,
            type = Model.data_type(model, table.type),
            field <- type.system_fields ++ type.fields,
            not field.deleted and is_nil(field.raw) and field.id != "_id",
            field.id not in Enum.map(table.columns, & &1.field),
            field.id not in Enum.map(table.derived, & &1.field),
            field.id not in table.joined,
            do: field.id

      assert uncovered == [], "#{name}: #{length(uncovered)} fields not covered"

      derived = Enum.flat_map(plan.tables, & &1.derived)
      counts = Enum.frequencies_by(derived, &elem(&1.derivation, 0))

      IO.puts(
        "load plan (#{name}): #{length(plan.tables)} tables, " <>
          "#{plan.tables |> Enum.map(&length(&1.columns)) |> Enum.sum()} columns, " <>
          "derived #{inspect(counts)}, text references " <>
          "#{plan.tables |> Enum.flat_map(& &1.columns) |> Enum.count(& &1.text_ref)}, " <>
          "counted lists #{plan.tables |> Enum.flat_map(& &1.columns) |> Enum.count(& &1.drop_dangling)}, " <>
          "join tables #{length(plan.joins)} (#{plan.joins |> Enum.flat_map(& &1.sides) |> length()} lists)"
      )

      # every joined list is one side of one join table
      sides = for j <- plan.joins, s <- j.sides, do: {s.type, s.field}
      joined = for t <- plan.tables, f <- t.joined, do: {t.type, f}
      assert Enum.sort(sides) == Enum.sort(joined)
    end
  end

  test "a dry run over an export with no rows completes", %{
    model: model,
    projects: projects,
    tmp_dir: dir
  } do
    for {name, project} <- projects do
      plan = plan(project, model)
      types = for t <- plan.tables, do: %{type: t.type, path: t.type, rows: []}
      {:ok, export} = Export.write(Path.join(dir, Atom.to_string(name)), %{types: types})

      assert {:ok, report} = Load.dry_run(export, model, LoadMemoryTarget.start(project))
      assert report.blocked == []
      assert Enum.all?(Map.values(report.types), &(&1.records == 0))
      assert Plan.sha256(plan) == report.plan_sha256
    end
  end
end
