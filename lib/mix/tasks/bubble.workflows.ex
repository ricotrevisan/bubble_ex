defmodule Mix.Tasks.Bubble.Workflows do
  @shortdoc "Export a static workflow inventory from supplied JSON"
  @moduledoc """
  Reads a local decoded app payload or Bubble editor export. Writes inventory.json
  and WORKFLOWS.md. Does not fetch data or execute workflows. The output directory
  must be absent or empty. Reports retain source properties and can be sensitive.

      mix bubble.workflows app.bubble.json -o private/workflows
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: [out: :string], aliases: [o: :out])

    with {[], [path], out} when is_binary(out) <- {invalid, args, opts[:out]},
         {:ok, input} <- File.read(path),
         {:ok, payload} <- Jason.decode(input),
         {:ok, result} <- BubbleEx.Workflows.export(payload, out) do
      Mix.shell().info(
        "Wrote #{result.coverage.workflow_entries} workflow entries to #{result.out_dir}"
      )
    else
      {:error, %BubbleEx.Error{} = error} -> Mix.raise(Exception.message(error))
      {:error, _} -> Mix.raise("Could not read/decode input JSON")
      _ -> Mix.raise("usage: mix bubble.workflows INPUT.json -o OUT_DIR")
    end
  end
end
