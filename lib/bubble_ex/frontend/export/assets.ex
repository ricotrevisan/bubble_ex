defmodule BubbleEx.Frontend.Export.Assets do
  @moduledoc false

  alias BubbleEx.{Config, HTTP}
  alias BubbleEx.Frontend.{Auth, SafeUrl}
  alias BubbleEx.Frontend.Fetch.Context
  alias BubbleEx.Frontend.Normalized.Node

  @max_redirects 5

  @content_types %{
    "png" => "png",
    "jpeg" => "jpg",
    "jpg" => "jpg",
    "gif" => "gif",
    "webp" => "webp",
    "svg" => "svg",
    "woff2" => "woff2",
    "woff" => "woff"
  }

  @spec collect(Node.t() | [Node.t()], keyword()) :: {%{optional(String.t()) => map()}, [map()]}
  def collect(nodes, opts) when is_list(nodes) do
    state = %{assets: %{}, findings: [], cache: %{}}

    state =
      nodes
      |> Enum.flat_map(&asset_nodes/1)
      |> Enum.reduce(state, &collect_one(&1, &2, opts))

    {state.assets, state.findings |> Enum.reverse() |> redact_findings(opts)}
  end

  def collect(%Node{} = node, opts), do: collect([node], opts)

  defp collect_one(node, state, opts) do
    case resolved_src(node) do
      url when is_binary(url) and url != "" -> collect_url(node, url, state, opts)
      _ -> state
    end
  end

  defp collect_url(node, raw_url, state, opts) do
    case resolve_asset_url(raw_url, opts) do
      {:ok, url} ->
        key = cache_key(url)

        case Map.fetch(state.cache, key) do
          {:ok, outcome} -> apply_outcome(node, outcome, state)
          :error -> download_and_cache(node, raw_url, url, key, state, opts)
        end

      {:error, finding} ->
        assets =
          if authenticated_asset_mode?(opts),
            do: Map.put(state.assets, node.exporter_id, %{failed?: true}),
            else: state.assets

        %{state | assets: assets, findings: [finding | state.findings]}
    end
  end

  defp download_and_cache(node, raw_url, url, key, state, opts) do
    protected? = protected_asset?(url, opts)
    outcome = download(raw_url, url, protected?, opts)
    state = %{state | cache: Map.put(state.cache, key, {outcome, protected?})}
    apply_outcome(node, {outcome, protected?}, state)
  end

  defp apply_outcome(%Node{kind: :icon} = node, {{:ok, asset}, _protected?}, state) do
    fragment = node.attributes["asset_fragment"]

    case sanitize_icon_sprite(asset.bytes, fragment) do
      {:ok, bytes} ->
        sanitized = asset_record(asset.url, bytes, [{"content-type", "image/svg+xml"}])
        %{state | assets: Map.put(state.assets, node.exporter_id, sanitized)}

      :error ->
        finding =
          asset_finding(asset.url, "icon sprite did not contain a safe Font Awesome symbol")
          |> Map.put("refs", [node.exporter_id])

        %{state | findings: [finding | state.findings]}
    end
  end

  defp apply_outcome(node, {{:ok, asset}, _protected?}, state) do
    %{state | assets: Map.put(state.assets, node.exporter_id, asset)}
  end

  defp apply_outcome(node, {{:error, finding}, protected?}, state) do
    assets =
      if protected? do
        Map.put(state.assets, node.exporter_id, %{failed?: true})
      else
        state.assets
      end

    findings = if finding in state.findings, do: state.findings, else: [finding | state.findings]
    %{state | assets: assets, findings: findings}
  end

  defp asset_nodes(%Node{kind: kind} = node) when kind in [:image, :icon], do: [node]
  defp asset_nodes(%Node{children: children}), do: Enum.flat_map(children, &asset_nodes/1)

  defp resolved_src(%Node{content: %{"src" => %{resolved: url}}}), do: url
  defp resolved_src(%Node{content: %{"src" => %{"resolved" => url}}}), do: url
  defp resolved_src(%Node{attributes: %{"asset_src" => url}}), do: url
  defp resolved_src(_), do: nil

  defp resolve_asset_url(raw_url, opts) do
    cond do
      local_asset_configured?(raw_url, opts) ->
        {:ok, raw_url}

      http?(raw_url) and not SafeUrl.userinfo?(raw_url) ->
        {:ok, raw_url}

      http?(raw_url) ->
        {:error, asset_finding(raw_url, "asset URL must not contain userinfo")}

      match?(%Context{}, Keyword.get(opts, :fetch_context)) ->
        %Context{page_url: page_url} = Keyword.fetch!(opts, :fetch_context)

        case SafeUrl.resolve(page_url, raw_url) do
          {:ok, url} -> {:ok, url}
          {:error, _} -> {:error, asset_finding(raw_url, "asset URL is invalid")}
        end

      true ->
        {:error, asset_finding(raw_url, "asset is not a public HTTP URL")}
    end
  end

  defp cache_key(url) do
    if http?(url), do: SafeUrl.normalize(url), else: url
  end

  defp download(raw_url, url, protected?, opts) do
    case local_asset(raw_url, url, opts) do
      {:ok, bytes} -> store_or_reject(url, bytes, [], Config.frontend_max_asset_bytes(opts))
      :none -> if protected?, do: fetch_protected(url, opts), else: fetch_public(url, opts)
    end
  end

  defp local_asset_configured?(url, opts) do
    files = Keyword.get(opts, :asset_files, %{})
    Map.has_key?(files, url) or Map.has_key?(files, strip_query(url))
  end

  defp local_asset(raw_url, resolved_url, opts) do
    files = Keyword.get(opts, :asset_files, %{})

    value =
      files[raw_url] || files[strip_query(raw_url)] || files[resolved_url] ||
        files[strip_query(resolved_url)]

    case value do
      path when is_binary(path) ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, _} -> :none
        end

      bytes when is_binary(bytes) ->
        {:ok, bytes}

      _ ->
        :none
    end
  end

  defp strip_query(url) do
    case String.split(url, "?", parts: 2) do
      [base, _] -> base
      [base] -> base
    end
  end

  defp authenticated_asset_mode?(opts) do
    case {Keyword.get(opts, :asset_access, :public), Keyword.get(opts, :fetch_context)} do
      {:same_origin, %Context{auth: auth}} -> Auth.enabled?(auth)
      _ -> false
    end
  end

  defp credential_taints(opts) do
    case Keyword.get(opts, :fetch_context) do
      %Context{auth: auth} -> Auth.taints(auth)
      _ -> []
    end
  end

  defp redact_findings(findings, opts), do: redact_term(findings, credential_taints(opts))

  defp redact_term(value, taints) when is_binary(value) do
    Enum.reduce(taints, value, fn
      taint, acc when is_binary(taint) and taint != "" -> String.replace(acc, taint, "[REDACTED]")
      _, acc -> acc
    end)
  end

  defp redact_term(value, taints) when is_list(value),
    do: Enum.map(value, &redact_term(&1, taints))

  defp redact_term(value, taints) when is_map(value) do
    Map.new(value, fn {key, item} -> {redact_term(key, taints), redact_term(item, taints)} end)
  end

  defp redact_term(value, _taints), do: value

  defp protected_asset?(url, opts) do
    case {Keyword.get(opts, :asset_access, :public), Keyword.get(opts, :fetch_context)} do
      {:same_origin, %Context{auth: auth}} ->
        Auth.enabled?(auth) and SafeUrl.https?(url) and Auth.scoped_to?(auth, url)

      _ ->
        false
    end
  end

  defp fetch_public(url, opts) do
    timeout = Config.frontend_asset_timeout(opts)
    max_bytes = Config.frontend_max_asset_bytes(opts)

    case HTTP.get(url, [],
           recv_timeout: timeout,
           timeout: timeout,
           max_body_length: max_bytes,
           bounded_body: true,
           redact_values: credential_taints(opts)
         ) do
      {:ok, %{status_code: 200, body: body, headers: headers}} ->
        store_or_reject(url, body, headers, max_bytes)

      {:ok, %{status_code: status}} ->
        {:error, asset_finding(url, "asset download returned HTTP #{status}")}

      {:error, %HTTP.Error{reason: :body_too_large}} ->
        {:error, asset_finding(url, "asset exceeded max_asset_bytes")}

      {:error, _} ->
        {:error, asset_finding(url, "asset download failed")}
    end
  end

  defp fetch_protected(url, opts) do
    %Context{auth: auth} = Keyword.fetch!(opts, :fetch_context)
    do_fetch_protected(url, auth, opts, MapSet.new(), 0)
  end

  defp do_fetch_protected(_url, _auth, _opts, _visited, hops) when hops > @max_redirects do
    {:error, asset_finding(nil, "asset redirect limit exceeded")}
  end

  defp do_fetch_protected(url, auth, opts, visited, hops) do
    normalized = SafeUrl.normalize(url)

    if MapSet.member?(visited, normalized) do
      {:error, asset_finding(url, "asset redirect loop detected")}
    else
      timeout = Config.frontend_asset_timeout(opts)
      max_bytes = Config.frontend_max_asset_bytes(opts)

      case HTTP.get(url, Auth.headers(auth, url),
             follow_redirect: false,
             recv_timeout: timeout,
             timeout: timeout,
             max_body_length: max_bytes,
             bounded_body: true,
             redact_values: Auth.taints(auth)
           ) do
        {:ok, %{status_code: 200, body: body, headers: headers}} ->
          store_or_reject(url, body, headers, max_bytes)

        {:ok, %{status_code: status, headers: headers}} when status in 300..399 ->
          follow_protected_redirect(url, headers, auth, opts, visited, normalized, hops)

        {:ok, %{status_code: status}} ->
          {:error, asset_finding(url, "asset download returned HTTP #{status}")}

        {:error, %HTTP.Error{reason: :body_too_large}} ->
          {:error, asset_finding(url, "asset exceeded max_asset_bytes")}

        {:error, _} ->
          {:error, asset_finding(url, "asset download failed")}
      end
    end
  end

  defp follow_protected_redirect(url, headers, auth, opts, visited, normalized, hops) do
    with location when is_binary(location) <- header(headers, "location"),
         {:ok, next} <- SafeUrl.resolve(url, location),
         true <- SafeUrl.https?(next) and Auth.scoped_to?(auth, next) do
      do_fetch_protected(next, auth, opts, MapSet.put(visited, normalized), hops + 1)
    else
      _ -> {:error, asset_finding(url, "asset redirect left the authenticated origin")}
    end
  end

  defp sanitize_icon_sprite(bytes, fragment)
       when is_binary(bytes) and is_binary(fragment) do
    with true <- Regex.match?(~r/^fa-[a-z0-9]+(?:-[a-z0-9]+)*$/, fragment),
         regex =
           Regex.compile!(
             "<symbol\\s+id=\\\"#{Regex.escape(fragment)}\\\"\\s+viewBox=\\\"([^\\\"]+)\\\"[^>]*>(.*?)</symbol>",
             "s"
           ),
         [_, view_box, body] <- Regex.run(regex, bytes),
         true <- safe_view_box?(view_box),
         {:ok, paths} <- sanitize_icon_paths(body) do
      {:ok,
       [
         ~s(<svg xmlns="http://www.w3.org/2000/svg">),
         ~s(<symbol id="#{fragment}" viewBox="#{view_box}">),
         paths,
         "</symbol></svg>"
       ]
       |> IO.iodata_to_binary()}
    else
      _ -> :error
    end
  end

  defp sanitize_icon_sprite(_bytes, _fragment), do: :error

  defp safe_view_box?(view_box) do
    parts = String.split(view_box, ~r/\s+/, trim: true)
    length(parts) == 4 and Enum.all?(parts, &Regex.match?(~r/^-?(?:\d+(?:\.\d+)?|\.\d+)$/, &1))
  end

  defp sanitize_icon_paths(body) do
    path_regex = ~r/<path\b[^>]*\/>/
    tags = Regex.scan(path_regex, body) |> Enum.map(&hd/1)
    remainder = Regex.replace(path_regex, body, "") |> String.trim()

    if tags != [] and remainder == "" do
      tags
      |> Enum.reduce_while({:ok, []}, fn tag, {:ok, paths} ->
        case Regex.run(~r/\bd="([^\"]+)"/, tag) do
          [_, data] ->
            if Regex.match?(~r/^[0-9eE.,+\-\sMmZzLlHhVvCcSsQqTtAa]+$/, data),
              do: {:cont, {:ok, [~s(<path fill="currentColor" d="#{data}"/>) | paths]}},
              else: {:halt, :error}

          _ ->
            {:halt, :error}
        end
      end)
      |> case do
        {:ok, paths} -> {:ok, Enum.reverse(paths)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp store_or_reject(url, body, headers, max_bytes) when is_binary(body) do
    cond do
      content_length(headers) > max_bytes ->
        {:error, asset_finding(url, "asset exceeded max_asset_bytes")}

      byte_size(body) > max_bytes ->
        {:error, asset_finding(url, "asset exceeded max_asset_bytes")}

      unexpected_content_type?(headers) ->
        {:error, asset_finding(url, "asset returned an unexpected content type")}

      true ->
        {:ok, asset_record(url, body, headers)}
    end
  end

  defp store_or_reject(url, _body, _headers, _max_bytes),
    do: {:error, asset_finding(url, "asset download returned an invalid body")}

  defp content_length(headers) do
    case header(headers, "content-length") do
      nil ->
        0

      value ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> length
          _ -> 0
        end
    end
  end

  defp unexpected_content_type?(headers) do
    case content_type(headers) do
      nil ->
        false

      type ->
        type = String.downcase(type)

        String.starts_with?(type, "text/html") or
          not (String.starts_with?(type, "image/") or
                 String.starts_with?(type, "font/") or
                 String.starts_with?(type, "application/font") or
                 String.starts_with?(type, "application/octet-stream"))
    end
  end

  defp asset_record(url, body, headers) do
    hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    name = hashed_name(hash, extension(headers, url))
    %{path: "assets/" <> name, bytes: body, sha256: hash, url: SafeUrl.safe(url)}
  end

  defp hashed_name(hash, nil), do: hash
  defp hashed_name(hash, ext), do: hash <> "." <> ext

  defp http?(url), do: String.starts_with?(url, "http://") or String.starts_with?(url, "https://")

  defp extension(headers, url) do
    headers
    |> content_type()
    |> ext_from_content_type()
    |> Kernel.||(ext_from_url(url))
  end

  defp content_type(headers), do: header(headers, "content-type")

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: header_value(value)
    end)
  end

  defp header_value([first | _]), do: to_string(first)
  defp header_value(value), do: to_string(value)

  defp ext_from_content_type(ctype) when is_binary(ctype) do
    Enum.find_value(@content_types, fn {needle, ext} ->
      if String.contains?(String.downcase(ctype), needle), do: ext
    end)
  end

  defp ext_from_content_type(_), do: nil

  defp ext_from_url(url) do
    path = url |> URI.parse() |> Map.get(:path)
    ext_from_path(path)
  end

  defp ext_from_path(path) when is_binary(path) do
    case Path.extname(path) do
      "." <> rest -> String.downcase(rest)
      _ -> nil
    end
  end

  defp ext_from_path(_), do: nil

  defp asset_finding(nil, message) do
    %{
      "severity" => "warning",
      "type" => "asset_failure",
      "message" => message,
      "refs" => [],
      "payload" => %{}
    }
  end

  defp asset_finding(url, message) do
    %{
      "severity" => "warning",
      "type" => "asset_failure",
      "message" => message,
      "refs" => [],
      "payload" => %{"url" => SafeUrl.safe(url)}
    }
  end
end
