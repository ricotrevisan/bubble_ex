defmodule BubbleEx.Load.Ledger do
  @moduledoc """
  The loader's checkpoint: what one run (an export, a plan and a target)
  has written, so an interrupted run resumes where it stopped. One JSON
  file per run, `<ledger_dir>/<run key>.json`, rewritten atomically
  (`0600`) after every batch and file.

      {"format": "bubble_ex.load_ledger", "version": 1, "run": "<run key>",
       "export_sha256": "…", "plan_sha256": "…", "target": "<target identity>",
       "status": "running" | "complete",
       "files": {"<url>": "<storage reference>"},
       "types": {"task": {"rows_done": 1500, "complete": false,
                          "inserted": 1400, "updated": 100, "unchanged": 0}}}

  The run key is the SHA-256 of the export's identity, the plan's and the
  target's, so a new export (a delta sync), another plan or another target
  starts a new ledger. The loader's writes are idempotent upserts, so a
  batch written just before a crash and replayed on resume changes
  nothing: the ledger is an optimization and a record, not what makes a
  rerun safe.

  A ledger holds no stored value and no credential: counts, Bubble file
  URLs and storage references only.
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Load.Export

  @format "bubble_ex.load_ledger"
  @version 1

  @enforce_keys [:path, :data]
  defstruct [:path, :data, resumed: %{}]

  # `resumed` (not persisted): rows this process skipped per type because
  # the ledger had them.
  @type t :: %__MODULE__{
          path: Path.t() | nil,
          data: map(),
          resumed: %{String.t() => non_neg_integer()}
        }

  @doc "The run key of an export, plan and target identity."
  @spec run_key(String.t(), String.t(), String.t()) :: String.t()
  def run_key(export_sha256, plan_sha256, target),
    do: Export.sha256_hex(Enum.join([export_sha256, plan_sha256, target], "\n"))

  @doc """
  Opens (or starts) the ledger of a run in `dir`. With `dir` nil the ledger
  lives in memory only (a dry run, or a caller that does not resume).
  """
  @spec open(Path.t() | nil, map()) :: {:ok, t()} | {:error, Error.t()}
  def open(nil, ids), do: {:ok, %__MODULE__{path: nil, data: fresh(ids)}}

  def open(dir, ids) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    key = run_key(ids.export_sha256, ids.plan_sha256, ids.target)
    path = Path.join(dir, key <> ".json")

    case File.read(path) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"format" => @format, "version" => @version, "run" => ^key} = data} ->
            {:ok, %__MODULE__{path: path, data: data}}

          _ ->
            {:error, Error.new(:invalid_input, "the load ledger is unreadable", %{run: key})}
        end

      {:error, :enoent} ->
        ledger = %__MODULE__{path: path, data: fresh(ids)}
        save(ledger)
        {:ok, ledger}

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
  def file_copied(%__MODULE__{} = l, url, ref),
    do: save(%{l | data: put_in(l.data, ["files", url], ref)})

  @doc "Records a written batch of `type`: rows done so far and the batch's counts."
  @spec batch(t(), String.t(), non_neg_integer(), map()) :: t()
  def batch(%__MODULE__{} = l, type, rows_done, counts) do
    entry =
      l.data["types"]
      |> Map.get(type, %{"inserted" => 0, "updated" => 0, "unchanged" => 0, "complete" => false})
      |> Map.put("rows_done", rows_done)
      |> Map.update("inserted", counts.inserted, &(&1 + counts.inserted))
      |> Map.update("updated", counts.updated, &(&1 + counts.updated))
      |> Map.update("unchanged", counts.unchanged, &(&1 + counts.unchanged))

    save(%{l | data: put_in(l.data, ["types", type], entry)})
  end

  @doc "Marks `type` complete."
  @spec type_complete(t(), String.t(), non_neg_integer()) :: t()
  def type_complete(%__MODULE__{} = l, type, rows) do
    entry =
      l.data["types"]
      |> Map.get(type, %{"inserted" => 0, "updated" => 0, "unchanged" => 0})
      |> Map.merge(%{"rows_done" => rows, "complete" => true})

    save(%{l | data: put_in(l.data, ["types", type], entry)})
  end

  @doc "Starts a finished run over: forgets its types and files."
  @spec restart(t()) :: t()
  def restart(%__MODULE__{} = l),
    do:
      save(%{
        l
        | data: Map.merge(l.data, %{"status" => "running", "types" => %{}, "files" => %{}})
      })

  @doc "Counts rows of `type` skipped because the ledger had them."
  @spec resumed(t(), String.t(), non_neg_integer()) :: t()
  def resumed(%__MODULE__{} = l, _type, 0), do: l

  def resumed(%__MODULE__{} = l, type, n),
    do: %{l | resumed: Map.update(l.resumed, type, n, &(&1 + n))}

  @doc "Marks the run complete."
  @spec complete(t()) :: t()
  def complete(%__MODULE__{} = l), do: save(%{l | data: Map.put(l.data, "status", "complete")})

  defp save(%__MODULE__{path: nil} = l), do: l

  defp save(%__MODULE__{path: path, data: data} = l) do
    Export.write_private!(path, CanonicalJson.encode(data))
    l
  end
end
