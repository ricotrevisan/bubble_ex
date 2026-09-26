defmodule BubbleEx.Verify.Replay.Ledger do
  @moduledoc """
  The seed ledger of one replay run (WTF-358 §3.6, §6.1 rule 2): every
  record the run created on the replay branch, as `symbolic key → Bubble
  ID`, in creation order.

  **Cleanup deletes only ledger records.** The replay client has no delete
  or update that takes a Bubble ID: it takes a ledger and a seed key
  (`BubbleEx.Verify.Replay.Client.delete_seeded/3`,
  `update_seeded/4`). So a wrong constraint, a search that returns the
  owner's own development records, or a forged ID can never reach a delete.

  An entry's `state` is `:created` or `:deleted` (deleted after seeding to
  leave dangling references, or by cleanup). `live/1` lists the entries
  cleanup still has to delete, newest first.

  JSON (`to_json/2`, for the target stack's loader, which inserts the same
  records under the same Bubble IDs): run, app, branch and the entries.
  Bubble IDs are not secrets; the credential scan runs anyway.
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Verify.Replay.{CredentialScan, Target}

  @format "bubble_ex.verify.replay_ledger"

  @type state :: :created | :deleted
  @type entry :: %{key: String.t(), type: String.t(), id: String.t(), state: state()}
  @type t :: %__MODULE__{
          run_id: String.t(),
          app: String.t(),
          branch: String.t(),
          entries: [entry()]
        }

  @enforce_keys [:run_id, :app, :branch]
  defstruct [:run_id, :app, :branch, entries: []]

  @doc "An empty ledger for run `run_id` on `target`."
  @spec new(Target.t(), String.t()) :: t()
  def new(%Target{} = target, run_id) when is_binary(run_id),
    do: %__MODULE__{run_id: run_id, app: target.app, branch: target.branch}

  @doc """
  Records a created record. A key or ID already in the ledger, or an ID
  that is not a Bubble record ID, is `:invalid_input`.
  """
  @spec put(t(), String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def put(%__MODULE__{} = ledger, key, type, id) do
    cond do
      not Target.record_id?(id) ->
        {:error, Error.new(:invalid_input, "Bubble returned an invalid record ID", %{key: key})}

      fetch(ledger, key) != nil ->
        {:error, Error.new(:invalid_input, "seed key is already in the ledger", %{key: key})}

      key_for_id(ledger, id) != nil ->
        {:error, Error.new(:invalid_input, "Bubble ID is already in the ledger", %{key: key})}

      true ->
        entry = %{key: key, type: type, id: id, state: :created}
        {:ok, %{ledger | entries: ledger.entries ++ [entry]}}
    end
  end

  @doc "The entry of `key`, or nil."
  @spec fetch(t(), String.t()) :: entry() | nil
  def fetch(%__MODULE__{entries: entries}, key), do: Enum.find(entries, &(&1.key == key))

  @doc "The Bubble ID of `key`, or nil."
  @spec id(t(), String.t()) :: String.t() | nil
  def id(ledger, key), do: ledger |> fetch(key) |> then(&(&1 && &1.id))

  @doc "The seed key of Bubble ID `id`, or nil (not created by this run)."
  @spec key_for_id(t(), String.t()) :: String.t() | nil
  def key_for_id(%__MODULE__{entries: entries}, id),
    do: Enum.find_value(entries, &(&1.id == id && &1.key))

  @doc "Marks `key` deleted."
  @spec mark_deleted(t(), String.t()) :: t()
  def mark_deleted(%__MODULE__{} = ledger, key) do
    %{
      ledger
      | entries:
          Enum.map(ledger.entries, fn
            %{key: ^key} = e -> %{e | state: :deleted}
            e -> e
          end)
    }
  end

  @doc "Entries still to delete, newest first."
  @spec live(t()) :: [entry()]
  def live(%__MODULE__{entries: entries}),
    do: entries |> Enum.filter(&(&1.state == :created)) |> Enum.reverse()

  @doc "Keys of entries in state `:deleted`."
  @spec deleted_keys(t()) :: [String.t()]
  def deleted_keys(%__MODULE__{entries: entries}),
    do: for(%{state: :deleted, key: k} <- entries, do: k)

  @doc "JSON form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = l) do
    %{
      "format" => @format,
      "schema_version" => 1,
      "run_id" => l.run_id,
      "app" => l.app,
      "branch" => l.branch,
      "entries" =>
        Enum.map(l.entries, fn e ->
          %{"key" => e.key, "type" => e.type, "id" => e.id, "state" => Atom.to_string(e.state)}
        end)
    }
  end

  @doc """
  Canonical JSON text, after the credential scan
  (`BubbleEx.Verify.Replay.CredentialScan`) with the run's `secrets`.
  """
  @spec to_json(t(), [String.t()]) :: {:ok, String.t()} | {:error, Error.t()}
  def to_json(%__MODULE__{} = ledger, secrets) do
    text = ledger |> to_map() |> CanonicalJson.encode()
    with :ok <- CredentialScan.check(text, secrets), do: {:ok, text}
  end
end
