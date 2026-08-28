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
  for streaming progress, and `:log_level`. Values supplied through
  Adapter errors preserve only their kind at this dispatcher boundary; messages
  and context are replaced with a safe generic error.
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
      taints = Keyword.get(opts, :telemetry_redact_values, [])

      result =
        payload
        |> adapter.scan(Keyword.delete(opts, :telemetry_redact_values))
        |> redact_error_result(taints)

      {result, scan_stop_metadata(result, taints)}
    end)
  end

  defp redact_error_result({:error, %Error{} = error}, _taints) do
    {:error, Error.new(error.kind, "secret scan failed safely", %{})}
  end

  defp redact_error_result(result, _taints), do: result

  defp scan_stop_metadata({:ok, findings}, _taints),
    do: %{finding_count: length(findings), error: nil}

  defp scan_stop_metadata({:error, %Error{} = error}, _taints),
    do: %{finding_count: 0, error: error}

  defp configured_adapter do
    Application.get_env(:bubble_ex, :secrets_adapter, @default_adapter)
  end
end
