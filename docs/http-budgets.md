# App HTTP resource budgets

High-level `BubbleEx.HTTP.fetch_page/2`, `fetch_json/2`, `post_json/4` and
`check_redirect/2` now use the bounded streaming path, including discovered dynamic
bundles in `BubbleEx.fetch_app/2`. A rejection drops accumulated chunks, halts the
stream, and never flattens the rejected body. Successful bodies are materialized
only after the byte check. A response-budget step runs **before Req redirects**:
halting Finch alone is insufficient, because Req could otherwise discard a
rejected redirect body's stream error and request its destination. Headers-only
responses are checked at that same boundary. `check_redirect`/`dedicated?` preserve
transport/resource failures as `:request_failed`, not evidence of an invalid app.
These are wire/body limits, not bounds on decoded JSON,
parser memory or total VM memory.

## Defaults and configuration

| Budget | Default | Override |
| --- | --- | --- |
| Landing HTML | 5,000,000 bytes | `:html_max_body_length` |
| Dynamic bundle | 100,000,000 bytes | `:script_max_body_length` |
| JSON endpoint | 100,000,000 bytes (legacy) | `:max_body_length` |
| Connect | 10 seconds | `:timeout` / apps `:default_timeout` |
| Pool checkout | 5 seconds (Req/Finch default) | per-call `:pool_timeout` |
| Receive inactivity | 10 seconds | per-call `:recv_timeout` |
| Streaming / retry elapsed budget | 30 seconds | `:total_timeout` |
| Maximum individual in-process retry delay | 1 second | `:max_retry_delay` |
| Retries | 2 | `:max_retries` |

Size, total-time and retry options accept per-call overrides or configuration under
`config :bubble_ex, :apps, ...`. The legacy per-call `:max_body_length` deliberately
overrides both HTML and bundle limits. Bundle size falls back to the legacy apps
body limit; HTML does not. Config values must be finite positive integers (retry
count may be zero).

The 100 MB bundle default preserves the previous supported ceiling rather than
rejecting large apps without production size data. The 5 MB HTML default is well
above committed landing-page fixtures, whose bodies are short synthetic script
stubs. The largest committed payload JSON is about 150 KB; this is not evidence of
production maxima. Consumers should monitor rejections before lowering budgets.

A stream checks its monotonic deadline on every chunk. Retry attempts share that
deadline; receive and checkout waits are capped by the remaining time. A delay
exceeding the cap or remaining budget is **not slept or retried**: the original
error/status is returned for the caller to schedule later. Body/encoding/deadline
errors are never retried in-process. No sleep occurs with `max_retries: 0`.

`Retry-After` accepts unsigned decimal seconds or an IMF-fixdate HTTP date,
using Req's documented non-raising `Req.Utils.parse_http_date/1` parser.
Past dates mean zero delay. Values over 64 bytes are ignored **before parsing**;
malformed values (including negative/signed seconds and invalid dates) use the
existing exponential backoff, still subject to the same delay/deadline caps.
Valid huge numeric/date delays return the original result without sleeping;
HTTP dates are compared to UTC wall time only to derive a delay, while the
remaining request budget continues to use monotonic time.

The streaming deadline is cooperative, not a hard wall-clock interrupt: a stalled
read, connection setup, redirects or custom adapter can overrun it until the
finite transport wait returns. Queue consumers must also use an outer execution
deadline. PluginProphet uses Oban's 120-second worker timeout, covering all fetches,
redirects, fallback versions, proxy fallback and parsing in the job.

Bounded requests ask for identity encoding and reject servers that still send
compressed bodies. They do not silently decompress a compressed bomb. Low-level
`get`/`post` retain the existing opt-in `bounded_body: true` contract so callers
that deliberately use ordinary decompression are not changed by this batch.

Named Finch pools own their connection configuration; per-request connection
options are not passed to Req alongside the pool name (Req rejects that
combination). Pool owners must configure a finite connection timeout. Receive,
checkout and streaming bounds still apply. Connect options must remain stable:
Req creates a pool for each distinct connection configuration, so remaining
milliseconds must not be used as a connection-pool key.

## Transport seam and verification

Destination/redirect/DNS policy is deliberately not implemented here. All app
fetches continue through `BubbleEx.HTTP`; named Finch pools remain injectable for
proxy routing and the next public-destination transport policy.

`test/bubble_ex/http_budget_test.exs` covers independent HTML/script ceilings,
real chunked TCP early closure, compressed-response rejection, named pools,
slow trickles, rejected 302/307 destinations, oversized JSON (GET/POST), dedicated
instance failure classification, numeric/date Retry-After (past, future, malformed,
overlong and huge values), zero-retry behavior and retry delays beyond the remaining
deadline. No production traffic or memory
benchmark was used. The streaming release changes reuse only the HTTP portion of
`9a34f18`; scanner and parser-memory changes from that branch are not included.
