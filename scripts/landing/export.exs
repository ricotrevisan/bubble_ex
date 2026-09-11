# Usage: mix run scripts/landing/export.exs BASELINE_DIR OUTPUT_DIR [SOURCE_STYLES_DIR]
# Only the captured, credential-redacted payload is rendered. Roots are requested
# once to discover safe font stylesheet URLs; no source application is modified.
alias BubbleEx.Frontend
alias BubbleEx.Frontend.{Auth, Fetch, Normalized}
alias BubbleEx.Frontend.Export.Fonts

defmodule LandingAssets do
  def nodes(%Normalized{} = model), do: Enum.flat_map(model.pages ++ model.reusables, &flatten/1)
  defp flatten(node), do: [node | Enum.flat_map(node.children, &flatten/1)]

  def files(model, baseline) do
    html_assets =
      Path.wildcard(Path.join(baseline, "**/*.html"))
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> Floki.parse_document!()
        |> Floki.find("img[data-exporter-id][src]")
        |> Enum.map(fn image ->
          id = image |> Floki.attribute("data-exporter-id") |> List.first()
          src = image |> Floki.attribute("src") |> List.first()
          {id, Path.expand(src, Path.dirname(file))}
        end)
      end)
      |> Map.new()

    model
    |> nodes()
    |> Enum.flat_map(fn node ->
      src = get_in(node.content, ["src", :resolved]) || node.attributes["asset_src"]
      file = html_assets[node.exporter_id]
      if is_binary(src) and is_binary(file) and File.regular?(file), do: [{src, file}], else: []
    end)
    |> Map.new()
  end
end

[baseline, output | extra] = System.argv()
source_styles_dir = List.first(extra)
File.mkdir_p!(output)

for {site, url} <- [
      {"mochary", "https://beta.mocharymethod.com/"},
      {"bubble", "https://bubble.io/"}
    ] do
  payload =
    baseline |> Path.join("#{site}-redacted-payload.json") |> File.read!() |> Jason.decode!()

  {:ok, []} = BubbleEx.Secrets.Native.scan(payload)
  {:ok, model} = Frontend.normalize(payload)
  font_cache = Path.join(baseline, "#{site}-font-sources.json")

  sources =
    if File.regular?(font_cache) do
      font_cache |> File.read!() |> Jason.decode!()
    else
      {:ok, page} = BubbleEx.HTTP.fetch_page(url)
      urls = Fonts.discover(page.body, page.url)
      File.write!(font_cache, Jason.encode!(urls))
      urls
    end

  {:ok, _, auth} = Auth.prepare(url, [])

  source_styles =
    if source_styles_dir do
      lock = source_styles_dir |> Path.join("lock.json") |> File.read!() |> Jason.decode!()
      body = source_styles_dir |> Path.join("#{site}.json") |> File.read!()
      hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      true = hash == lock["#{site}.json"]
      record = Jason.decode!(body)
      true = record["url"] == url
      styles = record["styles"]
      %{"index" => %{blocks: styles["blocks"], omitted: styles["omitted"]}}
    else
      %{}
    end

  context = %Fetch.Context{
    page_url: url,
    auth: auth,
    font_sources: sources,
    source_styles: source_styles
  }

  opts = [
    pages: ["index"],
    force: true,
    secret_scan_adapter: BubbleEx.Secrets.Native,
    asset_timeout: 10_000,
    asset_files: LandingAssets.files(model, Path.join(baseline, "#{site}-redacted"))
  ]

  case Frontend.export_fetched(payload, Path.join(output, "#{site}-redacted"), opts, context) do
    {:ok, result} ->
      IO.puts(
        Jason.encode!(%{
          site: site,
          files: length(result.files),
          findings: length(result.findings)
        })
      )

    {:error, error} ->
      IO.puts(Jason.encode!(%{site: site, error: error.kind, message: error.message}))
      System.halt(1)
  end
end
