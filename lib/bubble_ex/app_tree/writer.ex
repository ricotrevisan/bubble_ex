defmodule BubbleEx.AppTree.Writer do
  @moduledoc """
  The only AppTree module that touches disk. Everything upstream produces
  `{relative_path, {:json, term} | {:text, iodata}}` entries; this writes them.
  """

  alias BubbleEx.Error

  @doc """
  Checks whether `out_dir` is a safe write target (absent, empty, or `force:
  true`) without writing anything. Meant to be called early — before any
  rendering work — so a doomed run fails fast. `write/3` re-checks (cheaply
  idempotent) since it is also usable standalone.
  """
  @spec precheck(String.t(), keyword()) :: :ok | {:error, Error.t()}
  def precheck(out_dir, opts \\ []) do
    check_target(out_dir, Keyword.get(opts, :force, false))
  end

  @spec write(String.t(), [{String.t(), {:json, term()} | {:text, iodata()}}], keyword()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def write(out_dir, entries, opts \\ []) do
    with :ok <- check_target(out_dir, Keyword.get(opts, :force, false)) do
      Enum.each(entries, fn {rel_path, content} ->
        path = Path.join(out_dir, rel_path)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, encode(content))
      end)

      {:ok, length(entries)}
    end
  end

  defp encode({:json, term}), do: Jason.encode!(term, pretty: true) <> "\n"
  defp encode({:text, iodata}), do: iodata

  defp check_target(dir, force) do
    cond do
      not File.exists?(dir) ->
        :ok

      not File.dir?(dir) ->
        {:error, Error.new(:invalid_input, "output path is not a directory", %{out_dir: dir})}

      force or File.ls!(dir) == [] ->
        :ok

      true ->
        {:error,
         Error.new(:invalid_input, "output directory is not empty (use force: true)", %{
           out_dir: dir
         })}
    end
  end
end
