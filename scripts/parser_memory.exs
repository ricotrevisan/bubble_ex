# Compare the same public parser interface in fresh VMs:
# MIX_ENV=test mix run --no-start scripts/parser_memory.exs baseline 50000
# MIX_ENV=test mix run --no-start scripts/parser_memory.exs current 50000
# Baseline is the parent implementation, compiled under a separate module name.
# Only synthetic data and numeric diagnostics are printed.
[mode, count] = System.argv()
count = String.to_integer(count)
{source, 0} = System.cmd("git", ["show", "1c0fafb:lib/bubble_ex/apps/parser.ex"])

Code.compile_string(
  String.replace(
    source,
    "defmodule BubbleEx.Apps.Parser do",
    "defmodule BubbleEx.Apps.ParserBaseline do"
  )
)

payload = %{
  "_id" => "synthetic",
  "records" =>
    Enum.map(1..count, fn n ->
      %{"id" => n, "label" => "some \\\"escaped\\\" text", "enabled" => true}
    end)
}

json = Jason.encode!(payload)
js = "const app = JSON.parse(" <> Jason.encode!(json) <> ");"
parser = if mode == "baseline", do: BubbleEx.Apps.ParserBaseline, else: BubbleEx.Apps.Parser
{microseconds, {:ok, result}} = :timer.tc(fn -> parser.parse_app_json(js) end)
unless result == payload, do: raise("parser result mismatch")

IO.puts(
  "mode=#{mode} bundle_bytes=#{byte_size(js)} records=#{count} elapsed_ms=#{div(microseconds, 1000)}"
)

case File.read("/proc/self/status") do
  {:ok, status} ->
    for line <- String.split(status, "\n"),
        String.starts_with?(line, ["VmHWM:", "VmRSS:"]),
        do: IO.puts(line)

  _ ->
    IO.puts("OS RSS unavailable; use the platform's peak-memory profiler")
end
