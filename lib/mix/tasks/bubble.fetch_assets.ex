defmodule Mix.Tasks.Bubble.FetchAssets do
  @shortdoc "Download a Bubble app's static page images into an asset store"

  @moduledoc """
  Downloads the images and icons set in the Bubble editor on an app's
  pages and reusable elements (WTF-447), so the generated Phoenix app
  serves them itself (`BubbleEx.Frontend.StaticAssets`).

      mix bubble.fetch_assets SOURCE --store DIR [--app-url URL] [--max-asset-bytes N]

  `SOURCE` is a Buildprint v5 workspace or an app JSON file. Only assets
  on Bubble's storage hosts are requested (`*.cdn.bubble.io`, Bubble's S3
  bucket and CloudFront distribution; redirects must stay there), and,
  with `--app-url https://<app host>`, the icon libraries on the app's own
  origin. Images on other hosts are never fetched: the generated pages
  link them to their original URLs, as Bubble does, and list them as
  `external` (informational). Images are kept only if their bytes are PNG, JPEG, GIF or
  WebP, or an SVG (sanitized). Already stored assets are not fetched
  again.

  This is the only step that makes requests. Then render with the store:

      {:ok, store} = BubbleEx.Frontend.StaticAssets.load_store(dir)
      BubbleEx.Target.Phoenix.render(project, frontend: frontend, asset_store: store, ...)
  """

  use Mix.Task

  alias BubbleEx.Frontend.StaticAssets

  @strict [store: :string, app_url: :string, max_asset_bytes: :integer]
  @usage "usage: mix bubble.fetch_assets SOURCE --store DIR [--app-url URL] [--max-asset-bytes N]"

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @strict) do
      {opts, [source], []} ->
        unless is_binary(opts[:store]), do: Mix.raise(@usage)
        Mix.Task.run("app.start")

        with {:ok, app} <- load_app(source),
             {:ok, frontend} <- BubbleEx.Frontend.normalize(app),
             {:ok, report} <- StaticAssets.fetch(frontend, opts[:store], fetch_opts(opts)) do
          print(report, opts[:store])
        else
          {:error, %BubbleEx.Error{} = error} -> Mix.raise(Exception.message(error))
          {:error, other} -> Mix.raise(inspect(other))
        end

      _ ->
        Mix.raise(@usage)
    end
  end

  defp fetch_opts(opts) do
    Enum.flat_map([app_url: opts[:app_url], max_asset_bytes: opts[:max_asset_bytes]], fn
      {_key, nil} -> []
      pair -> [pair]
    end)
  end

  defp load_app(path) do
    cond do
      BubbleEx.Buildprint.V5.workspace?(path) ->
        with {:ok, %{app: app}} <- BubbleEx.Buildprint.V5.load(path), do: {:ok, app}

      File.regular?(path) ->
        with {:ok, body} <- File.read(path),
             {:ok, app} when is_map(app) <- Jason.decode(body) do
          {:ok, app}
        else
          _ -> Mix.raise("#{path} is not an app JSON file")
        end

      true ->
        Mix.raise("not a Buildprint v5 workspace or an app JSON file: #{path}")
    end
  end

  defp print(report, dir) do
    Mix.shell().info(
      "#{report["stored"]} assets in #{dir}: #{report["fetched"]} fetched, " <>
        "#{report["reused"]} already stored, #{length(report["failed"])} failed; " <>
        "not fetched: #{report["external"]} on other hosts (linked), #{report["skipped"]} icon " <>
        "libraries (need --app-url), #{report["invalid"]} invalid, #{report["data"]} inline"
    )

    for %{"url" => url, "reason" => reason} <- report["failed"],
        do: Mix.shell().info("  failed #{url}: #{reason}")
  end
end
