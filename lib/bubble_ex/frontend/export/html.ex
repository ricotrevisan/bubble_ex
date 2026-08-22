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
    tag = if navigation_button?(node), do: "a", else: "button"
    wrap(tag, node, escape(body), opts)
  end

  defp do_render(%Node{kind: :link} = node, opts), do: render_link(node, opts)
  defp do_render(%Node{kind: :image} = node, opts), do: void("img", node, opts)
  defp do_render(%Node{kind: :input} = node, opts), do: void("input", node, opts)

  defp do_render(%Node{kind: :multiline_input} = node, opts),
    do: wrap("textarea", node, escape_textarea(slot_text(node, "value", opts)), opts)

  defp do_render(%Node{kind: :checkbox} = node, opts), do: render_checkbox(node, opts)
  defp do_render(%Node{kind: :dropdown} = node, opts), do: render_dropdown(node, opts)
  defp do_render(%Node{kind: :radio_buttons} = node, opts), do: render_radio_buttons(node, opts)

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

  defp render_checkbox(node, opts) do
    label = slot_text(node, "label", opts)

    input_attributes =
      node.attributes
      |> Map.put("type", "checkbox")
      |> Map.put("checked", if(resolved(node, "checked") == true, do: "checked"))
      |> maybe_put_control_label(label, node)

    inner = ["<input", raw_attrs(input_attributes), ">", checkbox_label(label)]
    wrap("label", node, inner, opts)
  end

  defp checkbox_label(""), do: ""
  defp checkbox_label(label), do: ["<span>", escape(label), "</span>"]

  defp render_dropdown(node, opts) do
    selected = resolved(node, "value")
    placeholder = slot_text(node, "placeholder", opts)
    choices = resolved_choices(node)

    inner =
      [
        dropdown_placeholder(placeholder, selected)
        | Enum.map(choices, &option_html(&1, selected))
      ]

    wrap("select", node, inner, opts)
  end

  defp dropdown_placeholder("", _selected), do: ""

  defp dropdown_placeholder(placeholder, selected) do
    attributes = %{
      "value" => "",
      "disabled" => "disabled",
      "selected" => if(is_nil(selected) or selected == "", do: "selected")
    }

    ["<option", raw_attrs(attributes), ">", escape(placeholder), "</option>"]
  end

  defp option_html(%{"label" => label, "value" => value}, selected) do
    value = to_string(value)

    attributes = %{
      "value" => value,
      "selected" => if(to_string(selected) == value, do: "selected")
    }

    ["<option", raw_attrs(attributes), ">", escape(label), "</option>"]
  end

  defp render_radio_buttons(node, opts) do
    label = slot_text(node, "label", opts)
    selected = resolved(node, "value")
    name = prefixed_id(node, opts)

    legend = if label == "", do: "", else: ["<legend>", escape(label), "</legend>"]

    options =
      node
      |> resolved_choices()
      |> Enum.with_index()
      |> Enum.map(fn {choice, index} ->
        radio_option_html(choice, selected, name, index, node.attributes)
      end)

    wrap("fieldset", node, [legend | options], opts)
  end

  defp radio_option_html(
         %{"label" => label, "value" => value},
         selected,
         name,
         index,
         attributes
       ) do
    value = to_string(value)
    option_id = "#{name}_option_#{index}"

    input_attributes =
      attributes
      |> Map.put("type", "radio")
      |> Map.put("id", option_id)
      |> Map.put("name", name)
      |> Map.put("value", value)
      |> Map.put("checked", if(to_string(selected) == value, do: "checked"))

    [
      "<input",
      raw_attrs(input_attributes),
      ">",
      "<label for=\"",
      escape(option_id),
      "\">",
      escape(label),
      "</label>"
    ]
  end

  defp resolved_choices(node) do
    case resolved(node, "choices") do
      choices when is_list(choices) -> choices
      _ -> []
    end
  end

  defp maybe_put_control_label(attributes, "", node) do
    Map.put(attributes, "aria-label", node.name || "Checkbox")
  end

  defp maybe_put_control_label(attributes, _label, _node), do: attributes

  defp html_attr({key, true}), do: [" ", key, "=\"", key, "\""]
  defp html_attr({key, value}), do: [" ", key, "=\"", escape(to_string(value)), "\""]

  defp raw_attrs(attributes) do
    attributes
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == false or value == "" end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&html_attr/1)
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

  @phrasing ~w(p h1 h2 h3 h4 button a label textarea select)

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
    |> Enum.map(&html_attr/1)
  end

  defp node_attrs(node, "img", opts) do
    src =
      case Keyword.get(opts, :assets, %{}) |> Map.get(node.exporter_id) do
        %{path: path} -> "../../" <> path
        %{failed?: true} -> nil
        _ -> Map.get(node.attributes, "asset_src") || resolved(node, "src") || ""
      end

    alt = resolved(node, "alt") || node.attributes["alt"] || ""
    %{"src" => src, "alt" => alt}
  end

  defp node_attrs(%Node{kind: :checkbox}, "label", _opts), do: %{}

  defp node_attrs(%Node{kind: :radio_buttons} = node, "fieldset", _opts) do
    label = resolved(node, "label")

    node.attributes
    |> Map.take(["disabled"])
    |> then(fn attributes ->
      if is_binary(label) and label != "",
        do: attributes,
        else: Map.put(attributes, "aria-label", node.name || "Radio buttons")
    end)
  end

  defp node_attrs(%Node{kind: :multiline_input} = node, "textarea", _opts) do
    placeholder = resolved(node, "placeholder")

    node.attributes
    |> Map.put("placeholder", placeholder)
    |> Map.put_new("aria-label", placeholder || node.name || "Multiline input")
  end

  defp node_attrs(%Node{kind: :dropdown} = node, "select", _opts) do
    placeholder = resolved(node, "placeholder")
    Map.put_new(node.attributes, "aria-label", placeholder || node.name || "Dropdown")
  end

  defp node_attrs(node, "input", _opts) do
    placeholder = resolved(node, "placeholder")

    node.attributes
    |> Map.put_new("type", "text")
    |> Map.put("value", resolved(node, "value"))
    |> Map.put("placeholder", placeholder)
    |> Map.put_new("aria-label", placeholder)
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

  defp navigation_button?(%Node{kind: :button, content: %{"destination" => %{resolved: dest}}})
       when is_binary(dest) and dest != "",
       do: true

  defp navigation_button?(_), do: false

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

  defp escape_textarea(value) do
    value
    |> escape()
    |> String.replace("\r\n", "&#10;")
    |> String.replace("\r", "&#10;")
    |> String.replace("\n", "&#10;")
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
