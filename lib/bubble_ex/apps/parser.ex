defmodule BubbleEx.Apps.Parser do
  @moduledoc """
  Parser module for extracting and processing data from Bubble.io applications.

  Handles parsing of HTML pages, JavaScript files, JSON data, and other formats
  returned by Bubble applications.
  """

  require Logger

  @doc """
  Extracts the dynamic JavaScript URL from a Bubble app's HTML payload.
  """
  @spec extract_dynamic_js_url(map()) :: {:ok, String.t()} | {:error, term()}
  def extract_dynamic_js_url(%{body: html_content, url: base_url}) do
    with {:ok, document} <- Floki.parse_document(html_content),
         {:ok, relative_url} <- find_dynamic_js_script(document),
         {:ok, absolute_url} <- build_absolute_url(relative_url, base_url) do
      {:ok, absolute_url}
    else
      {:error, reason} ->
        Logger.error("Failed to extract dynamic JS URL from #{base_url}: #{inspect(reason)}")
        {:error, %{phase: :discover_dynamic_js, url: base_url, reason: reason}}
    end
  end

  @doc """
  Parses the app JSON from a JavaScript payload.
  """
  @spec parse_app_json(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_app_json(js_content) do
    with {:ok, app_line} <- find_app_line(js_content),
         {:ok, json_string} <- extract_json_string_internal(app_line) do
      decode_json(json_string)
    end
  end

  @doc """
  Extracts the title from app data payload.
  """
  @spec extract_title(map()) :: String.t() | nil
  def extract_title(app_data) do
    client_safe = get_in(app_data, ["settings", "client_safe"]) || %{}

    client_safe["facebook_meta_tag_title"] ||
      client_safe["facebook_meta_tag_site_name"] ||
      client_safe["app_topdomain"]
  end

  @doc """
  Extracts bubble_id from a URL.
  """
  @spec extract_bubble_id_from_url(String.t()) :: String.t() | nil
  def extract_bubble_id_from_url(url) do
    case Regex.run(~r/^https?:\/\/([^\.]+)\.bubbleapps\.io/, url) do
      [_, bubble_id] -> bubble_id
      _ -> nil
    end
  end

  @doc """
  Parses latest changes response and converts timestamps.
  """
  @spec parse_latest_changes(map()) :: [{String.t(), map()}]
  def parse_latest_changes(changes_data) do
    Enum.map(changes_data, fn {branch, details} -> {branch, convert_change_date(details)} end)
  end

  defp convert_change_date(%{"last_change_date" => nil} = details), do: details

  defp convert_change_date(%{"last_change_date" => timestamp} = details) do
    Map.put(details, "last_change_date", DateTime.from_unix!(timestamp, :millisecond))
  end

  defp convert_change_date(details), do: details

  @doc """
  Extracts plugin information from app payload.
  """
  @spec extract_plugins(map()) :: {:ok, map() | :no_plugins} | {:error, atom()}
  def extract_plugins(app_data) do
    case get_in(app_data, ["settings", "client_safe", "plugins"]) do
      nil ->
        Logger.info("No plugins found for app: #{app_data["_id"]}")
        {:ok, :no_plugins}

      plugins when is_map(plugins) ->
        filtered_plugins =
          plugins
          |> Enum.reject(fn {_key, value} -> value === true end)
          |> Enum.into(%{})

        {:ok, filtered_plugins}

      _ ->
        Logger.error("Unexpected plugins format in payload")
        {:error, :invalid_plugin_format}
    end
  end

  @doc """
  Counts the number of plugins in an app.
  """
  @spec count_plugins(map()) :: non_neg_integer()
  def count_plugins(app_data) do
    case get_in(app_data, ["settings", "client_safe", "plugins"]) do
      plugins when is_map(plugins) -> Enum.count(plugins)
      _ -> 0
    end
  end

  @doc """
  Extracts Facebook description from app data.
  """
  @spec extract_description(map()) :: String.t() | nil
  def extract_description(app_data) do
    get_in(app_data, ["settings", "client_safe", "facebook_meta_tag_title"])
  end

  @doc """
  Finds the app line in JavaScript content.
  """
  @spec find_app_line(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def find_app_line(js_content) do
    find_marker_line(js_content, 0)
  end

  @marker "const app = JSON"

  defp find_marker_line(js_content, from) do
    case :binary.match(js_content, @marker, scope: {from, byte_size(js_content) - from}) do
      :nomatch ->
        {:error, :not_found}

      {pos, _len} ->
        line = String.trim(enclosing_line(js_content, pos))

        if String.starts_with?(line, @marker) do
          {:ok, line}
        else
          # The marker occurred mid-line; keep scanning after it.
          find_marker_line(js_content, pos + byte_size(@marker))
        end
    end
  end

  defp enclosing_line(binary, pos) do
    start =
      case binary |> binary_part(0, pos) |> :binary.matches("\n") |> List.last() do
        nil -> 0
        {nl_pos, _} -> nl_pos + 1
      end

    stop =
      case :binary.match(binary, "\n", scope: {pos, byte_size(binary) - pos}) do
        :nomatch -> byte_size(binary)
        {nl_pos, _} -> nl_pos
      end

    binary_part(binary, start, stop - start)
  end

  @doc """
  Extracts and decodes the JSON string argument from a `JSON.parse(...)` app line.
  """
  @spec extract_json_string(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_json_string(app_line), do: extract_json_string_internal(app_line)

  defp find_dynamic_js_script(document) do
    case Floki.find(document, "script[src*='/package/dynamic_js']") do
      [] ->
        {:error, :dynamic_js_script_not_found}

      scripts ->
        case Floki.attribute(scripts, "src") do
          [src | _] -> {:ok, src}
          [] -> {:error, :dynamic_js_script_src_not_found}
        end
    end
  end

  defp build_absolute_url(relative_url, base_url) do
    if String.starts_with?(relative_url, "http") do
      {:ok, relative_url}
    else
      absolutize(relative_url, URI.parse(base_url), base_url)
    end
  end

  defp absolutize(relative_url, %URI{scheme: scheme, host: host, port: port}, _base_url)
       when scheme != nil and host != nil do
    port_part = if port, do: ":#{port}", else: ""
    base_hostname = "#{scheme}://#{host}#{port_part}"
    separator = if String.starts_with?(relative_url, "/"), do: "", else: "/"
    {:ok, "#{base_hostname}#{separator}#{relative_url}"}
  end

  defp absolutize(_relative_url, _uri, base_url), do: {:error, {:invalid_base_url, base_url}}

  defp extract_json_string_internal(js_content) do
    with {:ok, literal} <- extract_json_parse_literal(js_content) do
      decode_js_string_literal(literal)
    end
  end

  defp decode_json(json_string) do
    case Jason.decode(json_string) do
      {:ok, parsed_data} ->
        {:ok, parsed_data}

      {:error, %Jason.DecodeError{position: position} = reason} ->
        Logger.warning("JSON decode failed at position #{position}")

        {:error,
         %{
           phase: :decode_app_json,
           reason: reason,
           position: position,
           byte_size: byte_size(json_string)
         }}
    end
  end

  defp extract_json_parse_literal(js_content) do
    with {:ok, parse_pos} <- find_binary(js_content, "JSON.parse"),
         {:ok, open_paren_pos} <- find_next_byte(js_content, ?(, parse_pos),
         {:ok, quote_pos} <- find_next_non_whitespace(js_content, open_paren_pos + 1),
         {:ok, quote} <- get_quote(js_content, quote_pos),
         {:ok, end_pos} <- find_string_literal_end(js_content, quote_pos + 1, quote) do
      {:ok, binary_part(js_content, quote_pos, end_pos - quote_pos + 1)}
    end
  end

  defp find_binary(binary, pattern) do
    case :binary.match(binary, pattern) do
      {position, _length} -> {:ok, position}
      :nomatch -> {:error, :no_json_parse_found}
    end
  end

  defp find_next_byte(binary, byte, position) when position < byte_size(binary) do
    case :binary.at(binary, position) do
      ^byte -> {:ok, position}
      _ -> find_next_byte(binary, byte, position + 1)
    end
  end

  defp find_next_byte(_binary, _byte, _position), do: {:error, :no_json_parse_call_found}

  defp find_next_non_whitespace(binary, position) when position < byte_size(binary) do
    case :binary.at(binary, position) do
      char when char in [?\s, ?\t, ?\n, ?\r] -> find_next_non_whitespace(binary, position + 1)
      _ -> {:ok, position}
    end
  end

  defp find_next_non_whitespace(_binary, _position), do: {:error, :missing_json_parse_argument}

  defp get_quote(binary, position) do
    case :binary.at(binary, position) do
      quote when quote in [?\", ?'] -> {:ok, quote}
      _ -> {:error, :json_parse_argument_is_not_string_literal}
    end
  end

  defp find_string_literal_end(binary, position, quote) when position < byte_size(binary) do
    case :binary.at(binary, position) do
      ^quote -> {:ok, position}
      ?\\ -> find_string_literal_end(binary, min(position + 2, byte_size(binary)), quote)
      _ -> find_string_literal_end(binary, position + 1, quote)
    end
  end

  defp find_string_literal_end(_binary, _position, _quote),
    do: {:error, :unterminated_string_literal}

  defp decode_js_string_literal(<<quote, rest::binary>>) when quote in [?\", ?'] do
    size = byte_size(rest)

    if size > 0 && :binary.at(rest, size - 1) == quote do
      content = binary_part(rest, 0, size - 1)
      decode_js_string_content(content, [])
    else
      {:error, :unterminated_string_literal}
    end
  end

  defp decode_js_string_literal(_literal), do: {:error, :invalid_string_literal}

  defp decode_js_string_content(<<>>, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp decode_js_string_content(<<"\\", rest::binary>>, acc), do: decode_js_escape(rest, acc)

  defp decode_js_string_content(<<char::utf8, rest::binary>>, acc) do
    decode_js_string_content(rest, [<<char::utf8>> | acc])
  end

  defp decode_js_escape(<<"'", rest::binary>>, acc),
    do: decode_js_string_content(rest, ["'" | acc])

  defp decode_js_escape(<<"\"", rest::binary>>, acc),
    do: decode_js_string_content(rest, ["\"" | acc])

  defp decode_js_escape(<<"\\", rest::binary>>, acc),
    do: decode_js_string_content(rest, ["\\" | acc])

  defp decode_js_escape(<<"b", rest::binary>>, acc),
    do: decode_js_string_content(rest, [<<8>> | acc])

  defp decode_js_escape(<<"f", rest::binary>>, acc),
    do: decode_js_string_content(rest, [<<12>> | acc])

  defp decode_js_escape(<<"n", rest::binary>>, acc),
    do: decode_js_string_content(rest, ["\n" | acc])

  defp decode_js_escape(<<"r", rest::binary>>, acc),
    do: decode_js_string_content(rest, ["\r" | acc])

  defp decode_js_escape(<<"t", rest::binary>>, acc),
    do: decode_js_string_content(rest, ["\t" | acc])

  defp decode_js_escape(<<"v", rest::binary>>, acc),
    do: decode_js_string_content(rest, [<<11>> | acc])

  defp decode_js_escape(<<"\n", rest::binary>>, acc), do: decode_js_string_content(rest, acc)
  defp decode_js_escape(<<"\r\n", rest::binary>>, acc), do: decode_js_string_content(rest, acc)
  defp decode_js_escape(<<"\r", rest::binary>>, acc), do: decode_js_string_content(rest, acc)

  defp decode_js_escape(<<"0", rest::binary>>, acc),
    do: decode_js_string_content(rest, [<<0>> | acc])

  defp decode_js_escape(<<"x", high, low, rest::binary>>, acc) do
    with {:ok, codepoint} <- hex_to_integer(<<high, low>>),
         {:ok, encoded} <- encode_codepoint(codepoint) do
      decode_js_string_content(rest, [encoded | acc])
    end
  end

  defp decode_js_escape(<<"u{", rest::binary>>, acc) do
    with {hex, <<"}", remaining::binary>>} <- take_until(rest, "}"),
         {:ok, codepoint} <- hex_to_integer(hex),
         {:ok, encoded} <- encode_codepoint(codepoint) do
      decode_js_string_content(remaining, [encoded | acc])
    else
      _ -> {:error, :invalid_unicode_escape}
    end
  end

  defp decode_js_escape(<<"u", h1, h2, h3, h4, rest::binary>>, acc) do
    with {:ok, codepoint} <- hex_to_integer(<<h1, h2, h3, h4>>),
         {:ok, encoded, remaining} <- encode_unicode_escape(codepoint, rest) do
      decode_js_string_content(remaining, [encoded | acc])
    end
  end

  defp decode_js_escape(<<char::utf8, rest::binary>>, acc) do
    decode_js_string_content(rest, [<<char::utf8>> | acc])
  end

  defp decode_js_escape(<<>>, _acc), do: {:error, :unterminated_escape_sequence}

  defp encode_unicode_escape(codepoint, <<"\\u", h1, h2, h3, h4, rest::binary>>)
       when codepoint in 0xD800..0xDBFF do
    with {:ok, low_surrogate} <- hex_to_integer(<<h1, h2, h3, h4>>),
         true <- low_surrogate in 0xDC00..0xDFFF,
         {:ok, encoded} <- encode_codepoint(combine_surrogates(codepoint, low_surrogate)) do
      {:ok, encoded, rest}
    else
      _ -> {:error, :invalid_unicode_surrogate_pair}
    end
  end

  defp encode_unicode_escape(codepoint, _rest) when codepoint in 0xD800..0xDFFF,
    do: {:error, :invalid_unicode_surrogate_pair}

  defp encode_unicode_escape(codepoint, rest) do
    with {:ok, encoded} <- encode_codepoint(codepoint) do
      {:ok, encoded, rest}
    end
  end

  defp combine_surrogates(high, low) do
    0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
  end

  defp take_until(binary, delimiter) do
    case :binary.match(binary, delimiter) do
      {position, _length} ->
        head = binary_part(binary, 0, position)
        tail = binary_part(binary, position, byte_size(binary) - position)
        {head, tail}

      :nomatch ->
        :error
    end
  end

  defp hex_to_integer(hex) when byte_size(hex) > 0 and byte_size(hex) <= 6 do
    if valid_hex?(hex) do
      {:ok, String.to_integer(hex, 16)}
    else
      {:error, :invalid_hex_escape}
    end
  end

  defp hex_to_integer(_hex), do: {:error, :invalid_hex_escape}

  defp valid_hex?(hex) do
    hex
    |> :binary.bin_to_list()
    |> Enum.all?(&hex_digit?/1)
  end

  defp hex_digit?(char), do: char in ?0..?9 or char in ?a..?f or char in ?A..?F

  defp encode_codepoint(codepoint)
       when codepoint in 0..0xD7FF or codepoint in 0xE000..0x10FFFF do
    {:ok, <<codepoint::utf8>>}
  end

  defp encode_codepoint(_codepoint), do: {:error, :invalid_unicode_codepoint}
end
