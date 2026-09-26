defmodule BubbleEx.Verify.Replay.CredentialScan do
  @moduledoc """
  The last check before the replay driver hands out anything it will write
  (a recording, a ledger): it refuses text that carries a credential
  (WTF-358 §6.3: the admin token, persona tokens and passwords are never
  written to recordings, ledgers, results or logs).

  A text is refused (`:export_blocked`) when it contains

    * any of the run's own secrets (`secrets`: the admin token, persona
      tokens and passwords), verbatim, URL-encoded or Base64-encoded
    * a `Bearer ` credential
    * a match of the `BubbleEx.Secrets.Native.Detectors` precision tier
      (JWTs, provider keys, private keys)
    * a non-empty string under a JSON member named like a credential
      (`token`, `password`, `secret`, `api_key`, `authorization`, …)

  The error names what was found and where (a JSON pointer), never the
  value.
  """

  alias BubbleEx.Error
  alias BubbleEx.Secrets.Native.Detectors

  @credential_key ~r/\A(?:[a-z0-9]+[_-])*(?:token|access_token|refresh_token|password|passwd|secret|client_secret|api_key|apikey|api_token|authorization|bearer|session|cookie|private_key)\z/i

  @doc """
  Checks `value` (a text, or a JSON term that is encoded first) against
  `secrets`. Returns `:ok` or `{:error, %BubbleEx.Error{kind: :export_blocked}}`.
  """
  @spec check(term(), [String.t()]) :: :ok | {:error, Error.t()}
  def check(value, secrets \\ [])

  def check(text, secrets) when is_binary(text) do
    term =
      case Jason.decode(text) do
        {:ok, term} -> term
        _ -> nil
      end

    findings =
      own_secrets(text, secrets) ++ bearer(text) ++ detectors(text) ++ keys(term, "")

    case findings do
      [] ->
        :ok

      found ->
        {:error,
         Error.new(:export_blocked, "refusing to write a credential into replay output", %{
           findings: Enum.uniq(found)
         })}
    end
  end

  def check(term, secrets), do: term |> Jason.encode!() |> check(secrets)

  defp own_secrets(text, secrets) do
    secrets
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 6))
    |> Enum.uniq()
    |> Enum.flat_map(fn secret ->
      forms = [secret, URI.encode_www_form(secret), Base.encode64(secret), Jason.encode!(secret)]

      if Enum.any?(forms, &String.contains?(text, trim_quotes(&1))),
        do: [%{kind: :run_secret}],
        else: []
    end)
  end

  defp trim_quotes(s), do: s |> String.trim_leading("\"") |> String.trim_trailing("\"")

  defp bearer(text),
    do: if(text =~ ~r/bearer\s+[A-Za-z0-9._~+\/-]{8,}/i, do: [%{kind: :bearer}], else: [])

  defp detectors(text),
    do: text |> Detectors.scan_value() |> Enum.map(&%{kind: :detector, detector: &1.detector})

  defp keys(map, path) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      here = path <> "/" <> escape(to_string(k))

      if is_binary(k) and k =~ @credential_key and is_binary(v) and v != "",
        do: [%{kind: :credential_key, pointer: here}],
        else: keys(v, here)
    end)
  end

  defp keys(list, path) when is_list(list) do
    list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> keys(v, "#{path}/#{i}") end)
  end

  defp keys(_value, _path), do: []

  defp escape(k), do: k |> String.replace("~", "~0") |> String.replace("/", "~1")
end
