defmodule BubbleEx.Frontend.Export.Html do
  @moduledoc false

  alias BubbleEx.Frontend.Normalized.Node

  @spec page_document(Node.t(), keyword()) :: String.t()
  def page_document(page, opts) do
    title = opts[:title] || page.name || "Page"
    page_css = opts[:page_css]
    markup = render_node(page, opts)

    [
      "<!DOCTYPE html>\n",
      "<html>\n",
      "<head>\n",
      "  <meta charset=\"utf-8\">\n",
      "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
      "  <title>",
      escape(title),
      "</title>\n",
      "  <link rel=\"stylesheet\" href=\"../../styles/shared.css\">\n",
      "  <link rel=\"stylesheet\" href=\"../../styles/pages/",
      escape(page_css),
      ".css\">\n",
      "</head>\n",
      "<body>\n",
      indent(markup, 1),
      "</body>\n",
      "</html>\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec catalog(String.t(), String.t(), [{String.t(), String.t()}]) :: String.t()
  def catalog(bubble_id, app_version, pages) do
    title = "#{bubble_id} (#{app_version})"

    links =
      pages
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {label, href} ->
        ["    <li><a href=\"", escape(href), "\">", escape(label), "</a></li>\n"]
      end)

    [
      "<!DOCTYPE html>\n",
      "<html>\n",
      "<head>\n",
      "  <meta charset=\"utf-8\">\n",
      "  <title>",
      escape(title),
      "</title>\n",
      "</head>\n",
      "<body>\n",
      "  <h1>",
      escape(title),
      "</h1>\n",
      "  <ul>\n",
      links,
      "  </ul>\n",
      "</body>\n",
      "</html>\n"
    ]
    |> IO.iodata_to_binary()
  end

  @spec fragment(Node.t(), keyword()) :: String.t()
  def fragment(node, opts \\ []) do
    node
    |> render_node(opts)
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  @spec render_node(Node.t(), keyword()) :: iodata()
  def render_node(%Node{} = node, opts) do
    opts = with_defaults(opts)
    do_render(node, opts)
  end

  defp with_defaults(opts) do
    opts
    |> Keyword.put_new(:expand, fn _ -> nil end)
    |> Keyword.put_new(:rewrite_href, fn _node, dest -> dest end)
    |> Keyword.put_new(:style_class, fn _ -> nil end)
  end

  defp do_render(%Node{kind: :page} = node, opts),
    do: wrap("main", node, children_html(node, opts), opts)

  defp do_render(%Node{kind: kind} = node, opts)
       when kind in [:group, :reusable_definition, :shape, :placeholder],
       do: wrap("div", node, children_html_or_empty(node, opts), opts)

  defp do_render(%Node{kind: :reusable_instance} = node, opts), do: render_instance(node, opts)

  defp do_render(%Node{kind: :text} = node, opts),
    do: wrap(text_tag(node.variant), node, escape(slot_text(node, "text", opts)), opts)

  defp do_render(%Node{kind: :button} = node, opts) do
    label = slot_text(node, "label", opts)
    body = if label == "", do: slot_text(node, "text", opts), else: label
    wrap("button", node, escape(body), opts)
  end

  defp do_render(%Node{kind: :link} = node, opts), do: render_link(node, opts)
  defp do_render(%Node{kind: :image} = node, opts), do: void("img", node, opts)
  defp do_render(%Node{kind: :input} = node, opts), do: void("input", node, opts)

  defp children_html_or_empty(%Node{kind: kind} = node, opts)
       when kind in [:group, :reusable_definition],
       do: children_html(node, opts)

  defp children_html_or_empty(_node, _opts), do: ""

  defp render_instance(node, opts) do
    inner =
      case Keyword.get(opts, :expand).(node) do
        %Node{} = definition -> children_html(definition, instance_opts(opts, node))
        _ -> ""
      end

    wrap("div", node, inner, opts)
  end

  defp instance_opts(opts, instance) do
    Keyword.put(opts, :id_prefix, instance.exporter_id)
  end

  defp children_html(%Node{children: children}, opts) do
    children
    |> Enum.map(&render_node(&1, opts))
    |> Enum.intersperse("\n")
  end

  defp render_link(node, opts) do
    wrap("a", node, escape(slot_text(node, "text", opts)), opts)
  end

  defp slot_text(node, slot, opts) do
    case resolved(node, slot) do
      value when is_binary(value) or is_number(value) ->
        to_string(value)

      _ ->
        if Keyword.get(opts, :fallback, false) and slot_present?(node, slot) do
          "[unresolved:#{slot}]"
        else
          ""
        end
    end
  end

  defp slot_present?(%Node{content: content}, slot) when is_map(content),
    do: Map.has_key?(content, slot)

  defp slot_present?(_, _), do: false

  defp text_tag(:h1), do: "h1"
  defp text_tag(:h2), do: "h2"
  defp text_tag(:h3), do: "h3"
  defp text_tag(:h4), do: "h4"
  defp text_tag(_), do: "p"

  @phrasing ~w(p h1 h2 h3 h4 button a)

  defp wrap(tag, node, inner, opts) do
    open = ["<", tag, attrs(node, tag, opts), ">"]

    cond do
      blank?(inner) ->
        [open, "</", tag, ">"]

      tag in @phrasing ->
        [open, inner, "</", tag, ">"]

      true ->
        [open, "\n", indent(inner, 1), "</", tag, ">"]
    end
  end

  defp maybe_put_bubble_id(attrs, %Node{source: %{bubble_id: id}})
       when is_binary(id) and id != "" do
    Map.put(attrs, "data-bubble-id", id)
  end

  defp maybe_put_bubble_id(attrs, _), do: attrs

  defp void(tag, node, opts) do
    ["<", tag, attrs(node, tag, opts), ">"]
  end

  defp attrs(node, tag, opts) do
    id = prefixed_id(node, opts)

    node
    |> node_attrs(tag, opts)
    |> Map.put("data-exporter-id", id)
    |> maybe_put_bubble_id(node)
    |> maybe_put_class(node, opts)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == false or v == "" end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {k, v} -> [" ", k, "=\"", escape(to_string(v)), "\""] end)
  end

  defp node_attrs(node, "img", opts) do
    src =
      case Keyword.get(opts, :assets, %{}) |> Map.get(node.exporter_id) do
        %{path: path} -> "../../" <> path
        _ -> Map.get(node.attributes, "asset_src") || resolved(node, "src") || ""
      end

    alt = resolved(node, "alt") || node.attributes["alt"] || ""
    %{"src" => src, "alt" => alt}
  end

  defp node_attrs(node, "input", _opts) do
    node.attributes
    |> Map.put_new("type", "text")
    |> Map.put("value", resolved(node, "value"))
    |> Map.put_new("placeholder", resolved(node, "placeholder"))
  end

  defp node_attrs(node, "button", _opts) do
    node.attributes
    |> Map.put("type", "button")
  end

  defp node_attrs(node, "a", opts) do
    href = link_href(node, opts)

    node.attributes
    |> Map.delete("disabled")
    |> then(fn attrs ->
      if href, do: Map.put(attrs, "href", href), else: Map.delete(attrs, "href")
    end)
  end

  defp node_attrs(node, _tag, _opts), do: node.attributes || %{}

  defp link_href(node, opts) do
    cond do
      node.attributes["disabled"] == true ->
        nil

      match?(%{"destination" => %{binding_id: _}}, node.content) ->
        nil

      true ->
        case resolved(node, "destination") do
          dest when is_binary(dest) -> Keyword.get(opts, :rewrite_href).(node, dest)
          _ -> nil
        end
    end
  end

  defp maybe_put_class(attrs, node, opts) do
    case Keyword.get(opts, :style_class).(node) do
      nil -> attrs
      class -> Map.update(attrs, "class", class, &(&1 <> " " <> class))
    end
  end

  defp prefixed_id(node, opts) do
    case Keyword.get(opts, :id_prefix) do
      nil -> node.exporter_id
      prefix -> prefix <> "/" <> node.map_key
    end
  end

  defp resolved(%Node{content: content}, slot) when is_map(content) do
    case content[slot] do
      %{resolved: value} -> value
      %{"resolved" => value} -> value
      _ -> nil
    end
  end

  defp resolved(_, _), do: nil

  defp indent(iodata, level) do
    prefix = String.duplicate("  ", level)

    iodata
    |> IO.iodata_to_binary()
    |> String.split("\n")
    |> Enum.map(fn
      "" -> "\n"
      line -> [prefix, line, "\n"]
    end)
  end

  defp blank?(iodata) do
    iodata |> IO.iodata_to_binary() |> String.trim() == ""
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
