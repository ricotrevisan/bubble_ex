defmodule BubbleEx.Target.Phoenix.Formatter do
  @moduledoc false

  @locals_file Path.join(__DIR__, "formatter_locals.exs")
  @external_resource @locals_file
  {locals, _} = Code.eval_file(@locals_file)
  @locals_without_parens locals

  @spec format(String.t(), binary()) :: binary()
  def format(path, source) do
    cond do
      String.ends_with?(path, ".heex") ->
        Phoenix.LiveView.HTMLFormatter.format(source, extension: ".heex", file: path)

      Path.extname(path) in [".ex", ".exs"] ->
        source
        |> Code.format_string!(locals_without_parens: @locals_without_parens)
        |> IO.iodata_to_binary()
        |> Kernel.<>("\n")

      true ->
        source
    end
  end
end
