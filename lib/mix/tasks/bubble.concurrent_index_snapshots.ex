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

  Generated projects ship the same code (WTF-499), for owners without
  bubble_ex: from the project root, `mix run --no-start
  priv/bubble/concurrent_index_snapshots.exs [--dry-run]`.
  """
  use Mix.Task

  alias BubbleEx.Target.Phoenix.IndexSnapshots.Upgrader

  @impl Mix.Task
  def run(argv) do
    case Upgrader.cli(argv,
           usage: "usage: mix bubble.concurrent_index_snapshots --root DIR [--dry-run]",
           info: fn line -> Mix.shell().info(line) end,
           error: fn line -> Mix.shell().error(line) end
         ) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
