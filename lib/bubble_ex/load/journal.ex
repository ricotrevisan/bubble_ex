defmodule BubbleEx.Load.Journal do
  @moduledoc false

  # The durable-state mechanics the loader's records share
  # (`BubbleEx.Load.Ledger`, `BubbleEx.Load.Written`): a snapshot
  # `<name>.json` written atomically (a temporary file, `fsync`, rename,
  # directory sync) and an append-only journal `<name>.journal`, one JSON
  # event per line with a sequence number, each appended and `fsync`ed
  # (a new journal's directory too). A torn last line (a crash in the
  # middle of a write) is skipped; any other undecodable line fails the
  # replay (fail closed); an event the snapshot's `seq` already covers is
  # skipped. Files are `0600`.

  alias BubbleEx.{CanonicalJson, Error}

  @doc false
  def journal_path(path), do: String.replace_suffix(path, ".json", ".journal")

  @doc false
  # Applies the journal's events to `data` with `apply` (`apply.(data,
  # event)`, which may raise on a malformed event); returns the data and
  # the number of events applied. Fails closed: only the last line, when
  # it is torn (a crash in the middle of a write: no newline after it), may
  # be skipped; any other line that does not decode to an event, or that
  # `apply` refuses, is an error.
  def replay(path, data, apply) do
    case File.read(journal_path(path)) do
      {:ok, text} ->
        # the unterminated rest, if any, is the torn line: skipped
        {complete, _torn} = split_lines(text)

        Enum.reduce_while(complete, {:ok, data, 0}, &replay_step(&1, &2, path, apply))

      {:error, :enoent} ->
        {:ok, data, 0}

      {:error, reason} ->
        {:error, Error.new(:invalid_input, "cannot read a load journal", %{reason: reason})}
    end
  end

  # Lines ended by a newline, and the unterminated rest (the torn line).
  defp split_lines(text) do
    parts = String.split(text, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.reject(complete, &(&1 == "")), rest}
  end

  defp replay_step(line, {:ok, data, n}, path, apply) do
    case replay_line(line, data, apply) do
      {:ok, data, applied} -> {:cont, {:ok, data, n + applied}}
      :error -> {:halt, corrupt(path)}
    end
  end

  defp replay_line(line, data, apply) do
    case Jason.decode(line) do
      {:ok, %{"seq" => seq} = event} when is_integer(seq) ->
        if seq <= Map.get(data, "seq", 0),
          do: {:ok, data, 0},
          else: {:ok, data |> apply.(event) |> Map.put("seq", seq), 1}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp corrupt(path),
    do:
      {:error,
       Error.new(:invalid_input, "a load journal is corrupt (a complete line does not decode)", %{
         journal: Path.basename(journal_path(path))
       })}

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

    # A new journal's directory entry is made durable too.
    if new? do
      File.chmod!(journal, 0o600)
      sync_dir(Path.dirname(journal))
    end

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
