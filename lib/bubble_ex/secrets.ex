defmodule BubbleEx.Secrets do
  @moduledoc """
  Behaviour and dispatcher for secret scanning.

  A scanner is any module implementing the `c:scan/2` callback. The default
  scanner is `BubbleEx.Secrets.Trufflehog`, which shells out to the optional
  `trufflehog` CLI. The active scanner can be overridden per call with the
  `:adapter` option, or globally via application config:

      config :bubble_ex, :secrets_adapter, MyApp.CustomScanner
  """

  alias BubbleEx.{Error, Telemetry}

  @typedoc "A single secret-scanning finding."
  @type finding :: map()

  @doc """
  Scans `payload` (an Elixir map or a JSON string) for exposed secrets.

  `opts` may carry adapter-specific options such as `:server_pid` and `:ref`
  for streaming progress, and `:log_level`.
  """
  @callback scan(payload :: map() | String.t(), opts :: keyword()) ::
              {:ok, [finding()]} | {:error, Error.t()}

  @default_adapter BubbleEx.Secrets.Trufflehog

  @doc """
  Dispatches a scan to the configured (or supplied) adapter.
  """
  @spec scan(map() | String.t(), keyword()) :: {:ok, [finding()]} | {:error, Error.t()}
  def scan(payload, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, configured_adapter())

    Telemetry.span([:secrets, :scan], %{adapter: adapter}, fn ->
      result = adapter.scan(payload, opts)
      {result, scan_stop_metadata(result)}
    end)
  end

  defp scan_stop_metadata({:ok, findings}), do: %{finding_count: length(findings), error: nil}
  defp scan_stop_metadata({:error, error}), do: %{finding_count: 0, error: error}

  defp configured_adapter do
    Application.get_env(:bubble_ex, :secrets_adapter, @default_adapter)
  end
end
