defmodule Mix.Tasks.Bubble.RenderDiff do
  @shortdoc "Compare a Bubble page capture with the generated app's, element by element"

  @moduledoc """
  Compares two captures of the same page at the same width, one from Bubble
  and one from the generated app (both made with
  `scripts/vertical_slice/render_capture.js`), and explains each difference
  from the export. See `BubbleEx.Frontend.RenderDiff`.

      mix bubble.render_diff BUBBLE.json OURS.json --export EXPORT
        [--generated-from EXPORT] [--project DIR] [--known KNOWN.json]
        [--box-tolerance PX] [--top N] [--out REPORT.json]

    * `--export` - the Buildprint v5 workspace (or `.bubble` JSON) of the
      version Bubble served
    * `--generated-from` - the export the app was generated from, when it
      is another one: elements missing from it are reported as drift
    * `--project` - the generated project, for its `TODO(bubble:ID)` notes
      and dev-marker texts
    * `--known` - a JSON object `{"<element id>": "<reason>"}` of
      differences the owner accepts (e.g. stricter privacy)

  Prints a summary; `--out` writes the full report as JSON. The captures
  hold the page's data: keep them, and the report, private.
  """

  use Mix.Task

  alias BubbleEx.Frontend.RenderDiff

  @switches [
    export: :string,
    generated_from: :string,
    project: :string,
    known: :string,
    box_tolerance: :integer,
    top: :integer,
    out: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    with [] <- invalid,
         [bubble_path, ours_path] <- args,
         export when is_binary(export) <- opts[:export] do
      Mix.Task.run("app.config")
      bubble = read_json!(bubble_path)
      ours = read_json!(ours_path)
      index = export |> load_app!() |> index()

      diff_opts =
        [
          box_tolerance: opts[:box_tolerance] || 32,
          generated_from:
            opts[:generated_from] && opts[:generated_from] |> load_app!() |> index(),
          known: if(opts[:known], do: read_json!(opts[:known]), else: %{}),
          notes: if(opts[:project], do: RenderDiff.project_notes(opts[:project]), else: %{})
        ]

      report = RenderDiff.diff(bubble, ours, index, diff_opts)
      Mix.shell().info(RenderDiff.summary(report, opts[:top] || 20))

      if out = opts[:out] do
        File.write!(out, Jason.encode_to_iodata!(report, pretty: true))
        File.chmod!(out, 0o600)
        Mix.shell().info("\nwrote #{out}")
      end
    else
      _ ->
        Mix.raise(
          "usage: mix bubble.render_diff BUBBLE.json OURS.json --export EXPORT " <>
            "[--generated-from EXPORT] [--project DIR] [--known KNOWN.json] " <>
            "[--box-tolerance PX] [--top N] [--out REPORT.json]"
        )
    end
  end

  defp index({app, nil}), do: RenderDiff.index(app)
  defp index({app, model}), do: RenderDiff.index(app, schema: BubbleEx.Model.schema(model))

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp load_app!(path) do
    cond do
      BubbleEx.Buildprint.V5.workspace?(path) ->
        case BubbleEx.Buildprint.V5.load(path) do
          {:ok, %{app: app, model: model}} -> {app, model}
          {:error, error} -> Mix.raise("cannot load #{path}: #{Exception.message(error)}")
        end

      File.regular?(path) ->
        case BubbleEx.Frontend.read_bubble_export(path) do
          {:ok, app} -> {app, nil}
          {:error, error} -> Mix.raise("cannot load #{path}: #{Exception.message(error)}")
        end

      true ->
        Mix.raise("not a Buildprint v5 workspace or a .bubble JSON file: #{path}")
    end
  end
end
