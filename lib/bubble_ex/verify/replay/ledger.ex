defmodule BubbleEx.Verify.Replay.Ledger do
  @moduledoc """
  The seed ledger of one replay run (WTF-358 §3.6, §6.1 rule 2): every
  record the run created, or may have created, on the replay branch, as
  `symbolic key → Bubble ID`, in creation order.

  **Journal.** With a directory (`new/3`, `dir:`), the ledger is also an
  append-only journal, `<dir>/<run id>.jsonl`, written and fsynced
  **before** the call it describes:

    1. `intend/4` records the intent to create `key` (and, for users, the
       run's unique sign-up email) before the create or sign-up is sent
    2. `confirm/3` records the Bubble ID Bubble returned
    3. `mark_deleted/2` records a delete

  If the process dies, `load/1` rebuilds the ledger from the journal and
  `BubbleEx.Verify.Replay.Cleanup.resume/3` deletes what it lists. An
  intent that was never confirmed is an **unconfirmed** entry: the create
  may or may not have happened (a lost response, a 5xx, an odd ID).
  Cleanup looks an unconfirmed user up by its exact per-run email; any
  other unconfirmed entry is reported, never searched for.

  **Cleanup deletes only ledger records.** The replay client has no delete
  or update that takes a Bubble ID: it takes a ledger and a seed key
  (`BubbleEx.Verify.Replay.Client.delete_seeded/3`, `update_seeded/4`).

  Entry states: `:intended` (unconfirmed), `:created`, `:deleted`.
  `live/1` lists the confirmed entries still to delete, newest first.
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Verify.Replay.{CredentialScan, Target}

  @format "bubble_ex.verify.replay_ledger"

  @type state :: :intended | :created | :deleted
  @type entry :: %{
          key: String.t(),
          type: String.t(),
          id: String.t() | nil,
          email: String.t() | nil,
          state: state()
        }
  @type t :: %__MODULE__{
          run_id: String.t(),
          app: String.t(),
          branch: String.t(),
          path: String.t() | nil,
          entries: [entry()]
        }

  @enforce_keys [:run_id, :app, :branch]
  defstruct [:run_id, :app, :branch, :path, entries: []]

  @doc """
  A new ledger for run `run_id` on `target`. With `dir:`, its journal is
  created there (a journal that already exists is an error: run IDs are
  never reused).
  """
  @spec new(Target.t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Target{} = target, run_id, opts \\ []) when is_binary(run_id) do
    ledger = %__MODULE__{run_id: run_id, app: target.app, branch: target.branch}

    case Keyword.get(opts, :dir) do
      nil ->
        {:ok, ledger}

      dir ->
        path = Path.join(dir, run_id <> ".jsonl")

        with :ok <- mkdir(dir),
             :ok <- fresh(path),
             ledger = %{ledger | path: path},
             :ok <-
               append(ledger, %{
                 "event" => "header",
                 "format" => @format,
                 "run_id" => run_id,
                 "app" => target.app,
                 "branch" => target.branch
               }) do
          {:ok, ledger}
        end
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> write_error(reason)
    end
  end

  defp fresh(path) do
    if File.exists?(path),
      do: {:error, Error.new(:invalid_input, "a ledger journal already exists for this run")},
      else: :ok
  end

  @doc "Records the intent to create `key` (journaled before the call)."
  @spec intend(t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, Error.t()}
  def intend(%__MODULE__{} = ledger, key, type, email \\ nil) do
    if fetch(ledger, key) do
      {:error, Error.new(:invalid_input, "seed key is already in the ledger", %{key: key})}
    else
      entry = %{key: key, type: type, id: nil, email: email, state: :intended}
      event = %{"event" => "intent", "key" => key, "type" => type, "email" => email}

      with :ok <- append(ledger, event),
           do: {:ok, %{ledger | entries: ledger.entries ++ [entry]}}
    end
  end

  @doc """
  Records the Bubble ID of an intended `key`. An ID that is not a Bubble
  record ID or is already in the ledger is `:invalid_input` (the entry
  stays unconfirmed).
  """
  @spec confirm(t(), String.t(), term()) :: {:ok, t()} | {:error, Error.t()}
  def confirm(%__MODULE__{} = ledger, key, id) do
    cond do
      not match?(%{state: :intended}, fetch(ledger, key)) ->
        {:error,
         Error.new(:invalid_input, "only an intended entry can be confirmed", %{key: key})}

      not Target.record_id?(id) ->
        {:error, Error.new(:invalid_input, "Bubble returned an invalid record ID", %{key: key})}

      key_for_id(ledger, id) != nil ->
        {:error, Error.new(:invalid_input, "Bubble ID is already in the ledger", %{key: key})}

      true ->
        ledger = update(ledger, key, &%{&1 | id: id, state: :created})

        with :ok <- append(ledger, %{"event" => "created", "key" => key, "id" => id}),
             do: {:ok, ledger}
    end
  end

  @doc "`intend/4` then `confirm/3`."
  @spec put(t(), String.t(), String.t(), term()) :: {:ok, t()} | {:error, Error.t()}
  def put(ledger, key, type, id) do
    with {:ok, ledger} <- intend(ledger, key, type), do: confirm(ledger, key, id)
  end

  @doc "Records that an unconfirmed entry was never created (cleanup found nothing)."
  @spec abandon(t(), String.t()) :: t()
  def abandon(ledger, key) do
    _ = append(ledger, %{"event" => "abandoned", "key" => key})
    %{ledger | entries: Enum.reject(ledger.entries, &(&1.key == key and &1.state == :intended))}
  end

  @doc """
  Marks `key` deleted. The remote delete already happened, so a journal
  write failure does not undo it (a resumed cleanup's delete then gets a
  404, which counts as deleted).
  """
  @spec mark_deleted(t(), String.t()) :: t()
  def mark_deleted(%__MODULE__{} = ledger, key) do
    _ = append(ledger, %{"event" => "deleted", "key" => key})
    update(ledger, key, &%{&1 | state: :deleted})
  end

  defp update(ledger, key, fun) do
    %{
      ledger
      | entries:
          Enum.map(ledger.entries, fn
            %{key: ^key} = e -> fun.(e)
            e -> e
          end)
    }
  end

  @doc "The entry of `key`, or nil."
  @spec fetch(t(), String.t()) :: entry() | nil
  def fetch(%__MODULE__{entries: entries}, key), do: Enum.find(entries, &(&1.key == key))

  @doc "The Bubble ID of `key` (confirmed entries only), or nil."
  @spec id(t(), String.t()) :: String.t() | nil
  def id(ledger, key), do: ledger |> fetch(key) |> then(&(&1 && &1.id))

  @doc "The seed key of Bubble ID `id`, or nil (not created by this run)."
  @spec key_for_id(t(), String.t()) :: String.t() | nil
  def key_for_id(%__MODULE__{entries: entries}, id),
    do: Enum.find_value(entries, &(&1.id != nil and &1.id == id and &1.key))

  @doc "Confirmed entries still to delete, newest first."
  @spec live(t()) :: [entry()]
  def live(%__MODULE__{entries: entries}),
    do: entries |> Enum.filter(&(&1.state == :created)) |> Enum.reverse()

  @doc "Unconfirmed entries (the create may or may not have happened)."
  @spec unconfirmed(t()) :: [entry()]
  def unconfirmed(%__MODULE__{entries: entries}),
    do: Enum.filter(entries, &(&1.state == :intended))

  @doc "Keys of entries in state `:deleted`."
  @spec deleted_keys(t()) :: [String.t()]
  def deleted_keys(%__MODULE__{entries: entries}),
    do: for(%{state: :deleted, key: k} <- entries, do: k)

  # --- journal -------------------------------------------------------------------------

  defp append(%__MODULE__{path: nil}, _event), do: :ok

  defp append(%__MODULE__{path: path}, event) do
    line = CanonicalJson.encode(event) <> "\n"

    case :file.open(String.to_charlist(path), [:append, :raw, :binary]) do
      {:ok, io} ->
        result =
          with :ok <- :file.write(io, line),
               do: :file.sync(io)

        _ = :file.close(io)
        if result == :ok, do: :ok, else: write_error(elem(result, 1))

      {:error, reason} ->
        write_error(reason)
    end
  end

  defp write_error(reason),
    do:
      {:error,
       Error.new(:request_failed, "cannot write the replay ledger journal", %{
         reason: :ledger_write_failed,
         error: reason
       })}

  @doc """
  Rebuilds a ledger from its journal. A torn last line (the process died
  mid-write) is ignored; any other malformed line is an error.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(path) do
    with {:ok, text} <- read(path),
         {:ok, [header | events]} <- decode_lines(text),
         {:ok, ledger} <- header(header, path) do
      {:ok, Enum.reduce(events, ledger, &replay/2)}
    else
      {:ok, []} -> invalid_journal()
      {:error, _} = error -> error
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:error, Error.new(:not_found, "no ledger journal at that path")}
    end
  end

  defp decode_lines(text) do
    # The last piece has no newline: empty, or a torn write (ignored).
    {complete, _torn} = text |> String.split("\n") |> Enum.split(-1)
    decoded = Enum.map(complete, &Jason.decode/1)

    if Enum.all?(decoded, &match?({:ok, %{"event" => _}}, &1)) do
      {:ok, Enum.map(decoded, &elem(&1, 1))}
    else
      invalid_journal()
    end
  end

  defp header(
         %{
           "event" => "header",
           "format" => @format,
           "run_id" => run,
           "app" => app,
           "branch" => b
         },
         path
       )
       when is_binary(run) and is_binary(app) and is_binary(b),
       do: {:ok, %__MODULE__{run_id: run, app: app, branch: b, path: path}}

  defp header(_, _), do: invalid_journal()

  defp invalid_journal, do: {:error, Error.new(:parse_failed, "malformed ledger journal")}

  defp replay(%{"event" => "intent", "key" => key, "type" => type} = e, ledger) do
    entry = %{key: key, type: type, id: nil, email: e["email"], state: :intended}
    %{ledger | entries: ledger.entries ++ [entry]}
  end

  defp replay(%{"event" => "created", "key" => key, "id" => id}, ledger),
    do: update(ledger, key, &%{&1 | id: id, state: :created})

  defp replay(%{"event" => "deleted", "key" => key}, ledger),
    do: update(ledger, key, &%{&1 | state: :deleted})

  defp replay(%{"event" => "abandoned", "key" => key}, ledger),
    do: %{
      ledger
      | entries: Enum.reject(ledger.entries, &(&1.key == key and &1.state == :intended))
    }

  defp replay(_event, ledger), do: ledger

  # --- JSON ----------------------------------------------------------------------------

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
          %{
            "key" => e.key,
            "type" => e.type,
            "id" => e.id,
            "email" => e.email,
            "state" => Atom.to_string(e.state)
          }
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
