[baseline, output, runtime] = System.argv()
File.mkdir_p!(output)

results =
  for site <- ["mochary", "bubble"], width <- [390, 768, 1440] do
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

File.write!(Path.join(output, "export-gates.json"), Jason.encode!(results, pretty: true))
