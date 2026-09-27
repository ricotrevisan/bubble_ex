defmodule Mix.Tasks.Bubble.Export.Delete do
  @shortdoc "Delete a Bubble data export after the cutover"
  @moduledoc """
  Deletes a data export made by `BubbleEx.Load.DataApi` (it holds the
  app's data and users' emails) once the cutover is done. Refuses any
  directory that is not a bubble_ex export, and symbolic links; deletes
  only the export's own files and lists anything else it leaves. See `BubbleEx.Load.Export`.

      mix bubble.export.delete exports/acme
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    case argv do
      [dir] ->
        case BubbleEx.Load.Export.delete(dir) do
          {:ok, %{deleted: n, left: []}} ->
            Mix.shell().info("Deleted the export in #{dir} (#{n} files)")

          {:ok, %{deleted: n, left: left}} ->
            Mix.shell().info(
              "Deleted #{n} export files from #{dir}; kept what is not the export's:\n  " <>
                Enum.join(left, "\n  ")
            )

          {:error, error} ->
            Mix.raise(Exception.message(error))
        end

      _ ->
        Mix.raise("usage: mix bubble.export.delete EXPORT_DIR")
    end
  end
end
