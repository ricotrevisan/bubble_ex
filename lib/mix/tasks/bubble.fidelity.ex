defmodule Mix.Tasks.Bubble.Fidelity do
  @shortdoc "Run frozen-case frontend fidelity gates"

  @moduledoc """
  Renders each frozen case through `BubbleEx.Frontend.export_payload/3` and
  compares it to committed Bubble references (#30).

      mix bubble.fidelity [CASE] [--out OUT_DIR]

  Does not recapture live Bubble. Recapture is a separate authorized path
  (`--recapture` is refused unless `BUBBLE_RECAPTURE=1` is set, and still
  requires credentials that are never written to the package).
  """

  use Mix.Task

  @strict [out: :string, recapture: :boolean]
  @aliases [o: :out]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @strict, aliases: @aliases)

    cond do
      invalid != [] ->
        Mix.raise("usage: mix bubble.fidelity [CASE] [--out OUT_DIR]")

      Keyword.get(opts, :recapture, false) ->
        Mix.raise(
          "live recapture is not implemented here; it is a separate authorized path and must not run in CI"
        )

      true ->
        Mix.Task.run("app.start")
        ids = if args == [], do: BubbleEx.Frontend.Fidelity.cases(), else: args
        run_cases(ids, opts)
    end
  end

  defp run_cases(ids, opts) do
    results =
      Enum.map(ids, fn id ->
        run_opts = if opts[:out], do: [out_dir: Path.join(opts[:out], id)], else: []

        case BubbleEx.Frontend.Fidelity.run(id, run_opts) do
          {:ok, report} ->
            Mix.shell().info("PASS #{id}")
            {:ok, id, report}

          {:error, error} ->
            Mix.shell().error("FAIL #{id}: #{Exception.message(error)}")
            {:error, id, error}
        end
      end)

    if Enum.any?(results, &match?({:error, _, _}, &1)) do
      Mix.raise("fidelity gate failed")
    end
  end
end
