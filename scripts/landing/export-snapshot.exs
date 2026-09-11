[baseline, output, runtime] = System.argv()
File.mkdir_p!(output)

sources =
  baseline
  |> Path.join("comparison.json")
  |> File.read!()
  |> Jason.decode!()
  |> Map.fetch!("results")

results =
  for %{"site" => site, "width" => width} = source <- sources do
    if source["error"] do
      %{site: site, width: width, accepted: false, error: source["error"]}
    else
      capture =
        baseline |> Path.join("#{site}-#{width}-snapshot.json") |> File.read!() |> Jason.decode!()

      out_dir = Path.join(output, "#{site}-#{width}")

      case BubbleEx.Frontend.Snapshot.export(capture, out_dir, snapshot_runtime: runtime) do
        {:ok, result} ->
          IO.inspect(%{
            site: site,
            width: width,
            files: length(result.files),
            findings: result.findings
          })

          %{site: site, width: width, accepted: true}

        {:error, error} ->
          IO.inspect(%{site: site, width: width, error: error.kind, context: error.context})
          %{site: site, width: width, accepted: false, error: error.kind}
      end
    end
  end

File.write!(Path.join(output, "export-gates.json"), Jason.encode!(results, pretty: true))
