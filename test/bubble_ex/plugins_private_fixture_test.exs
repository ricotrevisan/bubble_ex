defmodule BubbleEx.PluginsPrivateFixtureTest do
  # Plugin inventory and `:plugin` findings on a real app (WTF-376), like
  # BubbleEx.PlanPrivateFixtureTest. Excluded by default:
  #
  #     BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
  #
  # Aggregate counts only (no plugin IDs, names or symbol IDs) are compared
  # with a committed snapshot, by default the mm-137 test version's: how
  # many plugins are installed and used, how uses spread over plugins, the
  # findings per suggested option and confidence, and the plan's plugin
  # units with every plugin undecided and with every suggestion accepted.
  # A changed count means updating the snapshot, with the reason in the PR:
  #
  #     BUBBLE_EX_UPDATE_COUNTS=1 BUBBLE_EX_PRIVATE_EXPORT=… mix test --only private_fixture
  #
  # BUBBLE_EX_PLUGIN_COUNTS names another snapshot file.
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Decision, Findings, Index, Model, Plan}
  alias BubbleEx.Plugins.Inventory
  alias BubbleEx.Test.SplitExport

  @moduletag :private_fixture
  @moduletag timeout: :infinity

  @default_snapshot "test/support/plugins/counts/mm-137.json"
  @now ~U[2026-09-26 00:00:00Z]

  setup_all do
    path =
      System.get_env("BUBBLE_EX_PRIVATE_EXPORT") ||
        flunk("set BUBBLE_EX_PRIVATE_EXPORT to a private app export")

    app = SplitExport.load(path)
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, result} = Findings.analyze(app, model: model, index: index)
    %{app: app, model: model, index: index, findings: result.findings}
  end

  test "matches the recorded plugin snapshot", ctx do
    inventory = Inventory.build(ctx.index)
    plugins = Enum.filter(ctx.findings, &(&1.kind == :plugin))

    counts = %{
      "inventory" => inventory_counts(inventory),
      "findings" => finding_counts(plugins),
      "plan" => %{
        "undecided" => plan_units(ctx, []),
        "suggestions_accepted" => plan_units(ctx, accept_all(ctx, plugins))
      }
    }

    IO.puts("""

    plugins:
    #{counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)}
    """)

    snapshot = System.get_env("BUBBLE_EX_PLUGIN_COUNTS") || @default_snapshot

    if System.get_env("BUBBLE_EX_UPDATE_COUNTS") do
      File.mkdir_p!(Path.dirname(snapshot))

      File.write!(
        snapshot,
        (counts |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
      )
    end

    assert counts == snapshot |> File.read!() |> Jason.decode!(),
           "counts changed; update #{snapshot} with a reason"
  end

  test "one finding per plugin symbol, deterministic", ctx do
    plugins = Enum.filter(ctx.findings, &(&1.kind == :plugin))
    assert length(plugins) == length(Index.symbols(ctx.index, :plugin))

    {:ok, again} = Findings.analyze(ctx.app, kinds: [:plugin])
    assert Jason.encode!(again.findings) == Jason.encode!(plugins)
  end

  defp inventory_counts(inventory) do
    {used, unused} = Enum.split_with(inventory, &Inventory.used?/1)
    uses = &(&1.counts.elements + &1.counts.actions + &1.counts.events)

    %{
      "plugins" => length(inventory),
      "installed" => Enum.count(inventory, & &1.installed),
      "installed_unused" => Enum.count(unused, & &1.installed),
      "used_not_installed" => Enum.count(used, &(not &1.installed)),
      "in_catalog" => Enum.count(inventory, &(&1.name != nil)),
      "members_used" => inventory |> Enum.map(&length(&1.members)) |> Enum.sum(),
      "uses" =>
        Map.new(~w(elements actions events state_reads)a, fn k ->
          {Atom.to_string(k), inventory |> Enum.map(& &1.counts[k]) |> Enum.sum()}
        end),
      # Uses per plugin, bucketed (no plugin is named).
      "uses_per_plugin" =>
        inventory
        |> Enum.frequencies_by(&bucket(uses.(&1)))
        |> Map.new(fn {k, v} -> {k, v} end),
      "surfaces_per_plugin" => inventory |> Enum.frequencies_by(&bucket(&1.counts.surfaces))
    }
  end

  defp bucket(0), do: "0"
  defp bucket(n) when n < 10, do: "1-9"
  defp bucket(n) when n < 100, do: "10-99"
  defp bucket(_), do: "100+"

  defp finding_counts(plugins) do
    %{
      "total" => length(plugins),
      "suggested" => Enum.frequencies_by(plugins, &Atom.to_string(&1.proposal.option)),
      "confidence" => Enum.frequencies_by(plugins, &Atom.to_string(&1.confidence)),
      "offering_replace_native" => Enum.count(plugins, &(:replace_native in &1.proposal.options))
    }
  end

  defp accept_all(ctx, plugins) do
    records =
      for f <- plugins do
        {:ok, record} = Decision.for_finding(f, :accept)
        record
      end

    {:ok, resolved} = Decision.resolve(records, ctx.findings, index: ctx.index, now: @now)

    resolved
    |> Decision.applicable(ctx.findings)
    |> Enum.filter(&(&1.transform == :replace_plugin))
  end

  defp plan_units(ctx, applied) do
    {:ok, plan} = Plan.build(ctx.model, ctx.index, nil, applied)

    %{
      "plugins" => plan.coverage["units"]["plugins"],
      "top_level" => plan.coverage["top_level"],
      "decision_edges" =>
        Enum.count(for t <- plan.tasks, %{kind: :decision} <- t.depends_on, do: t),
      "plugin_edges" => Enum.count(for t <- plan.tasks, %{kind: :plugin} <- t.depends_on, do: t)
    }
  end
end
