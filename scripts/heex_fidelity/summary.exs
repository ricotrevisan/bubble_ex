# Summarizes scripts/heex_fidelity.sh: per frozen case, the browser gate's
# status and mismatches by category (geometry, typography, collapse,
# presence, document size, screenshot, input values) for the HEEx
# candidate, and the overlay-state check where the case has one.
#
#     MIX_ENV=test mix run scripts/heex_fidelity/summary.exs <out dir> <case>...
#
# With HEEX_FIDELITY_STRICT=1 (CI) it fails unless every case passes.

[out | cases] = System.argv()

rows =
  for id <- cases do
    report =
      case File.read(Path.join([out, id, "report.json"])) do
        {:ok, json} -> Jason.decode!(json)
        _ -> %{"status" => "missing", "mismatches" => []}
      end

    overlay =
      case File.read(Path.join([out, id, "overlay-states.txt"])) do
        {:ok, text} -> if text =~ "PASS", do: "pass", else: "fail"
        _ -> "-"
      end

    by_category = Enum.frequencies_by(report["mismatches"] || [], & &1["category"])

    %{
      id: id,
      status: report["status"],
      geometry: get_in(report, ["geometry", "sampleCount"]) || 0,
      geometry_off: Map.get(by_category, "geometry", 0),
      max_error: get_in(report, ["geometry", "maxAbsError"]),
      categories: Map.drop(by_category, ["geometry"]),
      overlay: overlay
    }
  end

IO.puts("\nHEEx fidelity (frozen cases, pinned browser):\n")
IO.puts("case      status  geometry exact/samples  max error  other mismatches  overlays")

for row <- rows do
  other =
    row.categories |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

  IO.puts(
    Enum.join(
      [
        String.pad_trailing(row.id, 10),
        String.pad_trailing(to_string(row.status), 8),
        String.pad_trailing("#{row.geometry - row.geometry_off}/#{row.geometry}", 24),
        String.pad_trailing(inspect(row.max_error), 11),
        String.pad_trailing(if(other == "", do: "-", else: other), 18),
        row.overlay
      ],
      ""
    )
  )
end

samples = Enum.sum(Enum.map(rows, & &1.geometry))
exact = Enum.sum(Enum.map(rows, &(&1.geometry - &1.geometry_off)))
passed = Enum.count(rows, &(&1.status == "pass"))

IO.puts(
  "\n#{passed}/#{length(rows)} cases pass; geometry exact on #{exact}/#{samples} samples"
)

if System.get_env("HEEX_FIDELITY_STRICT") in ["1", "true"] and
     (passed < length(rows) or Enum.any?(rows, &(&1.overlay == "fail"))),
   do: System.halt(1)
