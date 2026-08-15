defmodule BubbleEx.Error do
  @moduledoc """
  The single error type returned by every BubbleEx public function.

  All failures surface as `{:error, %BubbleEx.Error{}}`. `kind` is a closed,
  documented set of atoms that callers can pattern-match on; `message` is a
  human-readable summary; `context` carries structured detail (status code,
  url, offending value, ...).

  ## Examples

      iex> BubbleEx.Error.new(:invalid_input, "bad slug", %{value: "a b"})
      %BubbleEx.Error{kind: :invalid_input, message: "bad slug", context: %{value: "a b"}}

      iex> BubbleEx.Error.from_http(404, "missing", %{url: "https://example.com"})
      %BubbleEx.Error{kind: :not_found, message: "HTTP 404", context: %{status: 404, body: "missing", url: "https://example.com"}}

  `BubbleEx.Error` is also an `Exception`, so it can be raised at an application
  boundary (`raise error`) when a caller prefers exceptions to tuples. The
  library itself never raises it for control flow.
  """

  @typedoc """
  The closed set of error kinds BubbleEx can return.

  - `:not_a_bubble_app` - a fetched page is reachable but is not a Bubble app
  - `:http_error` - an HTTP response with an unexpected status code
  - `:unauthorized` / `:forbidden` / `:not_found` - HTTP 401 / 403 / 404
  - `:invalid_input` - caller-supplied input failed validation
  - `:parse_failed` - a payload could not be parsed (JSON/JS/HTML)
  - `:body_too_large` - a response body exceeded the configured limit
  - `:cli_missing` - an optional external CLI (e.g. trufflehog) is not installed
  - `:cli_failed` - an external CLI ran but exited non-zero / unusable output
  - `:request_failed` - the request never completed (transport/timeout error)
  - `:unknown_format` - an unrecognized schema/output format was requested
  - `:unsupported_renderer` - the app is not using Bubble's modern responsive renderer
  - `:export_blocked` - a blocking finding (e.g. leaked credential) stopped a frontend export
  """
  @type kind ::
          :not_a_bubble_app
          | :http_error
          | :unauthorized
          | :forbidden
          | :not_found
          | :invalid_input
          | :parse_failed
          | :body_too_large
          | :cli_missing
          | :cli_failed
          | :request_failed
          | :unknown_format
          | :unsupported_renderer
          | :export_blocked

  @type t :: %__MODULE__{kind: kind(), message: String.t(), context: map()}

  defexception [:kind, :message, context: %{}]

  @doc """
  Builds an error of the given `kind` with a human-readable `message` and
  optional structured `context`.
  """
  @spec new(kind(), String.t(), map()) :: t()
  def new(kind, message, context \\ %{}) when is_atom(kind) and is_binary(message) do
    %__MODULE__{kind: kind, message: message, context: context}
  end

  @doc """
  Builds an error from an HTTP status code, mapping the common auth/missing
  codes to specific kinds and folding the status and body into `context`.
  """
  @spec from_http(pos_integer(), term(), map()) :: t()
  def from_http(status, body, context \\ %{})

  def from_http(401, body, context),
    do: new(:unauthorized, "HTTP 401", http_context(401, body, context))

  def from_http(403, body, context),
    do: new(:forbidden, "HTTP 403", http_context(403, body, context))

  def from_http(404, body, context),
    do: new(:not_found, "HTTP 404", http_context(404, body, context))

  def from_http(status, body, context) when is_integer(status) do
    new(:http_error, "HTTP #{status}", http_context(status, body, context))
  end

  defp http_context(status, body, context) do
    Map.merge(context, %{status: status, body: body})
  end

  @impl true
  def message(%__MODULE__{kind: kind, message: message}), do: "[#{kind}] #{message}"
end
