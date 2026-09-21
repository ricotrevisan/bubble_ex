defmodule BubbleEx.HTTP.Transport do
  @moduledoc false
  alias BubbleEx.HTTP.Destination
  alias BubbleEx.Frontend.SafeUrl

  # A request owns its socket. No per-host atoms, pools, registries or background
  # connections. The URL remains logical; only Mint's socket address is numeric.
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    opts = Req.Request.get_private(request, :bubble_ex_transport)
    deadline = Keyword.fetch!(opts, :deadline)
    timeout = min(Keyword.get(opts, :timeout, 5_000), remaining(deadline))
    resolver = Keyword.get(opts, :resolver, resolver(request, opts))

    with true <- timeout > 0,
         :ok <- socket_policy(opts),
         {:ok, {ip, host}} <- Destination.pin(URI.to_string(request.url), timeout, resolver),
         {:ok, profile} <- profile(opts),
         :ok <- socket_policy(connect_options: profile),
         :ok <- proxy_policy(request.url, profile),
         true <- remaining(deadline) > 0 do
      request =
        request
        |> scope_credentials(opts[:credential_origin])
        |> Req.Request.delete_header("host")
        |> Req.Request.delete_header("proxy-authorization")
        |> Req.Request.put_header(
          "host",
          if(String.contains?(host, ":"), do: "[#{host}]", else: host)
        )

      cond do
        request.options[:plug] -> run_plug(request)
        opts[:test_adapter] -> opts[:test_adapter].(request)
        true -> owned_connection(request, ip, host, profile, opts)
      end
    else
      false -> {request, %Req.TransportError{reason: :total_timeout}}
      {:error, reason} -> {request, %Req.TransportError{reason: reason}}
    end
  end

  defp scope_credentials(request, nil), do: request

  defp scope_credentials(request, original_url) do
    with {:ok, origin} <- SafeUrl.origin(original_url),
         true <- SafeUrl.same_origin?(origin, URI.to_string(request.url)) do
      request
    else
      _ ->
        request
        |> Req.Request.delete_header("authorization")
        |> Req.Request.delete_header("cookie")
        |> Req.Request.delete_option(:auth)
    end
  end

  defp run_plug(request) do
    if function_exported?(Req.Steps, :run_plug, 1),
      do: apply(Req.Steps, :run_plug, [request]),
      else: apply(Req.Plug, :run, [request])
  end

  # Req.Test is an in-memory transport, not an egress escape hatch. Domain names
  # have a synthetic public DNS answer there; literals and injected DNS answers
  # still pass the exact production classifier before the plug can run.
  defp resolver(request, opts) do
    if request.options[:plug] || opts[:test_adapter],
      do: fn _, _ -> {:ok, [{8, 8, 8, 8}]} end,
      else: &Destination.resolve/2
  end

  defp owned_connection(request, ip, host, profile, opts) do
    task =
      Task.async(fn ->
        try do
          connect(request, ip, host, profile, opts)
        rescue
          _ -> {request, %Req.TransportError{reason: :transport_failure}}
        end
      end)

    case Task.yield(task, remaining(opts[:deadline])) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {request, %Req.TransportError{reason: :total_timeout}}
    end
  end

  defp profile(opts) do
    case Keyword.get(opts, :finch) do
      nil ->
        {:ok, Keyword.get(opts, :connect_options, [])}

      name ->
        named_profile(name, opts)
    end
  end

  defp named_profile(name, opts) do
    case Map.fetch(Application.get_env(:bubble_ex, :http_profiles, %{}), name) do
      {:ok, profile} ->
        requested_proxy = Keyword.get(opts, :connect_options, [])[:proxy]

        if requested_proxy && requested_proxy != profile[:proxy],
          do: {:error, :unsafe_proxy},
          else: {:ok, profile}

      :error ->
        {:error, :unknown_http_profile}
    end
  end

  defp socket_policy(opts) do
    if opts[:unix_socket] || Keyword.get(opts, :connect_options, [])[:unix_socket],
      do: {:error, :unsafe_destination},
      else: :ok
  end

  defp proxy_policy(%URI{scheme: "http"}, opts) do
    if opts[:proxy] || opts[:proxy_headers] not in [nil, []],
      do: {:error, :unsafe_proxy},
      else: :ok
  end

  defp proxy_policy(_, opts) do
    case opts[:proxy] do
      nil ->
        if opts[:proxy_headers] in [nil, []], do: :ok, else: {:error, :unsafe_proxy}

      {scheme, host, port, proxy_opts}
      when scheme in [:http, :https] and is_binary(host) and is_integer(port) and
             is_list(proxy_opts) ->
        :ok

      _ ->
        {:error, :unsafe_proxy}
    end
  end

  defp connect(request, ip, host, profile, opts) do
    deadline = opts[:deadline]
    timeout = min(Keyword.get(opts, :timeout, 5_000), remaining(deadline))
    # Identity and certificate validation cannot be overridden by connection options.
    transport_opts =
      if request.url.scheme == "https" do
        profile
        |> Keyword.get(:transport_opts, [])
        |> Keyword.take([:cacertfile, :cacerts, :ciphers, :versions])
        |> Keyword.merge(
          timeout: timeout,
          verify: :verify_peer,
          server_name_indication: String.to_charlist(host)
        )
      else
        [timeout: timeout]
      end

    connection_opts =
      profile
      |> Keyword.take([:proxy, :proxy_headers])
      |> bound_proxy(timeout)
      |> Keyword.merge(
        hostname: host,
        protocols: [:http1],
        mode: :passive,
        transport_opts: transport_opts
      )

    connector = Keyword.get(opts, :connect, &Mint.HTTP.connect/4)
    scheme = if request.url.scheme == "https", do: :https, else: :http

    case connector.(scheme, ip, request.url.port, connection_opts) do
      {:ok, conn} ->
        try do
          send_request(conn, request, opts)
        after
          Mint.HTTP.close(conn)
        end

      {:error, reason} ->
        {request, transport_error(reason)}
    end
  end

  defp bound_proxy(opts, timeout) do
    case opts[:proxy] do
      {scheme, host, port, proxy_opts} ->
        transport =
          proxy_opts |> Keyword.get(:transport_opts, []) |> Keyword.put(:timeout, timeout)

        proxy_opts = Keyword.merge(proxy_opts, transport_opts: transport, tunnel_timeout: timeout)
        Keyword.put(opts, :proxy, {scheme, host, port, proxy_opts})

      nil ->
        opts
    end
  end

  defp send_request(conn, request, opts) do
    path = if request.url.path in [nil, ""], do: "/", else: request.url.path
    path = if request.url.query, do: path <> "?" <> request.url.query, else: path
    headers = for {name, values} <- request.headers, value <- List.wrap(values), do: {name, value}
    method = request.method |> Atom.to_string() |> String.upcase()

    case Mint.HTTP.request(conn, method, path, headers, request.body) do
      {:ok, conn, ref} -> receive_response(conn, ref, {request, Req.Response.new()}, opts)
      {:error, _conn, reason} -> {request, transport_error(reason)}
    end
  end

  defp receive_response(conn, ref, {request, _} = acc, opts) do
    timeout = min(Keyword.get(opts, :recv_timeout, 10_000), remaining(opts[:deadline]))

    if timeout <= 0 do
      {request, %Req.TransportError{reason: :total_timeout}}
    else
      case Mint.HTTP.recv(conn, 0, timeout) do
        {:ok, conn, events} ->
          continue_response(events(events, ref, acc), conn, ref, opts)

        {:error, _conn, reason, _events} ->
          {request, receive_error(reason, opts[:deadline])}
      end
    end
  end

  defp receive_error(reason, deadline) do
    error = if remaining(deadline) <= 0, do: :total_timeout, else: reason
    transport_error(error)
  end

  defp continue_response({:cont, acc}, conn, ref, opts),
    do: receive_response(conn, ref, acc, opts)

  defp continue_response({:halt, acc}, _conn, _ref, _opts), do: acc

  defp events([], _, acc), do: {:cont, acc}

  defp events([event | rest], ref, {request, response}) do
    case event do
      {:status, ^ref, status} ->
        events(rest, ref, {request, %{response | status: status}})

      {:headers, ^ref, headers} ->
        response =
          Enum.reduce(headers, response, fn {key, value}, resp ->
            %{resp | headers: Map.update(resp.headers, key, [value], &(&1 ++ [value]))}
          end)

        events(rest, ref, {request, response})

      {:data, ^ref, data} ->
        case data(request, response, data) do
          {:cont, acc} -> events(rest, ref, acc)
          {:halt, acc} -> {:halt, acc}
        end

      {:done, ^ref} ->
        {:halt, {request, response}}

      {:error, ^ref, reason} ->
        {:halt, {request, transport_error(reason)}}
    end
  end

  defp data(%{into: fun} = request, response, data) when is_function(fun, 2),
    do: fun.({:data, data}, {request, response})

  defp data(request, response, data),
    do: {:cont, {request, %{response | body: response.body <> data}}}

  defp transport_error(%{__exception__: true} = error), do: error
  defp transport_error(reason), do: %Req.TransportError{reason: reason}
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
