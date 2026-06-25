defmodule BubbleEx.Logs do
  @moduledoc """
  Interface for querying logs from Bubble.io applications.

  This module provides functionality to fetch application logs from Bubble's jetstream logs API,
  allowing developers to programmatically retrieve logs for monitoring, debugging, and analytics.

  ## Authentication

  All log queries require authentication via a Bubble session cookie. This cookie can be obtained
  by logging into your Bubble account and extracting the session cookie from your browser.

  ## Examples

      # Fetch logs for the last hour
      {:ok, logs} = BubbleEx.Logs.fetch_logs("my-app",
        cookie: "bubble_session=abc123...",
        after: System.system_time(:millisecond) - 3_600_000
      )

      # Fetch only error logs
      {:ok, error_logs} = BubbleEx.Logs.fetch_logs("my-app",
        cookie: "bubble_session=abc123...",
        tags: %{message: ["error occurred during workflow execution", "failed because of error"]}
      )

      # Fetch logs from test version
      {:ok, test_logs} = BubbleEx.Logs.fetch_logs("my-app",
        cookie: "bubble_session=abc123...",
        app_version: "test"
      )

  ## Security

  Never log or expose session cookies in your application logs. Store them securely as
  environment variables or in secure configuration.
  """

  require Logger
  alias BubbleEx.{Config, Error, HTTP}
  alias BubbleEx.HTTP.Response

  @type fetch_logs_option ::
          {:cookie, String.t()}
          | {:after, integer()}
          | {:before, integer()}
          | {:tags, map()}
          | {:app_version, String.t()}
          | {:ascending, boolean()}
          | {:timeout, integer()}
          | {:is_state_ar, boolean()}

  @type log_entry :: %{
          String.t() => any()
        }

  @type logs_response :: %{
          logs: [log_entry()],
          total: integer() | nil,
          has_more: boolean() | nil
        }

  @default_message_tags [
    "running event",
    "event condition passed",
    "event condition failed, terminating",
    "running action",
    "action condition failed",
    "action completed",
    "event completed",
    "error occurred during workflow execution",
    "failed because of error",
    "server_db.modify",
    "plugin action console output",
    "plugin action console error",
    "scheduled task to run",
    "scheduled task completed",
    "http_request",
    "http_request response",
    "received request for API workflow",
    "Sending email failed"
  ]

  @doc """
  Fetches logs from a Bubble.io application.

  ## Parameters

    * `app_id` - The Bubble app ID or app name
    * `opts` - Keyword list of options

  ## Options

    * `:cookie` - **Required**. Bubble session cookie for authentication
    * `:after` - Start timestamp in Unix milliseconds. Defaults to 1 hour ago
    * `:before` - End timestamp in Unix milliseconds. Defaults to current time
    * `:tags` - Map of tag filters. Defaults to common log message types
    * `:app_version` - App version to query ("live", "test", "development"). Defaults to "live"
    * `:ascending` - Sort order. Defaults to true
    * `:timeout` - Request timeout in milliseconds. Defaults to 30000
    * `:is_state_ar` - Internal Bubble parameter. Defaults to false

  ## Returns

    * `{:ok, logs_response()}` - Success with log data
    * `{:error, term()}` - Error with reason

  ## Examples

      # Basic usage with required cookie
      {:ok, logs} = BubbleEx.Logs.fetch_logs("my-app", cookie: "bubble_session=...")

      # Custom time range (last 30 minutes)
      now = System.system_time(:millisecond)
      thirty_minutes_ago = now - (30 * 60 * 1000)
      {:ok, logs} = BubbleEx.Logs.fetch_logs("my-app",
        cookie: "bubble_session=...",
        after: thirty_minutes_ago,
        before: now
      )

      # Only error messages
      {:ok, errors} = BubbleEx.Logs.fetch_logs("my-app",
        cookie: "bubble_session=...",
        tags: %{
          message: ["error occurred during workflow execution", "failed because of error"],
          appname: "my-app",
          app_version: "live"
        }
      )

  """
  @spec fetch_logs(String.t(), [fetch_logs_option()]) :: {:ok, logs_response()} | {:error, term()}
  def fetch_logs(app_id, opts \\ []) do
    with {:ok, cookie} <- extract_cookie(opts),
         {:ok, request_body} <- build_request_body(app_id, opts),
         {:ok, response} <- make_request(request_body, cookie, opts) do
      parse_response(response)
    end
  end

  @doc """
  Creates a preset filter for common log types.

  ## Examples

      # Get all error-related logs
      error_filter = BubbleEx.Logs.preset_filter(:errors, "my-app")

      # Get all workflow-related logs
      workflow_filter = BubbleEx.Logs.preset_filter(:workflows, "my-app")

      # Get all API-related logs
      api_filter = BubbleEx.Logs.preset_filter(:api, "my-app")

  """
  @spec preset_filter(atom(), String.t()) :: map()
  @spec preset_filter(atom(), String.t(), String.t()) :: map()
  def preset_filter(type, app_name) when is_atom(type) and is_binary(app_name) do
    preset_filter(type, app_name, "live")
  end

  def preset_filter(:errors, app_name, app_version) do
    %{
      message: [
        "error occurred during workflow execution",
        "failed because of error",
        "action condition failed",
        "event condition failed, terminating",
        "Sending email failed"
      ],
      appname: app_name,
      app_version: app_version
    }
  end

  def preset_filter(:workflows, app_name, app_version) do
    %{
      message: [
        "running event",
        "event condition passed",
        "event condition failed, terminating",
        "running action",
        "action completed",
        "event completed"
      ],
      appname: app_name,
      app_version: app_version
    }
  end

  def preset_filter(:api, app_name, app_version) do
    %{
      message: [
        "http_request",
        "http_request response",
        "received request for API workflow"
      ],
      appname: app_name,
      app_version: app_version
    }
  end

  def preset_filter(:database, app_name, app_version) do
    %{
      message: ["server_db.modify"],
      appname: app_name,
      app_version: app_version
    }
  end

  def preset_filter(:plugins, app_name, app_version) do
    %{
      message: [
        "plugin action console output",
        "plugin action console error"
      ],
      appname: app_name,
      app_version: app_version
    }
  end

  def preset_filter(:scheduled, app_name, app_version) do
    %{
      message: [
        "scheduled task to run",
        "scheduled task completed"
      ],
      appname: app_name,
      app_version: app_version
    }
  end

  def preset_filter(:all, app_name, app_version) do
    %{
      message: @default_message_tags,
      appname: app_name,
      app_version: app_version
    }
  end

  @doc """
  Calculates time range helpers for common periods.

  ## Examples

      # Last hour
      {after_time, before_time} = BubbleEx.Logs.time_range(:last_hour)

      # Last 24 hours
      {after_time, before_time} = BubbleEx.Logs.time_range(:last_day)

      # Custom duration in minutes
      {after_time, before_time} = BubbleEx.Logs.time_range({:minutes, 30})

  """
  @spec time_range(atom() | {atom(), integer()}) :: {integer(), integer()}
  def time_range(period) do
    now = System.system_time(:millisecond)

    duration_ms =
      case period do
        :last_hour -> 60 * 60 * 1000
        :last_day -> 24 * 60 * 60 * 1000
        :last_week -> 7 * 24 * 60 * 60 * 1000
        {:minutes, n} -> n * 60 * 1000
        {:hours, n} -> n * 60 * 60 * 1000
        {:days, n} -> n * 24 * 60 * 60 * 1000
      end

    {now - duration_ms, now}
  end

  # Private functions

  @spec extract_cookie([fetch_logs_option()]) :: {:ok, String.t()} | {:error, term()}
  defp extract_cookie(opts) do
    case Keyword.get(opts, :cookie) do
      nil ->
        {:error,
         Error.new(:invalid_input, "a session cookie is required", %{reason: :missing_cookie})}

      "" ->
        {:error,
         Error.new(:invalid_input, "the session cookie is empty", %{reason: :empty_cookie})}

      cookie when is_binary(cookie) ->
        {:ok, cookie}

      _ ->
        {:error,
         Error.new(:invalid_input, "the session cookie must be a string", %{
           reason: :invalid_cookie
         })}
    end
  end

  @spec build_request_body(String.t(), [fetch_logs_option()]) :: {:ok, map()} | {:error, term()}
  defp build_request_body(app_id, opts) do
    now = System.system_time(:millisecond)
    one_hour_ago = now - 60 * 60 * 1000

    app_version = Config.logs_app_version(opts)
    after_time = Keyword.get(opts, :after, one_hour_ago)
    before_time = Keyword.get(opts, :before, now)
    ascending = Keyword.get(opts, :ascending, true)
    is_state_ar = Keyword.get(opts, :is_state_ar, false)

    # Build tags with defaults
    custom_tags = Keyword.get(opts, :tags, %{})

    default_tags = %{
      message: @default_message_tags,
      appname: app_id,
      app_version: app_version
    }

    tags = Map.merge(default_tags, custom_tags)

    request_body = %{
      tags: tags,
      ascending: ascending,
      after: after_time,
      before: before_time,
      is_state_ar: is_state_ar
    }

    {:ok, request_body}
  end

  @spec make_request(map(), String.t(), [fetch_logs_option()]) ::
          {:ok, Response.t()} | {:error, term()}
  defp make_request(request_body, cookie, opts) do
    endpoint = Config.logs_endpoint(opts)
    timeout = Config.logs_timeout(opts)

    headers = [
      {"Content-Type", "application/json"},
      {"Cookie", cookie}
    ]

    body = Jason.encode!(request_body)

    pool_timeout = Config.logs_pool_timeout(opts)

    http_opts = [
      timeout: timeout,
      recv_timeout: timeout,
      pool_timeout: pool_timeout
    ]

    Logger.debug("Making logs request to #{endpoint}")

    case HTTP.post(endpoint, body, headers, http_opts) do
      {:ok, %Response{status_code: 200} = response} ->
        {:ok, response}

      {:ok, %Response{status_code: status_code, body: resp_body}} ->
        {:error, Error.from_http(status_code, resp_body, %{endpoint: endpoint})}

      {:error, %HTTP.Error{reason: reason}} ->
        {:error,
         Error.new(:request_failed, "logs request failed: #{inspect(reason)}", %{reason: reason})}
    end
  end

  @spec parse_response(Response.t()) :: {:ok, logs_response()} | {:error, term()}
  defp parse_response(%Response{body: body}) do
    case Jason.decode(body) do
      {:ok, %{"rows" => logs} = response} ->
        # Bubble API returns logs in "rows" key
        result = %{
          logs: logs,
          total: Map.get(response, "total", length(logs)),
          has_more: Map.get(response, "has_more", false)
        }

        {:ok, result}

      {:ok, %{"logs" => logs} = response} ->
        # Fallback for other possible formats
        result = %{
          logs: logs,
          total: Map.get(response, "total"),
          has_more: Map.get(response, "has_more")
        }

        {:ok, result}

      {:ok, logs} when is_list(logs) ->
        # Handle case where response is directly a list of logs
        result = %{
          logs: logs,
          total: length(logs),
          has_more: false
        }

        {:ok, result}

      {:ok, _other} ->
        {:error, Error.new(:parse_failed, "unexpected logs response format", %{})}

      {:error, reason} ->
        {:error, Error.new(:parse_failed, "failed to decode logs JSON", %{reason: reason})}
    end
  end

  @doc """
  Flattened version that returns a list of grouped entries with metadata
  """
  def group_and_flatten(log_entries) do
    log_entries
    |> group_by_fiber_and_process()
    |> Enum.flat_map(fn {fiber_id, process_groups} ->
      Enum.map(process_groups, fn {process_id, entries} ->
        %{
          fiber_id: fiber_id,
          process_id: process_id,
          entry_count: length(entries),
          entries: entries,
          time_span: calculate_time_span(entries),
          appname: get_item(entries, "appname"),
          environment_name: get_item(entries, "environment_name"),
          app_version: get_item(entries, "app_version")
        }
      end)
    end)
    |> Enum.sort_by(& &1.fiber_id)
  end

  defp group_by_fiber_and_process(log_entries) do
    log_entries
    |> Enum.group_by(&get_fiber_id/1)
    |> Map.new(fn {fiber_id, entries} ->
      grouped_by_process = Enum.group_by(entries, &get_process_id/1)
      {fiber_id, grouped_by_process}
    end)
  end

  # Helper functions to extract fiber_id and process_id safely
  defp get_fiber_id(%{"tags" => %{"fiber_id" => fiber_id}}), do: fiber_id
  defp get_fiber_id(_), do: "unknown_fiber"

  defp get_process_id(%{"data" => %{"process_id" => process_id}}), do: process_id
  defp get_process_id(_), do: "unknown_process"

  defp calculate_time_span([]), do: 0

  defp calculate_time_span(entries) do
    timestamps = Enum.map(entries, &Map.get(&1, "created", 0))
    Enum.max(timestamps) - Enum.min(timestamps)
  end

  defp get_item(entries, key_to_get) do
    target_key =
      entries
      |> Enum.map(fn entry ->
        entry
        |> Map.get("tags", %{})
        |> Kernel.||(%{})
        |> Map.get(key_to_get, nil)
      end)

    if Enum.all?(target_key) do
      target_key |> List.first()
    else
      nil
    end
  end
end
