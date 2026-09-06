defmodule BubbleEx.Frontend.Export.Bbcode do
  @moduledoc false

  @tags ~w(b i u s ul ol li url)

  @spec present?(term()) :: boolean()
  def present?(text) when is_binary(text) do
    Regex.match?(~r/\[(?:\/)?(?:b|i|u|s|ul|ol|li|url)\b/i, text)
  end

  def present?(_), do: false

  @spec to_html(String.t()) :: String.t()
  def to_html(text) when is_binary(text), do: text |> parse([]) |> emit()

  defp parse("", acc), do: Enum.reverse(acc)

  defp parse(<<"[", rest::binary>>, acc) do
    case take_open_tag(rest) do
      {:ok, name, attr, after_tag} ->
        case take_until_close(after_tag, name, 1, []) do
          {:ok, inner, rest2} ->
            parse(rest2, [{:tag, name, attr, parse(inner, [])} | acc])

          :error ->
            parse(rest, prepend_text(acc, "["))
        end

      :error ->
        parse(rest, prepend_text(acc, "["))
    end
  end

  defp parse(<<cp::utf8, rest::binary>>, acc) do
    parse(rest, prepend_text(acc, <<cp::utf8>>))
  end

  defp prepend_text([{:text, prev} | acc], chunk), do: [{:text, prev <> chunk} | acc]
  defp prepend_text(acc, chunk), do: [{:text, chunk} | acc]

  defp take_open_tag(rest) do
    cond do
      match = Regex.run(~r/\Aurl=([^\]]+)\]/i, rest, capture: :all_but_first) ->
        [attr] = match
        {:ok, "url", attr, binary_slice_after(rest, "url=" <> attr <> "]")}

      match = Regex.run(~r/\A(b|i|u|s|ul|ol|li|url)\]/i, rest, capture: :all_but_first) ->
        [name] = match
        {:ok, String.downcase(name), nil, binary_slice_after(rest, name <> "]")}

      true ->
        :error
    end
  end

  defp binary_slice_after(text, prefix) do
    size = byte_size(prefix)
    binary_part(text, size, byte_size(text) - size)
  end

  defp take_until_close("", _name, _depth, _acc), do: :error

  defp take_until_close(<<"[", rest::binary>>, name, depth, acc) do
    close = "/" <> name <> "]"
    open = name <> "]"
    open_attr = name <> "="

    cond do
      String.starts_with?(String.downcase(rest), String.downcase(close)) ->
        rest2 = binary_slice_after(rest, close)

        if depth == 1 do
          {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest2}
        else
          take_until_close(rest2, name, depth - 1, ["[/" <> name <> "]" | acc])
        end

      String.starts_with?(String.downcase(rest), String.downcase(open)) ->
        rest2 = binary_slice_after(rest, open)
        take_until_close(rest2, name, depth + 1, ["[" <> name <> "]" | acc])

      String.starts_with?(String.downcase(rest), String.downcase(open_attr)) ->
        case Regex.run(~r/\A[^\]]*\]/, rest) do
          [matched] ->
            rest2 = binary_slice_after(rest, matched)
            take_until_close(rest2, name, depth + 1, ["[" <> matched | acc])

          nil ->
            take_until_close(rest, name, depth, ["[" | acc])
        end

      true ->
        take_until_close(rest, name, depth, ["[" | acc])
    end
  end

  defp take_until_close(<<cp::utf8, rest::binary>>, name, depth, acc) do
    take_until_close(rest, name, depth, [<<cp::utf8>> | acc])
  end

  defp emit(nodes) when is_list(nodes), do: Enum.map_join(nodes, &emit_node/1)

  defp emit_node({:text, text}), do: escape(text)

  defp emit_node({:tag, "b", _attr, children}), do: wrap("strong", children)
  defp emit_node({:tag, "i", _attr, children}), do: wrap("em", children)
  defp emit_node({:tag, "u", _attr, children}), do: wrap("u", children)
  defp emit_node({:tag, "s", _attr, children}), do: wrap("s", children)
  defp emit_node({:tag, "ul", _attr, children}), do: wrap("ul", children)
  defp emit_node({:tag, "ol", _attr, children}), do: wrap("ol", children)
  defp emit_node({:tag, "li", _attr, children}), do: wrap("li", children)

  defp emit_node({:tag, "url", attr, children}) do
    href = safe_href(attr) || safe_href(plain_text(children))

    if href do
      ~s(<a href="#{escape(href)}">#{emit(children)}</a>)
    else
      emit(children)
    end
  end

  defp emit_node({:tag, name, _attr, children}) when name in @tags, do: emit(children)

  defp wrap(tag, children), do: "<#{tag}>" <> emit(children) <> "</#{tag}>"

  defp plain_text(nodes) do
    Enum.map_join(nodes, fn
      {:text, text} -> text
      {:tag, _name, _attr, children} -> plain_text(children)
    end)
  end

  defp safe_href(nil), do: nil

  defp safe_href(href) when is_binary(href) do
    trimmed = String.trim(href)

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        if String.trim(host) != "", do: trimmed

      _ ->
        nil
    end
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
