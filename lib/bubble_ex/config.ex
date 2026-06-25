defmodule BubbleEx.Config do
  @moduledoc """
  Configuration module for BubbleEx.

  This module provides centralized configuration management for all BubbleEx modules,
  including default endpoints, timeouts, and other configurable options.

  ## Configuration Options

  BubbleEx can be configured in your application config:

      config :bubble_ex,
        logs: [
          default_endpoint: "https://bubble.io/appeditor/get_jetstream_logs",
          default_timeout: 30_000,
          default_app_version: "live",
          pool_max_connections: 10,
          pool_timeout: 30_000
        ],
        apps: [
          default_timeout: 10_000,
          max_body_length: 100_000_000
        ]

  ## Examples

      # Get logs configuration
      endpoint = BubbleEx.Config.get(:logs, :default_endpoint)

      # Get with default fallback
      timeout = BubbleEx.Config.get(:logs, :timeout, 30_000)

      # Get all logs configuration
      logs_config = BubbleEx.Config.get(:logs)

  """

  @doc """
  Gets a configuration value for a specific module and key.

  ## Parameters

    * `module` - The module atom (e.g., `:logs`, `:apps`)
    * `key` - The configuration key atom
    * `default` - Default value if not found (optional)

  ## Examples

      iex> BubbleEx.Config.get(:logs, :default_endpoint)
      "https://bubble.io/appeditor/get_jetstream_logs"

      iex> BubbleEx.Config.get(:logs, :timeout, 30_000)
      30000

  """
  @spec get(atom(), atom(), any()) :: any()
  def get(module, key, default \\ nil) do
    case get(module) do
      nil -> default
      config when is_list(config) -> Keyword.get(config, key, default)
    end
  end

  @doc """
  Gets all configuration for a specific module.

  ## Parameters

    * `module` - The module atom (e.g., `:logs`, `:apps`)

  ## Examples

      iex> BubbleEx.Config.get(:logs)
      [default_endpoint: "https://bubble.io/appeditor/get_jetstream_logs", default_timeout: 30000]

  """
  @spec get(atom()) :: keyword() | nil
  def get(module) do
    Application.get_env(:bubble_ex, module)
  end

  @doc """
  Gets the logs endpoint URL with support for custom Bubble instances.

  ## Parameters

    * `opts` - Keyword list of options that may contain `:endpoint`

  ## Examples

      iex> BubbleEx.Config.logs_endpoint([])
      "https://bubble.io/appeditor/get_jetstream_logs"

      iex> BubbleEx.Config.logs_endpoint(endpoint: "https://custom.bubble.io/appeditor/get_jetstream_logs")
      "https://custom.bubble.io/appeditor/get_jetstream_logs"

  """
  @spec logs_endpoint(keyword()) :: String.t()
  def logs_endpoint(opts \\ []) do
    Keyword.get(opts, :endpoint) ||
      get(:logs, :default_endpoint) ||
      "https://bubble.io/appeditor/get_jetstream_logs"
  end

  @doc """
  Gets the timeout value for logs requests.

  ## Parameters

    * `opts` - Keyword list of options that may contain `:timeout`

  ## Examples

      iex> BubbleEx.Config.logs_timeout([])
      30000

      iex> BubbleEx.Config.logs_timeout(timeout: 15000)
      15000

  """
  @spec logs_timeout(keyword()) :: integer()
  def logs_timeout(opts \\ []) do
    Keyword.get(opts, :timeout) ||
      get(:logs, :default_timeout) ||
      30_000
  end

  @doc """
  Gets the maximum connections for the logs HTTP pool.

  ## Parameters

    * `opts` - Keyword list of options that may contain `:pool_max_connections`

  ## Examples

      iex> BubbleEx.Config.logs_pool_max_connections([])
      10

      iex> BubbleEx.Config.logs_pool_max_connections(pool_max_connections: 20)
      20

  """
  @spec logs_pool_max_connections(keyword()) :: integer()
  def logs_pool_max_connections(opts \\ []) do
    Keyword.get(opts, :pool_max_connections) ||
      get(:logs, :pool_max_connections) ||
      10
  end

  @doc """
  Gets the pool timeout for the logs HTTP pool.

  ## Parameters

    * `opts` - Keyword list of options that may contain `:pool_timeout`

  ## Examples

      iex> BubbleEx.Config.logs_pool_timeout([])
      30000

      iex> BubbleEx.Config.logs_pool_timeout(pool_timeout: 15000)
      15000

  """
  @spec logs_pool_timeout(keyword()) :: integer()
  def logs_pool_timeout(opts \\ []) do
    Keyword.get(opts, :pool_timeout) ||
      get(:logs, :pool_timeout) ||
      30_000
  end

  @doc """
  Gets the default app version for logs requests.

  ## Parameters

    * `opts` - Keyword list of options that may contain `:app_version`

  ## Examples

      iex> BubbleEx.Config.logs_app_version([])
      "live"

      iex> BubbleEx.Config.logs_app_version(app_version: "test")
      "test"

  """
  @spec logs_app_version(keyword()) :: String.t()
  def logs_app_version(opts \\ []) do
    Keyword.get(opts, :app_version) ||
      get(:logs, :default_app_version) ||
      "live"
  end

  @doc """
  Gets the timeout value for app requests.

  ## Parameters

    * `opts` - Keyword list of options that may contain `:timeout`

  ## Examples

      iex> BubbleEx.Config.apps_timeout([])
      10000

      iex> BubbleEx.Config.apps_timeout(timeout: 5000)
      5000

  """
  @spec apps_timeout(keyword()) :: integer()
  def apps_timeout(opts \\ []) do
    Keyword.get(opts, :timeout) ||
      get(:apps, :default_timeout) ||
      10_000
  end

  @doc """
  Gets the maximum body length for app requests.

  ## Parameters

    * `opts` - Keyword list of options that may contain `:max_body_length`

  ## Examples

      iex> BubbleEx.Config.apps_max_body_length([])
      100000000

  """
  @spec apps_max_body_length(keyword()) :: integer()
  def apps_max_body_length(opts \\ []) do
    Keyword.get(opts, :max_body_length) ||
      get(:apps, :max_body_length) ||
      100_000_000
  end
end
