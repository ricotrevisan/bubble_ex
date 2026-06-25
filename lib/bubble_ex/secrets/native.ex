defmodule BubbleEx.Secrets.Native do
  @moduledoc """
  Pure-Elixir `BubbleEx.Secrets` adapter — a zero-dependency, offline drop-in
  alternative to `BubbleEx.Secrets.Trufflehog`.

  It walks the payload, applies curated regex detectors (and an optional,
  gated entropy tier) to every string leaf, and returns clean native findings:

      %{detector:, raw:, redacted:, path:, decoder:, verified: false, confidence:}

  **No live verification.** Unlike Trufflehog, this adapter never contacts
  provider APIs, so every finding is `verified: false` (a *potential* secret).
  It also has far fewer detectors than Trufflehog — treat it as a zero-dependency
  baseline, not a replacement.

  ## Options

    * `:entropy` - when `true`, also flag unknown high-entropy strings under
      sensitively-named keys as low-confidence findings (default `false`)
    * `:min_length` / `:min_entropy` - entropy thresholds (see
      `BubbleEx.Secrets.Native.Entropy`)
  """

  @behaviour BubbleEx.Secrets

  alias BubbleEx.Error
  alias BubbleEx.Secrets.Native.{Detectors, Entropy, Traversal}

  @impl true
  @doc """
  Scans `payload` (an Elixir map or a JSON string) for exposed secrets.

  Returns `{:ok, [finding]}` on success, or `{:error, %BubbleEx.Error{}}` if
  the payload is not a JSON object or an Elixir map.
  """
  @spec scan(map() | String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def scan(payload, opts \\ [])

  def scan(payload, opts) when is_map(payload) do
    findings =
      payload
      |> Traversal.string_leaves()
      |> Enum.flat_map(&leaf_findings(&1, opts))
      # Collapse identical findings (same detector+raw+path+decoder); the same
      # secret at *different* paths is kept — each occurrence is a separate hit.
      |> Enum.uniq()

    {:ok, findings}
  end

  def scan(payload, opts) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, map} when is_map(map) -> scan(map, opts)
      _ -> {:error, invalid_input()}
    end
  end

  def scan(_payload, _opts), do: {:error, invalid_input()}

  @doc "Masks a secret for safe logging, keeping a short prefix/suffix."
  @spec redact(String.t()) :: String.t()
  def redact(raw) when is_binary(raw) do
    len = String.length(raw)

    if len <= 12 do
      String.duplicate("*", len)
    else
      String.slice(raw, 0, 4) <> "…" <> String.slice(raw, -4, 4)
    end
  end

  defp leaf_findings({path, key, value}, opts) do
    regex =
      value
      |> Detectors.scan_value()
      |> Enum.map(fn %{detector: d, raw: r} -> build(d, r, path, :plain, :high) end)

    base64 = base64_findings(path, value)
    known = regex ++ base64

    cond do
      known != [] ->
        known

      Keyword.get(opts, :entropy, false) and Entropy.candidate?(key, value, opts) ->
        [build("high_entropy_string", value, path, :plain, :low)]

      true ->
        []
    end
  end

  # Try base64-decoding plausibly-encoded leaves and re-run detectors on the
  # decoded text. The path is the encoded leaf's own path, so (unlike the
  # Trufflehog adapter) no payload re-search is needed.
  defp base64_findings(path, value) do
    with true <- maybe_base64?(value),
         {:ok, decoded} <- Base.decode64(value),
         true <- String.printable?(decoded) do
      decoded
      |> Detectors.scan_value()
      |> Enum.map(fn %{detector: d, raw: r} -> build(d, r, path, :base64, :high) end)
    else
      _ -> []
    end
  end

  defp maybe_base64?(value),
    do:
      byte_size(value) >= 16 and rem(byte_size(value), 4) == 0 and
        Regex.match?(~r/^[A-Za-z0-9+\/]+={0,2}$/, value)

  defp build(detector, raw, path, decoder, confidence) do
    %{
      detector: detector,
      raw: raw,
      redacted: redact(raw),
      path: path,
      decoder: decoder,
      verified: false,
      confidence: confidence
    }
  end

  defp invalid_input,
    do: Error.new(:invalid_input, "payload must be a JSON object or an Elixir map", %{})
end
