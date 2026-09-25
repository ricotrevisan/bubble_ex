# Run each mode in a fresh VM, e.g.:
# /usr/bin/time -v env MIX_ENV=test mix run --no-start scripts/scan_memory.exs legacy 8
# /usr/bin/time -v env MIX_ENV=test mix run --no-start scripts/scan_memory.exs artifact 8
# Synthetic single-payload preparation benchmark, not a production scan replay.
# No network, database, or real credentials. Reports sizes only.
[mode, megabytes] = System.argv()
bytes = String.to_integer(megabytes) * 1_000_000

payload = %{
  "_id" => "synthetic",
  "records" =>
    Enum.map(1..div(bytes, 1024), fn n ->
      %{"id" => n, "text" => String.duplicate("x", 1024)}
    end)
}

measure = fn name ->
  IO.puts("#{name}: vm_bytes=#{:erlang.memory(:total)}")
end

measure.("decoded_payload")

case mode do
  "legacy" ->
    pretty = Jason.encode!(payload, pretty: true)
    compact = Jason.encode!(payload)

    path =
      Path.join(
        System.tmp_dir!(),
        "bubble_legacy_benchmark_#{System.unique_integer([:positive])}.json"
      )

    try do
      File.write!(path, pretty)
      measure.("prepared")
      IO.puts("artifact_bytes=#{byte_size(pretty)} verification_bytes=#{byte_size(compact)}")
    after
      File.rm(path)
    end

  "artifact" ->
    BubbleEx.PayloadFile.with_file(payload, [max_input_bytes: bytes * 2], fn file ->
      measure.("prepared")
      IO.puts("artifact_bytes=#{file.bytes}")
    end)
end

# Keep the input live in both modes, as it is in the current app scan action.
IO.puts("records=#{length(payload["records"])}")
