defmodule BubbleEx.Editor.Target do
  @moduledoc """
  Explicit identity and authentication for one Bubble editor child version.

  The session cookie is deliberately redacted from `Inspect` output. Callers
  should supply it from process environment or another secret store.
  """

  alias BubbleEx.Error

  @enforce_keys [:appname, :version, :cookie]
  defstruct [:appname, :version, :cookie, origin: "https://bubble.io"]

  @type t :: %__MODULE__{
          appname: String.t(),
          version: String.t(),
          cookie: String.t(),
          origin: String.t()
        }

  @spec new(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(appname, version, cookie, opts \\ []) do
    with :ok <- validate_segment(appname, :appname),
         :ok <- validate_segment(version, :version),
         :ok <- validate_child_version(version),
         :ok <- validate_cookie(cookie),
         {:ok, origin} <- validate_origin(Keyword.get(opts, :origin, "https://bubble.io")) do
      {:ok, %__MODULE__{appname: appname, version: version, cookie: cookie, origin: origin}}
    end
  end

  defp validate_segment(value, field)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 120 do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, value) do
      :ok
    else
      invalid("#{field} contains unsupported characters", %{field: field})
    end
  end

  defp validate_segment(_value, field),
    do: invalid("#{field} must be a non-empty string", %{field: field})

  defp validate_child_version(version) when version in ["test", "live"] do
    invalid("editor writes require an isolated child app version", %{reason: :protected_version})
  end

  defp validate_child_version(_version), do: :ok

  defp validate_cookie(cookie) when is_binary(cookie) and byte_size(cookie) > 0 do
    if String.contains?(cookie, ["\r", "\n"]) do
      invalid("editor cookie contains control characters", %{reason: :invalid_cookie})
    else
      :ok
    end
  end

  defp validate_cookie(_cookie),
    do: invalid("an editor session cookie is required", %{reason: :missing_cookie})

  defp validate_origin(origin) when is_binary(origin) do
    uri = URI.parse(origin)

    if uri.scheme == "https" and is_binary(uri.host) and uri.path in [nil, ""] do
      {:ok, String.trim_trailing(origin, "/")}
    else
      invalid("editor origin must be an HTTPS origin", %{reason: :invalid_origin})
    end
  end

  defp validate_origin(_origin),
    do: invalid("editor origin must be a string", %{reason: :invalid_origin})

  defp invalid(message, context), do: {:error, Error.new(:invalid_input, message, context)}
end

defimpl Inspect, for: BubbleEx.Editor.Target do
  import Inspect.Algebra

  def inspect(target, opts) do
    concat([
      "#BubbleEx.Editor.Target<",
      to_doc(%{appname: target.appname, version: target.version, origin: target.origin}, opts),
      ", cookie: [REDACTED]>"
    ])
  end
end
