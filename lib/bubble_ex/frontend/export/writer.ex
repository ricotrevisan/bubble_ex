defmodule BubbleEx.Frontend.Export.Writer do
  @moduledoc false

  alias BubbleEx.Error

  @spec precheck(String.t(), keyword()) :: :ok | {:error, Error.t()}
  def precheck(out_dir, opts \\ []) do
    check_target(out_dir, Keyword.get(opts, :force, false))
  end

  @spec publish(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def publish(out_dir, entries, opts \\ []) do
    files = entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    staging = Path.join(System.tmp_dir!(), "bubble_ex_frontend_" <> random_id())

    with :ok <- check_target(out_dir, Keyword.get(opts, :force, false)),
         :ok <- write_staging(staging, entries),
         :ok <- move_into(staging, out_dir) do
      {:ok, files}
    else
      {:error, _} = error ->
        File.rm_rf(staging)
        error
    end
  rescue
    e ->
      {:error,
       Error.new(:invalid_input, "failed writing output", %{
         error: Exception.message(e),
         out_dir: out_dir
       })}
  end

  defp write_staging(staging, entries) do
    File.rm_rf!(staging)
    File.mkdir_p!(staging)

    Enum.each(entries, fn {rel, body} ->
      path = Path.join(staging, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end)

    :ok
  end

  defp move_into(staging, out_dir) do
    File.mkdir_p!(out_dir)

    staging
    |> File.ls!()
    |> Enum.each(fn name ->
      src = Path.join(staging, name)
      dest = Path.join(out_dir, name)
      File.rm_rf!(dest)

      if File.dir?(src) do
        File.cp_r!(src, dest)
      else
        File.cp!(src, dest)
      end
    end)

    File.rm_rf!(staging)
    :ok
  end

  defp check_target(dir, force) do
    cond do
      not File.exists?(dir) ->
        :ok

      not File.dir?(dir) ->
        {:error, Error.new(:invalid_input, "output path is not a directory", %{out_dir: dir})}

      true ->
        check_listing(dir, force)
    end
  end

  defp check_listing(dir, force) do
    case File.ls(dir) do
      {:ok, entries} ->
        if force or entries == [] do
          :ok
        else
          {:error,
           Error.new(:invalid_input, "output directory is not empty (use force: true)", %{
             out_dir: dir
           })}
        end

      {:error, reason} ->
        {:error,
         Error.new(:invalid_input, "cannot read output directory", %{reason: reason, out_dir: dir})}
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
