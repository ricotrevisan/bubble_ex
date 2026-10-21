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
    * `--known` - the known-differences file: a JSON object keyed by
      element ID of the differences the owner accepts, each a reason or
      `{"reason": ..., "class": ..., "kinds": [...]}` (classes `privacy`,
      `server_data`, `drift`, `capture_gap`, `other`); see
      `BubbleEx.Frontend.RenderDiff.parse_known/1`. They are reported
      apart from the candidate bugs, and listed elements on the page that
      no longer differ are named (fixed, or a stale entry). One file can
      cover several pages. Keep it with the captures (it names the app's
      elements)
    * `--no-text` - leave the pages' texts out of the printed summary

  Capture the generated app with its dev markers on (the default in dev),
  so the capture holds each marker's reason. The steps, all under
  `scripts/vertical_slice/`:

    1. On the Bubble page, evaluate `render_capture.js` (the elements) and
       `render_records.js` (the records the page holds in browser memory)
       at each width.
    2. Load those records into the slice under their Bubble IDs:
       `slice.exs records EXPORT DECISIONS OUT RECORDS.json...` (a fresh
       database; see its header). Its dangling references are records the
       page pointed at but never held: values that read them differ.
    3. Serve the slice and capture it as the same user, at the same widths:
       `capture_ours.mjs` (127.0.0.1 only, magic-link sign-in).
    4. Compare each pair with this task.

  Prints a summary; `--out` writes the full report as JSON. The captures
  hold the page's data: keep them, and the report, private.
  """

  use Mix.Task

  alias BubbleEx.Frontend.RenderDiff

  @usage "usage: mix bubble.render_diff BUBBLE.json OURS.json --export EXPORT " <>
           "[--generated-from EXPORT] [--project DIR] [--known KNOWN.json] " <>
           "[--box-tolerance PX] [--top N] [--no-text] [--out REPORT.json]"

  @switches [
    export: :string,
    generated_from: :string,
    project: :string,
    known: :string,
    box_tolerance: :integer,
    top: :integer,
    out: :string,
    text: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    {top, tolerance} = check_options!(opts, invalid)

    with [bubble_path, ours_path] <- args,
         export when is_binary(export) <- opts[:export] do
      Mix.Task.run("app.config")
      bubble = read_json!(bubble_path)
      ours = read_json!(ours_path)
      index = export |> load_app!() |> index()

      diff_opts =
        [
          box_tolerance: tolerance,
          generated_from:
            opts[:generated_from] && opts[:generated_from] |> load_app!() |> index(),
          known: if(opts[:known], do: read_known!(opts[:known]), else: %{}),
          notes: if(opts[:project], do: RenderDiff.project_notes(opts[:project]), else: %{})
        ]

      report = RenderDiff.diff(bubble, ours, index, diff_opts)
      Mix.shell().info(RenderDiff.summary(report, top, text: Keyword.get(opts, :text, true)))

      if out = opts[:out] do
        # Private from the first byte: the report holds the pages' texts.
        File.write!(out, "")
        File.chmod!(out, 0o600)
        File.write!(out, Jason.encode_to_iodata!(report, pretty: true))
        Mix.shell().info("\nwrote #{out}")
      end
    else
      _ -> Mix.raise(@usage)
    end
  end

  defp check_options!(opts, invalid) do
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}\n" <> @usage)
    top = opts[:top] || 20
    tolerance = opts[:box_tolerance] || 32
    if top < 1 or tolerance < 0, do: Mix.raise("--top must be > 0 and --box-tolerance >= 0")
    {top, tolerance}
  end

  defp read_known!(path) do
    case path |> read_json!() |> RenderDiff.parse_known() do
      {:ok, known} -> known
      {:error, why} -> Mix.raise("--known #{path}: #{why}")
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
