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
    case create_temp_file(payload) do
      {:ok, temp} -> run_scan_with_temp(temp, id, cli, opts)
      {:error, %Error{}} = error -> error
    end
  end

  defp run_scan_with_temp(temp, id, cli, opts) do
    ref = Keyword.get(opts, :ref)
    server_pid = Keyword.get(opts, :server_pid)
    log_level = Keyword.get(opts, :log_level, "5")

    try do
      Logger.info("Starting Trufflehog scan")
      stream(server_pid, ref, "Starting Trufflehog scan for payload with ID: #{id}")

      # `:spawn_executable` with an explicit argv avoids shell interpolation of
      # the (untrusted) temp path / id — no command-injection surface.
      args = [
        "filesystem",
        temp.path,
        "--json",
        "--log-level=#{log_level}",
        "--results=verified,unknown",
        "--no-update"
      ]

      port = Port.open({:spawn_executable, cli}, [:binary, :exit_status, args: args])
      {terminal_output, status} = collect_output(port, "", ref, server_pid)
      findings = parse_findings(terminal_output, temp.payload_json)

      handle_status(status, findings, ref, server_pid)
    rescue
      _error ->
        {:error, Error.new(:cli_failed, "trufflehog scan failed safely", %{})}
    after
      File.rm_rf(temp.dir)
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

  defp create_temp_file(payload) do
    with {:ok, payload_json, file_contents} <- encode_payload(payload),
         {:ok, temp_dir} <- create_private_temp_dir(3) do
      write_private_temp_file(temp_dir, payload_json, file_contents)
    end
  rescue
    _ -> temp_setup_error(:setup_failed)
  end

  defp write_private_temp_file(temp_dir, payload_json, file_contents) do
    temp_file = Path.join(temp_dir, "payload.json")

    case File.write(temp_file, file_contents, [:exclusive]) do
      :ok ->
        {:ok, %{path: temp_file, dir: temp_dir, payload_json: payload_json}}

      {:error, reason} ->
        File.rm_rf(temp_dir)
        temp_setup_error(reason)
    end
  end

  defp encode_payload(payload) when is_map(payload) do
    with {:ok, payload_json} <- Jason.encode(payload),
         {:ok, file_contents} <- Jason.encode(payload, pretty: true) do
      {:ok, payload_json, file_contents}
    else
      {:error, reason} -> temp_setup_error(reason)
    end
  end

  defp encode_payload(payload) when is_binary(payload), do: {:ok, payload, payload}

  defp create_private_temp_dir(attempts) when attempts > 0 do
    case System.tmp_dir() do
      temp_root when is_binary(temp_root) -> create_named_temp_dir(temp_root, attempts)
      _ -> temp_setup_error(:temp_dir_unavailable)
    end
  end

  defp create_private_temp_dir(_attempts), do: temp_setup_error(:name_collision)

  defp create_named_temp_dir(temp_root, attempts) do
    random = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    temp_dir = Path.join(temp_root, "bubble_ex_trufflehog_#{random}")
    secure_temp_dir(temp_dir, attempts)
  end

  defp secure_temp_dir(temp_dir, attempts) do
    case File.mkdir(temp_dir) do
      :ok -> restrict_temp_dir(temp_dir)
      {:error, :eexist} -> create_private_temp_dir(attempts - 1)
      {:error, reason} -> temp_setup_error(reason)
    end
  end

  defp restrict_temp_dir(temp_dir) do
    case File.chmod(temp_dir, 0o700) do
      :ok ->
        {:ok, temp_dir}

      {:error, reason} ->
        File.rm_rf(temp_dir)
        temp_setup_error(reason)
    end
  end

  defp temp_setup_error(_reason) do
    {:error, Error.new(:cli_failed, "could not prepare private trufflehog input", %{})}
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
