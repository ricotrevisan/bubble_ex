defmodule BubbleEx.Frontend.Snapshot.Runtime do
  @moduledoc false
  alias BubbleEx.Error

  @runtime_dir Path.join(__DIR__, "runtime")
  @sources (for name <-
                  ~w(archive.cjs data.cjs capture.cjs scroll.cjs package.cjs runner.cjs package.json package-lock.json) do
              path = Path.join(@runtime_dir, name)
              @external_resource path
              {name, File.read!(path)}
            end)

  @spec directory() :: String.t()
  def directory do
    System.get_env("BUBBLE_EX_SNAPSHOT_RUNTIME") ||
      Path.join(:filename.basedir(:user_cache, "bubble_ex"), "snapshot-v1")
  end

  @spec setup_files(String.t()) :: :ok | {:error, Error.t()}
  def setup_files(dir) do
    File.mkdir_p!(dir)
    Enum.each(@sources, fn {name, body} -> File.write!(Path.join(dir, name), body) end)
    :ok
  rescue
    _ -> {:error, Error.new(:invalid_input, "cannot write snapshot runtime", %{})}
  end

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, opts) do
    node = Keyword.get(opts, :snapshot_node, System.find_executable("node"))
    modules = Keyword.get(opts, :snapshot_runtime, directory())

    if is_binary(node) and
         File.regular?(Path.join(modules, "node_modules/playwright/package.json")) do
      execute(input, opts, node, modules)
    else
      {:error,
       Error.new(:cli_missing, "snapshot mode requires Node and mix bubble.snapshot.setup", %{})}
    end
  end

  defp execute(input, opts, node, modules) do
    parent = Keyword.get(opts, :snapshot_tmp_dir, System.tmp_dir!())

    temp =
      Path.join(parent, "bubbleex-snapshot-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)))

    try do
      File.mkdir_p!(temp)
      File.chmod!(temp, 0o700)
      Enum.each(@sources, fn {name, body} -> File.write!(Path.join(temp, name), body) end)
      input_path = Path.join(temp, "input.json")
      output_path = Path.join(temp, "output.json")
      File.write!(input_path, Jason.encode!(Map.put(input, :modules, Path.expand(modules))))
      File.chmod!(input_path, 0o600)

      {_output, status} =
        System.cmd(node, [Path.join(temp, "runner.cjs"), input_path, output_path],
          stderr_to_stdout: true
        )

      decode_result(status, output_path)
    rescue
      _ -> failed()
    after
      File.rm_rf(temp)
    end
  end

  defp decode_result(0, path) do
    with {:ok, %{size: size}} when size <= 200_000_000 <- File.stat(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"ok" => result}} when is_map(result) <- Jason.decode(body) do
      {:ok, result}
    else
      _ -> failed()
    end
  end

  defp decode_result(_, _), do: failed()
  defp failed, do: {:error, Error.new(:cli_failed, "browser snapshot backend failed", %{})}
end
