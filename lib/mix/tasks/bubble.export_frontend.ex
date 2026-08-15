defmodule Mix.Tasks.Bubble.ExportFrontend do
  @shortdoc "Export a modern Bubble app version as portable HTML/CSS"

  @moduledoc """
  Fetches one public Bubble app version and writes a frontend export package.

      mix bubble.export_frontend APP -o OUT_DIR [--version VERSION] [--pages PAGES] [--fallback] [--force]

  `APP` is a bubble ID or URL. `--version` is `live` (default), `test`, or
  `development`. `--pages` is a comma-separated inclusion list of page slugs or
  map keys. Credentials are not accepted on the CLI.
  """

  use Mix.Task

  @strict [out: :string, version: :string, pages: :string, fallback: :boolean, force: :boolean]
  @aliases [o: :out]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @strict, aliases: @aliases)

    cond do
      invalid != [] ->
        Mix.raise(
          "usage: mix bubble.export_frontend APP -o OUT_DIR [--version VERSION] [--pages PAGES] [--fallback] [--force]"
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
          "usage: mix bubble.export_frontend APP -o OUT_DIR [--version VERSION] [--pages PAGES] [--fallback] [--force]"
        )
    end
  end

  defp export_opts(opts) do
    []
    |> put_opt(:app_version, Keyword.get(opts, :version))
    |> put_opt(:pages, parse_pages(Keyword.get(opts, :pages)))
    |> put_opt(:fallback, Keyword.get(opts, :fallback))
    |> put_opt(:force, Keyword.get(opts, :force))
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
