defmodule BubbleEx.Secrets.Native.Detectors do
  @moduledoc """
  Curated, high-precision regex detectors for common secret formats. Each
  detector is a `{name, regex}` pair; `scan_value/1` returns the matched secret
  substrings found in a single string.

  This is the precision tier — low false-positive rate. Unknown high-entropy
  strings are handled separately by `BubbleEx.Secrets.Native.Entropy`.
  """

  @type match :: %{detector: String.t(), raw: String.t()}

  @doc "Runs every detector against `value`, returning each matched secret."
  @spec scan_value(String.t()) :: [match()]
  def scan_value(value) when is_binary(value) do
    Enum.flat_map(detectors(), fn {name, regex} ->
      regex
      |> Regex.scan(value)
      |> Enum.map(fn [match | _] -> %{detector: name, raw: match} end)
    end)
  end

  # Order is irrelevant; every detector is tried against every value.
  # NOTE: `~r//` sigils expand to `%Regex{}` structs containing internal
  # references, which cannot be stored in a module attribute — Elixir's
  # attribute injection cannot escape #Reference values. A `defp` keeps the
  # list local without the injection issue.
  defp detectors do
    [
      # AKIA = long-term keys, ASIA = temporary STS credentials.
      {"aws_access_key_id", ~r/(?:AKIA|ASIA)[0-9A-Z]{16}/},
      # Legacy PATs (gho_/ghp_/ghs_/ghu_) and modern fine-grained PATs.
      {"github_pat", ~r/gh[opsu]_[A-Za-z0-9]{36,}/},
      {"github_pat", ~r/github_pat_[0-9A-Za-z_]{82}/},
      {"stripe_secret_key", ~r/sk_live_[A-Za-z0-9]{24,}/},
      {"slack_token", ~r/xox[baprs]-[A-Za-z0-9-]{10,}/},
      {"google_api_key", ~r/AIza[0-9A-Za-z_-]{35}/},
      {"jwt", ~r/eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/},
      # Capture the full PEM block (header through footer), not just the header,
      # so `raw` is the actual key span. `s` flag lets `.` span newlines; `.*?`
      # stops at the first matching footer.
      {"private_key",
       ~r/-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/s}
    ]
  end
end
