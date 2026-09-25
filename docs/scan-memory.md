# Bounded scans

The existing `Trufflehog.scan/2` interface remains available. It now encodes one
private JSON artifact, reads scanner NDJSON incrementally, and checks BASE64
findings against the file in bounded chunks. Scanner input formatting remains
pretty JSON, preserving the previous scanner input representation for maps.
Raw stdout is no longer retained alongside a second parsed result list.

For callers that also upload or inspect the source, share its lifetime:

```elixir
BubbleEx.PayloadFile.with_file(payload, fn artifact ->
  with {:ok, findings} <- BubbleEx.Secrets.Trufflehog.scan_file(artifact) do
    # Consume/upload artifact.path here, before the callback returns.
    {:ok, findings}
  end
end)
```

The callback owns all consumers: don't return a lazy stream of the file or start
an unawaited task. The private directory is removed after the callback, including
on exceptions. Abrupt VM/OS termination can leave files behind; use ephemeral
worker storage and an operational cleanup policy. This is a file-backed scanner
input, not yet a fully streaming Bubble bundle decoder.

Default scanner budgets are `max_input_bytes: 32_000_000`,
`max_output_bytes: 8_000_000`, `max_line_bytes: 1_000_000`,
`max_findings: 10_000`, and `timeout_ms: 120_000`. Supply positive integers to
override. An exceeded budget returns `:invalid_input` with a safe `context.reason`
such as `:input_limit`, `:output_limit`, `:line_limit`, `:findings_limit`, or
`:scan_timeout`, never partial successful findings. CLI exit failures remain
`:cli_failed`. The POSIX `kill` executable is required so timeouts can terminate
the OS scanner instead of merely closing stdout. Caller/VM hard kills cannot
run Elixir cleanup; container isolation remains necessary.

App HTTP helpers now use the existing bounded streaming path by default. The
body-size check happens while receiving, with no retry for an oversized body.
They request identity encoding and reject unexpectedly encoded responses. This
avoids decompressing an arbitrary response outside a budget. Compatibility:
servers that insist on compressed responses now produce an error. A future
streaming decompressor must enforce both wire and decoded byte budgets.

The JavaScript-string decoder appends decoded spans to one binary instead of
retaining one list entry per span and escape. Characterization tests cover the
existing escape semantics. `scripts/parser_memory.exs` compares both public
parsers on identical synthetic input; the checked-in baseline revision is
`1c0fafb`. The 3,988,958-byte/50,000-record case measured 436,148 KiB vs
285,372 KiB fresh-VM peak RSS, and 807 ms vs 313 ms parsing duration. Both results
equal the original map. These measurements include VM overhead and do not
establish a production per-job budget.

`scripts/scan_memory.exs` measures artifact preparation separately. The initial
8 MB sample had similar VM-memory snapshots in both modes; removal of duplicate
serialization is not presented as a measured peak-memory win on that sample.

Limits are admission control: decoding an accepted JSON document still creates
a full map, scanner findings still form a bounded list, and the external CLI
uses additional memory. Run workers separately from web processes with an OS
memory limit, then size concurrency using representative end-to-end profiles.
