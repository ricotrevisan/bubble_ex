defmodule BubbleEx.Load.Journal do
  @moduledoc false

  # The durable-state mechanics the loader's records share
  # (`BubbleEx.Load.Ledger`, `BubbleEx.Load.Written`): a snapshot
  # `<name>.json` written atomically (a temporary file, `fsync`, rename,
  # directory sync) and an append-only journal `<name>.journal`, one JSON
  # event per line with a sequence number, each appended and `fsync`ed. A
  # torn last line (a crash in the middle of a write) ends the replay; an
  # event the snapshot's `seq` already covers is skipped. Files are `0600`.

  alias BubbleEx.CanonicalJson

  @doc false
  def journal_path(path), do: String.replace_suffix(path, ".json", ".journal")

  @doc false
  # Applies the journal's events to `data` with `apply` (`apply.(data,
  # event)`); returns the data and the number of events applied.
  def replay(path, data, apply) do
    case File.read(journal_path(path)) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.reduce_while({data, 0}, &replay_line(&1, &2, apply))

      {:error, _} ->
        {data, 0}
    end
  end

  defp replay_line(line, {data, n}, apply) do
    case Jason.decode(line) do
      {:ok, %{"seq" => seq} = event} when is_integer(seq) ->
        if seq <= Map.get(data, "seq", 0),
          do: {:cont, {data, n}},
          else: {:cont, {data |> apply.(event) |> Map.put("seq", seq), n + 1}}

      _ ->
        {:halt, {data, n}}
    end
  end

  @doc false
  # Appends one event (with its `seq`) and syncs it.
  def append(io, event) do
    :ok = :file.write(io, [CanonicalJson.encode(event), "\n"])
    :ok = :file.datasync(io)
  end

  @doc false
  def write_snapshot(path, data) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, io} = :file.open(tmp, [:write, :raw, :binary])
    :ok = :file.write(io, CanonicalJson.encode(data))
    :ok = :file.sync(io)
    :ok = :file.close(io)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
    sync_dir(Path.dirname(path))
  end

  @doc false
  # Empties the journal (after a snapshot covers it).
  def remove_journal(path) do
    File.rm(journal_path(path))
    sync_dir(Path.dirname(path))
  end

  @doc false
  def open_journal(path) do
    journal = journal_path(path)
    new? = not File.exists?(journal)
    {:ok, io} = :file.open(journal, [:append, :raw, :binary])
    if new?, do: File.chmod!(journal, 0o600)
    io
  end

  @doc false
  # A directory the loader creates is `0700` (an existing one is left as it is).
  def ensure_dir(dir) do
    unless File.dir?(dir) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end

    :ok
  end

  # Makes a rename (and a journal's removal) durable: Erlang cannot fsync
  # a directory, so this asks `sync` to, best effort (GNU coreutils syncs
  # the directory itself; elsewhere it syncs everything).
  defp sync_dir(dir) do
    case System.find_executable("sync") do
      nil -> :ok
      sync -> System.cmd(sync, [dir], stderr_to_stdout: true)
    end

    :ok
  end
end
