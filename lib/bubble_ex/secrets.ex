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
      result = adapter.scan(payload, Keyword.delete(opts, :telemetry_redact_values))
      {result, scan_stop_metadata(result, Keyword.get(opts, :telemetry_redact_values, []))}
    end)
  end

  defp scan_stop_metadata({:ok, findings}, _taints),
    do: %{finding_count: length(findings), error: nil}

  defp scan_stop_metadata({:error, %Error{} = error}, taints) do
    safe_error =
      if tainted?(error, taints),
        do: Error.new(error.kind, "secret scan failed safely", %{}),
        else: error

    %{finding_count: 0, error: safe_error}
  end

  defp tainted?(term, taints) do
    binary = :erlang.term_to_binary(term)

    Enum.any?(taints, fn taint ->
      is_binary(taint) and taint != "" and :binary.match(binary, taint) != :nomatch
    end)
  end

  defp configured_adapter do
    Application.get_env(:bubble_ex, :secrets_adapter, @default_adapter)
  end
end
