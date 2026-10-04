defmodule BubbleEx.Editor.Target do
  @moduledoc """
  Explicit identity and authentication for one Bubble editor app version.

  `new/4` constructs an isolated child target. `readable/4` also accepts `test`
  and `live`. Neither constructor grants write permission: mutations independently
  resolve an active child parented by `test` immediately before submission.

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
    with :ok <- validate_child_version(version) do
      readable(appname, version, cookie, opts)
    end
  end

  @spec readable(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def readable(appname, version, cookie, opts \\ []) do
    with :ok <- validate_segment(appname, :appname),
         :ok <- validate_segment(version, :version),
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
    if Regex.match?(~r/[\x00-\x1F\x7F]/, cookie) do
      invalid("editor cookie contains control characters", %{reason: :invalid_cookie})
    else
      :ok
    end
  end

  defp validate_cookie(_cookie),
    do: invalid("an editor session cookie is required", %{reason: :missing_cookie})

  @doc false
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = target) do
    with :ok <- validate_segment(target.appname, :appname),
         :ok <- validate_segment(target.version, :version),
         :ok <- validate_cookie(target.cookie),
         {:ok, _origin} <- validate_origin(target.origin) do
      :ok
    end
  end

  @doc false
  @spec validate_child(t()) :: :ok | {:error, Error.t()}
  def validate_child(%__MODULE__{} = target) do
    with :ok <- validate(target), do: validate_child_version(target.version)
  end

  defp validate_origin("https://bubble.io"), do: {:ok, "https://bubble.io"}

  defp validate_origin(_origin),
    do: invalid("editor origin must be exactly https://bubble.io", %{reason: :invalid_origin})

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
