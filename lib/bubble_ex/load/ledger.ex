defmodule BubbleEx.Load.Ledger do
  @moduledoc """
  The loader's checkpoint: what one run (an export, a plan, a target and a
  storage) has written, so an interrupted run resumes where it stopped.

  Two files per run in the ledger directory: a snapshot
  `<run key>.json` and an append-only journal `<run key>.journal`, one JSON
  event per line, each appended and `fsync`ed as it happens (a copied
  file, a written batch, a finished type). Opening a ledger reads the
  snapshot and replays the journal (a torn last line, from a crash in the
  middle of a write, is ignored). Every `:compact_every` events (default
  1,000) the state is written to a new snapshot (a temporary file,
  `fsync`, rename) and the journal is emptied, so writes stay linear in
  the number of events. Snapshot:

      {"format": "bubble_ex.load_ledger", "version": 2, "run": "<run key>",
       "export_sha256": "…", "plan_sha256": "…", "target": "<identity>",
       "status": "running" | "complete",
       "files": {"<url>": "<storage reference>"},
       "types": {"task": {"rows_done": 1500, "complete": false,
                          "inserted": 1400, "updated": 100, "unchanged": 0}}}

  The run key is the SHA-256 of the export's identity, the plan's and the
  target's (the database, the storage and the `:keys` option; see
  `BubbleEx.Load`), so a new export (a delta sync), another plan, target
  or storage starts a new ledger. The loader's writes are idempotent
  upserts, so a batch written just before a crash and replayed on resume
  changes nothing: the ledger is an optimization and a record, not what
  makes a rerun safe.

  A ledger holds no stored value and no credential: counts, Bubble file
  URLs and storage references only. Its files are `0600`; a directory the
  ledger creates is `0700` (an existing one is left as it is).

  The journal's file descriptor belongs to the process that opened the
  ledger: record events from that process.
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Load.Export

  @format "bubble_ex.load_ledger"
  @version 2
  @compact_every 1_000

  @enforce_keys [:path, :data]
  defstruct [:path, :data, :journal, events: 0, compact_every: @compact_every, resumed: %{}]

  # `resumed` (not persisted): rows this process skipped per type because
  # the ledger had them. `journal`: the open journal (nil in memory).
  @type t :: %__MODULE__{
          path: Path.t() | nil,
          data: map(),
          journal: term(),
          events: non_neg_integer(),
          compact_every: pos_integer(),
          resumed: %{String.t() => non_neg_integer()}
        }

  @doc "The run key of an export, plan and target identity."
  @spec run_key(String.t(), String.t(), String.t()) :: String.t()
  def run_key(export_sha256, plan_sha256, target),
    do: Export.sha256_hex(Enum.join([export_sha256, plan_sha256, target], "\n"))

  @doc """
  Opens (or starts) the ledger of a run in `dir`. With `dir` nil the ledger
  lives in memory only (a dry run, or a caller that does not resume).
  Options: `:compact_every`.
  """
  @spec open(Path.t() | nil, map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(dir, ids, opts \\ [])
  def open(nil, ids, _opts), do: {:ok, %__MODULE__{path: nil, data: fresh(ids)}}

  def open(dir, ids, opts) do
    unless File.dir?(dir) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end

    key = run_key(ids.export_sha256, ids.plan_sha256, ids.target)
    path = Path.join(dir, key <> ".json")

    with {:ok, data} <- read_snapshot(path, key, ids) do
      {data, events} = replay(journal_path(path), data)

      ledger = %__MODULE__{
        path: path,
        data: data,
        events: events,
        compact_every: Keyword.get(opts, :compact_every, @compact_every)
      }

      {:ok, ledger |> compact() |> open_journal()}
    end
  end

  defp read_snapshot(path, key, ids) do
    case File.read(path) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"format" => @format, "version" => @version, "run" => ^key} = data} ->
            {:ok, data}

          _ ->
            {:error, Error.new(:invalid_input, "the load ledger is unreadable", %{run: key})}
        end

      {:error, :enoent} when ids != nil ->
        {:ok, fresh(ids)}

      {:error, :enoent} ->
        {:error, Error.new(:invalid_input, "no load ledger", %{run: key})}

      {:error, reason} ->
        {:error, Error.new(:invalid_input, "cannot read the load ledger", %{reason: reason})}
    end
  end

  defp journal_path(path), do: String.replace_suffix(path, ".json", ".journal")

  # Applies the journal's events; a line that does not decode (a torn
  # write) ends the replay.
  defp replay(journal, data) do
    case File.read(journal) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.reduce_while({data, 0}, &replay_line/2)

      {:error, _} ->
        {data, 0}
    end
  end

  defp replay_line(line, {data, n}) do
    case Jason.decode(line) do
      {:ok, event} -> {:cont, {apply_event(data, event), n + 1}}
      {:error, _} -> {:halt, {data, n}}
    end
  end

  defp fresh(ids) do
    %{
      "format" => @format,
      "version" => @version,
      "run" => run_key(ids.export_sha256, ids.plan_sha256, ids.target),
      "export_sha256" => ids.export_sha256,
      "plan_sha256" => ids.plan_sha256,
      "target" => ids.target,
      "status" => "running",
      "files" => %{},
      "types" => %{}
    }
  end

  @doc """
  The state recorded at a snapshot path (`<dir>/<run key>.json`), with its
  journal replayed; for inspection. `{:error, _}` when there is none.
  """
  @spec read(Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def read(path) do
    key = Path.basename(path, ".json")

    with {:ok, data} <- read_snapshot(path, key, nil) do
      {data, _events} = replay(journal_path(path), data)
      {:ok, data}
    end
  end

  @doc "The run key."
  @spec run(t()) :: String.t()
  def run(%__MODULE__{data: d}), do: d["run"]

  @doc "Whether the run finished."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{data: d}), do: d["status"] == "complete"

  @doc "Rows of `type` already written."
  @spec rows_done(t(), String.t()) :: non_neg_integer()
  def rows_done(%__MODULE__{data: d}, type), do: get_in(d, ["types", type, "rows_done"]) || 0

  @doc "The counts recorded for `type`."
  @spec type_counts(t(), String.t()) :: map()
  def type_counts(%__MODULE__{data: d}, type), do: get_in(d, ["types", type]) || %{}

  @doc "Files already copied: URL => storage reference."
  @spec files(t()) :: %{String.t() => String.t()}
  def files(%__MODULE__{data: d}), do: d["files"]

  @doc "Records a copied file."
  @spec file_copied(t(), String.t(), String.t()) :: t()
  def file_copied(%__MODULE__{} = l, url, ref), do: record(l, %{"file" => url, "ref" => ref})

  @doc "Records a written batch of `type`: rows done so far and the batch's counts."
  @spec batch(t(), String.t(), non_neg_integer(), map()) :: t()
  def batch(%__MODULE__{} = l, type, rows_done, counts) do
    record(l, %{
      "batch" => type,
      "rows_done" => rows_done,
      "inserted" => counts.inserted,
      "updated" => counts.updated,
      "unchanged" => counts.unchanged
    })
  end

  @doc "Marks `type` complete."
  @spec type_complete(t(), String.t(), non_neg_integer()) :: t()
  def type_complete(%__MODULE__{} = l, type, rows),
    do: record(l, %{"type_complete" => type, "rows" => rows})

  @doc "Starts a finished run over: forgets its types and files."
  @spec restart(t()) :: t()
  def restart(%__MODULE__{} = l), do: record(l, %{"restart" => true})

  @doc "Counts rows of `type` skipped because the ledger had them."
  @spec resumed(t(), String.t(), non_neg_integer()) :: t()
  def resumed(%__MODULE__{} = l, _type, 0), do: l

  def resumed(%__MODULE__{} = l, type, n),
    do: %{l | resumed: Map.update(l.resumed, type, n, &(&1 + n))}

  @doc "Marks the run complete, compacts and closes the journal."
  @spec complete(t()) :: t()
  def complete(%__MODULE__{} = l) do
    l |> record(%{"complete" => true}) |> close() |> compact()
  end

  @doc "Closes the journal (the ledger stays readable)."
  @spec close(t()) :: t()
  def close(%__MODULE__{journal: nil} = l), do: l

  def close(%__MODULE__{journal: io} = l) do
    :file.close(io)
    %{l | journal: nil}
  end

  # --- events ---------------------------------------------------------------------------

  defp apply_event(d, %{"file" => url, "ref" => ref}), do: put_in(d, ["files", url], ref)

  defp apply_event(d, %{"batch" => type} = e) do
    entry =
      d["types"]
      |> Map.get(type, %{"inserted" => 0, "updated" => 0, "unchanged" => 0, "complete" => false})
      |> Map.put("rows_done", e["rows_done"])
      |> Map.update("inserted", e["inserted"], &(&1 + e["inserted"]))
      |> Map.update("updated", e["updated"], &(&1 + e["updated"]))
      |> Map.update("unchanged", e["unchanged"], &(&1 + e["unchanged"]))

    put_in(d, ["types", type], entry)
  end

  defp apply_event(d, %{"type_complete" => type, "rows" => rows}) do
    entry =
      d["types"]
      |> Map.get(type, %{"inserted" => 0, "updated" => 0, "unchanged" => 0})
      |> Map.merge(%{"rows_done" => rows, "complete" => true})

    put_in(d, ["types", type], entry)
  end

  defp apply_event(d, %{"restart" => true}),
    do: Map.merge(d, %{"status" => "running", "types" => %{}, "files" => %{}})

  defp apply_event(d, %{"complete" => true}), do: Map.put(d, "status", "complete")
  defp apply_event(d, _unknown), do: d

  defp record(%__MODULE__{path: nil} = l, event), do: %{l | data: apply_event(l.data, event)}

  defp record(%__MODULE__{} = l, event) do
    :ok = :file.write(l.journal, [CanonicalJson.encode(event), "\n"])
    :ok = :file.datasync(l.journal)
    l = %{l | data: apply_event(l.data, event), events: l.events + 1}
    if l.events >= l.compact_every, do: l |> close() |> compact() |> open_journal(), else: l
  end

  # --- snapshot ---------------------------------------------------------------------------

  defp compact(%__MODULE__{path: nil} = l), do: l

  defp compact(%__MODULE__{events: 0} = l) do
    unless File.exists?(l.path), do: write_snapshot(l)
    l
  end

  defp compact(%__MODULE__{} = l) do
    write_snapshot(l)
    File.rm(journal_path(l.path))
    %{l | events: 0}
  end

  defp write_snapshot(%__MODULE__{path: path, data: data}) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, io} = :file.open(tmp, [:write, :raw, :binary])
    :ok = :file.write(io, CanonicalJson.encode(data))
    :ok = :file.sync(io)
    :ok = :file.close(io)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  defp open_journal(%__MODULE__{path: nil} = l), do: l

  defp open_journal(%__MODULE__{path: path} = l) do
    journal = journal_path(path)
    new? = not File.exists?(journal)
    {:ok, io} = :file.open(journal, [:append, :raw, :binary])
    if new?, do: File.chmod!(journal, 0o600)
    %{l | journal: io}
  end
end
