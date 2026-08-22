defmodule BubbleEx.Frontend.Fetch do
  @moduledoc false

  alias BubbleEx.Apps.Parser
  alias BubbleEx.{Config, Error, HTTP}
  alias BubbleEx.Frontend.{Auth, SafeUrl}

  @max_redirects 5

  defmodule Context do
    @moduledoc false
    @enforce_keys [:page_url, :auth]
    defstruct [:page_url, :auth]
    @type t :: %__MODULE__{page_url: String.t(), auth: BubbleEx.Frontend.Auth.t()}
  end

  @spec run(String.t(), Auth.t(), keyword()) ::
          {:ok, map(), Context.t()} | {:error, Error.t()}
  def run(url, %Auth{} = auth, opts \\ []) do
    with {:ok, page_url, scoped_auth} <- resolve_dedicated(url, auth, opts),
         {:ok, page} <-
           fetch_bubble_page(page_url, scoped_auth, auth_state(scoped_auth, page_url), opts),
         {:ok, dynamic_url} <- dynamic_url(page, scoped_auth),
         {:ok, dynamic} <-
           fetch_bubble_page(dynamic_url, scoped_auth, auth_state(scoped_auth, dynamic_url), opts),
         {:ok, payload} <- parse_payload(dynamic.body) do
      {:ok, payload, %Context{page_url: page.url, auth: scoped_auth}}
    end
  end

  defp resolve_dedicated(url, auth, opts) do
    if Auth.enabled?(auth) and SafeUrl.bubbleapps_host?(url) do
      case request_once(url, [], opts, Auth.taints(auth)) do
        {:ok, %{status_code: status, headers: headers}} when status in 300..399 ->
          resolve_dedicated_redirect(url, headers, auth)

        _ ->
          {:ok, url, auth}
      end
    else
      {:ok, url, auth}
    end
  end

  defp resolve_dedicated_redirect(url, headers, auth) do
    with {:ok, location} <- redirect_location(url, headers, auth),
         true <- SafeUrl.https?(location) and SafeUrl.dedicated_host?(location),
         {:ok, scoped} <- Auth.rescope(auth, location) do
      {:ok, location, scoped}
    else
      _ -> {:error, unsafe_dedicated_error(url, auth)}
    end
  end

  defp fetch_bubble_page(url, auth, state, opts) do
    with {:ok, response, effective_url} <- fetch_redirects(url, auth, state, opts),
         :ok <- require_bubble_header(response.headers, effective_url, auth) do
      {:ok, %{body: response.body, url: effective_url}}
    end
  end

  defp fetch_redirects(url, auth, state, opts) do
    do_fetch_redirects(url, auth, state, opts, MapSet.new(), 0)
  end

  defp do_fetch_redirects(_url, _auth, _state, _opts, _visited, hops)
       when hops > @max_redirects do
    {:error, Error.new(:request_failed, "frontend request exceeded the redirect limit", %{})}
  end

  defp do_fetch_redirects(url, auth, state, opts, visited, hops) do
    normalized = SafeUrl.normalize(url)

    if MapSet.member?(visited, normalized) do
      {:error,
       Error.new(:request_failed, "frontend request encountered a redirect loop", %{
         url: safe(url, auth)
       })}
    else
      headers = if state == :scoped, do: Auth.headers(auth, url), else: []

      case request_once(url, headers, opts, Auth.taints(auth)) do
        {:ok, %{status_code: 200} = response} ->
          {:ok, response, url}

        {:ok, %{status_code: status, headers: response_headers}} when status in 300..399 ->
          follow_redirect(url, response_headers, auth, state, opts, visited, normalized, hops)

        {:ok, %{status_code: status}} ->
          {:error, status_error(status, url, auth)}

        {:error, %HTTP.Error{reason: :body_too_large}} ->
          {:error,
           Error.new(:body_too_large, "frontend response exceeded the configured size limit", %{
             url: safe(url, auth)
           })}

        {:error, _} ->
          {:error, Error.new(:request_failed, "frontend request failed", %{url: safe(url, auth)})}
      end
    end
  end

  defp follow_redirect(url, response_headers, auth, state, opts, visited, normalized, hops) do
    with {:ok, next} <- redirect_location(url, response_headers, auth),
         {:ok, next_state} <- redirect_state(state, auth, next) do
      do_fetch_redirects(
        next,
        auth,
        next_state,
        opts,
        MapSet.put(visited, normalized),
        hops + 1
      )
    end
  end

  defp redirect_state(:none, auth, next) do
    if SafeUrl.https?(next), do: {:ok, :none}, else: {:error, unsafe_redirect_error(next, auth)}
  end

  defp redirect_state(:scoped, auth, next) do
    if SafeUrl.https?(next) and Auth.scoped_to?(auth, next) do
      {:ok, :scoped}
    else
      {:error, unsafe_redirect_error(next, auth)}
    end
  end

  defp request_once(url, headers, opts, taints) do
    timeout = Config.apps_timeout(opts)

    HTTP.get(url, headers,
      follow_redirect: false,
      timeout: timeout,
      recv_timeout: timeout,
      max_body_length: Config.apps_max_body_length(opts),
      redact_values: taints
    )
  end

  defp redirect_location(base, headers, auth) do
    case header(headers, "location") do
      location when is_binary(location) and location != "" ->
        case SafeUrl.resolve(base, location) do
          {:ok, url} ->
            {:ok, url}

          {:error, _} ->
            {:error,
             Error.new(:request_failed, "frontend redirect location is invalid", %{
               url: SafeUrl.safe(location, Auth.taints(auth))
             })}
        end

      _ ->
        {:error,
         Error.new(:request_failed, "frontend redirect had no location", %{
           url: safe(base, auth)
         })}
    end
  end

  defp dynamic_url(page, auth) do
    case Parser.extract_dynamic_js_url(page) do
      {:ok, url} ->
        if SafeUrl.userinfo?(url) or not SafeUrl.https?(url) do
          {:error,
           Error.new(
             :parse_failed,
             "dynamic app payload URL must be an HTTPS URL without userinfo",
             %{}
           )}
        else
          {:ok, url}
        end

      {:error, _} ->
        {:error,
         Error.new(:parse_failed, "failed to discover the dynamic app payload", %{
           url: safe(page.url, auth)
         })}
    end
  end

  defp parse_payload(body) do
    case Parser.parse_app_json(body) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      {:ok, _} ->
        {:error, Error.new(:parse_failed, "dynamic app payload is not an object", %{})}

      {:error, _} ->
        {:error, Error.new(:parse_failed, "failed to parse the dynamic app payload", %{})}
    end
  end

  defp require_bubble_header(headers, url, auth) do
    if Enum.any?(normalize_headers(headers), fn {key, _} ->
         String.starts_with?(String.downcase(key), "x-bubble")
       end) do
      :ok
    else
      {:error,
       Error.new(:not_a_bubble_app, "response is missing the x-bubble header", %{
         url: safe(url, auth)
       })}
    end
  end

  defp header(headers, name) do
    headers
    |> normalize_headers()
    |> Enum.find_value(fn {key, value} -> if String.downcase(key) == name, do: value end)
  end

  defp normalize_headers(headers) when is_map(headers),
    do: Enum.flat_map(headers, &normalize_header/1)

  defp normalize_headers(headers) when is_list(headers),
    do: Enum.flat_map(headers, &normalize_header/1)

  defp normalize_headers(_), do: []

  defp normalize_header({key, values}) when is_list(values),
    do: Enum.map(values, &{to_string(key), to_string(&1)})

  defp normalize_header({key, value}), do: [{to_string(key), to_string(value)}]
  defp normalize_header(_), do: []

  defp auth_state(auth, url) do
    if Auth.enabled?(auth) and Auth.scoped_to?(auth, url), do: :scoped, else: :none
  end

  defp status_error(401, url, auth),
    do:
      Error.new(:unauthorized, "frontend authentication failed (HTTP 401)", %{
        status: 401,
        url: safe(url, auth)
      })

  defp status_error(403, url, auth),
    do:
      Error.new(:forbidden, "frontend authorization failed (HTTP 403)", %{
        status: 403,
        url: safe(url, auth)
      })

  defp status_error(404, url, auth),
    do:
      Error.new(:not_found, "frontend request returned HTTP 404", %{
        status: 404,
        url: safe(url, auth)
      })

  defp status_error(status, url, auth),
    do:
      Error.new(:http_error, "frontend request returned HTTP #{status}", %{
        status: status,
        url: safe(url, auth)
      })

  defp safe(url, auth), do: SafeUrl.safe(url, Auth.taints(auth))

  defp unsafe_redirect_error(url, auth) do
    Error.new(
      :request_failed,
      "frontend payload redirected to an untrusted origin; provide the final URL directly",
      %{url: safe(url, auth)}
    )
  end

  defp unsafe_dedicated_error(url, auth) do
    Error.new(
      :request_failed,
      "Bubble dedicated-instance redirect was not a trusted HTTPS bubble.is URL; provide the final URL directly",
      %{url: safe(url, auth)}
    )
  end
end

defimpl Inspect, for: BubbleEx.Frontend.Fetch.Context do
  import Inspect.Algebra
  def inspect(_context, _opts), do: concat(["#BubbleEx.Frontend.Fetch.Context<redacted>"])
end
