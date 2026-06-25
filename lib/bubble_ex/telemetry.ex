defmodule BubbleEx.Telemetry do
  @moduledoc """
  Telemetry events emitted by BubbleEx.

  Every instrumented operation emits a [`:telemetry.span/3`](https://hexdocs.pm/telemetry)
  triple — `:start`, then either `:stop` (success or a handled `{:error, _}`) or
  `:exception` (an unhandled raise). Attach a handler to observe them:

      :telemetry.attach_many(
        "my-handler",
        [
          [:bubble_ex, :http, :request, :stop],
          [:bubble_ex, :apps, :fetch_app, :stop],
          [:bubble_ex, :secrets, :scan, :stop]
        ],
        &MyApp.handle_event/4,
        nil
      )

  ## Events

  ### `[:bubble_ex, :http, :request, :start | :stop | :exception]`
  Emitted by `BubbleEx.HTTP.request/5` (every HTTP call funnels through it, so
  each wire request — including each retry attempt — is one span).
    * start metadata: `%{method, url}`
    * stop metadata: adds `%{status, error}` (`error` is `nil` on success)

  ### `[:bubble_ex, :apps, :fetch_app, :start | :stop | :exception]`
  Emitted by `BubbleEx.Apps.fetch_app/2`.
    * start metadata: `%{input}`
    * stop metadata: adds `%{bubble_id, valid?, error}`

  ### `[:bubble_ex, :secrets, :scan, :start | :stop | :exception]`
  Emitted by `BubbleEx.Secrets.scan/2`.
    * start metadata: `%{adapter}`
    * stop metadata: adds `%{finding_count, error}`

  ## Measurements

    * `:start` → `%{system_time, monotonic_time}`
    * `:stop` / `:exception` → `%{duration, monotonic_time}` (native time units)
  """

  @doc """
  Wraps `fun` in a `:telemetry` span under the `[:bubble_ex | suffix]` prefix.

  `fun` must return `{result, stop_metadata}`. The `:start` metadata is merged
  into `stop_metadata` so the `:stop` event carries the full context (raw
  `:telemetry.span/3` does not propagate start metadata to `:stop`). Returns
  `result`.
  """
  @spec span([atom()], map(), (-> {term(), map()})) :: term()
  def span(suffix, metadata, fun) when is_list(suffix) and is_map(metadata) do
    :telemetry.span([:bubble_ex | suffix], metadata, fn ->
      {result, stop_metadata} = fun.()
      {result, Map.merge(metadata, stop_metadata)}
    end)
  end
end
