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

  defp print(%{changes: changes, skipped: skipped}, dry_run?) do
    verb = if dry_run?, do: "Would record", else: "Recorded"

    for %{path: path, indexes: indexes} <- changes,
        do: Mix.shell().info("#{verb} as concurrent in #{path}: #{Enum.join(indexes, ", ")}")

    for %{path: path, reason: reason} <- skipped,
        do: Mix.shell().error("Skipped #{path}: #{reason}")

    count = changes |> Enum.map(&length(&1.indexes)) |> Enum.sum()

    Mix.shell().info(
      cond do
        changes == [] ->
          "No snapshot records a generated index as not concurrent."

        dry_run? ->
          "#{count} index(es) in #{length(changes)} snapshot(s); nothing written (--dry-run)."

        true ->
          "#{count} index(es) in #{length(changes)} snapshot(s). Now run mix ash.codegen."
      end
    )
  end
end
