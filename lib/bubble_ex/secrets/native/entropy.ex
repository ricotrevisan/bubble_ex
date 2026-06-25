defmodule BubbleEx.Secrets.Native.Entropy do
  @moduledoc """
  Shannon-entropy detection for unknown high-entropy strings.

  Deliberately conservative: Bubble payloads are dense with high-entropy
  non-secrets (record ids, element ids), so a candidate must clear a length
  floor, look like a token, exceed an entropy threshold, **and** sit under a
  sensitively-named key. Off by default in the adapter; opt in with
  `entropy: true`.
  """

  @sensitive_key ~r/(api[_-]?key|secret|token|password|passwd|auth|credential|private[_-]?key)/i
  @default_min_length 20
  @default_min_entropy 4.0

  @doc "Shannon entropy of `string` in bits per character."
  @spec shannon(String.t()) :: float()
  def shannon(""), do: 0.0

  def shannon(string) when is_binary(string) do
    chars = String.graphemes(string)
    len = length(chars)

    chars
    |> Enum.frequencies()
    |> Enum.reduce(0.0, fn {_char, count}, acc ->
      p = count / len
      acc - p * :math.log2(p)
    end)
  end

  @doc "True when `value` under `key` looks like an unknown secret."
  @spec candidate?(String.t() | nil, String.t(), keyword()) :: boolean()
  def candidate?(key, value, opts \\ []) when is_binary(value) do
    min_length = Keyword.get(opts, :min_length, @default_min_length)
    min_entropy = Keyword.get(opts, :min_entropy, @default_min_entropy)

    sensitive_key?(key) and String.length(value) >= min_length and tokenish?(value) and
      shannon(value) >= min_entropy
  end

  defp tokenish?(value), do: Regex.match?(~r/^[A-Za-z0-9_\-.+\/=]+$/, value)
  defp sensitive_key?(key) when is_binary(key), do: Regex.match?(@sensitive_key, key)
  # Defensive: `Traversal` normalizes keys to strings, but keep this total so a
  # direct caller passing nil/atom keys gets `false` rather than a crash.
  defp sensitive_key?(_key), do: false
end
