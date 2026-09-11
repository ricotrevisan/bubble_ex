defmodule Mix.Tasks.Bubble.ExportFrontend do
  @shortdoc "Export a modern Bubble app version as portable HTML/CSS"

  @moduledoc """
  Fetches one Bubble app version and writes a frontend export package.

      mix bubble.export_frontend APP -o OUT_DIR [--version VERSION] [--pages PAGES] [--max-page-fetches N] [--authenticated-assets] [--fallback] [--force]

  `APP` is a Bubble ID or URL. `--version` is `live` (default), `test`, or
  `development`. `--pages` is a comma-separated inclusion list of page slugs or
  map keys. `--max-page-fetches` bounds extra page-specific hydration requests
  and defaults to 20.

  Use `--mode snapshot --width 390 --height 900 --locale en-US` with one full
  anonymous page URL for a browser snapshot. First run `mix bubble.snapshot.setup`.
  Snapshot mode does not accept renderer version/page/authentication options.

  Private-app credentials come from `BUBBLE_EX_FRONTEND_USERNAME` plus
  `BUBBLE_EX_FRONTEND_PASSWORD`, or from URL userinfo such as
  `https://<username>:<password>@<app-host>/version-test`. An existing
  application-user session can be imported with
  `BUBBLE_EX_FRONTEND_SESSION_COOKIE`. Do not combine URL userinfo with the
  Basic environment pair.

  Authentication is HTTPS-only and scoped to the exact effective app origin.
  Assets remain public by default; `--authenticated-assets` opts exact-origin
  assets into authentication. BubbleEx never persists credentials or sessions,
  performs login or session renewal, executes private workflows, or fetches
  private Bubble records.
  """

  use Mix.Task

  @strict [
    out: :string,
    mode: :string,
    width: :integer,
    height: :integer,
    locale: :string,
    version: :string,
    pages: :string,
    max_page_fetches: :integer,
    authenticated_assets: :boolean,
    fallback: :boolean,
    force: :boolean
  ]
  @aliases [o: :out]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @strict, aliases: @aliases)

    cond do
      invalid != [] ->
        Mix.raise(
          "usage: mix bubble.export_frontend APP -o OUT_DIR [--version VERSION] [--pages PAGES] [--max-page-fetches N] [--authenticated-assets] [--fallback] [--force]"
        )

      match?([_], args) and is_binary(Keyword.get(opts, :out)) ->
        Mix.Task.run("app.start")
        [app] = args
        out = Keyword.fetch!(opts, :out)

        case BubbleEx.export_frontend(app, out, export_opts(opts)) do
          {:ok, result} ->
            Mix.shell().info("Wrote #{length(result.files)} files to #{out}")

          {:error, error} ->
            Mix.raise(Exception.message(error))
        end

      true ->
        Mix.raise(
          "usage: mix bubble.export_frontend APP -o OUT_DIR [--version VERSION] [--pages PAGES] [--max-page-fetches N] [--authenticated-assets] [--fallback] [--force]"
        )
    end
  end

  defp export_opts(opts) do
    []
    |> put_opt(:mode, parse_mode(Keyword.get(opts, :mode)))
    |> put_opt(:width, Keyword.get(opts, :width))
    |> put_opt(:height, Keyword.get(opts, :height))
    |> put_opt(:locale, Keyword.get(opts, :locale))
    |> put_opt(:app_version, Keyword.get(opts, :version))
    |> put_opt(:pages, parse_pages(Keyword.get(opts, :pages)))
    |> put_opt(:max_page_fetches, Keyword.get(opts, :max_page_fetches))
    |> put_opt(:fallback, Keyword.get(opts, :fallback))
    |> put_opt(:force, Keyword.get(opts, :force))
    |> put_opt(:asset_access, authenticated_asset_access(opts))
    |> put_opt(:username, System.get_env("BUBBLE_EX_FRONTEND_USERNAME"))
    |> put_opt(:password, System.get_env("BUBBLE_EX_FRONTEND_PASSWORD"))
    |> put_opt(:session_cookie, System.get_env("BUBBLE_EX_FRONTEND_SESSION_COOKIE"))
  end

  defp parse_mode(nil), do: nil
  defp parse_mode("renderer"), do: :renderer
  defp parse_mode("snapshot"), do: :snapshot
  defp parse_mode(_), do: :invalid

  defp authenticated_asset_access(opts) do
    if Keyword.get(opts, :authenticated_assets, false), do: :same_origin, else: nil
  end

  defp parse_pages(nil), do: nil

  defp parse_pages(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, false), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
