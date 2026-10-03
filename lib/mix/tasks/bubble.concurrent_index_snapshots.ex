defmodule Mix.Tasks.Bubble.ConcurrentIndexSnapshots do
  @shortdoc "Record a generated project's index hints as concurrent in its snapshots"
  @moduledoc """
  Upgrades a project generated before WTF-418 (index hints built
  concurrently) without dropping and rebuilding its indexes. Run it once
  from a bubble_ex checkout, after regenerating and before `mix
  ash.codegen`:

      mix bubble.concurrent_index_snapshots --root /path/to/project --dry-run
      mix bubble.concurrent_index_snapshots --root /path/to/project

  In each table's latest AshPostgres snapshot
  (`priv/resource_snapshots/<repo>/<table>/<timestamp>.json`) it sets
  `"concurrently": true` on the custom indexes the generated resources
  declare `concurrently: true` (same name, fields and method; never a
  unique index, an identity or an index of your own). `mix ash.codegen`
  then sees no change for them, and builds the indexes it adds later
  concurrently. Running it again changes nothing. See
  `BubbleEx.Target.Phoenix.IndexSnapshots`.

  Options: `--root DIR` (required), `--dry-run` (report, write nothing).
  It exits non-zero when it skips a snapshot it cannot rewrite safely
  (fix that one by hand), and when the resources were not regenerated yet
  (they still declare their indexes without `concurrently: true`). It
  warns about what it does not look at: a symbolically linked
  `priv/resource_snapshots` (or repo or table directory), and `_dev`
  snapshots.
  """
  use Mix.Task

  alias BubbleEx.Target.Phoenix.IndexSnapshots

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: [root: :string, dry_run: :boolean])

    root =
      case {opts[:root], rest, invalid} do
        {root, [], []} when is_binary(root) -> root
        _ -> Mix.raise("usage: mix bubble.concurrent_index_snapshots --root DIR [--dry-run]")
      end

    dry_run? = Keyword.get(opts, :dry_run, false)

    case IndexSnapshots.fix(root, dry_run: dry_run?) do
      {:ok, report} -> print(report, dry_run?)
      {:error, error} -> Mix.raise(Exception.message(error))
    end
  end

  defp print(report, dry_run?) do
    verb = if dry_run?, do: "Would record", else: "Recorded"

    for %{path: path, indexes: indexes} <- report.changes,
        do: Mix.shell().info("#{verb} as concurrent in #{path}: #{Enum.join(indexes, ", ")}")

    for warning <- report.warnings, do: Mix.shell().error("Warning: " <> warning)

    for %{path: path, reason: reason} <- report.skipped,
        do: Mix.shell().error("Skipped #{path}: #{reason}")

    conclude(report, dry_run?)
  end

  defp conclude(%{skipped: [_ | _] = skipped} = report, dry_run?) do
    Mix.raise(
      "#{length(skipped)} snapshot(s) skipped: fix them as said above before mix " <>
        "ash.codegen, or it drops and rebuilds their indexes (#{done(report)} " <>
        if(dry_run?, do: "to record)", else: "recorded)")
    )
  end

  defp conclude(%{changes: [], not_concurrent: n}, _dry_run?) when n > 0 do
    Mix.raise(
      "The generated resources declare #{n} index(es) without concurrently: true: " <>
        "regenerate the project with this bubble_ex first, then run this task again " <>
        "(before mix ash.codegen)."
    )
  end

  defp conclude(%{changes: []}, _dry_run?),
    do: Mix.shell().info("No snapshot records a generated index as not concurrent.")

  defp conclude(report, true),
    do: Mix.shell().info(done(report) <> "; nothing written (--dry-run).")

  defp conclude(report, false),
    do: Mix.shell().info(done(report) <> ". Now run mix ash.codegen.")

  defp done(%{changes: changes}) do
    count = changes |> Enum.map(&length(&1.indexes)) |> Enum.sum()
    "#{count} index(es) in #{length(changes)} snapshot(s)"
  end
end
