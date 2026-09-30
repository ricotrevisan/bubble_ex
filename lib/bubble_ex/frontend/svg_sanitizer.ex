defmodule BubbleEx.Frontend.SvgSanitizer do
  @moduledoc """
  Rebuilds an SVG image from an allowlist, so it can be served from the
  generated app's own origin (WTF-447). A Bubble app's static SVG (a logo
  set in the editor) is input: opened on its own, an SVG is a document that
  can run script, so only what an image needs is kept.

    * **Elements**: shapes, groups, gradients, clip paths, masks, patterns,
      symbols, `use`, `text` and a constrained `style`. Anything else
      (`script`, `foreignObject`, `image`, `a`, animation, filters,
      `title`, editor metadata…) is dropped with its content.
    * **Attributes**: presentation and geometry attributes only (no event
      handlers, no namespaced attributes). `href` only on `use`, and only
      to a fragment of the same file (`#id`). A value that is not plain
      text (`javascript:`, `data:`, `expression(`, `@import`, a `url(…)`
      other than `url(#id)`, any quoted string or token with a `:` or `//`
      in a value, whatever function holds it, a backslash, control
      characters) drops the
      attribute; so does a `style` attribute or element with such CSS.
    * **Output** is serialized here, not echoed: canonical element and
      attribute names, escaped values, text without characters XML does
      not allow (control characters, decoded `&#0;`), no comments, processing
      instructions or DOCTYPE (entities are never expanded), and the
      SVG namespace on the root.

  `sanitize/1` is idempotent: its output sanitizes to itself, so a stored
  copy can be checked again when it is read.
  """

  @max_bytes 5_000_000
  @max_depth 64
  @max_elements 50_000

  @elements %{
    "svg" => "svg",
    "g" => "g",
    "path" => "path",
    "rect" => "rect",
    "circle" => "circle",
    "ellipse" => "ellipse",
    "line" => "line",
    "polyline" => "polyline",
    "polygon" => "polygon",
    "defs" => "defs",
    "lineargradient" => "linearGradient",
    "radialgradient" => "radialGradient",
    "stop" => "stop",
    "clippath" => "clipPath",
    "mask" => "mask",
    "pattern" => "pattern",
    "symbol" => "symbol",
    "use" => "use",
    "text" => "text",
    "tspan" => "tspan",
    "style" => "style"
  }

  # Elements whose text content is kept (escaped). `title` and `desc` are
  # dropped: an image needs neither, and the parser keeps their text raw.
  @text_elements ~w(text tspan)

  @attributes Map.new(
                ~w(id class style d x y x1 y1 x2 y2 cx cy r rx ry fx fy fr width height
                   points fill fill-opacity fill-rule stroke stroke-width stroke-linecap
                   stroke-linejoin stroke-miterlimit stroke-dasharray stroke-dashoffset
                   stroke-opacity opacity transform offset stop-color stop-opacity clip-path
                   clip-rule mask font-family font-size font-weight font-style text-anchor
                   letter-spacing word-spacing dominant-baseline alignment-baseline
                   baseline-shift display visibility color dx dy rotate paint-order
                   vector-effect shape-rendering text-rendering overflow version),
                &{&1, &1}
              )
              |> Map.merge(%{
                "viewbox" => "viewBox",
                "gradientunits" => "gradientUnits",
                "gradienttransform" => "gradientTransform",
                "spreadmethod" => "spreadMethod",
                "clippathunits" => "clipPathUnits",
                "maskunits" => "maskUnits",
                "maskcontentunits" => "maskContentUnits",
                "patternunits" => "patternUnits",
                "patterncontentunits" => "patternContentUnits",
                "patterntransform" => "patternTransform",
                "preserveaspectratio" => "preserveAspectRatio",
                "textlength" => "textLength",
                "lengthadjust" => "lengthAdjust"
              })

  @fragment ~r/\A#[A-Za-z_][A-Za-z0-9_.:-]*\z/
  @id ~r/\A[A-Za-z_][A-Za-z0-9_.:-]*\z/

  @doc """
  The sanitized SVG, or `:error` when `bytes` is not an SVG document (one
  root `svg` element, valid UTF-8, at most 5 MB, bounded depth and size).
  """
  @spec sanitize(term()) :: {:ok, binary()} | :error
  def sanitize(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with true <- String.valid?(bytes),
         true <- String.contains?(String.downcase(bytes), "<svg"),
         {:ok, nodes} <- parse(bytes),
         [{"svg", attributes, children}] <- Enum.filter(nodes, &element?/1),
         {:ok, body, _count} <- children(children, "svg", 1, 1) do
      attrs = attributes |> attributes("svg") |> List.keydelete("xmlns", 0)

      {:ok,
       IO.iodata_to_binary([
         ~s(<svg xmlns="http://www.w3.org/2000/svg"),
         attrs_xml(attrs),
         ">",
         body,
         "</svg>"
       ])}
    else
      _ -> :error
    end
  end

  def sanitize(_bytes), do: :error

  defp element?({tag, _attributes, _children}) when is_binary(tag), do: true
  defp element?(_node), do: false

  defp parse(bytes) do
    Floki.parse_document(bytes, attributes_as_maps: false)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp children(_nodes, _parent, depth, _count) when depth > @max_depth, do: :error

  defp children(nodes, parent, depth, count) do
    Enum.reduce_while(nodes, {:ok, [], count}, fn node, {:ok, acc, count} ->
      case child(node, parent, depth, count) do
        {:ok, xml, count} when count <= @max_elements -> {:cont, {:ok, [acc, xml], count}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp child(text, parent, _depth, count) when is_binary(text) do
    if parent in @text_elements,
      do: {:ok, text |> xml_chars() |> escape(), count},
      else: {:ok, [], count}
  end

  defp child({"style", attributes, content}, _parent, _depth, count) do
    css = content |> Enum.filter(&is_binary/1) |> Enum.join() |> strip_cdata()

    if safe_css?(css) do
      attrs = attributes(attributes, "style") |> Enum.filter(&match?({"id", _}, &1))
      {:ok, ["<style", attrs_xml(attrs), ">", css, "</style>"], count + 1}
    else
      {:ok, [], count}
    end
  end

  defp child({tag, attributes, content}, _parent, depth, count) when is_binary(tag) do
    case Map.fetch(@elements, tag) do
      {:ok, name} when tag != "svg" ->
        with {:ok, body, count} <- children(content, tag, depth + 1, count + 1) do
          attrs = attributes(attributes, tag)
          {:ok, ["<", name, attrs_xml(attrs), ">", body, "</", name, ">"], count}
        end

      _ ->
        {:ok, [], count}
    end
  end

  # Comments, processing instructions, DOCTYPE and anything else.
  defp child(_node, _parent, _depth, count), do: {:ok, [], count}

  defp attributes(attributes, tag) do
    attributes
    |> Enum.flat_map(fn {key, value} -> attribute(String.downcase(key), value, tag) end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp attribute(key, value, "use") when key in ["href", "xlink:href"] do
    if Regex.match?(@fragment, value), do: [{"href", value}], else: []
  end

  defp attribute("id", value, _tag),
    do: if(Regex.match?(@id, value), do: [{"id", value}], else: [])

  defp attribute("style", value, _tag),
    do: if(safe_css?(value), do: [{"style", value}], else: [])

  defp attribute(key, value, _tag) do
    case Map.fetch(@attributes, key) do
      {:ok, name} -> if safe_value?(value) and safe_tokens?(value), do: [{name, value}], else: []
      :error -> []
    end
  end

  defp strip_cdata(css) do
    css
    |> String.trim()
    |> String.replace_prefix("<![CDATA[", "")
    |> String.replace_suffix("]]>", "")
  end

  # CSS of a style element or attribute: rules and declarations only, no
  # at-rules, escapes, markup or references outside the file.
  defp safe_css?(css) when is_binary(css) and byte_size(css) <= 200_000 do
    safe_value?(css) and not String.contains?(css, ["@", "<", ">", "&", "\\", "/*", "*/"]) and
      safe_declarations?(css)
  end

  defp safe_css?(_css), do: false

  defp safe_value?(value) when is_binary(value) do
    compact = value |> String.downcase() |> String.replace(~r/\s+/u, "")

    String.valid?(value) and not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, value) and
      xml_chars(value) == value and
      not String.contains?(value, "\\") and
      not String.contains?(compact, [
        "javascript:",
        "vbscript:",
        "data:",
        "expression(",
        "@import",
        "-moz-binding",
        "behavior:"
      ]) and
      local_urls?(compact)
  end

  defp safe_value?(_value), do: false

  # No URL whatever function holds it (`image("…")`, `cross-fade(…, "…")`,
  # `image-set(…)`, `src(…)`, one not invented yet): in every declaration
  # value, no quoted string and no unquoted token has a `:` or `//` (a
  # scheme, absolute or protocol-relative URL). `url(#id)` is a token
  # `#id`. The property name before a declaration's first `:` (or a
  # selector's pseudo-class) is not a value.
  defp safe_declarations?(css) do
    css
    |> String.split(~r/[;{}]/)
    |> Enum.all?(fn declaration ->
      case String.split(declaration, ":", parts: 2) do
        [_property, value] -> safe_tokens?(value)
        [other] -> safe_tokens?(other)
      end
    end)
  end

  @quoted ~r/"[^"]*"|'[^']*'/

  # A CSS value (or a presentation attribute's): its strings and tokens.
  defp safe_tokens?(value) do
    rest = Regex.replace(@quoted, value, " ")

    not String.contains?(rest, ["\"", "'"]) and
      @quoted |> Regex.scan(value) |> List.flatten() |> Enum.all?(&safe_token?/1) and
      rest |> String.split(~r/[\s,()]+/u, trim: true) |> Enum.all?(&safe_token?/1)
  end

  defp safe_token?(token), do: not String.contains?(token, [":", "//"])

  # Every url(…) points at an element of the same file.
  defp local_urls?(compact) do
    compact
    |> String.split("url(")
    |> Enum.drop(1)
    |> Enum.all?(&Regex.match?(~r/\A["']?#[a-z_][a-z0-9_.:-]*["']?\)/, &1))
  end

  defp attrs_xml(attrs) do
    Enum.map(attrs, fn {key, value} -> [" ", key, "=\"", escape(value), "\""] end)
  end

  # Only characters XML allows: text (entities decoded by the parser, as
  # `&#0;`) loses control characters, noncharacters and surrogates.
  defp xml_chars(text) do
    for <<c::utf8 <- text>>, xml_char?(c), into: "", do: <<c::utf8>>
  end

  defp xml_char?(c) when c in [0x9, 0xA, 0xD], do: true
  defp xml_char?(c) when c in 0x20..0xD7FF, do: true
  defp xml_char?(c) when c in 0xE000..0xFFFD, do: true
  defp xml_char?(c) when c in 0x10000..0x10FFFF, do: true
  defp xml_char?(_c), do: false

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
