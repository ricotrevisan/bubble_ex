defmodule BubbleEx.Target.Phoenix.IndexSnapshots do
  @moduledoc """
  Upgrades a generated project's AshPostgres resource snapshots to the
  concurrent index hints (WTF-418).

  The generated resources declare their custom indexes (the search index
  hints) `concurrently: true`, so `mix ash.codegen` builds the indexes it
  adds without locking writes. A project whose migrations were generated
  before that has snapshots recording those indexes as not concurrent, and
  AshPostgres compares the flag: its next `mix ash.codegen` would drop
  every such index and build it again. `fix/2` records them as concurrent
  instead, in each table's latest snapshot, so codegen sees no change for
  them (the database keeps its indexes) and builds later ones
  concurrently.

  A snapshot index is changed only when it is one of the generated
  resources' (listed in `.wtf/generated.json`): same table (and repo),
  same name, same fields and access method, declared `concurrently: true`
  in the resource, not unique, recorded `"concurrently": false`. Identities
  (unique indexes) are never touched, nor indexes the owner declared, nor
  older or `_dev` snapshots, nor tenant snapshots (`<repo>/tenants/`). A
  snapshot is rewritten in AshPostgres' layout, keeping its trailing
  whitespace; one whose JSON differs from that layout by more than
  whitespace (key order, duplicate keys), or is not valid JSON, is
  `skipped` with a reason, and still counts as `stale` (codegen would
  rebuild its indexes). Each file is written atomically (a temporary file
  in its directory, then renamed). Run again, it changes nothing.

  The logic lives in `BubbleEx.Target.Phoenix.IndexSnapshots.Upgrader`,
  a self-contained file (Elixir and Jason only) that every generated
  project also ships as `priv/bubble/concurrent_index_snapshots.exs`
  (`script/0`), so owners without bubble_ex can run it:

      mix run --no-start priv/bubble/concurrent_index_snapshots.exs

  `mix bubble.concurrent_index_snapshots` runs it from bubble_ex;
  `check_manifest/3` lists the snapshots that need it
  (`index_snapshots_stale`).
  """

  alias BubbleEx.Error
  alias BubbleEx.Target.Phoenix.IndexSnapshots.Upgrader

  @upgrader Path.join(__DIR__, "index_snapshots/upgrader.ex")
  @external_resource @upgrader
  @upgrader_source File.read!(@upgrader)

  @script_path "priv/bubble/concurrent_index_snapshots.exs"
  @command "mix run --no-start #{@script_path}"

  @type report :: Upgrader.report()

  @doc """
  Records the generated resources' concurrent indexes as concurrent in the
  latest snapshots of the project at `root` (`Upgrader.fix/2`). With
  `dry_run: true`, only reports what it would change. A failure is an
  `BubbleEx.Error` (`:invalid_input`); a failed write stops at that file,
  leaving it unchanged, with `error.context.written`.
  """
  @spec fix(Path.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def fix(root, opts \\ []) do
    case Upgrader.fix(root, opts) do
      {:ok, report} ->
        {:ok, report}

      {:error, %{message: message, context: context}} ->
        {:error, Error.new(:invalid_input, message, context)}
    end
  end

  @doc false
  # The latest snapshots whose generated indexes the next `mix
  # ash.codegen` would rebuild (Manifest.check/3).
  @spec stale(map(), (String.t() -> binary() | nil), (String.t() -> [String.t()])) ::
          [String.t()]
  defdelegate stale(manifest, read, list), to: Upgrader

  @doc "Where a generated project ships the upgrader (`script/0`)."
  @spec script_path() :: String.t()
  def script_path, do: @script_path

  @doc "The command an owner runs in a generated project, from its root."
  @spec command() :: String.t()
  def command, do: @command

  @doc """
  The generated project's `priv/bubble/concurrent_index_snapshots.exs`:
  `Upgrader`'s source, byte for byte, then its command line. The same
  source as `mix bubble.concurrent_index_snapshots`, so the two cannot
  drift.
  """
  @spec script() :: String.t()
  def script do
    """
    # Records the generated index hints as concurrent in this project's
    # AshPostgres snapshots, so `mix ash.codegen` does not drop and rebuild
    # them (migrations generated before bubble_ex built them concurrently).
    # Run it from the project root after regenerating, before
    # `mix ash.codegen`:
    #
    #     #{@command} --dry-run
    #     #{@command}
    #
    # It exits non-zero when it skips a snapshot it cannot rewrite safely
    # (fix that one by hand, as it says) or the resources were not
    # regenerated yet. Running it again changes nothing.

    """ <>
      @upgrader_source <>
      """

      case BubbleEx.Target.Phoenix.IndexSnapshots.Upgrader.cli(System.argv(),
             root: File.cwd!(),
             usage: "usage: #{@command} [--dry-run] [--root DIR]"
           ) do
        :ok ->
          :ok

        {:error, message} ->
          IO.puts(:stderr, "** " <> message)
          System.halt(1)
      end
      """
  end
end
