defmodule BubbleEx.Frontend.Snapshot do
  @moduledoc """
  Captures one anonymous Bubble page as a portable, inert initial view.

  The optional backend requires `mix bubble.snapshot.setup`. A capture belongs
  to one viewport; it does not recreate responsive rules or Bubble workflows.
  `capture/2` returns private browser data in memory. `export/3` builds local
  HTML/assets, scans decoded text for credentials, and publishes only on success.
  Keep capture data private; it has not passed the export credential gate.
  """
  alias BubbleEx.Error
  alias BubbleEx.Frontend.Export.Writer
  alias BubbleEx.Frontend.Snapshot.{Result, Runtime}
  alias BubbleEx.Secrets.Native

  @doc "Capture a single explicit HTTP(S) URL in a fresh anonymous browser context."
  @spec capture(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def capture(url, opts \\ []) do
    with :ok <- validate_options(opts),
         :ok <- validate_url(url, opts),
         {:ok, viewport} <- viewport(opts) do
      Runtime.run(%{operation: "capture", url: url, options: viewport}, opts)
    end
  end

  @doc "Export captured browser data without contacting the source site."
  @spec export(map(), String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def export(capture, out_dir, opts \\ []) do
    with :ok <- validate_capture(capture),
         :ok <- Writer.precheck(out_dir, opts),
         {:ok, package} <- Runtime.run(%{operation: "export", capture: capture}, opts),
         :ok <- scan(package, capture),
         {:ok, entries} <- entries(package) do
      manifest = manifest(capture, package)
      entries = entries ++ [{"MANIFEST.json", Jason.encode!(manifest, pretty: true)}]

      with {:ok, files} <- Writer.publish(out_dir, entries, opts) do
        {:ok,
         %Result{out_dir: out_dir, files: files, manifest: manifest, findings: manifest.findings}}
      end
    end
  end

  @doc "Capture and export one page. The default app-data renderer is separate."
  @spec run(String.t(), String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(url, out_dir, opts \\ []) do
    with :ok <- Writer.precheck(out_dir, opts),
         {:ok, capture} <- capture(url, opts) do
      export(capture, out_dir, opts)
    end
  end

  defp validate_options(opts) do
    renderer_keys = [:app_version, :pages, :max_page_fetches, :fallback, :asset_access]

    if Enum.any?(renderer_keys, &Keyword.has_key?(opts, &1)),
      do: invalid("snapshot mode accepts one full URL, not renderer version/page/asset options"),
      else: :ok
  end

  defp validate_url(url, opts) when is_binary(url) do
    parsed = URI.parse(url)

    if parsed.scheme in ["http", "https"] and is_binary(parsed.host) and parsed.host != "" and
         is_nil(parsed.userinfo) and
         not Enum.any?([:username, :password, :session_cookie], &Keyword.has_key?(opts, &1)) do
      :ok
    else
      invalid("snapshot mode requires an anonymous HTTP(S) URL")
    end
  end

  defp validate_url(_, _), do: invalid("snapshot mode requires an anonymous HTTP(S) URL")

  defp viewport(opts) do
    width = Keyword.get(opts, :width, 1440)
    height = Keyword.get(opts, :height, 900)
    locale = Keyword.get(opts, :locale, "en-US")

    if is_integer(width) and width in 320..3840 and is_integer(height) and height in 240..2160 and
         is_binary(locale) and byte_size(locale) in 2..50 do
      {:ok, %{width: width, height: height, locale: locale}}
    else
      invalid("snapshot viewport must be 320–3840 by 240–2160 pixels with a locale")
    end
  end

  defp validate_capture(%{"schema" => 1, "archive" => archive, "url" => url} = capture)
       when is_binary(archive) and byte_size(archive) <= 100_000_000 do
    with :ok <- validate_url(url, []),
         true <- is_map(capture["viewport"]),
         true <- is_list(capture["findings"] || []) do
      :ok
    else
      _ -> invalid("invalid snapshot capture")
    end
  end

  defp validate_capture(_), do: invalid("invalid snapshot capture")

  defp scan(package, capture) do
    resource_urls =
      Enum.map(capture["resources"] || capture["fonts"] || [], fn resource ->
        url = resource["url"] || ""

        if String.starts_with?(url, ["http://", "https://"]),
          do: Map.take(resource, ["url", "mime"]),
          else: %{}
      end)

    payload = %{
      "source_text" => package["scan"],
      "findings" => package["findings"],
      "resources" => resource_urls,
      "capture" =>
        Map.take(capture, [
          "url",
          "viewport",
          "browser",
          "platform",
          "arch",
          "capturedAt",
          "findings"
        ])
    }

    case Native.scan(payload) do
      {:ok, []} ->
        :ok

      {:ok, findings} ->
        {:error,
         Error.new(:export_blocked, "snapshot export blocked by potential credentials", %{
           finding_count: length(findings)
         })}
    end
  end

  defp entries(%{"entries" => entries}) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with %{"name" => name, "body" => encoded} <- entry,
           true <-
             is_binary(name) and
               Regex.match?(~r/\A(?:index\.html|assets\/[a-f0-9]{64}\.[a-z0-9]+)\z/, name),
           {:ok, body} <- Base.decode64(encoded) do
        {:cont, {:ok, [{name, body} | acc]}}
      else
        _ -> {:halt, invalid("invalid snapshot package")}
      end
    end)
  end

  defp entries(_), do: invalid("invalid snapshot package")

  defp manifest(capture, package) do
    %{
      schema: 1,
      mode: "browser_snapshot",
      url: capture["url"],
      viewport: capture["viewport"],
      browser: capture["browser"],
      captured_at: capture["capturedAt"],
      workflows: false,
      findings: (capture["findings"] || []) ++ (package["findings"] || [])
    }
  end

  defp invalid(message), do: {:error, Error.new(:invalid_input, message, %{})}
end
