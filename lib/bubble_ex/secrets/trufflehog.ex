defmodule BubbleEx.Secrets.Trufflehog do
  @moduledoc """
  `BubbleEx.Secrets` adapter backed by the [Trufflehog](https://github.com/trufflesecurity/trufflehog)
  CLI.

  Writes the payload to a temp file, runs `trufflehog filesystem` over it, and
  parses the JSON findings. The CLI is optional: when it is not installed,
  `scan/2` returns `{:error, %BubbleEx.Error{kind: :cli_missing}}` rather than
  raising.

  By default TruffleHog asks each provider whether a found key works and only
  verified and unknown (verification errored) results are reported. With
  `verify: false` it contacts no provider (`--no-verification`) and reports
  every result, each marked `"Verification" => "skipped"`: TruffleHog's
  `"Verified" => false` then means not asked, never invalid (WTF-485).

  Both modes run with `--results=verified,unknown,unverified` (without
  `unverified` a run that verifies nothing reports nothing); in verify mode
  the results a provider rejected are dropped here instead.

  Every scan also loads bubble_ex's TruffleHog custom detectors
  (`priv/trufflehog/custom_detectors.yaml`, WTF-538) for secrets TruffleHog
  has no detector for. Their findings are renamed from TruffleHog's generic
  `"CustomRegex"` to a provider name and a `"DetectorType"` id of bubble_ex's
  own (`custom_detectors/0`). They are never verified, so they are marked
  `"Verification" => "skipped"` in both modes.
  """

  @behaviour BubbleEx.Secrets

  # Custom detector name (priv/trufflehog/custom_detectors.yaml) =>
  # {DetectorType, DetectorName}. The ids start above 1_000_000, far above
  # TruffleHog's own DetectorType enum, so they never name a TruffleHog
  # detector.
  @custom_detectors %{"ElasticAppSearch" => {1_000_001, "ElasticAppSearch"}}

  alias BubbleEx.{Error, PayloadFile}
  alias BubbleEx.Secrets.Output

  @doc """
  Scans a payload for exposed secrets.

  Accepts an Elixir map (which must contain a string `"_id"` field) or a JSON
  string. Supported `opts`:

    * `:log_level` - trufflehog verbosity, `"0"`..`"5"` (default `"5"`)
    * `:verify` - ask providers whether found keys work (default `true`);
      `false` contacts no provider and marks every finding
      `"Verification" => "skipped"`
    * `:server_pid` / `:ref` - when both are set, progress is streamed to the
      pid as `{:scan_output, ref, data}` and `{:scan_completed, ref, findings}`
  """
  @impl true
  @spec scan(map() | String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def scan(payload, opts \\ []) do
    with {:ok, _id} <- extract_id(payload),
         :ok <- validate_verify(opts),
         {:ok, cli} <- find_cli() do
      PayloadFile.with_file(payload, opts, &run_file(&1, cli, opts))
    end
  end

  @doc """
  Scans an existing `PayloadFile` without decoding or re-encoding its JSON.
  The caller owns the artifact lifetime. Input is bounded to 32 MB by default;
  stdout to 8 MB, each finding line to 1 MB, and execution to 120 seconds.
  Limits can be set with `:max_input_bytes`, `:max_output_bytes`,
  `:max_line_bytes`, `:max_findings`, and `:timeout_ms`. Takes `:verify` as
  `scan/2` does.
  """
  @spec scan_file(PayloadFile.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def scan_file(%PayloadFile{} = file, opts \\ []) do
    limit = Keyword.get(opts, :max_input_bytes, 32_000_000)

    with :ok <- validate_verify(opts),
         true <- is_integer(limit) and limit > 0,
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

  defp validate_verify(opts) do
    if is_boolean(Keyword.get(opts, :verify, true)),
      do: :ok,
      else: {:error, Error.new(:invalid_input, ":verify must be a boolean", %{})}
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
    args =
      [
        "filesystem",
        file.path,
        "--json",
        "--log-level=#{Keyword.get(opts, :log_level, "5")}",
        "--config=#{custom_detectors_path()}"
      ] ++
        verification_args(Keyword.get(opts, :verify, true)) ++
        ["--results=verified,unknown,unverified", "--no-update"]

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

  # A run without verification reports nothing as verified or unknown, so it
  # must ask for unverified results or it would report none. A verifying run
  # asks for them too, because the custom detectors never verify; the results
  # a provider rejected are dropped by `mark_verification/2`.
  defp verification_args(true), do: []
  defp verification_args(false), do: ["--no-verification"]

  @doc """
  The custom detectors every scan adds, as `%{name => {detector_type,
  detector_name}}`, where `name` is the detector's name in
  `priv/trufflehog/custom_detectors.yaml`.
  """
  @spec custom_detectors() :: %{String.t() => {pos_integer(), String.t()}}
  def custom_detectors, do: @custom_detectors

  defp custom_detectors_path,
    do: Application.app_dir(:bubble_ex, "priv/trufflehog/custom_detectors.yaml")

  defp collect_findings(port, output, file, opts, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    verify = Keyword.get(opts, :verify, true)

    # Rejected results are dropped before `enhance_result/3`, whose payload
    # searches read the whole file.
    enhance =
      &(&1
        |> name_custom_detector()
        |> mark_verification(verify)
        |> enhance_result(file, deadline))

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
        close_port(port)

      nil ->
        :ok
    end
  end

  # The killed scanner may exit, closing its port, at any moment after the
  # kill, so an open-check before Port.close/1 is a race (WTF-395): the badarg
  # was rescued by run_port/5 and turned a timeout into :cli_failed.
  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp enhance_result(nil, _file, _deadline), do: nil
  defp enhance_result(%{"InvalidResult" => true}, _file, _deadline), do: nil

  # A BASE64 finding whose encoded form is not in the payload is a decoder
  # artifact and is dropped, unless the secret is in the payload as is.
  # TruffleHog drops a finding as a duplicate when another decoder already
  # reported it at the same location, and a payload file is a single line, so
  # a plain-text secret comes back labelled BASE64 whenever the base64
  # decoding of its chunk left it intact and won the race (WTF-538: a GCP
  # service-account key was lost that way). It is reported as PLAIN.
  defp enhance_result(%{"DecoderName" => "BASE64", "Raw" => raw} = finding, file, deadline)
       when is_binary(raw) do
    encoded = Base.encode64(raw)

    cond do
      PayloadFile.contains?(file, encoded, deadline) -> Map.put(finding, "Encoded", encoded)
      PayloadFile.contains?(file, raw, deadline) -> Map.put(finding, "DecoderName", "PLAIN")
      true -> nil
    end
  end

  # The same race labels plain-text secrets HTML (or another decoder's name),
  # which leaves callers unable to find where they are; one that is in the
  # payload as is is PLAIN. Any other is kept as TruffleHog reported it.
  defp enhance_result(%{"DecoderName" => decoder, "Raw" => raw} = finding, file, deadline)
       when decoder != "PLAIN" and is_binary(raw) do
    if PayloadFile.contains?(file, raw, deadline),
      do: Map.put(finding, "DecoderName", "PLAIN"),
      else: finding
  end

  defp enhance_result(finding, _file, _deadline), do: finding

  defp name_custom_detector(
         %{"DetectorName" => "CustomRegex", "ExtraData" => %{"name" => name}} = finding
       ) do
    case Map.fetch(@custom_detectors, name) do
      {:ok, {type, detector_name}} ->
        Map.merge(finding, %{
          "DetectorType" => type,
          "DetectorName" => detector_name,
          "Verification" => "skipped"
        })

      :error ->
        finding
    end
  end

  defp name_custom_detector(finding), do: finding

  # In verify mode a result is kept when the provider accepted it, when it
  # could not be asked (a verification error: unknown), or when it was never
  # meant to be asked (a custom detector); one the provider rejected is not.
  defp mark_verification(%{"Verification" => "skipped"} = finding, _verify), do: finding
  defp mark_verification(%{"Verified" => true} = finding, true), do: finding

  defp mark_verification(finding, true) do
    case finding["VerificationError"] do
      error when is_binary(error) and error != "" -> finding
      _rejected -> nil
    end
  end

  defp mark_verification(finding, false), do: Map.put(finding, "Verification", "skipped")

  defp stream(nil, _ref, _data), do: :ok
  defp stream(_pid, nil, _data), do: :ok
  defp stream(pid, ref, data), do: send(pid, {:scan_output, ref, data})
end
