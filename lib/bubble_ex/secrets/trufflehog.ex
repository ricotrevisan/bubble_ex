defmodule BubbleEx.Secrets.Trufflehog do
  @moduledoc """
  `BubbleEx.Secrets` adapter backed by the [Trufflehog](https://github.com/trufflesecurity/trufflehog)
  CLI.

  Writes the payload to a temp file, runs `trufflehog filesystem` over it, and
  parses the JSON findings. The CLI is optional: when it is not installed,
  `scan/2` returns `{:error, %BubbleEx.Error{kind: :cli_missing}}` rather than
  raising.
  """

  @behaviour BubbleEx.Secrets

  alias BubbleEx.{Error, PayloadFile}
  alias BubbleEx.Secrets.Output

  @doc """
  Scans a payload for exposed secrets.

  Accepts an Elixir map (which must contain a string `"_id"` field) or a JSON
  string. Supported `opts`:

    * `:log_level` - trufflehog verbosity, `"0"`..`"5"` (default `"5"`)
    * `:server_pid` / `:ref` - when both are set, progress is streamed to the
      pid as `{:scan_output, ref, data}` and `{:scan_completed, ref, findings}`
  """
  @impl true
  @spec scan(map() | String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def scan(payload, opts \\ []) do
    with {:ok, _id} <- extract_id(payload),
         {:ok, cli} <- find_cli() do
      PayloadFile.with_file(payload, opts, &run_file(&1, cli, opts))
    end
  end

  @doc """
  Scans an existing `PayloadFile` without decoding or re-encoding its JSON.
  The caller owns the artifact lifetime. Input is bounded to 32 MB by default;
  stdout to 8 MB, each finding line to 1 MB, and execution to 120 seconds.
  Limits can be set with `:max_input_bytes`, `:max_output_bytes`,
  `:max_line_bytes`, `:max_findings`, and `:timeout_ms`.
  """
  @spec scan_file(PayloadFile.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def scan_file(%PayloadFile{} = file, opts \\ []) do
    limit = Keyword.get(opts, :max_input_bytes, 32_000_000)

    with true <- is_integer(limit) and limit > 0,
         {:ok, cli} <- find_cli(),
         {:ok, stat} <- File.stat(file.path),
         true <- stat.type == :regular and stat.size <= limit do
      run_file(file, cli, opts)
    else
      {:error, %Error{}} = error ->
        error

      _ ->
        {:error,
         Error.new(:invalid_input, "scan artifact unavailable or too large", %{
           reason: :input_limit
         })}
    end
  end

  @doc """
  Collects output from a port until it sends its exit status, accumulating the
  data and (optionally) streaming each chunk to `server_pid`.
  """
  @spec collect_output(port() | atom(), String.t(), reference() | nil, pid() | nil) ::
          {String.t(), integer()}
  def collect_output(port, acc, ref \\ nil, server_pid \\ nil) do
    receive do
      {^port, {:data, data}} ->
        stream(server_pid, ref, data)
        collect_output(port, acc <> data, ref, server_pid)

      {^port, {:exit_status, status}} ->
        stream(server_pid, ref, "Trufflehog process exited with status: #{status}")
        {acc, status}
    end
  end

  defp find_cli do
    case System.find_executable("trufflehog") do
      nil ->
        {:error,
         Error.new(:cli_missing, "the trufflehog CLI is not installed or not on PATH", %{})}

      path ->
        {:ok, path}
    end
  end

  defp extract_id(%{"_id" => id}) when is_binary(id), do: {:ok, id}

  defp extract_id(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"_id" => id}} when is_binary(id) -> {:ok, id}
      _ -> missing_id_error()
    end
  end

  defp extract_id(_payload), do: missing_id_error()

  defp missing_id_error do
    {:error, Error.new(:invalid_input, ~s(payload must contain a string "_id" field), %{})}
  end

  defp run_file(file, cli, opts) do
    output = Output.new(opts)
    timeout = Keyword.get(opts, :timeout_ms, 120_000)

    if Enum.all?(
         [timeout, output.max_bytes, output.max_line, output.max_findings],
         &(is_integer(&1) and &1 > 0)
       ) do
      case System.find_executable("kill") do
        nil ->
          {:error,
           Error.new(:cli_missing, "scan cancellation requires the POSIX kill utility", %{})}

        kill ->
          run_port(file, cli, Keyword.put(opts, :kill_executable, kill), output, timeout)
      end
    else
      {:error, Error.new(:invalid_input, "scan budgets must be positive integers", %{})}
    end
  end

  defp run_port(file, cli, opts, output, timeout) do
    args = [
      "filesystem",
      file.path,
      "--json",
      "--log-level=#{Keyword.get(opts, :log_level, "5")}",
      "--results=verified,unknown",
      "--no-update"
    ]

    port =
      Port.open({:spawn_executable, cli}, [:binary, :exit_status, :stderr_to_stdout, args: args])

    try do
      deadline = System.monotonic_time(:millisecond) + timeout
      collect_findings(port, output, file, opts, deadline)
    after
      terminate_port(port, opts[:kill_executable])
    end
  rescue
    _ -> {:error, Error.new(:cli_failed, "trufflehog scan failed safely", %{})}
  catch
    :throw, {:scan_budget, reason} -> budget_error(reason)
  end

  defp collect_findings(port, output, file, opts, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    enhance = &enhance_result(&1, file, deadline)

    if remaining == 0 do
      budget_error(:scan_timeout)
    else
      receive do
        {^port, {:data, data}} ->
          case Output.push(output, data, enhance) do
            {:ok, next} ->
              stream(Keyword.get(opts, :server_pid), Keyword.get(opts, :ref), data)
              collect_findings(port, next, file, opts, deadline)

            {:error, reason} ->
              budget_error(reason)
          end

        {^port, {:exit_status, 0}} ->
          case Output.finish(output, enhance) do
            {:ok, findings} = result ->
              if opts[:server_pid] && opts[:ref],
                do: send(opts[:server_pid], {:scan_completed, opts[:ref], findings})

              result

            {:error, reason} ->
              budget_error(reason)
          end

        {^port, {:exit_status, status}} ->
          {:error,
           Error.new(:cli_failed, "trufflehog exited with status #{status}", %{status: status})}
      after
        remaining -> budget_error(:scan_timeout)
      end
    end
  end

  defp budget_error(reason),
    do: {:error, Error.new(:invalid_input, "scan resource budget exceeded", %{reason: reason})}

  # Close the OS process as well as the port: a closed stdout pipe alone is not
  # a cancellation mechanism for a scanner blocked on network verification.
  defp terminate_port(port, kill) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        if Port.info(port), do: Port.close(port)

      nil ->
        :ok
    end
  end

  defp enhance_result(%{"DecoderName" => "BASE64", "Raw" => raw} = finding, file, deadline)
       when is_binary(raw) do
    encoded = Base.encode64(raw)

    if PayloadFile.contains?(file, encoded, deadline),
      do: Map.put(finding, "Encoded", encoded),
      else: nil
  end

  defp enhance_result(%{"InvalidResult" => true}, _file, _deadline), do: nil
  defp enhance_result(finding, _file, _deadline), do: finding

  defp stream(nil, _ref, _data), do: :ok
  defp stream(_pid, nil, _data), do: :ok
  defp stream(pid, ref, data), do: send(pid, {:scan_output, ref, data})
end
