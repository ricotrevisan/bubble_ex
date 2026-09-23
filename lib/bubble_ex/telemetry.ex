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
          [:bubble_ex, :secrets, :scan, :stop],
          [:bubble_ex, :frontend, :normalize, :stop],
          [:bubble_ex, :frontend, :export, :stop]
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

  ### `[:bubble_ex, :frontend, :normalize, :start | :stop | :exception]`
  Emitted by `BubbleEx.Frontend.normalize/2`.
    * start metadata: `%{}`
    * stop metadata: adds `%{page_count, error}`

  ### `[:bubble_ex, :frontend, :export, :start | :stop | :exception]`
  Emitted by `BubbleEx.Frontend.export/3`.
    * start metadata: `%{out_dir}`
    * stop metadata: adds `%{file_count, error}`

  Metadata is sanitized by `BubbleEx.SafeMetadata` before every emission:
  URLs become origins, unknown strings and nested exception messages are redacted,
  and exception events omit stacktraces (which may contain request arguments).
  Results and raised/thrown terms returned to the caller are unchanged. Monitoring
  metadata is not a fetch address and must never be used to retry a request.

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
    event = [:bubble_ex | suffix]

    metadata =
      metadata |> BubbleEx.SafeMetadata.sanitize() |> Map.put(:telemetry_span_context, make_ref())

    started = System.monotonic_time()

    :telemetry.execute(
      event ++ [:start],
      %{system_time: System.system_time(), monotonic_time: started},
      metadata
    )

    try do
      {result, stop_metadata} = fun.()

      emit_finish(
        event,
        :stop,
        started,
        Map.merge(
          metadata,
          BubbleEx.SafeMetadata.sanitize(Map.delete(stop_metadata, :telemetry_span_context))
        )
      )

      result
    catch
      kind, reason ->
        # telemetry.span/3 would emit the raw exception and stack arguments before
        # a caller can sanitize them. Preserve raising semantics, not that payload.
        emit_finish(
          event,
          :exception,
          started,
          Map.merge(metadata, %{kind: kind, reason: BubbleEx.SafeMetadata.sanitize(reason)})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_finish(event, phase, started, metadata) do
    now = System.monotonic_time()

    :telemetry.execute(
      event ++ [phase],
      %{duration: now - started, monotonic_time: now},
      metadata
    )
  end
end
