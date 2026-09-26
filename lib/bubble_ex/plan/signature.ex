defmodule BubbleEx.Plan.Signature do
  @moduledoc """
  Signs what a trusted run of `mix wtf.task` verifies against
  (`BubbleEx.Plan.sign/2`, `BubbleEx.Plan.verify/2`; WTF-375).

  Everything in the owner's repository (`.wtf/plan.json`,
  `.wtf/generated.json`, `.wtf/tasks/`, verification results) can be
  written by the agent being verified, and `plan_sha256` is a plain hash
  anyone can recompute. The trust anchor is therefore a key outside the
  repository: WTF signs the plan and the generated-file manifest when it
  publishes them, with an HMAC-SHA256 key it holds (and hands to the
  owner's CI as the `WTF_PLAN_SIGNING_KEY` secret, base64). The
  signature, `.wtf/plan.sig`, may live in the repository: without the key
  it cannot be forged.

  ```json
  {"format": "bubble_ex.plan_signature", "version": 1, "algorithm": "hmac-sha256",
   "key_id": "<16 hex>", "plan_sha256": "<sha256 of the plan.json bytes>",
   "generated_sha256": "<sha256 of the generated.json bytes, or null>",
   "mac": "<hmac of the canonical JSON of the members above>"}
  ```

  The same key signs verification results (`sign_file/3` with the
  `"result"` purpose, a `<result>.json.sig` next to the file): a trusted
  run counts only results signed that way.
  """

  alias BubbleEx.{CanonicalJson, Error}

  @format "bubble_ex.plan_signature"
  @path ".wtf/plan.sig"
  @min_key 32

  @doc "The signature's path in the repository."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  Reads a key from its base64 text (the `WTF_PLAN_SIGNING_KEY` form). At
  least #{@min_key} bytes.
  """
  @spec decode_key(String.t() | nil) :: {:ok, binary()} | {:error, Error.t()}
  def decode_key(text) when is_binary(text) do
    case Base.decode64(String.trim(text)) do
      {:ok, key} when byte_size(key) >= @min_key -> {:ok, key}
      _ -> error("the signing key must be base64 of at least #{@min_key} bytes")
    end
  end

  def decode_key(_), do: error("no signing key (WTF_PLAN_SIGNING_KEY)")

  @doc "Key ID: the first 16 hex digits of a keyed hash (names the key, reveals nothing)."
  @spec key_id(binary()) :: String.t()
  def key_id(key), do: key |> mac("key_id", "") |> binary_part(0, 16)

  @doc """
  Signs `%{plan: plan_json_bytes, generated: manifest_bytes | nil}` with
  `key`. Returns the signature map (write it with `encode/1`).
  """
  @spec sign(%{plan: binary(), generated: binary() | nil}, binary()) :: map()
  def sign(%{plan: plan} = files, key) when is_binary(plan) and is_binary(key) do
    body = body(files, key)
    Map.put(body, "mac", mac(key, "plan", CanonicalJson.encode(body)))
  end

  @doc "Canonical, pretty-printed JSON of a signature."
  @spec encode(map()) :: String.t()
  def encode(sig), do: (sig |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"

  @doc """
  Verifies `%{plan:, generated:, signature:}` (the signature as a map or
  its JSON) with `key`: the MAC, the key ID and the hashes of both files.
  """
  @spec verify(map(), binary()) :: :ok | {:error, Error.t()}
  def verify(%{plan: plan, signature: sig} = files, key) when is_binary(plan) do
    with {:ok, sig} <- decode(sig) do
      body = body(files, key)

      cond do
        sig["key_id"] != body["key_id"] ->
          error("the plan was signed with another key")

        not equal?(sig["mac"], mac(key, "plan", CanonicalJson.encode(Map.delete(sig, "mac")))) ->
          error("the plan signature is invalid")

        sig["plan_sha256"] != body["plan_sha256"] ->
          error(".wtf/plan.json is not the signed plan")

        sig["generated_sha256"] != body["generated_sha256"] ->
          error(".wtf/generated.json is not the signed manifest")

        true ->
          :ok
      end
    end
  end

  def verify(_, _), do: error("verify needs %{plan:, generated:, signature:}")

  @doc "The MAC of a file's bytes for `purpose` (e.g. `\"result\"`), hex."
  @spec sign_file(binary(), String.t(), binary()) :: String.t()
  def sign_file(bytes, purpose, key), do: mac(key, "file:" <> purpose, bytes)

  @doc "Whether `mac` is `sign_file/3` of the bytes."
  @spec verify_file(binary(), String.t(), String.t(), binary()) :: boolean()
  def verify_file(bytes, purpose, mac, key),
    do: is_binary(mac) and equal?(String.trim(mac), sign_file(bytes, purpose, key))

  defp body(files, key) do
    %{
      "format" => @format,
      "version" => 1,
      "algorithm" => "hmac-sha256",
      "key_id" => key_id(key),
      "plan_sha256" => sha256(files.plan),
      "generated_sha256" => files |> Map.get(:generated) |> then(&(&1 && sha256(&1)))
    }
  end

  defp decode(sig) when is_binary(sig) do
    case Jason.decode(sig) do
      {:ok, map} -> decode(map)
      _ -> error("the plan signature is not JSON")
    end
  end

  defp decode(%{"format" => @format, "version" => 1, "mac" => mac} = sig) when is_binary(mac),
    do: {:ok, sig}

  defp decode(_), do: error("not a plan signature")

  # Domain-separated HMAC-SHA256, lowercase hex.
  defp mac(key, purpose, data),
    do:
      :hmac
      |> :crypto.mac(:sha256, key, ["bubble_ex:", purpose, 0, data])
      |> Base.encode16(case: :lower)

  defp equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp equal?(_, _), do: false

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp error(message), do: {:error, Error.new(:invalid_input, message)}
end
