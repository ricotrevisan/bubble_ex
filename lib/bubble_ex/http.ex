defmodule BubbleEx.HTTP do
  @moduledoc """
  Lightweight HTTP wrapper around Req that keeps BubbleEx's tuple-based API.

  The module exposes minimal `get/3` and `post/4` helpers returning
  `{:ok, %Response{}}` or `{:error, %Error{}}`, mirroring the shape used when
  the project depended on HTTPoison.

  Requests are pooled by Req's underlying Finch adapter by default. To use a
  dedicated pool, start a named `Finch` instance in your supervision tree and set
  `config :bubble_ex, :finch, MyApp.Finch` (or pass `finch: MyApp.Finch` per call).
  """

  require Logger

  alias __MODULE__.{Error, Response}
  alias BubbleEx.Telemetry

  @type headers :: [{binary(), binary()}]
  @type options :: keyword()

  @type page_result :: %{
          body: String.t(),
          url: String.t(),
          domain: String.t(),
          bubble_id: String.t() | nil
        }

  @default_recv_timeout 10_000
  @default_max_retries 2
  @default_retry_base_delay 250
  @transient_status_codes [408, 429, 500, 502, 503, 504]

  defmodule Response do
    @moduledoc false
    @enforce_keys [:status_code, :headers, :body, :request_url]
    defstruct status_code: nil, headers: [], body: "", request_url: nil

    @type t :: %__MODULE__{
            status_code: non_neg_integer() | nil,
            headers: BubbleEx.HTTP.headers(),
            body: iodata(),
            request_url: String.t() | nil
          }
  end

  defmodule Error do
    @moduledoc false
    @enforce_keys [:reason]
    defstruct [:reason, :original]

    @type t :: %__MODULE__{reason: term(), original: term() | nil}
  end

  @spec get(String.t(), headers(), options()) :: {:ok, Response.t()} | {:error, Error.t()}
  def get(url, headers \\ [], options \\ []) do
    request(:get, url, nil, headers, options)
  end

  @spec post(String.t(), iodata(), headers(), options()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def post(url, body, headers \\ [], options \\ []) do
    request(:post, url, body, headers, options)
  end

  @spec request(atom(), String.t(), iodata() | nil, headers(), options()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def request(method, url, body, headers \\ [], options \\ []) when method in [:get, :post] do
    Telemetry.span([:http, :request], %{method: method, url: url}, fn ->
      result = do_request(method, url, body, headers, options)
      {result, request_stop_metadata(result)}
    end)
  end

  defp request_stop_metadata({:ok, %Response{status_code: status}}),
    do: %{status: status, error: nil}

  defp request_stop_metadata({:error, error}), do: %{status: nil, error: error}

  @doc false
  @spec resolve_finch(keyword()) :: term() | nil
  def resolve_finch(options) do
    Keyword.get(options, :finch) || Application.get_env(:bubble_ex, :finch)
  end

  defp do_request(method, url, body, headers, options) do
    process_options = Process.get({__MODULE__, :options}, [])
    default_options = Application.get_env(:bubble_ex, :req_options, [])

    effective_options =
      default_options
      |> merge_options(process_options)
      |> merge_options(options)

    {req_options, header_overrides, control_options} = build_request_options(effective_options)

    req_options =
      req_options
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, url)
      |> Keyword.put(:headers, header_overrides ++ headers)
      |> maybe_put_body(method, body)
      |> Keyword.put_new(:decode_body, false)
      |> Keyword.put_new(:retry, false)

    req_options =
      case resolve_finch(effective_options) do
        nil -> req_options
        finch -> Keyword.put(req_options, :finch, finch)
      end

    try do
      case Req.run(req_options) do
        {%Req.Request{} = request, %Req.Response{} = response} ->
          build_response(request, response, control_options)

        {_request, %{__exception__: true} = exception} ->
          {:error, build_error(exception)}
      end
    rescue
      exception ->
        {:error, build_error(exception)}
    end
  end

  defp build_request_options(options) do
    follow_redirect = Keyword.get(options, :follow_redirect, true)
    timeout = Keyword.get(options, :timeout)
    recv_timeout = Keyword.get(options, :recv_timeout)
    max_body_length = Keyword.get(options, :max_body_length)
    pool_timeout = Keyword.get(options, :pool_timeout)
    proxy = Keyword.get(options, :proxy)
    proxy_auth = Keyword.get(options, :proxy_auth)

    req_options =
      []
      |> maybe_put_redirect(follow_redirect)
      |> maybe_put_receive_timeout(recv_timeout)
      |> maybe_put_connect_option(:timeout, timeout)
      |> maybe_put_proxy(proxy)
      |> maybe_put_proxy_headers(proxy_auth)
      |> maybe_put_pool_timeout(pool_timeout)

    header_overrides = []

    req_options = merge_remaining_options(req_options, options)

    control_options =
      if max_body_length do
        %{max_body_length: max_body_length}
      else
        %{}
      end

    {req_options, header_overrides, control_options}
  end

  defp maybe_put_body(opts, :get, _body), do: opts
  defp maybe_put_body(opts, _method, nil), do: opts
  defp maybe_put_body(opts, _method, body), do: Keyword.put(opts, :body, body)

  defp maybe_put_redirect(opts, redirect?) when is_boolean(redirect?) do
    Keyword.put(opts, :redirect, redirect?)
  end

  defp maybe_put_receive_timeout(opts, nil), do: opts

  defp maybe_put_receive_timeout(opts, timeout) do
    Keyword.put(opts, :receive_timeout, timeout)
  end

  defp maybe_put_connect_option(opts, _key, nil), do: opts

  defp maybe_put_connect_option(opts, key, value) do
    Keyword.update(opts, :connect_options, [{key, value}], fn connect_opts ->
      Keyword.put(connect_opts, key, value)
    end)
  end

  defp maybe_put_proxy(opts, nil), do: opts

  defp maybe_put_proxy(opts, {host, port}) when is_binary(host) and is_integer(port) do
    proxy = {:http, host, port, []}
    maybe_put_connect_option(opts, :proxy, proxy)
  end

  defp maybe_put_proxy(opts, _proxy), do: opts

  defp maybe_put_proxy_headers(opts, nil), do: opts

  defp maybe_put_proxy_headers(opts, {username, password}) do
    header = {"proxy-authorization", encode_basic_auth(username, password)}

    Keyword.update(opts, :connect_options, [{:proxy_headers, [header]}], fn connect_opts ->
      Keyword.update(connect_opts, :proxy_headers, [header], fn headers ->
        [header | headers]
      end)
    end)
  end

  defp maybe_put_proxy_headers(opts, _auth), do: opts

  defp maybe_put_pool_timeout(opts, nil), do: opts

  defp maybe_put_pool_timeout(opts, timeout) do
    Keyword.put(opts, :pool_timeout, timeout)
  end

  defp merge_remaining_options(req_options, options) do
    recognized = [
      :follow_redirect,
      :timeout,
      :recv_timeout,
      :max_body_length,
      :proxy,
      :proxy_auth,
      :pool_timeout
    ]

    options
    |> Keyword.drop(recognized)
    |> Enum.reduce(req_options, fn {key, value}, acc ->
      Keyword.update(acc, key, value, fn existing -> merge_option(key, existing, value) end)
    end)
  end

  defp merge_option(:connect_options, existing, value)
       when is_list(existing) and is_list(value) do
    Keyword.merge(existing, value, fn _k, _v1, v2 -> v2 end)
  end

  defp merge_option(_key, _existing, value), do: value

  defp merge_options(defaults, overrides) do
    Keyword.merge(defaults, overrides, fn key, default, override ->
      merge_override(key, default, override)
    end)
  end

  defp merge_override(:connect_options, default, override)
       when is_list(default) and is_list(override) do
    Keyword.merge(default, override, fn _k, _v1, v2 -> v2 end)
  end

  defp merge_override(_key, _default, override), do: override

  @doc """
  Sets per-process request options.

  This is a **test-only** seam: it exists so tests can inject a `Req.Test` plug
  (`put_process_options(plug: {Req.Test, MyTest})`) without threading the plug
  through every call site. Production request options flow explicitly through
  function arguments and `BubbleEx.Config` — do not use this to configure
  requests outside of tests.
  """
  @spec put_process_options(keyword()) :: :ok
  def put_process_options(options) when is_list(options) do
    Process.put({__MODULE__, :options}, options)
    :ok
  end

  @doc """
  Clears the per-process request options set by `put_process_options/1`.
  Test-only; see that function.
  """
  @spec delete_process_options() :: :ok
  def delete_process_options do
    Process.delete({__MODULE__, :options})
    :ok
  end

  defp build_response(request, response, control_options) do
    body = response.body
    max_body_length = Map.get(control_options, :max_body_length)

    if max_body_length && is_binary(body) && byte_size(body) > max_body_length do
      {:error, %Error{reason: :body_too_large, original: :body_too_large}}
    else
      {:ok,
       %Response{
         status_code: response.status,
         headers: response.headers,
         body: body,
         request_url: URI.to_string(request.url)
       }}
    end
  end

  defp build_error(exception) do
    reason =
      cond do
        Map.has_key?(exception, :reason) -> Map.get(exception, :reason)
        function_exported?(exception.__struct__, :message, 1) -> exception
        true -> exception
      end

    %Error{reason: reason, original: exception}
  end

  defp encode_basic_auth(username, password) do
    credentials = "#{username}:#{password}"
    "Basic " <> Base.encode64(credentials)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # High-level Bubble fetch helpers
  #
  # These build on get/2,3 and post/3,4 with retries, redirect handling, and
  # Bubble-specific response interpretation, returning the unified
  # `BubbleEx.Error` type. Request timeouts and body limits come from
  # `BubbleEx.Config`.
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Fetches a Bubble app page, verifying the response is actually a Bubble app
  (carries an `x-bubble-*` header) and extracting its domain and bubble id.
  """
  @spec fetch_page(String.t(), keyword()) :: {:ok, page_result()} | {:error, BubbleEx.Error.t()}
  def fetch_page(url, opts \\ []) do
    headers = build_auth_headers(opts)
    http_opts = build_http_options(opts)

    case request_with_retry(:get, url, nil, headers, http_opts, opts) do
      {:ok, %Response{status_code: 200, headers: resp_headers, body: body, request_url: req_url}} ->
        if has_bubble_header?(resp_headers) do
          {:ok,
           %{
             body: body,
             url: req_url,
             domain: extract_domain(resp_headers),
             bubble_id: extract_bubble_id(resp_headers)
           }}
        else
          {:error,
           BubbleEx.Error.new(
             :not_a_bubble_app,
             "response is missing the x-bubble header",
             %{url: req_url}
           )}
        end

      {:ok, %Response{status_code: status, body: body}} ->
        {:error, BubbleEx.Error.from_http(status, body, %{url: url})}

      {:error, %Error{reason: reason}} ->
        {:error, request_failed(url, reason)}
    end
  end

  @doc """
  Fetches and JSON-decodes a Bubble endpoint, unwrapping the `"response"`
  envelope when present.
  """
  @spec fetch_json(String.t(), keyword()) :: {:ok, map()} | {:error, BubbleEx.Error.t()}
  def fetch_json(url, opts \\ []) do
    http_opts = build_http_options(opts)

    case request_with_retry(:get, url, nil, [], http_opts, opts) do
      {:ok, %Response{status_code: 200, body: body}} ->
        decode_json_body(body, url, unwrap: true)

      {:ok, %Response{status_code: status, body: body}} ->
        {:error, BubbleEx.Error.from_http(status, body, %{url: url})}

      {:error, %Error{reason: reason}} ->
        {:error, request_failed(url, reason)}
    end
  end

  @doc """
  Posts a body to a Bubble endpoint and JSON-decodes the response.
  """
  @spec post_json(String.t(), iodata(), headers(), keyword()) ::
          {:ok, map()} | {:error, BubbleEx.Error.t()}
  def post_json(url, body, headers \\ [], opts \\ []) do
    http_opts = build_http_options(opts)

    case request_with_retry(:post, url, body, headers, http_opts, opts) do
      {:ok, %Response{status_code: 200, body: response_body}} ->
        decode_json_body(response_body, url, unwrap: false)

      {:ok, %Response{status_code: status, body: response_body}} ->
        {:error, BubbleEx.Error.from_http(status, response_body, %{url: url})}

      {:error, %Error{reason: reason}} ->
        {:error, request_failed(url, reason)}
    end
  end

  @doc """
  Checks whether a Bubble version URL redirects (used to detect dedicated
  instances). Does not follow redirects.
  """
  @spec check_redirect(String.t(), String.t()) ::
          {:ok, %{is_redirect: boolean(), location: String.t() | nil}}
          | {:error, BubbleEx.Error.t()}
  def check_redirect(bubble_id, version) do
    url = "https://#{bubble_id}.bubbleapps.io/version-#{version}/"
    opts = [follow_redirect: false, max_retries: 0]

    case request_with_retry(:get, url, nil, [], build_http_options(opts), opts) do
      {:ok, %Response{status_code: code, headers: headers}} when code in 300..399 ->
        {:ok, %{is_redirect: true, location: extract_location_header(headers)}}

      {:ok, %Response{status_code: 200}} ->
        {:ok, %{is_redirect: false, location: nil}}

      _ ->
        {:error,
         BubbleEx.Error.new(:not_a_bubble_app, "not a valid bubble_id", %{bubble_id: bubble_id})}
    end
  end

  defp request_failed(url, reason) do
    BubbleEx.Error.new(:request_failed, "request failed: #{inspect(reason)}", %{
      url: url,
      reason: reason
    })
  end

  defp decode_json_body(body, url, unwrap: unwrap?) do
    case Jason.decode(body) do
      {:ok, decoded} when unwrap? and is_map(decoded) ->
        {:ok, Map.get(decoded, "response", decoded)}

      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error,
         BubbleEx.Error.new(:parse_failed, "failed to decode JSON response", %{
           url: url,
           reason: reason
         })}
    end
  end

  defp build_auth_headers(opts) do
    username = Keyword.get(opts, :username)
    password = Keyword.get(opts, :password)

    if username && password do
      [{"Authorization", encode_basic_auth(username, password)}]
    else
      []
    end
  end

  @doc false
  @spec build_http_options(keyword()) :: keyword()
  def build_http_options(opts) do
    base = [
      timeout: BubbleEx.Config.apps_timeout(opts),
      recv_timeout: Keyword.get(opts, :recv_timeout, @default_recv_timeout),
      follow_redirect: Keyword.get(opts, :follow_redirect, true),
      max_body_length: BubbleEx.Config.apps_max_body_length(opts)
    ]

    # Carry a per-call :finch through to the low-level request so the high-level
    # helpers honour `fetch_page(url, finch: MyApp.Finch)` and friends.
    case Keyword.get(opts, :finch) do
      nil -> base
      finch -> Keyword.put(base, :finch, finch)
    end
  end

  defp request_with_retry(method, url, body, headers, http_opts, opts) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay = Keyword.get(opts, :retry_base_delay, @default_retry_base_delay)
    do_request_with_retry(method, url, body, headers, http_opts, max_retries, base_delay, 0)
  end

  defp do_request_with_retry(
         method,
         url,
         body,
         headers,
         http_opts,
         max_retries,
         base_delay,
         attempt
       ) do
    result =
      case method do
        :get -> get(url, headers, http_opts)
        :post -> post(url, body, headers, http_opts)
      end

    if retryable_result?(result) and attempt < max_retries do
      delay = retry_delay(result, base_delay, attempt)
      Logger.debug("Retrying #{method} #{url} in #{delay}ms after attempt #{attempt + 1}")
      Process.sleep(delay)

      do_request_with_retry(
        method,
        url,
        body,
        headers,
        http_opts,
        max_retries,
        base_delay,
        attempt + 1
      )
    else
      result
    end
  end

  defp retryable_result?({:ok, %Response{status_code: status_code}}),
    do: status_code in @transient_status_codes

  defp retryable_result?({:error, %Error{}}), do: true
  defp retryable_result?(_result), do: false

  defp retry_delay({:ok, %Response{headers: headers}}, base_delay, attempt) do
    case retry_after_delay(headers) do
      nil -> exponential_delay(base_delay, attempt)
      delay -> delay
    end
  end

  defp retry_delay(_result, base_delay, attempt), do: exponential_delay(base_delay, attempt)

  defp retry_after_delay(headers) do
    headers
    |> header_values("retry-after")
    |> List.first()
    |> case do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> seconds * 1000
          _ -> nil
        end
    end
  end

  defp exponential_delay(base_delay, attempt) do
    trunc(base_delay * :math.pow(2, attempt)) + :rand.uniform(max(base_delay, 1))
  end

  defp has_bubble_header?(headers) do
    headers
    |> normalize_headers()
    |> Enum.any?(fn {key, _value} ->
      key |> String.trim() |> String.downcase() |> String.starts_with?("x-bubble")
    end)
  end

  defp extract_domain(headers) do
    headers
    |> header_values("set-cookie")
    |> Enum.find_value(fn value ->
      case Regex.run(~r/domain=([^;]+)/i, value) do
        [_, domain] -> domain
        _ -> nil
      end
    end) || ""
  end

  defp extract_bubble_id(headers) do
    headers
    |> header_values("set-cookie")
    |> Enum.find_value(fn value ->
      case Regex.run(~r/^([^=;]+)_(?:live|test|development)_/, value) do
        [_, bubble_id] -> bubble_id
        _ -> nil
      end
    end)
  end

  defp extract_location_header(headers) do
    headers |> header_values("location") |> List.first()
  end

  defp header_values(headers, name) do
    normalized_name = String.downcase(name)

    headers
    |> normalize_headers()
    |> Enum.flat_map(fn {key, value} ->
      if String.downcase(key) == normalized_name, do: [value], else: []
    end)
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {key, value} -> normalize_header_value(key, value) end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, value} -> normalize_header_value(key, value)
      _ -> []
    end)
  end

  defp normalize_headers(_headers), do: []

  defp normalize_header_value(key, values) when is_binary(key) and is_list(values) do
    Enum.flat_map(values, &normalize_header_value(key, &1))
  end

  defp normalize_header_value(key, value) when is_binary(key) and is_binary(value) do
    [{key, value}]
  end

  defp normalize_header_value(_key, _value), do: []
end
