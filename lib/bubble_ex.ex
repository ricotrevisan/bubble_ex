defmodule BubbleEx do
  @moduledoc """
  BubbleEx is a library for fetching and parsing information from Bubble.io.
  """

  alias BubbleEx.{Apps, Contributors, Logs, Plugins, Secrets, Server}

  @doc """
  Fetches information about a Bubble.io app.

  ## Options

    * `:include_payload` - When true, includes the full app payload in the result. Defaults to `false`.
    * `:include_db_diagram` - When true, includes the database diagram in the result. Defaults to `false`.
    * `:try_test` - When true, attempts to fetch the test version if the live version is not accessible. Defaults to `true`.
    * `:username` - Username for authentication, if required.
    * `:password` - Password for authentication, if required.

  ## Examples

      {:ok, app_attrs} = BubbleEx.fetch_app("app_id")
      {:ok, app_attrs_with_payload} = BubbleEx.fetch_app("app_id", include_payload: true)
      {:error, reason} = BubbleEx.fetch_app("invalid_app_id")

  """
  @spec fetch_app(String.t(), [Apps.fetch_option()]) :: {:ok, Apps.app_attrs()} | {:error, any()}
  def fetch_app(app_id, opts \\ []) do
    Apps.fetch_app(app_id, opts)
  end

  @doc "Fetches information about Bubble.io plugins."

  def fetch_plugin(plugin_id) do
    Plugins.fetch_plugin(plugin_id)
  end

  @doc "Fetches information about contributors."
  def fetch_contributor(contributor_id) do
    Contributors.fetch_contributor(contributor_id)
  end

  @doc """
  Fetches logs from a Bubble.io application.

  ## Options

    * `:cookie` - **Required**. Bubble session cookie for authentication
    * `:after` - Start timestamp in Unix milliseconds. Defaults to 1 hour ago
    * `:before` - End timestamp in Unix milliseconds. Defaults to current time
    * `:tags` - Map of tag filters. Defaults to common log message types
    * `:app_version` - App version to query ("live", "test", "development"). Defaults to "live"
    * `:ascending` - Sort order. Defaults to true
    * `:timeout` - Request timeout in milliseconds. Defaults to 30000
    * `:is_state_ar` - Internal Bubble parameter. Defaults to false

  ## Examples

      # Basic usage with required cookie
      {:ok, logs} = BubbleEx.fetch_logs("my-app", cookie: "bubble_session=...")

      # Custom time range (last 30 minutes)
      now = System.system_time(:millisecond)
      thirty_minutes_ago = now - (30 * 60 * 1000)
      {:ok, logs} = BubbleEx.fetch_logs("my-app",
        cookie: "bubble_session=...",
        after: thirty_minutes_ago,
        before: now
      )

      # Only error messages
      {:ok, errors} = BubbleEx.fetch_logs("my-app",
        cookie: "bubble_session=...",
        tags: BubbleEx.Logs.preset_filter(:errors, "my-app")
      )

  """
  @spec fetch_logs(String.t(), [Logs.fetch_logs_option()]) ::
          {:ok, Logs.logs_response()} | {:error, term()}
  def fetch_logs(app_id, opts \\ []) do
    Logs.fetch_logs(app_id, opts)
  end

  @doc """
  Scans a payload for secrets.

  Dispatches the map to the configured `BubbleEx.Secrets` adapter (Trufflehog by
  default). The payload must contain a string `"_id"` field.

  ## Parameters

    * `payload` - A map containing the payload to scan for secrets

  ## Returns

    * `{:ok, list()}` - On success, a list of findings
    * `{:error, %BubbleEx.Error{}}` - On failure (e.g. `:cli_missing`, `:cli_failed`)

  ## Examples

      payload = %{"_id" => "example_123", "type" => "git"}
      BubbleEx.scan_payload_for_secrets(payload)
      #=> {:ok, []}
  """
  @spec scan_payload_for_secrets(map()) :: {:ok, list()} | {:error, BubbleEx.Error.t()}
  def scan_payload_for_secrets(payload) when is_map(payload) do
    Secrets.scan(payload)
  end

  @doc """
  Starts an asynchronous scan for secrets in the given payload.

  This function uses the BubbleEx.Server to run Trufflehog scans asynchronously.
  The calling process will receive progress messages during the scan.

  ## Parameters

    * `payload` - A map containing the payload to scan. Must include an "_id" field.

  ## Returns

    * `{:ok, reference()}` - Success with a unique reference for the scan
    * `{:error, term()}` - Error starting the scan

  ## Examples

      payload = %{"_id" => "app_123", "data" => "content to scan"}
      {:ok, ref} = BubbleEx.start_scan_for_secrets(payload)

      # The calling process will receive messages:
      receive do
        {:scan_started, ^ref} -> :scan_started
        {:scan_completed, ^ref, scan_results} -> scan_results
      end

  """
  @spec start_scan_for_secrets(map()) :: {:ok, reference()} | {:error, term()}
  def start_scan_for_secrets(payload) when is_map(payload) do
    Server.start_scan(payload)
  end

  @doc """
  Gets the status of an asynchronous scan.

  ## Parameters

    * `ref` - The reference returned by `start_scan_for_secrets/1`

  ## Returns

    * `{:ok, status_info}` - Where status_info contains status, start_time, and payload_id
    * `{:error, :not_found}` - If the scan reference is not found

  ## Examples

      {:ok, status_info} = BubbleEx.scan_status(ref)

  """
  @spec scan_status(reference()) :: {:ok, map()} | {:error, :not_found}
  def scan_status(ref) when is_reference(ref) do
    Server.scan_status(ref)
  end

  @doc """
  Cancels a running asynchronous scan.

  ## Parameters

    * `ref` - The reference returned by `start_scan_for_secrets/1`

  ## Returns

    * `:ok` - Scan was cancelled or already completed
    * `{:error, :not_found}` - If the scan reference is not found

  ## Examples

      :ok = BubbleEx.cancel_scan(ref)

  """
  @spec cancel_scan(reference()) :: :ok | {:error, :not_found}
  def cancel_scan(ref) when is_reference(ref) do
    Server.cancel_scan(ref)
  end
end
