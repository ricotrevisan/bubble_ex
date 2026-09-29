defmodule BubbleEx.Load.Written do
  @moduledoc """
  What the loader has written into a target, across its runs (WTF-414):
  the Bubble IDs of the records it upserted per data type, and the
  `[left ID, right ID]` rows whose membership column it set per list of a
  join table (keyed `<join ID>/<type>/<field>`). Pruning
  (`BubbleEx.Load.run/4` with `prune:`) deletes only what this record
  holds, so a row created in the app after go-live, which the loader never
  wrote, is never deleted.

  It lives in the ledger directory, `written/<SHA-256 of the target's
  identity>.json` with its journal (see `BubbleEx.Load.Journal`), and is
  **bound** to what it describes:

    * `marker` - the UUID of the target database's marker table
      (`bubble_ex_load_target`, created by the first real load, the
      adapter's `marker/2`): a database recreated at the same address has
      another marker (or none), so its record does not apply to it. It
      guards against accidents, not against anyone with write access: a
      `pg_dump` clone of the database carries the same marker
    * `app` and `base_url` - the export's app and Data API base URL (the
      manifest's `app` and `source.base_url`): an export of another app,
      or of another version (e.g. the test version), is refused
    * `newest_export` - the latest `created_at` of an export loaded to
      completion: pruning refuses an older export

  An ID is recorded after the batch that wrote it succeeded, and forgotten
  after the batch that pruned it succeeded (and whenever a load finds a
  recorded join row gone): a crash between a write and its record leaves
  a row the record does not hold (never pruned; the resumed batch records
  it), and one between a prune and its record an ID whose row is gone
  (forgotten later). So the record never holds an ID the loader did not
  write.

      {"format": "bubble_ex.load_written", "version": 1,
       "target": "<identity>", "seq": <the last event it covers>,
       "marker": "<uuid>", "app": "<app>", "base_url": "<url>",
       "newest_export": "<ISO 8601>",
       "records": {"task": ["1700000000000x1", ...]},
       "joins": {"<join ID>/<type>/<field>": [["<left ID>", "<right ID>"], ...]}}

  Every journal event carries the target identity too, and a record or
  event that does not decode as this format is an error (fail closed).
  While a run records into it, it is locked (`<record>.lock`, created
  atomically with its content: the owner's host, OS and Erlang process
  IDs; a lock of this host whose process is gone is taken over, under a
  second lock; another host's never is).

  Bubble IDs only: no stored value, no credential. Files are `0600`; a
  directory it creates is `0700`. A target loaded before WTF-414 has no
  record: its rows are the app's until a run records them (rerunning the
  export they came from records every row it holds).
  """

  alias BubbleEx.Error
  alias BubbleEx.Load.{Export, Journal}

  @format "bubble_ex.load_written"
  @version 1
  @compact_every 1_000

  @enforce_keys [:data]
  defstruct [:path, :data, :journal, :lock, events: 0, compact_every: @compact_every]

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          data: map(),
          journal: term(),
          lock: Path.t() | nil,
          events: non_neg_integer(),
          compact_every: pos_integer()
        }

  @doc "The record's path for a ledger directory and a target identity."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(dir, identity),
    do: Path.join([dir, "written", Export.sha256_hex(identity) <> ".json"])

  @doc """
  Reads the record of `identity` in `dir` without writing anything (a dry
  run, planning); an empty record when there is none. `dir` nil: an empty
  record.
  """
  @spec read(Path.t() | nil, String.t()) :: {:ok, t()} | {:error, Error.t()}
  def read(nil, identity), do: {:ok, %__MODULE__{data: fresh(identity)}}

  def read(dir, identity) do
    path = path(dir, identity)

    with {:ok, data} <- read_snapshot(path, identity),
         {:ok, data, _} <- Journal.replay(path, data, &apply_event(&1, &2, identity)),
         do: {:ok, %__MODULE__{data: data}}
  end

  @doc """
  Opens (or starts) the record of `identity` in `dir`, to record writes,
  and locks it until `close/1`. `dir` nil: an in-memory record (nothing
  persists). Options: `:compact_every`.
  """
  @spec open(Path.t() | nil, String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(dir, identity, opts \\ [])
  def open(nil, identity, _opts), do: read(nil, identity)

  def open(dir, identity, opts) do
    path = path(dir, identity)
    Journal.ensure_dir(dir)
    Journal.ensure_dir(Path.dirname(path))

    with {:ok, lock} <- lock(path) do
      case load(path, identity, opts) do
        {:ok, w} ->
          {:ok, %{w | lock: lock}}

        error ->
          unlock(lock)
          error
      end
    end
  end

  defp load(path, identity, opts) do
    with {:ok, data} <- read_snapshot(path, identity),
         {:ok, data, events} <- Journal.replay(path, data, &apply_event(&1, &2, identity)) do
      w = %__MODULE__{
        path: path,
        data: data,
        events: events,
        compact_every: Keyword.get(opts, :compact_every, @compact_every)
      }

      # As the run ledger: whatever the journal held goes into a new
      # snapshot, and the journal starts empty.
      w =
        if File.exists?(Journal.journal_path(path)) or not File.exists?(path),
          do: force_compact(w),
          else: w

      {:ok, %{w | journal: Journal.open_journal(path)}}
    end
  end

  # --- the lock --------------------------------------------------------------------------

  # One writer at a time: `<record>.lock` holds the owner's host, OS
  # process ID and Erlang process ID. It is written to a temporary file
  # and hard-linked into place, so it exists only with its content, and
  # only one link can win. A lock whose owner is gone (on this host: the
  # OS process, or in this OS process the Erlang one) is taken over under
  # a second lock (`<record>.lock.takeover`), after checking it is still
  # the same stale lock. Another host's lock is never taken over.
  defp lock(path) do
    lock = path <> ".lock"
    tmp = "#{lock}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, holder())
    File.chmod!(tmp, 0o600)

    try do
      case File.ln(tmp, lock) do
        :ok -> {:ok, lock}
        {:error, :eexist} -> take_over(lock, tmp)
        {:error, reason} -> lock_error("cannot lock the written record", %{reason: reason})
      end
    after
      File.rm(tmp)
    end
  end

  defp holder do
    {:ok, host} = :inet.gethostname()
    Enum.join([host, System.pid(), :erlang.pid_to_list(self())], " ")
  end

  defp take_over(lock, tmp) do
    seen = read_holder(lock)

    cond do
      other_host?(seen) ->
        lock_error(
          "another host holds this target's lock (#{lock}): its load may still be recording; " <>
            "a lock left by a crashed run on another host is never taken over, so if no load " <>
            "runs there, remove the lock file by hand",
          %{lock: Path.basename(lock), host: seen |> String.split(" ") |> hd()}
        )

      not stale?(seen) ->
        lock_error("another load is recording into this target", %{lock: Path.basename(lock)})

      File.ln(tmp, lock <> ".takeover") != :ok ->
        lock_error(
          "another load is taking over this target's stale lock; if none is, remove it",
          %{
            lock: Path.basename(lock) <> ".takeover"
          }
        )

      true ->
        try do
          # still the same stale lock: nobody took it over meanwhile
          if read_holder(lock) == seen do
            File.rm(lock)

            if File.ln(tmp, lock) == :ok,
              do: {:ok, lock},
              else: lock_error("another load is recording into this target", %{})
          else
            lock_error("another load is recording into this target", %{})
          end
        after
          File.rm(lock <> ".takeover")
        end
    end
  end

  defp read_holder(lock) do
    case File.read(lock) do
      {:ok, text} -> String.trim(text)
      _ -> nil
    end
  end

  defp lock_error(message, context), do: {:error, Error.new(:invalid_input, message, context)}

  defp other_host?(nil), do: false

  defp other_host?(holder) do
    {:ok, host} = :inet.gethostname()

    case String.split(holder, " ") do
      [holder_host, _os, _erl] -> holder_host != List.to_string(host)
      _ -> false
    end
  end

  # Stale: this host's, and its process is gone. Anything else (another
  # host, an unreadable holder) is live.
  defp stale?(nil), do: false

  defp stale?(holder) do
    {:ok, host} = :inet.gethostname()
    host = List.to_string(host)
    me = System.pid()

    case String.split(holder, " ") do
      [^host, ^me, erl] -> not erlang_alive?(erl)
      [^host, os, _erl] -> not os_alive?(os)
      _ -> false
    end
  end

  defp erlang_alive?(erl) do
    erl |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?()
  rescue
    _ -> true
  end

  defp os_alive?(os) do
    cond do
      not String.match?(os, ~r/^\d+$/) -> true
      File.dir?("/proc/self") -> File.dir?("/proc/" <> os)
      true -> match?({_, 0}, System.cmd("kill", ["-0", os], stderr_to_stdout: true))
    end
  end

  defp unlock(nil), do: :ok
  defp unlock(lock), do: File.rm(lock)

  # --- reading ---------------------------------------------------------------------------

  defp read_snapshot(path, identity) do
    case File.read(path) do
      {:ok, text} ->
        with {:ok, %{"format" => @format, "version" => @version, "target" => ^identity} = data} <-
               Jason.decode(text),
             {:ok, data} <- decode(data) do
          {:ok, data}
        else
          _ -> {:error, Error.new(:invalid_input, "the load's written record is unreadable")}
        end

      {:error, :enoent} ->
        {:ok, fresh(identity)}

      {:error, reason} ->
        {:error, Error.new(:invalid_input, "cannot read the written record", %{reason: reason})}
    end
  end

  defp fresh(identity) do
    %{
      "format" => @format,
      "version" => @version,
      "target" => identity,
      "marker" => nil,
      "app" => nil,
      "base_url" => nil,
      "newest_export" => nil,
      "records" => %{},
      "joins" => %{}
    }
  end

  # In memory the IDs are sets; on disk sorted lists. Anything else is an
  # error (a malformed record).
  defp decode(data) do
    with true <- Enum.all?(~w(marker app base_url newest_export), &optional_text?(data[&1])),
         %{} = records <- Map.get(data, "records", %{}),
         %{} = joins <- Map.get(data, "joins", %{}),
         true <- Enum.all?(records, fn {t, ids} -> is_binary(t) and ids?(ids) end),
         true <- Enum.all?(joins, fn {k, pairs} -> is_binary(k) and pairs?(pairs) end) do
      {:ok,
       Map.merge(fresh(data["target"]), data)
       |> Map.put("records", Map.new(records, fn {t, ids} -> {t, MapSet.new(ids)} end))
       |> Map.put(
         "joins",
         Map.new(joins, fn {k, ps} -> {k, MapSet.new(ps, &List.to_tuple/1)} end)
       )}
    else
      _ -> :error
    end
  end

  defp optional_text?(v), do: is_nil(v) or is_binary(v)
  defp ids?(ids), do: is_list(ids) and Enum.all?(ids, &is_binary/1)

  defp pairs?(pairs),
    do:
      is_list(pairs) and Enum.all?(pairs, &match?([l, r] when is_binary(l) and is_binary(r), &1))

  defp encode(data) do
    data
    |> Map.update!("records", &Map.new(&1, fn {t, ids} -> {t, Enum.sort(ids)} end))
    |> Map.update!(
      "joins",
      &Map.new(&1, fn {k, pairs} ->
        {k, pairs |> Enum.sort() |> Enum.map(fn {l, r} -> [l, r] end)}
      end)
    )
  end

  # --- queries -----------------------------------------------------------------------------

  @doc "The IDs of `type` the loader wrote."
  @spec records(t(), String.t()) :: MapSet.t()
  def records(%__MODULE__{data: d}, type), do: get_in(d, ["records", type]) || MapSet.new()

  @doc "The `{left ID, right ID}` rows of a join's list (its key) the loader wrote."
  @spec pairs(t(), String.t()) :: MapSet.t()
  def pairs(%__MODULE__{data: d}, key), do: get_in(d, ["joins", key]) || MapSet.new()

  @doc "The data types with recorded IDs."
  @spec types(t()) :: [String.t()]
  def types(%__MODULE__{data: d}),
    do: for({t, ids} <- d["records"], MapSet.size(ids) > 0, do: t) |> Enum.sort()

  @doc "The join lists (keys) with recorded rows."
  @spec lists(t()) :: [String.t()]
  def lists(%__MODULE__{data: d}),
    do: for({k, pairs} <- d["joins"], MapSet.size(pairs) > 0, do: k) |> Enum.sort()

  @doc "Whether the record holds no ID."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = w), do: types(w) == [] and lists(w) == []

  @doc "The binding: `marker`, `app`, `base_url`, `newest_export` (nil when unset)."
  @spec bound(t()) :: map()
  def bound(%__MODULE__{data: d}),
    do: %{
      marker: d["marker"],
      app: d["app"],
      base_url: d["base_url"],
      newest_export: d["newest_export"]
    }

  @doc "The journal sequence number (to detect a change since a read)."
  @spec seq(t()) :: non_neg_integer()
  def seq(%__MODULE__{data: d}), do: Map.get(d, "seq", 0)

  # --- events --------------------------------------------------------------------------------

  @doc """
  Binds the record to a database marker and an export's app and base URL.
  A record bound to another marker (the database was recreated) is reset
  first: what it holds describes another database.
  """
  @spec bind(t(), String.t(), String.t() | nil, String.t() | nil) :: t()
  def bind(%__MODULE__{} = w, marker, app, base_url) do
    b = bound(w)

    w =
      if b.marker != marker and not (b.marker == nil and empty?(w)),
        do: record(w, %{"reset" => true}),
        else: w

    if bound(w).marker == marker and bound(w).app == app and bound(w).base_url == base_url,
      do: w,
      else: record(w, %{"bind" => marker, "app" => app, "base_url" => base_url})
  end

  @doc "Records a completed load of an export created at `created_at`."
  @spec loaded(t(), String.t() | nil) :: t()
  def loaded(%__MODULE__{} = w, nil), do: w

  def loaded(%__MODULE__{} = w, created_at) do
    newest = bound(w).newest_export

    if newest == nil or later?(created_at, newest),
      do: record(w, %{"loaded" => created_at}),
      else: w
  end

  @doc "Whether ISO 8601 `a` is later than `b` (false when either does not parse)."
  @spec later?(String.t(), String.t()) :: boolean()
  def later?(a, b) do
    with {:ok, a, _} <- DateTime.from_iso8601(a),
         {:ok, b, _} <- DateTime.from_iso8601(b),
         do: DateTime.compare(a, b) == :gt,
         else: (_ -> false)
  end

  @doc "Records IDs of `type` a successful batch wrote."
  @spec wrote(t(), String.t(), [String.t()]) :: t()
  def wrote(%__MODULE__{} = w, type, ids) do
    new = Enum.reject(ids, &MapSet.member?(records(w, type), &1))
    if new == [], do: w, else: record(w, %{"wrote" => type, "ids" => Enum.sort(new)})
  end

  @doc "Records `{left, right}` rows of a join's list a successful batch wrote."
  @spec wrote_join(t(), String.t(), [{String.t(), String.t()}]) :: t()
  def wrote_join(%__MODULE__{} = w, key, pairs) do
    new = Enum.reject(pairs, &MapSet.member?(pairs(w, key), &1))

    if new == [],
      do: w,
      else: record(w, %{"wrote_join" => key, "pairs" => lists_of(new)})
  end

  @doc "Forgets IDs of `type` (pruned, or found gone)."
  @spec pruned(t(), String.t(), [String.t()]) :: t()
  def pruned(%__MODULE__{} = w, type, ids) do
    gone = Enum.filter(ids, &MapSet.member?(records(w, type), &1))
    if gone == [], do: w, else: record(w, %{"pruned" => type, "ids" => Enum.sort(gone)})
  end

  @doc "Forgets rows of a join's list (pruned, or found gone)."
  @spec pruned_join(t(), String.t(), [{String.t(), String.t()}]) :: t()
  def pruned_join(%__MODULE__{} = w, key, pairs) do
    gone = Enum.filter(pairs, &MapSet.member?(pairs(w, key), &1))

    if gone == [],
      do: w,
      else: record(w, %{"pruned_join" => key, "pairs" => lists_of(gone)})
  end

  defp lists_of(pairs), do: pairs |> Enum.sort() |> Enum.map(&Tuple.to_list/1)

  @doc "Compacts, closes the journal and releases the lock."
  @spec close(t()) :: t()
  def close(%__MODULE__{journal: nil} = w), do: release(w)

  def close(%__MODULE__{journal: io} = w) do
    :file.close(io)
    w = %{w | journal: nil}
    w = if w.events > 0, do: force_compact(w), else: w
    release(w)
  end

  defp release(%__MODULE__{lock: lock} = w) do
    unlock(lock)
    %{w | lock: nil}
  end

  # Strict: an event of another target, or of an unknown shape, raises
  # (the journal replay turns it into an error).
  defp apply_event(d, %{"target" => identity} = e, identity), do: apply_event(d, e)

  defp apply_event(d, %{"wrote" => type, "ids" => ids}) when is_binary(type) do
    true = ids?(ids)

    update_in(
      d,
      ["records"],
      &Map.update(&1, type, MapSet.new(ids), fn s -> Enum.into(ids, s) end)
    )
  end

  defp apply_event(d, %{"pruned" => type, "ids" => ids}) when is_binary(type) do
    true = ids?(ids)

    update_in(
      d,
      ["records"],
      &Map.update(&1, type, MapSet.new(), fn s ->
        Enum.reduce(ids, s, fn id, s -> MapSet.delete(s, id) end)
      end)
    )
  end

  defp apply_event(d, %{"wrote_join" => key, "pairs" => pairs}) when is_binary(key) do
    true = pairs?(pairs)
    pairs = Enum.map(pairs, &List.to_tuple/1)

    update_in(
      d,
      ["joins"],
      &Map.update(&1, key, MapSet.new(pairs), fn s -> Enum.into(pairs, s) end)
    )
  end

  defp apply_event(d, %{"pruned_join" => key, "pairs" => pairs}) when is_binary(key) do
    true = pairs?(pairs)
    pairs = Enum.map(pairs, &List.to_tuple/1)

    update_in(
      d,
      ["joins"],
      &Map.update(&1, key, MapSet.new(), fn s ->
        Enum.reduce(pairs, s, fn p, s -> MapSet.delete(s, p) end)
      end)
    )
  end

  defp apply_event(d, %{"bind" => marker, "app" => app, "base_url" => base})
       when is_binary(marker) do
    true = optional_text?(app) and optional_text?(base)
    Map.merge(d, %{"marker" => marker, "app" => app, "base_url" => base})
  end

  defp apply_event(d, %{"loaded" => at}) when is_binary(at), do: Map.put(d, "newest_export", at)

  defp apply_event(d, %{"reset" => true}),
    do: Map.merge(d, %{"marker" => nil, "records" => %{}, "joins" => %{}, "newest_export" => nil})

  defp record(%__MODULE__{path: nil} = w, event),
    do: %{w | data: apply_event(w.data, event)}

  defp record(%__MODULE__{} = w, event) do
    seq = Map.get(w.data, "seq", 0) + 1
    event = Map.merge(event, %{"seq" => seq, "target" => w.data["target"]})
    :ok = Journal.append(w.journal, event)
    w = %{w | data: w.data |> apply_event(event) |> Map.put("seq", seq), events: w.events + 1}

    if w.events >= w.compact_every do
      :file.close(w.journal)
      w = force_compact(%{w | journal: nil})
      %{w | journal: Journal.open_journal(w.path)}
    else
      w
    end
  end

  defp force_compact(%__MODULE__{} = w) do
    Journal.write_snapshot(w.path, encode(w.data))
    Journal.remove_journal(w.path)
    %{w | events: 0}
  end
end
