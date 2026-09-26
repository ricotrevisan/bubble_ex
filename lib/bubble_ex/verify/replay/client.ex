defmodule BubbleEx.Verify.Replay.Client do
  @moduledoc """
  Data API client of the replay driver, bound to one
  `BubbleEx.Verify.Replay.Target` (a `wtfreplay…` branch). The only
  workflows it calls are the replay kit's own sign-up and login
  (`call_kit/4`); searches are always constrained to known IDs (or, for
  cleanup, one exact per-run email). The one exception is
  `anonymous_probe/3`, the preflight's check of what a logged-out visitor
  can already read from an exposed type: it keeps only field names and a
  count, never a value or an ID.

  Every request goes through `BubbleEx.HTTP.request/5` (public-destination
  checks, bounded bodies, sanitized telemetry) after
  `Target.check_url/2`, never follows redirects, and carries the
  credentials of one `auth`:

    * `:admin` - the target's admin token (seeding, cleanup, the kit)
    * `{:user, token}` - a persona's user token (what the persona sees)
    * `:none` - a logged-out visitor

  **Budgets (WTF-358 §3.8, §6.5).** `:max_calls` (default 2,000) counts
  every wire attempt, retries included; `:max_wall_ms` (default 15 min)
  bounds the run. Past either, calls fail with `:request_failed`
  (`reason: :budget_exhausted`) and the recorder marks what it was doing
  incomplete. Cleanup (`delete_seeded/3`) has a separate allowance, so a
  run that ran out of budget can still remove what it created.

  **Backoff.** 429 and 5xx (and transport failures) are retried with
  exponential backoff (or `Retry-After`), at most `:max_retries` times and
  never past the wall budget. Writes that create something (`create/4`,
  workflow calls) are retried only on 429: a 5xx or a lost response may
  have created a record the ledger would not know about.

  **Ledger-only writes.** Updates and deletes take a
  `BubbleEx.Verify.Replay.Ledger` and a seed key, never a Bubble ID
  (`update_seeded/4`, `delete_seeded/3`).

  Errors carry the status and Bubble's short error code, never a response
  body or a credential.
  """

  alias BubbleEx.{Error, HTTP}
  alias BubbleEx.Verify.Replay.{Kit, Ledger, Names, Target}

  @enforce_keys [:target, :names, :counter]
  defstruct [
    :target,
    :names,
    :counter,
    :deadline,
    max_calls: 2_000,
    cleanup_max_calls: 2_000,
    max_retries: 3,
    retry_base_delay: 500,
    max_retry_delay: 30_000,
    sleep: &Process.sleep/1,
    page_size: 100
  ]

  @type auth :: :admin | :none | {:user, String.t()}
  @type t :: %__MODULE__{}
  @type response :: %{status: pos_integer(), body: term()}

  @transient [429, 500, 502, 503, 504]

  @doc """
  A client for `target`. Options: `:names` (required,
  `BubbleEx.Verify.Replay.Names`), `:max_calls`, `:max_wall_ms`,
  `:cleanup_max_calls`, `:max_retries`, `:retry_base_delay`,
  `:max_retry_delay` (ms), `:page_size`, `:sleep` (a 1-arity function, for
  tests).
  """
  @spec new(Target.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Target{} = target, opts) do
    with {:ok, %Names{} = names} <- fetch_names(opts),
         {:ok, max_calls} <- positive(opts, :max_calls, 2_000),
         {:ok, wall} <- positive(opts, :max_wall_ms, 900_000),
         {:ok, cleanup} <- positive(opts, :cleanup_max_calls, 2_000),
         {:ok, page} <- positive(opts, :page_size, 100) do
      {:ok,
       %__MODULE__{
         target: target,
         names: names,
         counter: :counters.new(2, [:atomics]),
         deadline: System.monotonic_time(:millisecond) + wall,
         max_calls: max_calls,
         cleanup_max_calls: cleanup,
         max_retries: Keyword.get(opts, :max_retries, 3),
         retry_base_delay: Keyword.get(opts, :retry_base_delay, 500),
         max_retry_delay: Keyword.get(opts, :max_retry_delay, 30_000),
         sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
         page_size: min(page, 100)
       }}
    end
  end

  def new(_target, _opts),
    do: {:error, Error.new(:invalid_input, "a replay client needs a Replay.Target")}

  defp fetch_names(opts) do
    case Keyword.get(opts, :names) do
      %Names{} = names -> {:ok, names}
      _ -> {:error, Error.new(:invalid_input, "a replay client needs Replay.Names")}
    end
  end

  defp positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      n -> {:error, Error.new(:invalid_input, "#{key} must be a positive integer", %{value: n})}
    end
  end

  @doc "Wire attempts made so far (retries included), cleanup excluded."
  @spec calls(t()) :: non_neg_integer()
  def calls(%__MODULE__{counter: c}), do: :counters.get(c, 1)

  @doc "Wire attempts made by cleanup."
  @spec cleanup_calls(t()) :: non_neg_integer()
  def cleanup_calls(%__MODULE__{counter: c}), do: :counters.get(c, 2)

  # --- Data API ----------------------------------------------------------------

  @doc """
  Searches `type` as `auth` **among `ids` only** (`_id in […]`, required),
  following the cursor. The owner's own development records are never
  read: an empty `ids` makes no call, and a result outside `ids` (Bubble
  ignored the constraint) stops the search with `:invalid_input`
  (`reason: :constraint_ignored`). `:sort` is `%{key: api_key,
  descending: bool}`. Returns the result objects.
  """
  @spec search(t(), String.t(), auth(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def search(%__MODULE__{} = c, type, auth, opts) do
    case Keyword.fetch(opts, :ids) do
      {:ok, []} ->
        {:ok, []}

      {:ok, ids} when is_list(ids) ->
        constraint = %{"key" => "_id", "constraint_type" => "in", "value" => ids}
        allowed = MapSet.new(ids)
        constrained(c, type, auth, constraint, &MapSet.member?(allowed, &1["_id"]), opts)

      _ ->
        {:error, Error.new(:invalid_input, "a replay search must be constrained to ledger IDs")}
    end
  end

  @probe_id "0x0"

  @doc """
  Checks that `type` is exposed on the Data API without reading any record:
  a search as admin constrained to an ID that cannot exist. `{:ok,
  :exposed}`, or the error.
  """
  @spec probe(t(), String.t()) :: {:ok, :exposed} | {:error, Error.t()}
  def probe(%__MODULE__{} = c, type) do
    with {:ok, []} <- search(c, type, :admin, ids: [@probe_id]), do: {:ok, :exposed}
  end

  @anonymous_fields ["_id", "Created Date", "Modified Date"]

  @doc """
  What an anonymous caller (no token) gets from `type`'s Data API: one
  unconstrained page of at most `limit` records (default 25). Enabling the
  Data API on a branch exposes the development database, which the branch
  shares with `test`, to anyone, as far as the privacy rules allow; this
  measures that. Values and IDs are dropped as soon as the answer is
  decoded: the result holds only the count of records answered, the
  `remaining` count and the sorted names of the fields beyond `_id`,
  `Created Date` and `Modified Date` (`extra_fields`, empty when only
  those came back).

  `{:ok, %{status: :denied, http_status: s}}` when Bubble refused the
  anonymous search (401, 403, 404).
  """
  @spec anonymous_probe(t(), String.t(), pos_integer()) :: {:ok, map()} | {:error, Error.t()}
  def anonymous_probe(%__MODULE__{} = c, type, limit \\ 25)
      when is_integer(limit) and limit > 0 and limit <= 100 do
    with {:ok, path} <- Names.type_path(c.names, type),
         {:ok, url} <- Target.data_url(c.target, path) do
      query = URI.encode_query([{"cursor", "0"}, {"limit", Integer.to_string(limit)}])

      case request(c, :get, url <> "?" <> query, nil, :none, :read) do
        {:ok, %{status: 200, body: %{"response" => %{"results" => results} = r}}}
        when is_list(results) ->
          {:ok, anonymous_answer(results, r["remaining"])}

        {:ok, %{status: status}} when status in [401, 403, 404] ->
          {:ok, %{status: :denied, http_status: status}}

        other ->
          unexpected(other, "anonymous Data API probe")
      end
    end
  end

  # Only names and counts leave this function: values and IDs are dropped here.
  defp anonymous_answer(results, remaining) do
    fields =
      results
      |> Enum.flat_map(&record_keys/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @anonymous_fields))
      |> Enum.sort()

    %{
      status: :answered,
      records: length(results),
      remaining: if(is_integer(remaining), do: remaining, else: nil),
      extra_fields: fields
    }
  end

  defp record_keys(record) when is_map(record), do: Map.keys(record)
  defp record_keys(_), do: ["(not an object)"]

  @doc "Field names an anonymous caller may see on an exposed type."
  @spec anonymous_fields() :: [String.t()]
  def anonymous_fields, do: @anonymous_fields

  @doc """
  Finds users (as admin) whose `email` is exactly `email`: for cleanup of
  an unconfirmed sign-up, whose per-run email is unique. A result with
  another email stops the search (`:constraint_ignored`).
  """
  @spec find_user_by_email(t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def find_user_by_email(%__MODULE__{} = c, email) when is_binary(email) do
    with {:ok, key} <- Names.field_key(c.names, "user", "email") do
      constraint = %{"key" => key, "constraint_type" => "equals", "value" => email}
      constrained(c, "user", :admin, constraint, &(&1[key] == email), mode: :cleanup)
    end
  end

  defp constrained(c, type, auth, constraint, allowed?, opts) do
    with {:ok, path} <- Names.type_path(c.names, type),
         {:ok, url} <- Target.data_url(c.target, path),
         {:ok, constraints} <- encode([constraint]) do
      sort =
        case Keyword.get(opts, :sort) do
          nil -> []
          %{key: key, descending: desc} -> [{"sort_field", key}, {"descending", to_string(desc)}]
        end

      query = [{"constraints", constraints} | sort]
      page(c, url, {query, Keyword.get(opts, :mode, :read)}, auth, allowed?, 0, [])
    end
  end

  defp page(c, url, {query, mode} = q, auth, allowed?, cursor, acc) do
    params = query ++ [{"cursor", Integer.to_string(cursor)}, {"limit", "#{c.page_size}"}]

    case request(c, :get, url <> "?" <> URI.encode_query(params), nil, auth, mode) do
      {:ok, %{status: 200, body: %{"response" => %{"results" => results} = r}}}
      when is_list(results) ->
        next(c, {url, q, auth, allowed?}, cursor + length(results), acc, results, r["remaining"])

      other ->
        unexpected(other, "Data API search")
    end
  end

  defp next(c, {url, q, auth, allowed?}, cursor, acc, results, remaining) do
    cond do
      not Enum.all?(results, &(is_map(&1) and allowed?.(&1))) ->
        {:error,
         Error.new(:invalid_input, "Bubble returned records outside the search constraint", %{
           reason: :constraint_ignored
         })}

      is_integer(remaining) and remaining > 0 and results != [] ->
        page(c, url, q, auth, allowed?, cursor, acc ++ results)

      true ->
        {:ok, acc ++ results}
    end
  end

  @doc """
  Gets one record by Bubble ID as `auth`: `{:ok, {:found, fields}}` or
  `{:ok, :not_found}` (404: missing, or hidden from `auth`).
  """
  @spec get(t(), String.t(), String.t(), auth()) ::
          {:ok, {:found, map()} | :not_found} | {:error, Error.t()}
  def get(%__MODULE__{} = c, type, id, auth) do
    with {:ok, path} <- Names.type_path(c.names, type),
         {:ok, url} <- Target.data_url(c.target, path, id) do
      case request(c, :get, url, nil, auth, :read) do
        {:ok, %{status: 200, body: %{"response" => fields}}} when is_map(fields) ->
          {:ok, {:found, fields}}

        {:ok, %{status: 404}} ->
          {:ok, :not_found}

        other ->
          unexpected(other, "Data API get")
      end
    end
  end

  @doc "Creates a record of `type` with Data API `body` as `auth`; returns its Bubble ID."
  @spec create(t(), String.t(), map(), auth()) :: {:ok, String.t()} | {:error, Error.t()}
  def create(%__MODULE__{} = c, type, body, auth) when is_map(body) do
    with {:ok, path} <- Names.type_path(c.names, type),
         {:ok, url} <- Target.data_url(c.target, path) do
      case request(c, :post, url, body, auth, :write) do
        {:ok, %{status: s, body: %{"id" => id}}} when s in 200..201 and is_binary(id) ->
          {:ok, id}

        other ->
          unexpected(other, "Data API create")
      end
    end
  end

  @doc "Updates the ledger record `key` (never another) with Data API `body`, as admin."
  @spec update_seeded(t(), Ledger.t(), String.t(), map()) :: :ok | {:error, Error.t()}
  def update_seeded(%__MODULE__{} = c, %Ledger{} = ledger, key, body) when is_map(body) do
    with {:ok, entry} <- live_entry(ledger, key),
         {:ok, url} <- entry_url(c, entry) do
      case request(c, :patch, url, body, :admin, :write) do
        {:ok, %{status: s}} when s in 200..204 -> :ok
        other -> unexpected(other, "Data API update")
      end
    end
  end

  @doc """
  Deletes the ledger record `key` (never another), as admin, from the
  cleanup allowance; returns the ledger with it marked deleted. A 404
  (already gone) counts as deleted.
  """
  @spec delete_seeded(t(), Ledger.t(), String.t()) :: {:ok, Ledger.t()} | {:error, Error.t()}
  def delete_seeded(%__MODULE__{} = c, %Ledger{} = ledger, key) do
    with {:ok, entry} <- live_entry(ledger, key),
         {:ok, url} <- entry_url(c, entry) do
      case request(c, :delete, url, nil, :admin, :cleanup) do
        {:ok, %{status: s}} when s in 200..204 or s == 404 ->
          {:ok, Ledger.mark_deleted(ledger, key)}

        other ->
          unexpected(other, "Data API delete")
      end
    end
  end

  defp live_entry(ledger, key) do
    case Ledger.fetch(ledger, key) do
      %{state: :created} = entry ->
        {:ok, entry}

      _ ->
        {:error,
         Error.new(
           :invalid_input,
           "only records this run created (and has not deleted) can change",
           %{key: key}
         )}
    end
  end

  defp entry_url(c, entry) do
    with {:ok, path} <- Names.type_path(c.names, entry.type),
         do: Target.data_url(c.target, path, entry.id)
  end

  # --- Workflow API --------------------------------------------------------------

  @doc """
  Calls one of the replay kit's own workflows (`:signup` or `:login`, by
  the names in `kit`) as admin. Returns the status and decoded body of any
  HTTP answer. No other API workflow can be called: an app's own
  workflows are not replay-safe until V7 classifies them (WTF-358 §6.4).
  """
  @spec call_kit(t(), Kit.t(), :signup | :login, map()) ::
          {:ok, response()} | {:error, Error.t()}
  def call_kit(%__MODULE__{} = c, %Kit{} = kit, which, params)
      when which in [:signup, :login] and is_map(params) do
    with {:ok, url} <- Target.workflow_url(c.target, Map.fetch!(kit, which)) do
      request(c, :post, url, params, :admin, :write)
    end
  end

  @doc "Reads the API metadata (`/meta`) as admin."
  @spec meta(t()) :: {:ok, response()} | {:error, Error.t()}
  def meta(%__MODULE__{} = c), do: request(c, :get, Target.meta_url(c.target), nil, :admin, :read)

  @doc "Every secret the client holds (for the credential scan)."
  @spec secrets(t()) :: [String.t()]
  def secrets(%__MODULE__{target: t}), do: [t.admin_token]

  # --- transport ----------------------------------------------------------------

  defp request(c, method, url, body, auth, mode), do: attempt(c, method, url, body, auth, mode, 0)

  defp attempt(c, method, url, body, auth, mode, n) do
    with :ok <- Target.check_url(c.target, url),
         {:ok, encoded} <- encode(body),
         :ok <- budget(c, mode) do
      :counters.add(c.counter, slot(mode), 1)
      result = send_once(c, method, url, encoded, auth, mode)

      case retry_delay(c, result, mode, n) do
        nil ->
          finish(result)

        delay ->
          c.sleep.(delay)
          attempt(c, method, url, body, auth, mode, n + 1)
      end
    end
  end

  defp encode(nil), do: {:ok, nil}

  defp encode(body) do
    case Jason.encode(body) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:error, Error.new(:invalid_input, "request body is not JSON-encodable")}
    end
  end

  defp slot(:cleanup), do: 2
  defp slot(_), do: 1

  defp budget(c, :cleanup) do
    if cleanup_calls(c) < c.cleanup_max_calls, do: :ok, else: exhausted(:cleanup_calls)
  end

  defp budget(c, _mode) do
    cond do
      calls(c) >= c.max_calls -> exhausted(:calls)
      System.monotonic_time(:millisecond) >= c.deadline -> exhausted(:wall_time)
      true -> :ok
    end
  end

  defp exhausted(what),
    do:
      {:error,
       Error.new(:request_failed, "replay budget exhausted", %{
         reason: :budget_exhausted,
         budget: what
       })}

  defp send_once(c, method, url, body, auth, mode) do
    token = token(c, auth)

    headers =
      [{"accept", "application/json"}] ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: []) ++
        if(body, do: [{"content-type", "application/json"}], else: [])

    now = System.monotonic_time(:millisecond)
    deadline = if mode == :cleanup, do: now + 60_000, else: min(c.deadline, now + 60_000)

    HTTP.request(method, url, body, headers,
      follow_redirect: false,
      redact_values: Enum.reject([c.target.admin_token, token], &is_nil/1),
      timeout: 10_000,
      recv_timeout: 30_000,
      max_body_length: 20_000_000,
      bounded_body: true,
      deadline: deadline
    )
  end

  defp token(c, :admin), do: c.target.admin_token
  defp token(_c, {:user, token}) when is_binary(token), do: token
  defp token(_c, :none), do: nil

  defp retryable?({:ok, %HTTP.Response{status_code: 429}}, _mode), do: true

  defp retryable?({:ok, %HTTP.Response{status_code: s}}, mode),
    do: s in @transient and mode != :write

  defp retryable?({:error, _}, mode), do: mode != :write

  defp retry_delay(c, result, mode, n) do
    delay = min(backoff(c, result, n), c.max_retry_delay)

    cond do
      not retryable?(result, mode) or n >= c.max_retries -> nil
      mode != :cleanup and System.monotonic_time(:millisecond) + delay >= c.deadline -> nil
      true -> delay
    end
  end

  defp backoff(c, {:ok, %HTTP.Response{headers: headers}}, n) do
    case retry_after(headers) do
      nil -> exponential(c, n)
      ms -> ms
    end
  end

  defp backoff(c, _result, n), do: exponential(c, n)

  defp exponential(c, n), do: c.retry_base_delay * Integer.pow(2, n)

  defp retry_after(headers) do
    Enum.find_value(headers, fn {k, v} ->
      with "retry-after" <- String.downcase(k),
           {seconds, ""} when seconds >= 0 and seconds < 3600 <- Integer.parse(to_string(v)) do
        seconds * 1000
      else
        _ -> nil
      end
    end)
  end

  defp finish({:ok, %HTTP.Response{status_code: status}}) when status in 300..399,
    do:
      {:error,
       Error.new(:request_failed, "the replay branch redirected; redirects are not followed", %{
         status: status,
         reason: :redirect_refused
       })}

  defp finish({:ok, %HTTP.Response{status_code: status, body: body}}) do
    text = IO.iodata_to_binary(body)

    decoded =
      case text do
        "" ->
          nil

        _ ->
          case Jason.decode(text) do
            {:ok, term} -> term
            {:error, _} -> :invalid_json
          end
      end

    {:ok, %{status: status, body: decoded}}
  end

  defp finish({:error, %HTTP.Error{reason: reason}}),
    do:
      {:error,
       Error.new(:request_failed, "replay request failed", %{reason: safe_reason(reason)})}

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_), do: :transport_failure

  defp unexpected({:error, %Error{}} = error, _what), do: error

  defp unexpected({:ok, %{status: status, body: body}}, what) do
    kind =
      case status do
        401 -> :unauthorized
        403 -> :forbidden
        404 -> :not_found
        _ -> :http_error
      end

    {:error,
     Error.new(kind, "#{what}: unexpected answer", %{status: status, bubble: bubble_code(body)})}
  end

  # Bubble error bodies carry a short code (`MISSING_DATA`, `NOT_FOUND`);
  # keep only that, never a message or the body.
  defp bubble_code(%{"body" => %{"status" => code}}), do: code(code)
  defp bubble_code(%{"status" => code}), do: code(code)
  defp bubble_code(_), do: nil

  defp code(code) when is_binary(code) do
    if code =~ ~r/\A[A-Z_]{1,40}\z/, do: code, else: nil
  end

  defp code(_), do: nil
end
