defmodule BubbleEx.Frontend.Export.Html do
  @moduledoc false

  alias BubbleEx.Frontend.Export.{Bbcode, Css, Safety}
  alias BubbleEx.Frontend.Naming
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
       when kind in [
              :group,
              :floating_group,
              :reusable_definition,
              :repeating_group,
              :shape,
              :placeholder
            ],
       do: wrap("div", node, children_html_or_empty(node, opts), opts)

  defp do_render(%Node{kind: :slider, variant: :range} = node, opts),
    do: render_range_slider(node, opts)

  defp do_render(%Node{kind: :reusable_instance} = node, opts), do: render_instance(node, opts)

  defp do_render(%Node{kind: :text} = node, opts) do
    inner = text_inner_html(node, opts)
    wrap(text_wrapper_tag(node, opts), node, inner, opts)
  end

  defp do_render(%Node{kind: :button} = node, opts) do
    label = slot_text(node, "label", opts)
    text = if label == "", do: slot_text(node, "text", opts), else: label
    inner = button_inner_html(node, text, opts)
    tag = if navigation_button?(node), do: "a", else: "button"
    wrap(tag, node, inner, opts)
  end

  defp do_render(%Node{kind: :link} = node, opts), do: render_link(node, opts)
  defp do_render(%Node{kind: :image} = node, opts), do: void("img", node, opts)
  defp do_render(%Node{kind: :icon} = node, opts), do: render_icon(node, opts)

  defp do_render(%Node{kind: kind} = node, opts) when kind in [:input, :file_input, :slider],
    do: void("input", node, opts)

  defp do_render(%Node{kind: :search} = node, opts), do: render_search(node, opts)

  defp do_render(%Node{kind: :multiline_input} = node, opts),
    do: wrap("textarea", node, escape_textarea(slot_text(node, "value", opts)), opts)

  defp do_render(%Node{kind: :checkbox} = node, opts), do: render_checkbox(node, opts)
  defp do_render(%Node{kind: :dropdown} = node, opts), do: render_dropdown(node, opts)
  defp do_render(%Node{kind: :radio_buttons} = node, opts), do: render_radio_buttons(node, opts)

  defp children_html_or_empty(%Node{kind: kind} = node, opts)
       when kind in [:group, :floating_group, :reusable_definition, :repeating_group],
       do: children_html(node, opts)

  defp children_html_or_empty(_node, _opts), do: ""

  defp render_instance(node, opts) do
    stack = Keyword.get(opts, :expansion_stack, MapSet.new())
    definition = Keyword.get(opts, :expand).(node)
    node = instance_boundary(node, definition)

    inner =
      case definition do
        %Node{} = definition ->
          identity = definition.map_key

          if MapSet.member?(stack, identity),
            do: "",
            else: children_html(definition, instance_opts(opts, node, identity, stack))

        _ ->
          ""
      end

    wrap("div", node, inner, opts)
  end

  defp instance_boundary(node, %Node{variant: :runtime_overlay} = definition) do
    %{
      node
      | variant: :runtime_overlay,
        attributes: Map.merge(node.attributes || %{}, definition.attributes)
    }
  end

  defp instance_boundary(node, _definition), do: node

  defp instance_opts(opts, instance, identity, stack) do
    opts
    |> Keyword.put(:id_prefix, prefixed_id(instance, opts))
    |> Keyword.put(:expansion_stack, MapSet.put(stack, identity))
  end

  defp render_icon(%Node{variant: :inline_svg} = node, opts) do
    case BubbleEx.Frontend.StaticSvg.parse(node.attributes["inline_svg"]) do
      {:ok, svg} -> wrap("span", node, svg, opts)
      _ -> wrap("span", node, "", opts)
    end
  end

  defp render_icon(node, opts) do
    wrap("span", node, icon_svg(node, opts), opts)
  end

  defp button_inner_html(%Node{variant: variant} = node, text, opts)
       when variant in [:icon, :label_icon] do
    svg = icon_svg(node, opts)
    label = if text == "", do: [], else: escape(text)

    cond do
      svg == "" -> label
      label == [] -> svg
      node.attributes["icon_placement"] == "right" -> [label, svg]
      true -> [svg, label]
    end
  end

  defp button_inner_html(_node, text, _opts), do: escape(text)

  defp icon_svg(node, opts) do
    fragment = node.attributes["asset_fragment"]

    symbol =
      case Keyword.get(opts, :assets, %{}) |> Map.get(node.exporter_id) do
        %{bytes: bytes} -> inline_icon_symbol(bytes, fragment)
        _ -> nil
      end

    if is_binary(symbol) do
      icon_set = escape(node.attributes["icon_set"] || "fa")

      [
        ~s(<svg viewBox="0 0 32 32" data-icon-set="#{icon_set}" aria-hidden="true"><defs>),
        symbol,
        ~s(</defs><use width="32" height="32" href="##{fragment}"></use></svg>)
      ]
    else
      ""
    end
  end

  defp inline_icon_symbol(bytes, fragment) when is_binary(bytes) and is_binary(fragment) do
    regex =
      Regex.compile!(
        "<symbol\s+id=\"#{Regex.escape(fragment)}\"[^>]*>.*?</symbol>",
        "s"
      )

    case Regex.run(regex, bytes) do
      [symbol] -> symbol
      _ -> nil
    end
  end

  defp inline_icon_symbol(_bytes, _fragment), do: nil

  defp children_html(%Node{kind: :page, children: children}, opts) do
    {floating, flow} = Enum.split_with(children, &floating_boundary?(&1, opts))
    render_children(flow ++ floating, opts)
  end

  defp children_html(%Node{children: children}, opts), do: render_children(children, opts)

  defp floating_boundary?(%Node{kind: :floating_group}, _opts), do: true

  defp floating_boundary?(%Node{kind: :reusable_instance} = node, opts) do
    match?(%Node{variant: :floating_group}, Keyword.fetch!(opts, :expand).(node))
  end

  defp floating_boundary?(_node, _opts), do: false

  defp render_children(children, opts) do
    children
    |> Enum.map(&render_node(&1, opts))
    |> Enum.intersperse("\n")
  end

  defp render_link(node, opts) do
    text = slot_text(node, "text", opts)
    wrap("a", node, button_inner_html(node, text, opts), opts)
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

  defp render_range_slider(node, opts) do
    min = Map.get(node.attributes, "min")
    max = Map.get(node.attributes, "max")
    low = Map.get(node.attributes, "value") || min
    high = Map.get(node.attributes, "value_high") || max
    base = Map.take(node.attributes || %{}, ["min", "max", "step", "disabled"])

    inner_source =
      case node.source do
        %{} = source -> %{source | bubble_id: nil}
        source -> source
      end

    start_node = %{
      node
      | source: inner_source,
        attributes:
          base
          |> Map.put("type", "range")
          |> Map.put("value", low)
          |> Map.put("aria-label", "Range start")
    }

    end_node = %{
      node
      | source: inner_source,
        attributes:
          base
          |> Map.put("type", "range")
          |> Map.put("value", high)
          |> Map.put("aria-label", "Range end")
    }

    container = %{
      node
      | attributes:
          (node.attributes || %{})
          |> Map.drop(["min", "max", "step", "value", "value_high", "type"])
          |> Map.put("role", "group")
    }

    inner = [void("input", start_node, opts), void("input", end_node, opts)]
    wrap("div", container, inner, opts)
  end

  defp render_search(node, opts) do
    choices = resolved_choices(node)
    list_id = search_list_id(node)
    node = put_search_list(node, list_id, choices)
    input = void("input", node, opts)

    if choices == [] do
      input
    else
      options =
        Enum.map(choices, fn choice ->
          value = to_string(choice["value"] || choice["label"] || "")
          ["<option value=\"", escape(value), "\">"]
        end)

      [input, "<datalist id=\"", escape(list_id), "\">", options, "</datalist>"]
    end
  end

  defp search_list_id(%Node{source: %{bubble_id: id}}) when is_binary(id) and id != "",
    do: "list-" <> id

  defp search_list_id(%Node{exporter_id: id}) when is_binary(id),
    do: "list-" <> String.replace(id, "/", "-")

  defp search_list_id(_), do: "list-search"

  defp put_search_list(node, _list_id, []), do: node

  defp put_search_list(node, list_id, _choices) do
    %{node | attributes: Map.put(node.attributes || %{}, "list", list_id)}
  end

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

  defp text_inner_html(node, opts) do
    raw = slot_text(node, "text", opts)

    cond do
      Bbcode.present?(raw) ->
        Bbcode.to_html(raw)

      is_binary(raw) and String.contains?(raw, "\n") ->
        raw |> escape() |> String.replace("\n", "<br>")

      true ->
        escape(raw)
    end
  end

  defp text_wrapper_tag(node, opts) do
    raw = slot_text(node, "text", opts)

    if Bbcode.block?(raw) do
      "div"
    else
      text_tag(node.variant)
    end
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

      tag in @phrasing or match?(%Node{kind: :text}, node) ->
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
    |> put_authored_id(node)
    |> maybe_put_bubble_id(node)
    |> maybe_put_class(node, opts)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == false or v == "" end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&html_attr/1)
  end

  defp put_authored_id(attrs, node) do
    case authored_id(node) do
      nil -> attrs
      id -> Map.put(attrs, "id", id)
    end
  end

  defp authored_id(%Node{kind: :placeholder}), do: nil
  defp authored_id(%Node{variant: :runtime_overlay}), do: nil

  defp authored_id(node) do
    case resolved(node, "html_id") do
      id when is_binary(id) and byte_size(id) in 1..256 ->
        if Regex.match?(~r/^[A-Za-z_-][A-Za-z0-9_-]*$/, id), do: id

      _ ->
        nil
    end
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

  defp node_attrs(%Node{kind: :icon}, "span", _opts), do: %{"aria-hidden" => "true"}

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
    |> then(fn attrs ->
      if node.variant == :fit_height, do: Map.put(attrs, "rows", "1"), else: attrs
    end)
  end

  defp node_attrs(%Node{kind: :dropdown} = node, "select", _opts) do
    placeholder = resolved(node, "placeholder")

    node.attributes
    |> Map.put_new("aria-label", placeholder || node.name || "Dropdown")
    |> Map.put("style", Css.inline_control_font(node))
  end

  defp node_attrs(%Node{kind: :slider} = node, "input", _opts) do
    node.attributes
    |> Map.put("type", "range")
    |> Map.drop(["placeholder"])
  end

  defp node_attrs(%Node{kind: :search} = node, "input", _opts) do
    placeholder = resolved(node, "placeholder")

    node.attributes
    |> Map.put("type", "search")
    |> Map.put("placeholder", placeholder)
    |> Map.put_new("aria-label", placeholder || node.name || "Search")
  end

  defp node_attrs(%Node{kind: :file_input} = node, "input", _opts) do
    label = resolved(node, "placeholder") || node.name || "File"

    node.attributes
    |> Map.put("type", "file")
    |> Map.drop(["value", "placeholder"])
    |> Map.put_new("aria-label", label)
  end

  defp node_attrs(node, "input", _opts) do
    placeholder = resolved(node, "placeholder")

    node.attributes
    |> Map.put_new("type", "text")
    |> Map.put("value", input_display_value(node))
    |> Map.put("placeholder", placeholder)
    |> Map.put_new("aria-label", placeholder)
  end

  defp node_attrs(node, "button", _opts) do
    node.attributes
    |> Map.take(["disabled", "aria-label"])
    |> Map.put("type", "button")
  end

  defp node_attrs(node, "a", opts) do
    href = link_href(node, opts)

    node.attributes
    |> Map.drop(["disabled", "asset_src", "asset_fragment", "icon_set"])
    |> then(fn attrs ->
      if href, do: Map.put(attrs, "href", href), else: Map.delete(attrs, "href")
    end)
  end

  defp node_attrs(node, _tag, _opts), do: node.attributes || %{}

  defp navigation_button?(%Node{kind: :button, content: %{"destination" => %{resolved: dest}}})
       when is_binary(dest) and dest != "",
       do: true

  defp navigation_button?(_), do: false

  defp link_href(%Node{attributes: %{"disabled" => true}}, _opts), do: nil

  defp link_href(%Node{content: %{"destination" => %{binding_id: _}}}, _opts), do: nil

  defp link_href(node, opts) do
    safe_link_href(node, resolved(node, "destination"), opts)
  end

  defp safe_link_href(node, destination, opts) when is_binary(destination) do
    rewritten = Keyword.get(opts, :rewrite_href).(node, destination)
    if Safety.safe_href?(rewritten), do: rewritten
  end

  defp safe_link_href(_node, _destination, _opts), do: nil

  defp maybe_put_class(attrs, node, opts) do
    case Keyword.get(opts, :style_class).(node) do
      nil -> attrs
      class -> Map.update(attrs, "class", class, &(&1 <> " " <> class))
    end
  end

  defp prefixed_id(node, opts) do
    case Keyword.get(opts, :id_prefix) do
      nil -> node.exporter_id
      prefix -> Naming.expanded_id(prefix, node)
    end
  end

  # Static en-US presentation for the frozen Input formats. Preserve the numeric
  # model value; percentage values are fractions in Bubble (0.25 means 25%).
  defp input_display_value(%Node{variant: :percent} = node) do
    case resolved(node, "value") do
      value when is_number(value) -> compact_number(value * 100) <> "%"
      value -> value
    end
  end

  defp input_display_value(%Node{variant: :currency} = node) do
    case resolved(node, "value") do
      value when is_number(value) ->
        symbol = get_in(node.unmapped, ["properties", "currency_symbol"]) || "$"
        symbol <> :erlang.float_to_binary(value / 1, decimals: 2)

      value ->
        value
    end
  end

  defp input_display_value(%Node{variant: :phone} = node) do
    case resolved(node, "value") do
      <<area::binary-size(3), prefix::binary-size(3), line::binary-size(4)>> = value ->
        if String.match?(value, ~r/^[0-9]{10}$/),
          do: "(#{area}) #{prefix}-#{line}",
          else: value

      value ->
        value
    end
  end

  defp input_display_value(node), do: resolved(node, "value")

  defp compact_number(value) when is_integer(value), do: Integer.to_string(value)

  defp compact_number(value) do
    value
    |> :erlang.float_to_binary(decimals: 10)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
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
