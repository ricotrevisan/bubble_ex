defmodule BubbleEx.Frontend.Export.Bbcode do
  @moduledoc false

  @tags ~w(b i u s ul ol li url center sup color size)

  # Default split nodes retain the Phoenix target's inline vocabulary.
  # Extended nodes opt in to source alignment, superscript and safe colors.
  @inline %{
    "b" => :b,
    "i" => :i,
    "u" => :u,
    "s" => :s,
    "center" => :center,
    "sup" => :sup,
    "color" => :color,
    "size" => :size
  }

  # Tags Bubble knows that `split/1` leaves as text.
  @known ~w(url ul ol li color size font center left right justify highlight img youtube indent)

  @spec present?(term()) :: boolean()
  def present?(text) when is_binary(text) do
    Regex.match?(~r/\[(?:\/)?(?:b|i|u|s|ul|ol|li|url|center|sup|color|size)\b/i, text)
  end

  def present?(_), do: false

  @spec block?(term()) :: boolean()
  def block?(text) when is_binary(text) do
    Regex.match?(~r/\[(\/)?(?:ul|ol|center)\b/i, text)
  end

  def block?(_), do: false

  @doc """
  BBCode around dynamic values (WTF-450): `parts` are literal text
  (binaries, where tags are read) and opaque values (`{:value, term}`,
  never read for tags). Returns `{nodes, unsupported}` or `:none` when no
  literal part has a tag `split/1` renders. A node is a binary, a
  `{:value, term}` or `{tag, nodes}` for inline `:b`, `:i`, `:u`, `:s`.
  `extended: true` also emits `:center`, `:sup` and `{:color, value}` nodes;
  use `render_nodes/1` to render those safely. An opening tag pairs with
  its closing one at the same literal level, as `to_html/1` does.
  Other tags, or unpaired ones, stay text. `unsupported` lists the other
  known tags found (sorted names).
  """
  @spec split([String.t() | {:value, term()}], keyword()) :: {list(), [String.t()]} | :none
  def split(parts, opts \\ []) when is_list(parts) do
    literals = for part <- parts, is_binary(part), do: part

    inline =
      if Keyword.get(opts, :extended, false), do: @inline, else: Map.take(@inline, ~w(b i u s))

    if Enum.any?(literals, &Regex.match?(inline_tag(inline), &1)) do
      nodes = parts |> Enum.flat_map(&tokens(&1, inline)) |> nest([]) |> merge_text()
      {nodes, unsupported(literals, inline)}
    else
      :none
    end
  end

  @doc "Renders split nodes; supplied values stay escaped text, never parsed as tags."
  def render_nodes(nodes) when is_list(nodes), do: nodes |> Enum.map(&split_node/1) |> emit()

  defp split_node({:value, value}), do: {:value, to_string(value || "")}

  defp split_node({{name, attr}, children}) when name in [:color, :size],
    do: {:tag, Atom.to_string(name), attr, Enum.map(children, &split_node/1)}

  defp split_node({tag, children}),
    do: {:tag, Atom.to_string(tag), nil, Enum.map(children, &split_node/1)}

  defp split_node(text) when is_binary(text), do: {:text, text}

  defp inline_tag(inline),
    do:
      Regex.compile!(
        "\\[(\\/?)(" <> Enum.join(Map.keys(inline), "|") <> ")(?:=([^\\]]*))?\\]",
        "i"
      )

  defp tokens({:value, _} = value, _inline), do: [value]

  defp tokens(text, inline) when is_binary(text) do
    inline_tag(inline)
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn piece ->
      case Regex.run(inline_tag(inline), piece) do
        [^piece, "", name, attr] when name in ["color", "size"] -> {:open, {name, attr}, piece}
        [^piece, "", name] -> {:open, String.downcase(name), piece}
        [^piece, "/", name] -> {:close, String.downcase(name), piece}
        _ -> piece
      end
    end)
  end

  # Tokens to nodes: an opening tag pairs with its closing tag (same name,
  # counting nested ones); otherwise both stay text.
  defp nest([], acc), do: Enum.reverse(acc)

  defp nest([{:open, {name, attr}, raw} | rest], acc) when name in ["color", "size"] do
    case take_close(rest, name, 1, []) do
      {:ok, inner, rest} ->
        nest(rest, [{{Map.fetch!(@inline, name), attr}, nest(inner, [])} | acc])

      :error ->
        nest(rest, [raw | acc])
    end
  end

  defp nest([{:open, name, raw} | rest], acc) do
    case take_close(rest, name, 1, []) do
      {:ok, inner, rest} -> nest(rest, [{Map.fetch!(@inline, name), nest(inner, [])} | acc])
      :error -> nest(rest, [raw | acc])
    end
  end

  defp nest([{:close, _name, raw} | rest], acc), do: nest(rest, [raw | acc])
  defp nest([token | rest], acc), do: nest(rest, [token | acc])

  defp take_close([], _name, _depth, _acc), do: :error

  defp take_close([{:close, name, _} | rest], name, 1, acc), do: {:ok, Enum.reverse(acc), rest}

  defp take_close([{:close, name, _} = t | rest], name, depth, acc),
    do: take_close(rest, name, depth - 1, [t | acc])

  defp take_close([{:open, {name, _}, _} = t | rest], name, depth, acc),
    do: take_close(rest, name, depth + 1, [t | acc])

  defp take_close([{:open, name, _} = t | rest], name, depth, acc),
    do: take_close(rest, name, depth + 1, [t | acc])

  defp take_close([t | rest], name, depth, acc), do: take_close(rest, name, depth, [t | acc])

  # Adjacent texts as one; empty texts dropped.
  defp merge_text(nodes) do
    nodes
    |> Enum.map(fn
      {:value, _} = value -> value
      {tag, children} -> {tag, merge_text(children)}
      text -> text
    end)
    |> Enum.chunk_by(&is_binary/1)
    |> Enum.flat_map(fn
      [text | _] = texts when is_binary(text) -> [IO.iodata_to_binary(texts)]
      nodes -> nodes
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp unsupported(literals, inline) do
    for text <- literals,
        [_, name] <- Regex.scan(~r/\[\/?([a-z0-9]+)(?:=[^\]]*)?\]/i, text),
        name = String.downcase(name),
        name in @known and not Map.has_key?(inline, name),
        uniq: true do
      name
    end
    |> Enum.sort()
  end

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
      match = Regex.run(~r/\A(url|color|size)=([^\]]+)\]/i, rest, capture: :all_but_first) ->
        [name, attr] = match
        {:ok, String.downcase(name), attr, binary_slice_after(rest, name <> "=" <> attr <> "]")}

      match = Regex.run(~r/\A(b|i|u|s|ul|ol|li|url|center|sup)\]/i, rest, capture: :all_but_first) ->
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

  defp emit([]), do: ""

  # A trailing line inside an aligned block and the following blank line
  # are block boundaries in Bubble's HTML, not three inline line breaks.
  defp emit([{:tag, "center", _attr, children} = node, {:text, "\n\n" <> rest} | tail]) do
    case terminal_block_line(children) do
      {:ok, children} ->
        ~s(<div align="center">#{emit(children)}<br></div><div></div>\n) <>
          emit([{:text, rest} | tail])

      :none ->
        emit_node(node) <> emit([{:text, "\n\n" <> rest} | tail])
    end
  end

  # A line break next to a list is a block boundary, not a line: the one
  # before a list opens, the one after it closes, and those between its
  # items stay whitespace (frozen case bpwipyqn).
  defp emit([{:text, text}, {:tag, list, _, _} = node | rest]) when list in ~w(ul ol) do
    case String.split_at(text, -1) do
      {before, "\n"} -> emit_node({:text, before}) <> "\n" <> emit([node | rest])
      _ -> emit_node({:text, text}) <> emit([node | rest])
    end
  end

  defp emit([{:tag, list, _, _} = node, {:text, "\n" <> text} | rest]) when list in ~w(ul ol),
    do: emit_node(node) <> "\n" <> emit([{:text, text} | rest])

  defp emit([node | rest]), do: emit_node(node) <> emit(rest)

  defp terminal_block_line(nodes) do
    case List.pop_at(nodes, -1) do
      {{:text, text}, before} ->
        if String.ends_with?(text, "\n") do
          {:ok, before ++ [{:text, String.slice(text, 0..-2//1)}, :block_line]}
        else
          :none
        end

      {{:tag, name, attr, children}, before} ->
        case terminal_block_line(children) do
          {:ok, children} -> {:ok, before ++ [{:tag, name, attr, children}]}
          :none -> :none
        end

      _ ->
        :none
    end
  end

  defp list_items(children) do
    Enum.map(children, fn
      {:text, text} = node -> if String.trim(text) == "", do: {:whitespace, text}, else: node
      node -> node
    end)
  end

  defp emit_node(:block_line), do: "<div></div>\n"
  defp emit_node({:whitespace, text}), do: text
  defp emit_node({:value, value}), do: escape(value)
  defp emit_node({:text, text}), do: text |> escape() |> line_breaks()

  defp emit_node({:tag, "b", _attr, children}), do: wrap("strong", children)
  defp emit_node({:tag, "i", _attr, children}), do: wrap("em", children)
  defp emit_node({:tag, "u", _attr, children}), do: wrap("u", children)
  defp emit_node({:tag, "s", _attr, children}), do: wrap("s", children)
  defp emit_node({:tag, "ul", _attr, children}), do: wrap("ul", list_items(children))
  defp emit_node({:tag, "ol", _attr, children}), do: wrap("ol", list_items(children))
  defp emit_node({:tag, "li", _attr, children}), do: wrap("li", children)

  defp emit_node({:tag, "center", _attr, children}),
    do: ~s(<div style="text-align: center">#{emit(children)}</div>)

  defp emit_node({:tag, "sup", _attr, children}), do: wrap("sup", children)

  defp emit_node({:tag, "color", attr, children}) do
    if is_binary(attr) and Regex.match?(~r/\A#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})\z/i, attr),
      do: ~s(<span style="color: #{attr}">#{emit(children)}</span>),
      else: emit(children)
  end

  defp emit_node({:tag, "size", size, children}) do
    if size in ~w(1 2 3 4 5 6 7),
      do: ~s(<font size="#{size}">#{emit(children)}</font>),
      else: emit(children)
  end

  defp emit_node({:tag, "url", attr, children}) do
    href = safe_href(attr) || safe_href(plain_text(children))

    if href do
      ~s(<a href="#{escape(href)}" target="_blank">#{emit(children)}</a>)
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

  defp line_breaks(text), do: String.replace(text, ~r/\r\n|\r|\n/, "<br>")

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
