defmodule BubbleEx.Load.Ledger do
  @moduledoc """
  The loader's checkpoint: what one run (an export, a plan, a target and a
  storage) has written, so an interrupted run resumes where it stopped.

  Two files per run in the ledger directory: a snapshot
  `<run key>.json` and an append-only journal `<run key>.journal`, one JSON
  event per line with a sequence number, each appended and `fsync`ed as
  it happens (a copied file, a written batch, a finished type). Opening a ledger reads the
  snapshot and replays the journal events its sequence number does not
  cover (a torn last line, from a crash in the middle of a write, is
  skipped; any other line that does not decode fails the open: fail closed), then writes a new snapshot and empties the journal, so
  nothing is ever appended after a torn line. Every `:compact_every` events (default
  1,000) the state is written to a new snapshot (a temporary file,
  `fsync`, rename, directory sync) and the journal is emptied, so writes stay linear in
  the number of events. Snapshot:

      {"format": "bubble_ex.load_ledger", "version": 2, "run": "<run key>",
       "export_sha256": "…", "plan_sha256": "…", "target": "<identity>",
       "status": "running" | "complete", "seq": <the last event it covers>,
       "files": {"<url>": "<storage reference>"},
       "types": {"task": {"rows_done": 1500, "complete": false,
                          "inserted": 1400, "updated": 100, "unchanged": 0}},
       "pruned": {"task": {"rows_deleted": 3, "cleared": 0}}}

  (`pruned`, WTF-414: counts. A pruning run also records `prune_plan`,
  the plan it was confirmed with: its hash and the Bubble IDs it deletes.
  Which rows the loader wrote, and so may prune, is
  `BubbleEx.Load.Written`, kept across runs.)

  The run key is the SHA-256 of the export's identity, the plan's and the
  target's (the database, the storage and the `:keys` option; see
  `BubbleEx.Load`), so a new export (a delta sync), another plan, target
  or storage starts a new ledger. The loader's writes are idempotent
  upserts, so a batch written just before a crash and replayed on resume
  changes nothing: the ledger is an optimization and a record, not what
  makes a rerun safe.

  A ledger holds no stored value and no credential: counts, Bubble file
  URLs, storage references and (a confirmed prune plan) Bubble IDs only. Its files are `0600`; a directory the
  ledger creates is `0700` (an existing one is left as it is).

  The journal's file descriptor belongs to the process that opened the
  ledger: record events from that process.
  """

  alias BubbleEx.Error
  alias BubbleEx.Load.{Export, Journal}

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
    Journal.ensure_dir(dir)

    key = run_key(ids.export_sha256, ids.plan_sha256, ids.target)
    path = Path.join(dir, key <> ".json")

    with {:ok, data} <- read_snapshot(path, key, ids),
         {:ok, data, events} <- Journal.replay(path, data, &apply_event/2) do
      ledger = %__MODULE__{
        path: path,
        data: data,
        events: events,
        compact_every: Keyword.get(opts, :compact_every, @compact_every)
      }

      # Whatever the journal held (even only a torn line) goes into a new
      # snapshot and the journal starts empty: nothing is ever appended
      # after a torn line, where replay would not see it.
      ledger =
        if File.exists?(Journal.journal_path(path)),
          do: force_compact(ledger),
          else: compact(ledger)

      {:ok, open_journal(ledger)}
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

    with {:ok, data} <- read_snapshot(path, key, nil),
         {:ok, data, _events} <- Journal.replay(path, data, &apply_event/2),
         do: {:ok, data}
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

  @doc """
  Records a pruned batch of `key` (a data type or a join's list, WTF-414):
  the rows deleted and the memberships cleared.
  """
  @spec pruned(t(), String.t(), %{deleted: non_neg_integer(), cleared: non_neg_integer()}) :: t()
  def pruned(%__MODULE__{} = l, key, counts),
    do:
      record(l, %{"pruned" => key, "rows_deleted" => counts.deleted, "cleared" => counts.cleared})

  @doc "The prune counts recorded for `key` (`\"rows_deleted\"`, `\"cleared\"`)."
  @spec pruned_counts(t(), String.t()) :: map()
  def pruned_counts(%__MODULE__{data: d}, key), do: get_in(d, ["pruned", key]) || %{}

  @doc """
  Records the prune plan a run was confirmed with (`prune: [expect:
  sha256]`, WTF-414): the hash the caller confirmed and the records and
  join rows it deletes (Bubble IDs), so a resumed run may prune what is
  left of it under the same confirmation.
  """
  @spec prune_plan(t(), String.t(), map(), map()) :: t()
  def prune_plan(%__MODULE__{} = l, sha256, records, lists) do
    record(l, %{
      "prune_plan" => sha256,
      "records" => records,
      "lists" => Map.new(lists, fn {k, pairs} -> {k, Enum.map(pairs, &Tuple.to_list/1)} end)
    })
  end

  @doc "The confirmed prune plan recorded in a ledger or its data (nil when none)."
  @spec confirmed_prune(map() | t()) :: map() | nil
  def confirmed_prune(%__MODULE__{data: d}), do: confirmed_prune(d)
  def confirmed_prune(%{} = d), do: d["prune_plan"]

  @doc "Starts a finished run over: forgets its types, files and prune counts."
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

  defp apply_event(d, %{"pruned" => key} = e) do
    entry =
      d
      |> Map.get("pruned", %{})
      |> Map.get(key, %{"rows_deleted" => 0, "cleared" => 0})
      |> Map.update!("rows_deleted", &(&1 + e["rows_deleted"]))
      |> Map.update!("cleared", &(&1 + e["cleared"]))

    Map.put(d, "pruned", Map.put(Map.get(d, "pruned", %{}), key, entry))
  end

  defp apply_event(d, %{"prune_plan" => sha} = e),
    do:
      Map.put(d, "prune_plan", %{
        "sha256" => sha,
        "records" => e["records"],
        "lists" => e["lists"]
      })

  defp apply_event(d, %{"restart" => true}),
    do:
      d
      |> Map.merge(%{"status" => "running", "types" => %{}, "files" => %{}, "pruned" => %{}})
      |> Map.delete("prune_plan")

  defp apply_event(d, %{"complete" => true}), do: Map.put(d, "status", "complete")
  defp apply_event(d, _unknown), do: d

  defp record(%__MODULE__{path: nil} = l, event), do: %{l | data: apply_event(l.data, event)}

  defp record(%__MODULE__{} = l, event) do
    seq = Map.get(l.data, "seq", 0) + 1
    event = Map.put(event, "seq", seq)
    :ok = Journal.append(l.journal, event)
    data = l.data |> apply_event(event) |> Map.put("seq", seq)
    l = %{l | data: data, events: l.events + 1}
    if l.events >= l.compact_every, do: l |> close() |> compact() |> open_journal(), else: l
  end

  # --- snapshot ---------------------------------------------------------------------------

  defp compact(%__MODULE__{path: nil} = l), do: l

  defp compact(%__MODULE__{events: 0} = l) do
    unless File.exists?(l.path), do: Journal.write_snapshot(l.path, l.data)
    l
  end

  defp compact(%__MODULE__{} = l), do: force_compact(l)

  defp force_compact(%__MODULE__{} = l) do
    Journal.write_snapshot(l.path, l.data)
    Journal.remove_journal(l.path)
    %{l | events: 0}
  end

  defp open_journal(%__MODULE__{path: nil} = l), do: l
  defp open_journal(%__MODULE__{path: path} = l), do: %{l | journal: Journal.open_journal(path)}
end
