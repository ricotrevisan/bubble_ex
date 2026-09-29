defmodule BubbleEx.Load.Written do
  @moduledoc """
  What the loader has written into a target, across its runs (WTF-414):
  the Bubble IDs of the records it upserted per data type, and the
  `[left ID, right ID]` rows whose membership column it set per list of a
  join table (keyed `<join ID>/<type>/<field>`). Pruning
  (`BubbleEx.Load.run/4` with `prune: true`) deletes only what this
  record holds, so a row created in the app after go-live, which the
  loader never wrote, is never deleted.

  It lives in the ledger directory, `written/<SHA-256 of the target's
  identity>.json` with its journal (see `BubbleEx.Load.Journal`), keyed by
  the database alone (a new export, plan or storage adds to the same
  record). An ID is recorded after the batch that wrote it succeeded, and
  forgotten after the batch that pruned it succeeded: a crash between a
  write and its record leaves a row the record does not hold (never
  pruned; the resumed batch records it), and one between a prune and its
  record an ID whose row is gone (forgotten at the next prune). So the
  record never holds an ID the loader did not write.

      {"format": "bubble_ex.load_written", "version": 1,
       "target": "<identity>", "seq": <the last event it covers>,
       "records": {"task": ["1700000000000x1", ...]},
       "joins": {"<join ID>/<type>/<field>": [["<left ID>", "<right ID>"], ...]}}

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
  defstruct [:path, :data, :journal, events: 0, compact_every: @compact_every]

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          data: map(),
          journal: term(),
          events: non_neg_integer(),
          compact_every: pos_integer()
        }

  @doc "The record's path for a ledger directory and a target identity."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(dir, identity),
    do: Path.join([dir, "written", Export.sha256_hex(identity) <> ".json"])

  @doc """
  Reads the record of `identity` in `dir` without writing anything (a dry
  run); an empty record when there is none. `dir` nil: an empty record.
  """
  @spec read(Path.t() | nil, String.t()) :: {:ok, t()} | {:error, Error.t()}
  def read(nil, identity), do: {:ok, %__MODULE__{data: fresh(identity)}}

  def read(dir, identity) do
    path = path(dir, identity)

    with {:ok, data} <- read_snapshot(path, identity) do
      {data, _} = Journal.replay(path, data, &apply_event/2)
      {:ok, %__MODULE__{data: data}}
    end
  end

  @doc """
  Opens (or starts) the record of `identity` in `dir`, to record writes.
  `dir` nil: an in-memory record (nothing persists). Options:
  `:compact_every`.
  """
  @spec open(Path.t() | nil, String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(dir, identity, opts \\ [])
  def open(nil, identity, _opts), do: read(nil, identity)

  def open(dir, identity, opts) do
    path = path(dir, identity)
    Journal.ensure_dir(dir)
    Journal.ensure_dir(Path.dirname(path))

    with {:ok, data} <- read_snapshot(path, identity) do
      {data, events} = Journal.replay(path, data, &apply_event/2)

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

  defp read_snapshot(path, identity) do
    case File.read(path) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"format" => @format, "version" => @version, "target" => ^identity} = data} ->
            {:ok, decode(data)}

          _ ->
            {:error, Error.new(:invalid_input, "the load's written record is unreadable")}
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
      "records" => %{},
      "joins" => %{}
    }
  end

  # In memory the IDs are sets; on disk sorted lists.
  defp decode(data) do
    data
    |> Map.update("records", %{}, &Map.new(&1, fn {t, ids} -> {t, MapSet.new(ids)} end))
    |> Map.update(
      "joins",
      %{},
      &Map.new(&1, fn {k, pairs} -> {k, MapSet.new(pairs, fn [l, r] -> {l, r} end)} end)
    )
  end

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
      else:
        record(w, %{
          "wrote_join" => key,
          "pairs" => new |> Enum.sort() |> Enum.map(&Tuple.to_list/1)
        })
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
      else:
        record(w, %{
          "pruned_join" => key,
          "pairs" => gone |> Enum.sort() |> Enum.map(&Tuple.to_list/1)
        })
  end

  @doc "Compacts and closes the journal."
  @spec close(t()) :: t()
  def close(%__MODULE__{journal: nil} = w), do: w

  def close(%__MODULE__{journal: io} = w) do
    :file.close(io)
    w = %{w | journal: nil}
    if w.events > 0, do: force_compact(w), else: w
  end

  # --- events ---------------------------------------------------------------------------

  defp apply_event(d, %{"wrote" => type, "ids" => ids}),
    do:
      update_in(
        d,
        ["records"],
        &Map.update(&1, type, MapSet.new(ids), fn s -> Enum.into(ids, s) end)
      )

  defp apply_event(d, %{"pruned" => type, "ids" => ids}),
    do:
      update_in(
        d,
        ["records"],
        &Map.update(&1, type, MapSet.new(), fn s ->
          Enum.reduce(ids, s, fn id, s -> MapSet.delete(s, id) end)
        end)
      )

  defp apply_event(d, %{"wrote_join" => key, "pairs" => pairs}) do
    pairs = Enum.map(pairs, fn [l, r] -> {l, r} end)

    update_in(
      d,
      ["joins"],
      &Map.update(&1, key, MapSet.new(pairs), fn s -> Enum.into(pairs, s) end)
    )
  end

  defp apply_event(d, %{"pruned_join" => key, "pairs" => pairs}) do
    pairs = Enum.map(pairs, fn [l, r] -> {l, r} end)

    update_in(
      d,
      ["joins"],
      &Map.update(&1, key, MapSet.new(), fn s ->
        Enum.reduce(pairs, s, fn p, s -> MapSet.delete(s, p) end)
      end)
    )
  end

  defp apply_event(d, _unknown), do: d

  defp record(%__MODULE__{path: nil} = w, event), do: %{w | data: apply_event(w.data, event)}

  defp record(%__MODULE__{} = w, event) do
    seq = Map.get(w.data, "seq", 0) + 1
    event = Map.put(event, "seq", seq)
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
