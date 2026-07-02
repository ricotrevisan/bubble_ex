defmodule Mix.Tasks.Bubble.AppTree do
  @shortdoc "Explode a .bubble.json export into an agent-readable source tree"

  @moduledoc """
  Turns a Bubble.io `.bubble.json` export into a two-layer source tree.

      mix bubble.app_tree path/to/app.bubble.json -o out_dir [--force]

  See `BubbleEx.AppTree` for the tree layout and guarantees.
  """

  use Mix.Task

  @switches [out: :string, force: :boolean]
  @aliases [o: :out, f: :force]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _invalid} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    with [input] <- args,
         out when is_binary(out) <- Keyword.get(opts, :out, :missing) do
      case BubbleEx.AppTree.generate(input, out, force: Keyword.get(opts, :force, false)) do
        {:ok, %{files: files, coverage: cov}} ->
          Mix.shell().info(
            "Wrote #{files} files to #{out} " <>
              "(actions rendered: #{cov.actions.rendered}/#{cov.actions.total}, " <>
              "expressions: #{cov.expressions.rendered}/#{cov.expressions.total})"
          )

        {:error, error} ->
          Mix.raise(Exception.message(error))
      end
    else
      _ -> Mix.raise("usage: mix bubble.app_tree INPUT.bubble.json -o OUT_DIR [--force]")
    end
  end
end
