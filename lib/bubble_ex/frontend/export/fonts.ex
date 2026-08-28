defmodule BubbleEx.Frontend.Export.Fonts do
  @moduledoc false

  alias BubbleEx.{Config, HTTP}
  alias BubbleEx.Frontend.Fetch.Context
  alias BubbleEx.Frontend.Normalized.{Node, Style}

  @google_css_host "fonts.googleapis.com"
  @google_font_host "fonts.gstatic.com"
  @max_sources 4
  @max_faces 128
  @max_fonts 32
  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

  @type asset :: %{path: String.t(), bytes: binary(), sha256: String.t(), url: String.t()}

  @spec discover(String.t(), String.t()) :: [String.t()]
  def discover(html, base_url) when is_binary(html) and is_binary(base_url) do
    (google_config_urls(html) ++ stylesheet_links(html, base_url))
    |> Enum.filter(&allowed_css_url?/1)
    |> Enum.uniq()
    |> Enum.take(@max_sources)
  rescue
    _ -> []
  end

  def discover(_html, _base_url), do: []

  @spec collect([Node.t()], [Style.t()], keyword()) :: {String.t(), [asset()], [map()]}
  def collect(nodes, styles, opts) when is_list(nodes) and is_list(styles) do
    sources = font_sources(opts)
    used = used_faces(nodes, styles)

    if sources == [] or map_size(used) == 0 do
      {"", [], []}
    else
      state = %{assets: %{}, blocks: [], findings: [], fetched: MapSet.new(), total_bytes: 0}

      state =
        sources
        |> Enum.take(@max_sources)
        |> Enum.reduce(state, &collect_source(&1, &2, used, opts))
        |> ensure_face_finding(List.first(sources))

      css = state.blocks |> Enum.reverse() |> Enum.join("\n")
      assets = state.assets |> Map.values() |> Enum.sort_by(& &1.path)
      findings = state.findings |> Enum.reverse() |> Enum.uniq()
      {css, assets, findings}
    end
  end

  defp font_sources(opts) do
    case Keyword.get(opts, :fetch_context) do
      %Context{font_sources: sources} when is_list(sources) ->
        sources |> Enum.filter(&allowed_css_url?/1) |> Enum.uniq()

      _ ->
        []
    end
  end

  defp google_config_urls(html) do
    regex =
      ~r/(?:["']google["']|google)\s*:\s*\{.*?(?:["']families["']|families)\s*:\s*\[(?<families>.*?)\]/is

    regex
    |> Regex.scan(html, capture: :all_names)
    |> Enum.flat_map(fn [body] -> quoted_strings(body) end)
    |> Enum.filter(&valid_google_family_spec?/1)
    |> Enum.uniq()
    |> case do
      [] -> []
      families -> [google_css_url(families)]
    end
  end

  defp quoted_strings(body) do
    ~r/"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'/s
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn captures -> Enum.find(captures, &(&1 != "")) || "" end)
    |> Enum.map(&unescape_js_string/1)
  end

  defp unescape_js_string(value) do
    value
    |> String.replace("\\\"", "\"")
    |> String.replace("\\'", "'")
    |> String.replace("\\\\", "\\")
  end

  defp valid_google_family_spec?(value) do
    is_binary(value) and byte_size(value) in 1..160 and
      Regex.match?(~r/\A[A-Za-z0-9 ._+,:-]+\z/, value)
  end

  defp google_css_url(families) do
    encoded = families |> Enum.join("|") |> URI.encode_www_form()
    "https://fonts.googleapis.com/css?family=" <> encoded
  end

  defp stylesheet_links(html, base_url) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find("link[href]")
        |> Floki.attribute("href")
        |> Enum.flat_map(&resolve_url(base_url, &1))

      _ ->
        []
    end
  end

  defp resolve_url(base, reference) do
    case BubbleEx.Frontend.SafeUrl.resolve(base, reference) do
      {:ok, url} -> [url]
      _ -> []
    end
  end

  defp collect_source(url, state, used, opts) do
    case fetch_css(url, opts) do
      {:ok, css} ->
        css
        |> face_blocks()
        |> Enum.filter(&used_face?(&1, used))
        |> Enum.take(@max_faces)
        |> Enum.reduce(state, &collect_face(&1, &2, opts))

      {:error, message} ->
        add_finding(state, url, message)
    end
  end

  defp ensure_face_finding(%{blocks: [], findings: []} = state, source) do
    add_finding(state, source, "font stylesheet did not provide a safe used face")
  end

  defp ensure_face_finding(state, _source), do: state

  defp fetch_css(url, opts) do
    max_bytes = Config.frontend_max_asset_bytes(opts)
    timeout = Config.frontend_asset_timeout(opts)

    case HTTP.get(url, [{"user-agent", @user_agent}],
           follow_redirect: false,
           timeout: timeout,
           recv_timeout: timeout,
           max_body_length: max_bytes,
           bounded_body: true,
           redact_values: credential_taints(opts)
         ) do
      {:ok, %{status_code: 200, body: body, headers: headers}} when is_binary(body) ->
        cond do
          byte_size(body) > max_bytes ->
            {:error, "font stylesheet exceeded max_asset_bytes"}

          not css_content_type?(headers) ->
            {:error, "font stylesheet returned an unexpected content type"}

          true ->
            {:ok, body}
        end

      {:ok, %{status_code: status}} ->
        {:error, "font stylesheet download returned HTTP #{status}"}

      {:error, %HTTP.Error{reason: :body_too_large}} ->
        {:error, "font stylesheet exceeded max_asset_bytes"}

      {:error, _} ->
        {:error, "font stylesheet download failed"}
    end
  end

  defp face_blocks(css) do
    ~r/@font-face\s*\{(?<body>[^}]*)\}/is
    |> Regex.scan(css, capture: :all_names)
    |> Enum.flat_map(fn [body] -> parse_face(body) end)
  end

  defp parse_face(body) do
    family = declaration(body, "font-family") |> unquote_css()
    style = declaration(body, "font-style") || "normal"
    weight = declaration(body, "font-weight")
    stretch = declaration(body, "font-stretch")
    unicode_range = declaration(body, "unicode-range")
    src = declaration(body, "src") |> woff2_url()

    if valid_family?(family) and valid_style?(style) and valid_weight?(weight) and
         valid_stretch?(stretch) and valid_unicode_range?(unicode_range) and is_binary(src) and
         allowed_font_url?(src) do
      [
        %{
          family: family,
          style: String.downcase(String.trim(style)),
          weight: String.trim(weight),
          stretch: optional_trim(stretch),
          unicode_range: optional_trim(unicode_range),
          url: src
        }
      ]
    else
      []
    end
  end

  defp declaration(body, name) do
    regex = Regex.compile!("(?:^|;)\\s*" <> Regex.escape(name) <> "\\s*:\\s*([^;]+)", "i")

    case Regex.run(regex, body, capture: :all_but_first) do
      [value] -> String.trim(value)
      _ -> nil
    end
  end

  defp unquote_css(nil), do: nil

  defp unquote_css(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.slice(1, byte_size(value) - 2) |> String.replace("\\\"", "\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        String.slice(value, 1, byte_size(value) - 2)

      true ->
        value
    end
  end

  defp woff2_url(nil), do: nil

  defp woff2_url(src) do
    regex =
      ~r/url\(\s*["']?(https:\/\/fonts\.gstatic\.com\/[^\s"')]+\.woff2(?:\?[^\s"')]+)?)["']?\s*\)\s*format\(\s*["']woff2["']\s*\)/i

    case Regex.run(regex, src, capture: :all_but_first) do
      [url] -> url
      _ -> nil
    end
  end

  defp collect_face(face, state, opts) do
    cond do
      map_size(state.assets) >= @max_fonts and not MapSet.member?(state.fetched, face.url) ->
        add_finding(state, face.url, "font asset count exceeded the safe limit")

      MapSet.member?(state.fetched, face.url) ->
        case Map.get(state.assets, face.url) do
          nil -> state
          asset -> add_face_block(state, face, asset)
        end

      true ->
        case fetch_font(face.url, state.total_bytes, opts) do
          {:ok, asset} ->
            state
            |> Map.update!(:fetched, &MapSet.put(&1, face.url))
            |> Map.update!(:assets, &Map.put(&1, face.url, asset))
            |> Map.update!(:total_bytes, &(&1 + byte_size(asset.bytes)))
            |> add_face_block(face, asset)

          {:error, message} ->
            state
            |> Map.update!(:fetched, &MapSet.put(&1, face.url))
            |> add_finding(face.url, message)
        end
    end
  end

  defp fetch_font(url, total_bytes, opts) do
    max_bytes = Config.frontend_max_asset_bytes(opts)
    timeout = Config.frontend_asset_timeout(opts)

    url
    |> HTTP.get([{"user-agent", @user_agent}],
      follow_redirect: false,
      timeout: timeout,
      recv_timeout: timeout,
      max_body_length: max_bytes,
      bounded_body: true,
      redact_values: credential_taints(opts)
    )
    |> handle_font_response(url, total_bytes, max_bytes)
  end

  defp handle_font_response(
         {:ok, %{status_code: 200, body: body, headers: headers}},
         url,
         total_bytes,
         max_bytes
       )
       when is_binary(body) do
    with :ok <- validate_font_size(body, max_bytes),
         :ok <- validate_total_font_size(body, total_bytes, max_bytes * 4),
         :ok <- validate_font_content_type(headers),
         :ok <- validate_woff2_signature(body) do
      {:ok, asset_record(url, body)}
    end
  end

  defp handle_font_response({:ok, %{status_code: status}}, _url, _total_bytes, _max_bytes),
    do: {:error, "font asset download returned HTTP #{status}"}

  defp handle_font_response(
         {:error, %HTTP.Error{reason: :body_too_large}},
         _url,
         _total_bytes,
         _max_bytes
       ),
       do: {:error, "font asset exceeded max_asset_bytes"}

  defp handle_font_response({:error, _reason}, _url, _total_bytes, _max_bytes),
    do: {:error, "font asset download failed"}

  defp validate_font_size(body, max_bytes) when byte_size(body) > max_bytes,
    do: {:error, "font asset exceeded max_asset_bytes"}

  defp validate_font_size(_body, _max_bytes), do: :ok

  defp validate_total_font_size(body, total_bytes, max_total)
       when total_bytes + byte_size(body) > max_total,
       do: {:error, "font assets exceeded the total byte limit"}

  defp validate_total_font_size(_body, _total_bytes, _max_total), do: :ok

  defp validate_font_content_type(headers) do
    if woff2_content_type?(headers),
      do: :ok,
      else: {:error, "font asset returned an unexpected content type"}
  end

  defp validate_woff2_signature(<<"wOF2", _::binary>>), do: :ok
  defp validate_woff2_signature(_body), do: {:error, "font asset was not a valid WOFF2 file"}

  defp asset_record(url, body) do
    hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    %{path: "assets/" <> hash <> ".woff2", bytes: body, sha256: hash, url: url}
  end

  defp add_face_block(state, face, asset) do
    block =
      [
        "@font-face {",
        "  font-family: #{quote_css(face.family)};",
        "  font-style: #{face.style};",
        "  font-weight: #{face.weight};",
        optional_declaration("font-stretch", face.stretch),
        "  font-display: block;",
        "  src: url(\"../#{asset.path}\") format(\"woff2\");",
        optional_declaration("unicode-range", face.unicode_range),
        "}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    Map.update!(state, :blocks, &[block | &1])
  end

  defp optional_declaration(_name, nil), do: nil
  defp optional_declaration(name, value), do: "  #{name}: #{value};"
  defp optional_trim(nil), do: nil
  defp optional_trim(value), do: String.trim(value)

  defp quote_css(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"" <> escaped <> "\""
  end

  defp used_faces(nodes, styles) do
    referenced = referenced_style_keys(nodes)

    values =
      Enum.flat_map(nodes, &style_values/1) ++
        (styles
         |> Enum.filter(&MapSet.member?(referenced, &1.map_key))
         |> Enum.flat_map(&map_style_values(&1.properties)))

    families = values |> Enum.flat_map(&family_value/1) |> MapSet.new()
    weights = values |> Enum.flat_map(&weight_value/1) |> MapSet.new() |> MapSet.put(400)

    Map.new(families, &{String.downcase(&1), weights})
  end

  defp referenced_style_keys(nodes) do
    nodes
    |> Enum.flat_map(&collect_nodes/1)
    |> Enum.flat_map(fn node ->
      case node.style do
        style when is_map(style) -> [style[:style_key] || style["style_key"]]
        _ -> []
      end
    end)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp style_values(%Node{} = node) do
    own =
      case node.style do
        style when is_map(style) -> map_style_values(style[:resolved] || style["resolved"] || %{})
        _ -> []
      end

    own ++ Enum.flat_map(node.children, &style_values/1)
  end

  defp collect_nodes(%Node{} = node), do: [node | Enum.flat_map(node.children, &collect_nodes/1)]

  defp map_style_values(map) when is_map(map) do
    [
      {:family,
       map[:font_face] || map["font_face"] || map[:font_family] || map["font_family"] ||
         map["font-family"]},
      {:weight, map[:font_weight] || map["font_weight"] || map["font-weight"]}
    ]
  end

  defp map_style_values(_), do: []

  defp family_value({:family, family}) when is_binary(family) do
    family = family |> String.trim() |> String.trim("\"") |> String.trim("'")

    if valid_family?(family) and not String.contains?(family, [",", "var("]) do
      [family]
    else
      []
    end
  end

  defp family_value(_), do: []

  defp weight_value({:weight, value}) when is_integer(value) and value in 1..1000, do: [value]

  defp weight_value({:weight, value}) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "normal" ->
        [400]

      "regular" ->
        [400]

      "bold" ->
        [700]

      numeric ->
        case Integer.parse(numeric) do
          {weight, ""} when weight in 1..1000 -> [weight]
          _ -> []
        end
    end
  end

  defp weight_value(_), do: []

  defp used_face?(face, used) do
    case Map.get(used, String.downcase(face.family)) do
      nil -> false
      weights -> Enum.any?(weights, &weight_matches?(face.weight, &1))
    end
  end

  defp weight_matches?(descriptor, desired) do
    case descriptor |> String.split(~r/\s+/, trim: true) |> Enum.map(&Integer.parse/1) do
      [{weight, ""}] -> weight == desired
      [{low, ""}, {high, ""}] -> desired in low..high
      _ -> false
    end
  end

  defp valid_family?(value) do
    is_binary(value) and byte_size(value) in 1..100 and
      Regex.match?(~r/\A[\p{L}\p{N} ._+-]+\z/u, value)
  end

  defp valid_style?(value) when is_binary(value),
    do:
      Regex.match?(
        ~r/\A(?:normal|italic|oblique(?:\s+-?\d+(?:\.\d+)?deg)?)\z/i,
        String.trim(value)
      )

  defp valid_style?(_), do: false

  defp valid_weight?(value) when is_binary(value),
    do: Regex.match?(~r/\A(?:[1-9]\d{0,3})(?:\s+[1-9]\d{0,3})?\z/, String.trim(value))

  defp valid_weight?(_), do: false

  defp valid_stretch?(nil), do: true

  defp valid_stretch?(value),
    do: Regex.match?(~r/\A[0-9.]+%(?:\s+[0-9.]+%)?\z/, String.trim(value))

  defp valid_unicode_range?(nil), do: true

  defp valid_unicode_range?(value),
    do:
      Regex.match?(
        ~r/\AU\+[0-9A-F?]+(?:-[0-9A-F]+)?(?:\s*,\s*U\+[0-9A-F?]+(?:-[0-9A-F]+)?)*\z/i,
        String.trim(value)
      )

  defp allowed_css_url?(url), do: allowed_https_host?(url, @google_css_host)
  defp allowed_font_url?(url), do: allowed_https_host?(url, @google_font_host)

  defp allowed_https_host?(url, host) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: parsed_host, userinfo: nil, port: port}
      when is_binary(scheme) and is_binary(parsed_host) ->
        String.downcase(scheme) == "https" and String.downcase(parsed_host) == host and
          port in [nil, 443]

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp allowed_https_host?(_url, _host), do: false

  defp css_content_type?(headers) do
    case content_type(headers) do
      nil -> true
      type -> String.starts_with?(String.downcase(type), "text/css")
    end
  end

  defp woff2_content_type?(headers) do
    case content_type(headers) do
      nil ->
        true

      type ->
        type = String.downcase(type)

        String.starts_with?(type, "font/woff2") or
          String.starts_with?(type, "application/font-woff2") or
          String.starts_with?(type, "application/octet-stream")
    end
  end

  defp content_type(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == "content-type", do: header_value(value)
    end)
  end

  defp header_value([first | _]), do: to_string(first)
  defp header_value(value), do: to_string(value)

  defp credential_taints(opts) do
    case Keyword.get(opts, :fetch_context) do
      %Context{auth: auth} -> BubbleEx.Frontend.Auth.taints(auth)
      _ -> []
    end
  end

  defp add_finding(state, url, message) do
    finding = %{
      "severity" => "warning",
      "type" => "asset_failure",
      "message" => message,
      "refs" => [],
      "payload" => %{
        "url" => BubbleEx.Frontend.SafeUrl.safe(url, credential_taints_from_state(state))
      }
    }

    Map.update!(state, :findings, &[finding | &1])
  end

  # Font sources are allowlisted public URLs. The state never contains auth, but
  # keep this helper explicit so findings cannot accidentally gain credentials.
  defp credential_taints_from_state(_state), do: []
end
