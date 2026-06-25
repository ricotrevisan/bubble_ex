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

  require Logger
  alias BubbleEx.Error

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
    with {:ok, id} <- extract_id(payload),
         {:ok, cli} <- find_cli() do
      run_scan(payload, id, cli, opts)
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

  defp run_scan(payload, id, cli, opts) do
    ref = Keyword.get(opts, :ref)
    server_pid = Keyword.get(opts, :server_pid)
    log_level = Keyword.get(opts, :log_level, "5")

    {:ok, temp_file_path} = create_temp_file(payload, id)
    payload_json = if is_map(payload), do: Jason.encode!(payload), else: payload

    try do
      Logger.info("Starting Trufflehog scan for payload with ID: #{id}")
      stream(server_pid, ref, "Starting Trufflehog scan for payload with ID: #{id}")

      # `:spawn_executable` with an explicit argv avoids shell interpolation of
      # the (untrusted) temp path / id — no command-injection surface.
      args = [
        "filesystem",
        temp_file_path,
        "--json",
        "--log-level=#{log_level}",
        "--results=verified,unknown",
        "--no-update"
      ]

      port = Port.open({:spawn_executable, cli}, [:binary, :exit_status, args: args])
      {terminal_output, status} = collect_output(port, "", ref, server_pid)
      findings = parse_findings(terminal_output, payload_json)

      handle_status(status, findings, ref, server_pid)
    rescue
      e ->
        {:error, Error.new(:cli_failed, "trufflehog scan error: #{inspect(e)}", %{})}
    after
      File.rm(temp_file_path)
    end
  end

  defp handle_status(0, findings, ref, server_pid) do
    if server_pid && ref, do: send(server_pid, {:scan_completed, ref, findings})
    {:ok, findings}
  end

  defp handle_status(exit_code, _findings, _ref, _server_pid) do
    {:error,
     Error.new(:cli_failed, "trufflehog exited with status #{exit_code}", %{status: exit_code})}
  end

  defp parse_findings(terminal_output, payload_json) do
    terminal_output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, data} -> [enhance_result(data, payload_json)]
        {:error, _reason} -> []
      end
    end)
    |> Enum.reject(&Map.get(&1, "InvalidResult", false))
  end

  defp create_temp_file(payload, id) do
    temp_file_path = Path.join(System.tmp_dir!(), "#{id}.json")
    contents = if is_map(payload), do: Jason.encode!(payload, pretty: true), else: payload
    File.write!(temp_file_path, contents)
    {:ok, temp_file_path}
  end

  # Adds an "Encoded" field for BASE64 findings so the original encoded value can
  # be located in the source payload; marks the finding invalid if it cannot.
  defp enhance_result(%{"DecoderName" => "BASE64", "Raw" => raw_value} = result, payload_json) do
    encoded_value = Base.encode64(raw_value)
    result = Map.put(result, "Encoded", encoded_value)

    if String.contains?(payload_json, encoded_value) do
      result
    else
      Map.put(result, "InvalidResult", true)
    end
  end

  defp enhance_result(result, _payload_json), do: result

  defp stream(nil, _ref, _data), do: :ok
  defp stream(_pid, nil, _data), do: :ok
  defp stream(pid, ref, data), do: send(pid, {:scan_output, ref, data})
end
