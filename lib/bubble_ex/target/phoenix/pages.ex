defmodule BubbleEx.Target.Phoenix.Pages do
  @moduledoc """
  The HEEx emitter of the Phoenix target (WTF-370): a sibling of
  `BubbleEx.Frontend.Export.Html` over the same normalized frontend
  (`BubbleEx.Frontend.Normalized`), printing LiveViews instead of static
  HTML.

    * every page becomes a LiveView (`<Web>.<Page>Live`, a module and its
      colocated `.html.heex` template) routed at the Bubble page's path
    * every reusable element becomes a function component
      (`<Web>.Reusables.<Name>`, `.<name>/1` with an embedded template);
      instances are component calls that pass the instance's size and
      place as `class` and, where the instance resolves a reusable
      parameter differently, the value as an attribute
    * every element carries `data-bubble-id`
    * styles are Tailwind v4 (WTF-359 Q4): the app's tokens in `@theme`,
      named styles as component classes, each element's own declarations
      as utilities (`BubbleEx.Target.Phoenix.Tailwind`), and what utilities
      cannot say in a residue stylesheet keyed by `data-bubble-id`
    * dynamic content: a value binding the expression compiler lowered
      (`BubbleEx.Target.Elixir.Frontend`) is a helper in the LiveView whose
      arguments are assigns; anything else is a `TODO(bubble:<id>)` marker
      (a HEEx comment, rendering nothing, as the exporter renders an
      unresolved slot empty)
    * Popups, Group Focuses and Floating Groups follow the normalized
      `runtime` model: closed with `hidden`, opened and closed by
      `<Web>.Bubble.show_overlay/2` and `hide_overlay/2` (JS commands),
      dismissed by an outside click or Escape (one hook per page closes
      the topmost open overlay only), modal Popups named dialogs in a
      focus trap that give the focus back when they close. Runtime
      containers (dynamic Repeating Groups) render their template once per
      item of an assign that starts empty
    * a reusable instance's parameters reach its component: a link
      destination through the page map and URL allowlist, a Text's
      content as a slot rendered by the static text path, other values as
      attributes
    * Bubble IDs in generated Elixir and HEEx expressions are string
      literals (braces, `<` and `\#{` escaped), in comments sanitized

  Only prints: it reads the normalized frontend and the compiled bindings,
  never the Model (see the boundary test).

  LiveView modules, templates and reusable components are **owned**
  (scaffold once, WTF-359 Q1); the routes (`<Web>.BubbleRoutes`), the
  stylesheets, the `<Web>.Bubble` helpers, the surface name map
  (`.wtf/surfaces.json`) and the traceability test are **generated**.

  The `report` of `render/3` (see `BubbleEx.Target.Phoenix.frontend_report/2`):
  `native` elements are the ones printed as their own kind outside runtime
  templates, markers and residue rules included.
  """

  alias BubbleEx.Frontend.Export.{Bbcode, Css, Safety}
  alias BubbleEx.Frontend.{ReusableParameters, ResponsiveImages, StaticSvg}
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Target.Ash.Naming
  alias BubbleEx.Target.Phoenix.{Tailwind, Templates}

  @names_version 1

  # First path segments the scaffold routes (sign-in, the API, assets…).
  @reserved_paths ~w(auth sign-in sign-out register reset password-reset magic_link api dev live
                     assets fonts images favicon.ico robots.txt phoenix)

  @phrasing ~w(p h1 h2 h3 h4 button a label textarea select)

  @type result :: %{
          owned: %{String.t() => String.t()},
          generated: %{String.t() => String.t()},
          routes: [%{path: String.t(), module: String.t(), page: String.t()}],
          report: map()
        }

  @doc """
  The page and component files for `frontend`. `ctx` has the target's
  `:app`, `:module` and `:web`. Options:

    * `:names` - the previous `.wtf/surfaces.json` (decoded): its names are
      kept (WTF-352 D5)
    * `:expressions` - compiled bindings by binding ID
      (`BubbleEx.Target.Elixir.Frontend.compile/5`)
    * `:assets` - downloaded assets by exporter ID (`%{path, bytes}` as
      the HTML exporter collects them): images and icons are served from
      `priv/static/images/bubble/`
  """
  @spec render(Normalized.t(), map(), keyword()) :: result()
  def render(%Normalized{} = frontend, ctx, opts \\ []) do
    names = plan(frontend, Keyword.get(opts, :names))
    tokens = token_utilities(frontend)

    base = %{
      frontend: frontend,
      web: ctx.web,
      app: ctx.app,
      runtime: ctx.module <> ".Bubble.Runtime",
      names: names,
      tokens: tokens,
      styles: Map.new(frontend.styles, &{&1.map_key, &1.class_name}),
      expressions: Keyword.get(opts, :expressions, %{}),
      assets: Keyword.get(opts, :assets, %{}),
      overrides: overrides(frontend)
    }

    base =
      base
      |> Map.put(:required, required_vars(frontend, base))
      |> Map.put(:scoped, scoped(frontend))

    pages = Enum.map(names.pages, &page(&1, base))
    reusables = Enum.map(names.reusables, &reusable(&1, base))
    surfaces = pages ++ reusables

    owned = surfaces |> Enum.flat_map(& &1.files) |> Map.new()

    routes =
      Enum.map(names.pages, fn p ->
        %{path: p.path, module: "#{ctx.web}.#{p.module}", page: p.label, id: p.id}
      end)

    generated = %{
      routes_path(ctx) => routes_module(ctx, routes),
      "assets/css/bubble.css" => stylesheet(frontend),
      "assets/css/bubble_residue.css" => residue(surfaces),
      "lib/#{ctx.app}_web/components/bubble.ex" => format(helpers(ctx, frontend)),
      "test/#{ctx.app}_web/bubble_surfaces_test.exs" =>
        format(traceability_test(ctx, pages, reusables, base)),
      ".wtf/surfaces.json" => encode_names(names)
    }

    # Downloaded images, served from priv/static/images/bubble (asset_url/1).
    generated =
      for {_id, %{path: path, bytes: bytes}} <- base.assets,
          is_binary(path) and is_binary(bytes),
          into: generated,
          do: {"priv/static/images/bubble/" <> Path.basename(path), bytes}

    %{
      owned: owned,
      generated: generated,
      routes: routes,
      report: report(frontend, surfaces)
    }
  end

  @doc """
  The path of the generated routes module (`<Web>.BubbleRoutes`).
  """
  @spec routes_path(map()) :: String.t()
  def routes_path(ctx), do: "lib/#{ctx.app}_web/bubble_routes.ex"

  @doc """
  The generated `<Web>.BubbleRoutes`: the page routes, at their locked
  paths, in a macro the owned router calls once (`bubble_routes/0`).
  Regenerated with the pages, so a page added in Bubble later is routed
  without touching the router; without pages the macro defines nothing.
  `routes` are `render/3`'s.
  """
  @spec routes_module(map(), [map()]) :: String.t()
  def routes_module(ctx, routes) do
    pages =
      Enum.map_join(routes, ",\n", fn r ->
        "    {#{literal(r.id)}, #{inspect(r.path)}, #{r.module}}"
      end)

    body =
      if routes == [] do
        "  defmacro bubble_routes, do: nil\n"
      else
        lives = Enum.map_join(routes, "\n", &"          live #{inspect(&1.path)}, #{&1.module}")

        """
          defmacro bubble_routes do
            quote do
              scope "/" do
                pipe_through :browser

                ash_authentication_live_session :bubble_pages,
                  on_mount: {#{ctx.web}.LiveUserAuth, :live_user_optional} do
        #{lives}
                end
              end
            end
          end
        """
      end

    """
    defmodule #{ctx.web}.BubbleRoutes do
      @moduledoc \"\"\"
      The routes of the pages scaffolded from Bubble (WTF-370), at their
      Bubble paths (locked in `.wtf/surfaces.json`). Generated: a page added
      in Bubble is routed on the next generation, without touching the
      router, which calls `bubble_routes/0` once:

          require #{ctx.web}.BubbleRoutes
          #{ctx.web}.BubbleRoutes.bubble_routes()

      A router scaffolded before WTF-370 lacks that call: add it after the
      browser scope. `#{ctx.web}.BubbleSurfacesTest` fails for every page
      without its route and says so.
      \"\"\"

      @pages [
    #{pages}
      ]

      @doc "The pages: `{Bubble ID, path, LiveView}`."
      def pages, do: @pages

      @doc "The page routes (browser pipeline, optional sign-in)."
    #{body}end
    """
    |> String.replace("@pages [\n\n  ]", "@pages []")
    |> format()
  end

  @doc "The stylesheet for projects without a frontend: an empty theme."
  @spec empty_stylesheet() :: String.t()
  def empty_stylesheet do
    """
    /* The Bubble app's design tokens and named styles (WTF-359 Q4). No
       frontend was rendered, so there are none. */

    @theme {
    }
    """
  end

  # --- names (WTF-352 D5: locked at first generation) ------------------------------

  defp plan(frontend, locked) do
    locked = if is_map(locked), do: locked, else: %{}
    locked_pages = locked_section(locked, "pages")
    locked_reusables = locked_section(locked, "reusables")

    pages = Enum.sort_by(frontend.pages, &surface_id/1)
    reusables = Enum.sort_by(frontend.reusables, &surface_id/1)

    taken_modules =
      (Map.values(locked_pages) ++ Map.values(locked_reusables))
      |> Enum.map(& &1["module"])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    taken_paths =
      locked_pages |> Map.values() |> Enum.map(& &1["path"]) |> Enum.filter(&is_binary/1)

    {pages, {modules, _paths}} =
      Enum.map_reduce(pages, {taken_modules, MapSet.new(taken_paths)}, fn page,
                                                                          {modules, paths} ->
        id = surface_id(page)
        locked_page(page, id, locked_pages[id], modules, paths)
      end)

    {reusables, _modules} =
      Enum.map_reduce(reusables, modules, fn definition, modules ->
        id = surface_id(definition)
        locked_reusable(definition, id, locked_reusables[id], modules)
      end)

    %{
      pages: pages,
      reusables: reusables,
      page_by_ref: page_refs(pages),
      reusable_by_ref: reusable_refs(reusables)
    }
  end

  # A surface keeps its locked name if it is one this emitter could have
  # made; otherwise (none, or hand-edited) it gets a new one.
  defp locked_page(page, id, %{"module" => module, "path" => path}, modules, paths)
       when is_binary(module) and is_binary(path) do
    if locked_module?(module) and locked_path?(path),
      do: {page_entry(page, id, module, path), {modules, paths}},
      else: new_page(page, id, modules, paths)
  end

  defp locked_page(page, id, _locked, modules, paths), do: new_page(page, id, modules, paths)

  defp locked_reusable(definition, id, %{"module" => module}, modules) when is_binary(module) do
    if locked_module?(module),
      do: {reusable_entry(definition, id, module), modules},
      else: new_reusable(definition, id, modules)
  end

  defp locked_reusable(definition, id, _locked, modules),
    do: new_reusable(definition, id, modules)

  defp new_page(page, id, modules, paths) do
    {module, modules} =
      Naming.base(:pascal, page.name, id, "Page")
      |> Kernel.<>("Live")
      |> Naming.claim(modules, :pascal, :none)

    {path, paths} = claim_path(page_path(page), paths)
    {page_entry(page, id, module, path), {modules, paths}}
  end

  defp new_reusable(definition, id, modules) do
    {module, modules} =
      Naming.base(:pascal, definition.name, id, "Reusable")
      |> Naming.claim(modules, :pascal, :none)

    {reusable_entry(definition, id, module), modules}
  end

  # A locked name is kept only if it is one this emitter could have made:
  # the file is the owner's, so a hand-edited one must not reach the
  # generated source (a module alias segment, a path of slug segments).
  defp locked_module?(module), do: Regex.match?(~r/\A[A-Z][A-Za-z0-9]*\z/, module)
  defp locked_path?(path), do: Regex.match?(~r{\A/([a-z0-9_-]+(/[a-z0-9_-]+)*)?\z}, path)

  defp locked_section(locked, key) do
    case locked[key] do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp surface_id(%Node{source: %{bubble_id: id}}) when is_binary(id) and id != "", do: id
  defp surface_id(%Node{map_key: key}), do: key

  defp page_entry(page, id, module, path) do
    %{
      node: page,
      id: id,
      module: module,
      path: path,
      label: page.name || page.map_key,
      file: Naming.underscore(module)
    }
  end

  defp reusable_entry(definition, id, module) do
    function = Naming.underscore(module)
    %{node: definition, id: id, module: module, function: function, file: function}
  end

  # Bubble serves a page at /<page name> and the index page at /.
  defp page_path(%Node{name: "index"}), do: "/"

  defp page_path(%Node{name: name, map_key: key}) do
    segment =
      case name do
        name when is_binary(name) and name != "" ->
          if Regex.match?(~r/\A[a-z0-9_-]+\z/, name), do: name, else: slug(name)

        _ ->
          slug(key)
      end

    segment = if segment == "", do: "page", else: segment
    segment = if segment in @reserved_paths, do: segment <> "-page", else: segment
    "/" <> segment
  end

  defp slug(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9_-]+/u, "-")
    |> String.trim("-")
  end

  defp claim_path(path, taken) do
    path =
      if MapSet.member?(taken, path),
        do: Enum.find_value(2..(MapSet.size(taken) + 2), &free_path(path, &1, taken)),
        else: path

    {path, MapSet.put(taken, path)}
  end

  defp free_path(path, n, taken) do
    candidate = "#{path}-#{n}"
    if MapSet.member?(taken, candidate), do: nil, else: candidate
  end

  defp page_refs(pages) do
    Enum.reduce(pages, %{}, fn entry, acc ->
      page = entry.node
      refs = [page.map_key, page.name, entry.id, slug(page.name || "")]

      Enum.reduce(
        refs,
        acc,
        &if(is_binary(&1) and &1 != "", do: Map.put(&2, &1, entry), else: &2)
      )
    end)
  end

  defp reusable_refs(reusables) do
    Enum.reduce(reusables, %{}, fn entry, acc ->
      acc
      |> Map.put(entry.node.map_key, entry)
      |> Map.put(entry.id, entry)
    end)
  end

  defp encode_names(names) do
    %{
      "version" => @names_version,
      "pages" => Map.new(names.pages, &{&1.id, %{"module" => &1.module, "path" => &1.path}}),
      "reusables" =>
        Map.new(names.reusables, &{&1.id, %{"module" => &1.module, "function" => &1.function}})
    }
    |> BubbleEx.CanonicalJson.ordered()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  # --- surfaces -------------------------------------------------------------------

  defp page(entry, base) do
    page = entry.node
    lowered = page |> Css.lower(selector: &selector/1) |> index_lowered()
    ctx = Map.merge(base, %{surface: :page, entry: entry, lowered: lowered, stack: MapSet.new()})
    {markup, acc} = emit(page, ctx, new_acc())

    module = "#{base.web}.#{entry.module}"
    dir = "lib/#{base.app}_web/live/"

    %{
      kind: :page,
      entry: entry,
      acc: acc,
      files: [
        {dir <> entry.file <> ".ex", format(live_view_module(module, entry, acc, base))},
        {dir <> entry.file <> ".html.heex",
         [markup, overlay_keys(page, base)] |> IO.iodata_to_binary() |> finish()}
      ]
    }
  end

  defp reusable(entry, base) do
    definition = entry.node

    lowered =
      definition
      |> Css.lower_definition_children(selector: &selector/1)
      |> index_lowered()

    ctx =
      Map.merge(base, %{
        surface: :reusable,
        entry: entry,
        lowered: lowered,
        stack: MapSet.new([definition.map_key])
      })

    {children, acc} = children(definition, ctx, new_acc())

    root = [
      "<div class={@class} {@rest}>",
      if(blank?(children), do: "", else: ["\n", indent(children, 1)]),
      "</div>\n"
    ]

    module = "#{base.web}.Reusables.#{entry.module}"
    dir = "lib/#{base.app}_web/components/reusables/"

    %{
      kind: :reusable,
      entry: entry,
      acc: acc,
      files: [
        {dir <> entry.file <> ".ex", format(component_module(module, entry, acc, base))},
        {dir <> entry.file <> ".html.heex", IO.iodata_to_binary(root)}
      ]
    }
  end

  # A page whose overlays (its own or its reusables') close on Escape
  # renders the Escape hook once.
  defp overlay_keys(page, base) do
    by_ref =
      Enum.reduce(base.frontend.reusables, %{}, fn d, acc ->
        acc |> Map.put(d.map_key, d) |> Map.put(surface_id(d), d)
      end)

    if escapable?(page, by_ref, MapSet.new()), do: "\n<Bubble.overlay_keys />", else: ""
  end

  defp escapable?(
         %Node{runtime: %{"boundary" => "overlay", "dismiss" => dismiss}} = node,
         by_ref,
         seen
       )
       when is_list(dismiss) do
    "escape" in dismiss or Enum.any?(node.children, &escapable?(&1, by_ref, seen))
  end

  defp escapable?(%Node{kind: :reusable_instance, definition_ref: ref}, by_ref, seen) do
    case by_ref[ref] do
      %Node{} = d ->
        not MapSet.member?(seen, d.map_key) and
          escapable?(d, by_ref, MapSet.put(seen, d.map_key))

      _ ->
        false
    end
  end

  defp escapable?(%Node{children: children}, by_ref, seen),
    do: Enum.any?(children, &escapable?(&1, by_ref, seen))

  defp index_lowered(entries), do: Map.new(entries, &{&1.node.exporter_id, &1})

  defp new_acc do
    %{
      residue: [],
      assigns: MapSet.new(),
      helpers: [],
      imports: MapSet.new(),
      ids: [],
      dom_ids: MapSet.new(),
      template: false,
      counts: %{
        "elements" => 0,
        "native" => 0,
        "placeholder" => 0,
        "in_runtime_template" => 0,
        "markers" => 0,
        "bindings_compiled" => 0,
        "bindings_marked" => 0,
        "utilities" => 0,
        "residue_declarations" => 0,
        "elements_with_residue" => 0
      }
    }
  end

  defp finish(markup), do: String.trim_trailing(markup) <> "\n"

  # --- nodes ----------------------------------------------------------------------

  defp emit(%Node{kind: :page} = node, ctx, acc) do
    {floating, flow} = Enum.split_with(node.children, &floating_boundary?(&1, ctx))
    {inner, acc} = emit_list(flow ++ floating, ctx, acc)
    element("main", node, [], inner, ctx, acc)
  end

  defp emit(%Node{kind: :html_style} = node, ctx, acc) do
    case get_in(node.content, ["html_style", :inline_style]) do
      %{css: css, refs: []} ->
        element("div", node, [], ["<style>", css, "</style>"], ctx, acc)

      %{css: _css} ->
        acc = mark(acc, node, "an HTML style sized from other elements needs a hook")
        element("div", node, [], "", ctx, acc, placeholder: true)

      _ ->
        element("div", node, [], "", ctx, acc)
    end
  end

  defp emit(
         %Node{kind: :placeholder, runtime: %{"boundary" => "container"} = runtime} = node,
         ctx,
         acc
       ) do
    name = item_assign(node)
    acc = acc |> mark(node, runtime_note(runtime)) |> add_assign(name, "[]")

    {template, acc} =
      if node.children == [] do
        {"", acc}
      else
        lowered =
          node.children
          |> Enum.flat_map(fn child -> Css.lower(child, selector: &selector/1) end)
          |> index_lowered()

        inner_ctx = %{ctx | lowered: Map.merge(ctx.lowered, lowered)}
        was = acc.template
        {children, acc} = emit_list(node.children, inner_ctx, %{acc | template: true})

        {["<div :for={_item <- @", name, "}>\n", indent(children, 1), "</div>"],
         %{acc | template: was}}
      end

    element("div", node, [], template, ctx, acc, placeholder: true)
  end

  defp emit(%Node{kind: :placeholder} = node, ctx, acc) do
    type = node.attributes["data-placeholder-kind"] || "element"
    acc = mark(acc, node, "#{type} is not lowered (plugin or unsupported element)")
    element("div", node, [], "", ctx, acc, placeholder: true)
  end

  defp emit(%Node{kind: kind} = node, ctx, acc)
       when kind in [
              :group,
              :floating_group,
              :popup,
              :group_focus,
              :reusable_definition,
              :repeating_group
            ] do
    {inner, acc} = children(node, ctx, acc)
    element("div", node, [], inner, ctx, acc)
  end

  defp emit(%Node{kind: :shape} = node, ctx, acc), do: element("div", node, [], "", ctx, acc)

  defp emit(%Node{kind: :slider, variant: :range} = node, ctx, acc),
    do: range_slider(node, ctx, acc)

  defp emit(%Node{kind: :reusable_instance} = node, ctx, acc), do: instance(node, ctx, acc)

  defp emit(%Node{kind: :text} = node, ctx, acc) do
    {text, acc} = slot(node, "text", ctx, acc)

    case text do
      {:static, raw} ->
        tag = if Bbcode.block?(raw), do: "div", else: text_tag(node.variant)
        element(tag, node, [], text_html(raw), ctx, acc)

      {:expr, expr} ->
        element(text_tag(node.variant), node, [], ["{", expr, "}"], ctx, acc)

      # An instance's own content (a reusable parameter): the caller
      # renders it through text_html/1 into this slot.
      {:slot, name, block} ->
        tag = if block, do: "div", else: text_tag(node.variant)
        element(tag, node, [], ["{render_slot(@", name, ")}"], ctx, acc)
    end
  end

  defp emit(%Node{kind: :button} = node, ctx, acc) do
    {label, acc} = slot(node, "label", ctx, acc)
    {label, acc} = if label == {:static, ""}, do: slot(node, "text", ctx, acc), else: {label, acc}
    navigation? = navigation_button?(node, ctx)
    tag = if navigation?, do: "a", else: "button"
    inner = button_inner(node, label, ctx)

    attrs =
      if navigation?,
        do: link_attrs(node, ctx),
        else:
          node.attributes
          |> Map.take(["disabled", "aria-label"])
          |> Map.put("type", "button")
          |> Enum.to_list()

    element(tag, node, attrs, inner, ctx, acc)
  end

  defp emit(%Node{kind: :link} = node, ctx, acc) do
    {text, acc} = slot(node, "text", ctx, acc)
    element("a", node, link_attrs(node, ctx), button_inner(node, text, ctx), ctx, acc)
  end

  defp emit(%Node{kind: :image} = node, ctx, acc), do: image(node, ctx, acc)

  defp emit(%Node{kind: :icon, variant: :inline_svg} = node, ctx, acc) do
    svg =
      case StaticSvg.parse(node.attributes["inline_svg"]) do
        {:ok, svg} -> escape_braces(svg)
        _ -> ""
      end

    element("span", node, [{"aria-hidden", "true"}], svg, ctx, acc)
  end

  defp emit(%Node{kind: :icon} = node, ctx, acc),
    do: element("span", node, [{"aria-hidden", "true"}], icon_svg(node, ctx), ctx, acc)

  defp emit(%Node{kind: :search} = node, ctx, acc), do: search(node, ctx, acc)

  defp emit(%Node{kind: kind} = node, ctx, acc) when kind in [:input, :file_input, :slider] do
    {attrs, acc} = input_attrs(node, ctx, acc)
    void("input", node, attrs, ctx, acc)
  end

  defp emit(%Node{kind: :multiline_input} = node, ctx, acc) do
    {placeholder, acc} = slot(node, "placeholder", ctx, acc)
    {value, acc} = slot(node, "value", ctx, acc)

    label =
      case placeholder do
        {:static, ""} -> node.name || "Multiline input"
        {:static, text} -> text
        _ -> node.name || "Multiline input"
      end

    attrs =
      node.attributes
      |> Enum.to_list()
      |> put_attr("placeholder", slot_attr(placeholder))
      |> put_new_attr("aria-label", label)
      |> then(&if node.variant == :fit_height, do: put_attr(&1, "rows", "1"), else: &1)

    inner =
      case value do
        {:static, text} -> escape_textarea(text)
        {:expr, expr} -> ["{", expr, "}"]
      end

    element("textarea", node, attrs, inner, ctx, acc)
  end

  defp emit(%Node{kind: :checkbox} = node, ctx, acc) do
    {label, acc} = slot(node, "label", ctx, acc)

    input =
      node.attributes
      |> Enum.to_list()
      |> put_attr("type", "checkbox")
      |> put_attr("checked", resolved(node, "checked") == true)
      |> then(fn attrs ->
        if label == {:static, ""},
          do: put_attr(attrs, "aria-label", node.name || "Checkbox"),
          else: attrs
      end)

    label_html =
      case label do
        {:static, ""} -> ""
        {:static, text} -> ["<span>", escape(text), "</span>"]
        {:expr, expr} -> ["<span>{", expr, "}</span>"]
      end

    element("label", node, [], ["<input", attrs_html(input), ">", label_html], ctx, acc)
  end

  defp emit(%Node{kind: :dropdown} = node, ctx, acc) do
    {placeholder, acc} = slot(node, "placeholder", ctx, acc)
    placeholder = static_or_empty(placeholder)
    selected = resolved(node, "value")

    options =
      [
        dropdown_placeholder(placeholder, selected)
        | Enum.map(choices(node), &option_html(&1, selected))
      ]

    attrs =
      node.attributes
      |> Enum.to_list()
      |> put_new_attr(
        "aria-label",
        nonblank(resolved(node, "placeholder")) || node.name || "Dropdown"
      )
      |> put_attr("style", Css.inline_control_font(node))

    element("select", node, attrs, options, ctx, acc)
  end

  defp emit(%Node{kind: :radio_buttons} = node, ctx, acc) do
    {label, acc} = slot(node, "label", ctx, acc)
    label = static_or_empty(label)
    selected = resolved(node, "value")
    name = "bubble-" <> bid(node)

    legend = if label == "", do: "", else: ["<legend>", escape(label), "</legend>"]

    options =
      node
      |> choices()
      |> Enum.with_index()
      |> Enum.map(fn {choice, index} -> radio_option(choice, selected, name, index, node) end)

    attrs =
      node.attributes
      |> Map.take(["disabled"])
      |> Enum.to_list()
      |> then(fn attrs ->
        if label == "",
          do: put_attr(attrs, "aria-label", node.name || "Radio buttons"),
          else: attrs
      end)

    element("fieldset", node, attrs, [legend | options], ctx, acc)
  end

  defp emit(%Node{} = node, ctx, acc) do
    acc = mark(acc, node, "#{node.kind} is not lowered")
    element("div", node, [], "", ctx, acc, placeholder: true)
  end

  defp children(%Node{children: children}, ctx, acc), do: emit_list(children, ctx, acc)

  defp emit_list(nodes, ctx, acc) do
    {parts, acc} = Enum.map_reduce(nodes, acc, &emit(&1, ctx, &2))
    {Enum.intersperse(parts, "\n"), acc}
  end

  defp floating_boundary?(%Node{kind: :floating_group}, _ctx), do: true

  defp floating_boundary?(%Node{kind: :reusable_instance} = node, ctx),
    do: match?(%Node{variant: :floating_group}, definition(node, ctx))

  defp floating_boundary?(_node, _ctx), do: false

  # --- reusable instances ---------------------------------------------------------

  defp definition(%Node{definition_ref: ref}, ctx) do
    case ctx.names.reusable_by_ref[ref] do
      %{node: definition} -> definition
      _ -> nil
    end
  end

  defp instance(node, ctx, acc) do
    entry = ctx.names.reusable_by_ref[node.definition_ref]
    definition = entry && entry.node

    cond do
      is_nil(definition) ->
        acc = mark(acc, node, "the reusable element is missing")
        element("div", node, [], "", ctx, acc, placeholder: true)

      MapSet.member?(ctx.stack, definition.map_key) or reaches?(definition, ctx) ->
        acc = mark(acc, node, "recursive reusable element: expansion stops here")
        element("div", node, [], "", ctx, acc, placeholder: true)

      true ->
        component_call(node, entry, ctx, acc)
    end
  end

  # Whether the reusable `definition` contains (transitively) the component
  # being emitted: rendering it would recurse.
  defp reaches?(definition, %{surface: :reusable, entry: %{node: current}} = ctx),
    do: reaches?(definition, current.map_key, ctx, MapSet.new())

  defp reaches?(_definition, _ctx), do: false

  defp reaches?(%Node{} = definition, target, ctx, seen) do
    definition
    |> instances()
    |> Enum.any?(fn instance ->
      case ctx.names.reusable_by_ref[instance.definition_ref] do
        %{node: %Node{map_key: ^target}} ->
          true

        %{node: next} ->
          not MapSet.member?(seen, next.map_key) and
            reaches?(next, target, ctx, MapSet.put(seen, next.map_key))

        _ ->
          false
      end
    end)
  end

  defp instances(%Node{kind: :reusable_instance} = node), do: [node]
  defp instances(%Node{children: children}), do: Enum.flat_map(children, &instances/1)

  defp component_call(node, entry, ctx, acc) do
    definition = entry.node

    root = Css.lower_root(definition, node, selector: fn _ -> selector(node) end)
    own = Map.get(ctx.lowered, node.exporter_id, %{declarations: [], rules: ""})
    declarations = merge_declarations(root.declarations, own.declarations)
    rules = [root.rules, own.rules] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
    styled = %{declarations: declarations, rules: rules}

    {classes, acc} = classes(node, styled, ctx, acc)
    acc = track(acc, node, false)

    {params, slots} = parameter_attrs(node, definition, ctx)

    {own, acc} =
      node.attributes
      |> Enum.to_list()
      |> Kernel.++(overlay_attrs(node))
      |> put_authored_id(node, ctx, acc)

    attrs = [{"data-bubble-id", bid(node)}, {"class", classes}] ++ sorted_attrs(own) ++ params

    vars = Map.get(ctx.required, definition.map_key, [])
    acc = Enum.reduce(vars, acc, &need_var(&2, &1, ctx))

    attrs =
      attrs ++ Enum.map(vars, &{&1, {:expr, "@" <> &1}}) ++ scope_attr(node, definition, ctx)

    acc = %{acc | imports: MapSet.put(acc.imports, entry.module)}
    acc = add_expected(acc, definition, ctx)

    call =
      if slots == [],
        do: ["<.", entry.function, component_attrs_html(attrs), " />"],
        else: [
          ["<.", entry.function, component_attrs_html(attrs), ">\n"],
          indent(Enum.intersperse(slots, "\n"), 1),
          ["</.", entry.function, ">"]
        ]

    {[marker_html(acc, node), call], acc}
  end

  defp scope_attr(node, definition, ctx) do
    cond do
      not MapSet.member?(ctx.scoped, definition.map_key) -> []
      ctx.surface == :page -> [{"scope", bid(node)}]
      true -> [{"scope", {:expr, ~s|"\#{@scope}-" <> | <> literal(bid(node))}}]
    end
  end

  # The data-bubble-ids an instance renders: its definition's elements.
  defp add_expected(acc, definition, ctx) do
    if acc.template do
      acc
    else
      ids =
        definition.children
        |> Enum.flat_map(&static_ids(&1, ctx, MapSet.new([definition.map_key])))

      %{acc | ids: Enum.reverse(ids) ++ acc.ids}
    end
  end

  defp static_ids(%Node{kind: :placeholder, runtime: %{"boundary" => "container"}} = n, _ctx, _s),
    do: [bid(n)]

  defp static_ids(%Node{kind: :reusable_instance} = node, ctx, stack) do
    case ctx.names.reusable_by_ref[node.definition_ref] do
      %{node: definition} ->
        if MapSet.member?(stack, definition.map_key) do
          [bid(node)]
        else
          stack = MapSet.put(stack, definition.map_key)
          [bid(node) | Enum.flat_map(definition.children, &static_ids(&1, ctx, stack))]
        end

      _ ->
        [bid(node)]
    end
  end

  defp static_ids(%Node{} = node, ctx, stack),
    do: [bid(node) | Enum.flat_map(node.children, &static_ids(&1, ctx, stack))]

  # Later declarations win; a later shorthand also drops earlier longhands.
  defp merge_declarations(first, second) do
    later = Map.new(second)

    kept =
      Enum.reject(first, fn {property, _} ->
        Map.has_key?(later, property) or
          Enum.any?(Map.keys(later), &String.starts_with?(property, &1 <> "-"))
      end)

    Enum.sort_by(kept ++ second, &elem(&1, 0))
  end

  # Reusable parameters an instance resolves differently from the
  # definition (see overrides/1): component attributes, a link destination
  # through the same page map and URL allowlist as a static one, and a
  # Text's content as a slot, rendered through the static text path
  # (BBCode, line breaks, escaping).
  defp parameter_attrs(node, definition, ctx) do
    case ctx.overrides[definition.map_key] do
      nil ->
        {[], []}

      overrides ->
        expanded = ReusableParameters.expand(definition, node)
        values = slot_values(definition, expanded)

        passed =
          for {key, override} <- Enum.sort_by(overrides, &elem(&1, 1).name),
              value = values[key],
              value != nil,
              do: {override, value}

        attrs =
          for {%{as: as, name: name}, value} <- passed,
              as != :slot,
              expr = override_expr(as, value, ctx),
              do: {name, {:expr, expr}}

        slots =
          for {%{as: :slot, name: name}, value} <- passed,
              do: ["<:", name, ">", text_html(to_string(value)), "</:", name, ">"]

        {attrs, slots}
    end
  end

  defp override_expr(:href, value, ctx) do
    case href(value, ctx) do
      nil -> nil
      {:page, path} -> "~p" <> inspect(path)
      {:url, url} -> literal(url)
    end
  end

  defp override_expr(:attr, value, _ctx) when is_binary(value), do: literal(value)
  defp override_expr(:attr, value, _ctx), do: inspect(value)

  # For every reusable: the {element path, slot} its instances resolve to a
  # different value than the definition does, with the attribute name.
  defp overrides(frontend) do
    by_key = Map.new(frontend.reusables, &{&1.map_key, &1})

    by_ref =
      Enum.reduce(frontend.reusables, %{}, fn d, acc ->
        acc |> Map.put(d.map_key, d) |> Map.put(surface_id(d), d)
      end)

    (frontend.pages ++ frontend.reusables)
    |> Enum.flat_map(&instances_below/1)
    |> Enum.reduce(%{}, &differing_slots(&1, by_ref[&1.definition_ref], &2))
    |> Enum.reject(fn {_key, slots} -> slots == %{} end)
    |> Map.new(fn {key, slots} ->
      definition = by_key[key]
      nodes = definition |> path_nodes([]) |> Map.new()
      own = slot_values(definition, definition)

      {key,
       Map.new(slots, fn {{path, slot}, values} ->
         node = nodes[path]

         {{path, slot},
          %{
            name: attr_name(node, slot),
            as: override_kind(node, slot),
            # A Text whose content is a block (BBCode lists, alignment…)
            # for any instance is a div, as the exporter makes it.
            block: Enum.any?([own[{path, slot}] | values], &Bbcode.block?/1)
          }}
       end)}
    end)
  end

  defp override_kind(_node, "destination"), do: :href
  defp override_kind(%Node{kind: :text}, "text"), do: :slot
  defp override_kind(_node, _slot), do: :attr

  defp differing_slots(instance, %Node{} = definition, acc) do
    own = slot_values(definition, definition)
    expanded = slot_values(definition, ReusableParameters.expand(definition, instance))
    differing = for {key, value} <- expanded, value != own[key], into: %{}, do: {key, [value]}

    Map.update(
      acc,
      definition.map_key,
      differing,
      &Map.merge(&1, differing, fn _, a, b -> a ++ b end)
    )
  end

  defp differing_slots(_instance, _definition, acc), do: acc

  defp instances_below(%Node{kind: :reusable_instance} = node), do: [node]

  defp instances_below(%Node{kind: :reusable_definition, children: c}),
    do: Enum.flat_map(c, &instances/1)

  defp instances_below(%Node{children: children}), do: Enum.flat_map(children, &instances/1)

  # {position path, slot} => resolved value, walking both trees by position.
  defp slot_values(%Node{} = definition, %Node{} = expanded) do
    definition.children
    |> Enum.zip(expanded.children)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{d, e}, i} -> slot_values(d, e, [i]) end)
    |> Map.new()
  end

  defp slot_values(%Node{kind: :reusable_instance}, _expanded, _path), do: []

  defp slot_values(%Node{} = d, %Node{} = e, path) do
    own =
      for {slot, content} <- e.content || %{},
          not String.starts_with?(slot, "param_"),
          is_map(content),
          value = content[:resolved] || content["resolved"],
          is_binary(value) or is_number(value) or is_boolean(value),
          do: {{path, slot}, value}

    nested =
      d.children
      |> Enum.zip(e.children)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{dc, ec}, i} -> slot_values(dc, ec, path ++ [i]) end)

    own ++ nested
  end

  defp path_nodes(%Node{children: children}, path) do
    children
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, i} ->
      [{path ++ [i], child} | path_nodes(child, path ++ [i])]
    end)
  end

  defp attr_name(%Node{} = node, slot), do: "#{ident(slot)}_#{ident(bid(node))}"

  # The variables of the compiled bindings a reusable renders, its own and
  # its nested instances' (cycle-safe): attributes of its component.
  defp required_vars(frontend, base) do
    by_ref =
      Enum.reduce(frontend.reusables, %{}, fn d, acc ->
        acc |> Map.put(d.map_key, d) |> Map.put(surface_id(d), d)
      end)

    Map.new(frontend.reusables, fn definition ->
      vars =
        definition |> vars_below(by_ref, base, MapSet.new([definition.map_key])) |> Enum.uniq()

      {definition.map_key, Enum.sort(vars)}
    end)
  end

  defp vars_below(%Node{} = node, by_ref, base, seen) do
    own =
      for {_slot, %{kind: :value, id: id}} <- node.bindings,
          %{bindings: vars} <- [base.expressions[id]],
          %{var: var} <- vars,
          do: var

    own ++ nested_vars(node, by_ref, base, seen)
  end

  defp nested_vars(%Node{kind: :reusable_instance, definition_ref: ref}, by_ref, base, seen) do
    case by_ref[ref] do
      %Node{} = d ->
        if MapSet.member?(seen, d.map_key),
          do: [],
          else: vars_below(d, by_ref, base, MapSet.put(seen, d.map_key))

      _ ->
        []
    end
  end

  defp nested_vars(%Node{children: children}, by_ref, base, seen),
    do: Enum.flat_map(children, &vars_below(&1, by_ref, base, seen))

  # --- elements -------------------------------------------------------------------

  defp element(tag, node, attrs, inner, ctx, acc, opts \\ []) do
    {open, acc} = open_tag(tag, node, attrs, ctx, acc, opts)
    {close_tag, acc} = close(tag, node, ctx, acc)

    markup =
      cond do
        blank?(inner) ->
          [open, marker_html(acc, node), close_tag]

        tag in @phrasing or match?(%Node{kind: :text}, node) ->
          [open, marker_html(acc, node), inner, close_tag]

        true ->
          [open, "\n", indent([marker_html(acc, node), inner], 1), close_tag]
      end

    {markup, acc}
  end

  defp void(tag, node, attrs, ctx, acc) do
    {open, acc} = open_tag(tag, node, attrs, ctx, acc, [])
    {[marker_html(acc, node), open], acc}
  end

  # Modal Popups are focus traps: Phoenix's focus_wrap is the element.
  defp close(_tag, %Node{runtime: %{"overlay" => "popup", "modal" => true}}, _ctx, acc),
    do: {"</.focus_wrap>", acc}

  defp close(tag, _node, _ctx, acc), do: {["</", tag, ">"], acc}

  defp open_tag(tag, node, attrs, ctx, acc, opts) do
    styled = Map.get(ctx.lowered, node.exporter_id, %{declarations: [], rules: ""})
    {classes, acc} = classes(node, styled, ctx, acc)
    acc = track(acc, node, Keyword.get(opts, :placeholder, false))

    {rest, acc} =
      attrs
      |> Kernel.++(overlay_attrs(node))
      |> Kernel.++(overlay_dismissal(node, ctx))
      |> put_authored_id(node, ctx, acc)

    rest = sorted_attrs(rest)

    all = [{"data-bubble-id", bid(node)}, {"class", classes} | rest]

    case node.runtime do
      %{"overlay" => "popup", "modal" => true} ->
        {["<.focus_wrap", component_attrs_html([{"id", overlay_dom_id(node, ctx)} | all]), ">"],
         acc}

      _ ->
        {["<", tag, attrs_html(all), ">"], acc}
    end
  end

  defp classes(node, styled, ctx, acc) do
    {utilities, residue} = Tailwind.utilities(styled.declarations, ctx.tokens)
    style = style_class(node, ctx)
    classes = Enum.join(Enum.reject([style | utilities], &is_nil/1), " ")

    rule =
      if residue == [],
        do: "",
        else:
          "#{selector(node)} {\n" <>
            Enum.map_join(residue, "", fn {k, v} -> "  #{k}: #{v};\n" end) <> "}\n"

    css = [rule, styled.rules] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")

    counts =
      acc.counts
      |> Map.update!("utilities", &(&1 + length(utilities)))
      |> Map.update!("residue_declarations", &(&1 + length(residue)))
      |> Map.update!("elements_with_residue", &if(css == "", do: &1, else: &1 + 1))

    {classes,
     %{acc | residue: if(css == "", do: acc.residue, else: [css | acc.residue]), counts: counts}}
  end

  # The report's element counts: `native` is any element printed as its
  # own kind outside a runtime template, whatever markers or residue it
  # carries (see Phoenix.frontend_report/2).
  defp track(acc, %Node{kind: kind} = node, placeholder?) when kind not in [:page] do
    counts =
      acc.counts
      |> Map.update!("elements", &(&1 + 1))
      |> Map.update!(
        cond do
          acc.template -> "in_runtime_template"
          placeholder? -> "placeholder"
          true -> "native"
        end,
        &(&1 + 1)
      )

    ids = if acc.template, do: acc.ids, else: [bid(node) | acc.ids]
    %{acc | counts: counts, ids: ids}
  end

  defp track(acc, node, _placeholder?), do: %{acc | ids: [bid(node) | acc.ids]}

  defp style_class(%Node{style: style} = node, ctx) do
    key = is_map(style) && (style[:style_key] || style["style_key"])
    ctx.styles[key] || default_text_class(node)
  end

  defp default_text_class(%Node{kind: :button}),
    do: "bubbleex-text-default bubbleex-button-default"

  defp default_text_class(%Node{kind: kind})
       when kind in [:text, :link, :input, :multiline_input, :dropdown, :checkbox, :radio_buttons],
       do: "bubbleex-text-default"

  defp default_text_class(_node), do: nil

  defp selector(node), do: ~s([data-bubble-id="#{css_escape(bid(node))}"])

  # The element's Bubble ID; a normalized node without one (a synthetic
  # container) is marked by its map key.
  defp bid(%Node{source: %{bubble_id: id}}) when is_binary(id) and id != "", do: id
  defp bid(%Node{map_key: key}) when is_binary(key) and key != "", do: key

  defp bid(%Node{exporter_id: id}),
    do: "x" <> binary_part(Base.encode16(:crypto.hash(:sha256, id), case: :lower), 0, 12)

  # A CSS string's content: quotes and backslashes escaped, line breaks as
  # code points (a raw one would end the string).
  defp css_escape(value) do
    value
    |> to_string()
    |> String.replace(~r/["\\]/, "\\\\\\0")
    |> String.replace(~r/\r\n?|\n|\f/, "\\a ")
  end

  # --- overlays (the normalized runtime model, WTF-407) -----------------------------

  defp overlay_attrs(
         %Node{runtime: %{"boundary" => "overlay", "overlay" => overlay} = runtime} = node
       ) do
    [{"data-overlay", overlay}] ++
      if(runtime["initial"] == "hidden", do: [{"hidden", true}], else: []) ++
      if(runtime["modal"] == true,
        do: [{"role", "dialog"}, {"aria-modal", "true"}, {"aria-label", dialog_label(node)}],
        else: []
      )
  end

  defp overlay_attrs(_node), do: []

  # Escape is `<Web>.Bubble.overlay_keys/1`'s (the topmost open overlay
  # only): the overlay carries the command it runs. An outside click is
  # LiveView's `phx-click-away`, which skips hidden (closed) overlays.
  defp overlay_dismissal(%Node{runtime: %{"boundary" => "overlay"} = runtime}, _ctx) do
    dismiss = List.wrap(runtime["dismiss"])

    hide =
      if runtime["modal"] == true,
        do: "{Bubble.dismiss_modal()}",
        else: "{Bubble.dismiss_overlay()}"

    if("escape" in dismiss, do: [{"data-bubble-escape", {:raw, hide}}], else: []) ++
      if "outside_click" in dismiss, do: [{"phx-click-away", {:raw, hide}}], else: []
  end

  defp overlay_dismissal(_node, _ctx), do: []

  # A dialog's accessible name: its first heading, else the Popup's Bubble
  # name, else its first text (plain, BBCode tags dropped, one line, at
  # most 120 characters; attrs_html/1 escapes it).
  defp dialog_label(node) do
    texts = node |> texts() |> Enum.map(&plain_text/1) |> Enum.reject(&(&1 == ""))

    heading =
      node
      |> texts(&(&1.variant in [:h1, :h2, :h3, :h4]))
      |> Enum.map(&plain_text/1)
      |> Enum.find(&(&1 != ""))

    (heading || nonblank(node.name && plain_text(node.name)) || List.first(texts) || "Dialog")
    |> String.slice(0, 120)
  end

  defp texts(%Node{} = node, keep? \\ fn _ -> true end) do
    own = if node.kind == :text and keep?.(node), do: [resolved(node, "text")], else: []
    Enum.filter(own, &is_binary/1) ++ Enum.flat_map(node.children, &texts(&1, keep?))
  end

  defp plain_text(text) do
    text
    |> String.replace(~r/\[\/?[a-z_0-9]+(=[^\]]*)?\]/i, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # A modal Popup's DOM ID (its focus trap needs one): unique per instance
  # inside a component, through the `scope` its callers pass down.
  defp overlay_dom_id(node, %{surface: :page}), do: "bubble-overlay-" <> bid(node)

  defp overlay_dom_id(node, _ctx),
    do: {:expr, ~s|"bubble-overlay-\#{@scope}-" <> | <> literal(bid(node))}

  # Reusables that render a modal Popup or an icon (themselves or nested):
  # elements with DOM IDs, so their components take a `scope`.
  defp scoped(frontend) do
    by_ref =
      Enum.reduce(frontend.reusables, %{}, fn d, acc ->
        acc |> Map.put(d.map_key, d) |> Map.put(surface_id(d), d)
      end)

    for definition <- frontend.reusables,
        modal?(definition, by_ref, MapSet.new([definition.map_key])),
        into: MapSet.new(),
        do: definition.map_key
  end

  defp modal?(%Node{runtime: %{"overlay" => "popup", "modal" => true}}, _by_ref, _seen), do: true

  # An icon's inline symbol has an ID too.
  defp modal?(%Node{attributes: %{"asset_fragment" => fragment}}, _by_ref, _seen)
       when is_binary(fragment) and fragment != "",
       do: true

  defp modal?(%Node{kind: :reusable_instance, definition_ref: ref}, by_ref, seen) do
    case by_ref[ref] do
      %Node{} = d ->
        not MapSet.member?(seen, d.map_key) and modal?(d, by_ref, MapSet.put(seen, d.map_key))

      _ ->
        false
    end
  end

  defp modal?(%Node{children: children}, by_ref, seen),
    do: Enum.any?(children, &modal?(&1, by_ref, seen))

  # --- content --------------------------------------------------------------------

  # {:static, text} or {:expr, elixir}: a slot's resolved value, a
  # reusable-parameter attribute, a compiled binding, or empty with a marker.
  defp slot(node, name, ctx, acc) do
    cond do
      override = override(node, name, ctx) ->
        {override_slot(override), acc}

      (value = resolved(node, name)) != nil and (is_binary(value) or is_number(value)) ->
        {{:static, to_string(value)}, acc}

      binding = node.bindings[name] ->
        binding_slot(node, name, binding, ctx, acc)

      true ->
        {{:static, ""}, acc}
    end
  end

  defp override(node, slot, %{surface: :reusable} = ctx) do
    with %{} = slots <- ctx.overrides[ctx.entry.node.map_key],
         path when is_list(path) <- node_path(ctx.entry.node, node) do
      slots[{path, slot}]
    else
      _ -> nil
    end
  end

  defp override(_node, _slot, _ctx), do: nil

  defp override_slot(%{as: :slot, name: name, block: block}), do: {:slot, name, block}
  defp override_slot(%{name: name}), do: {:expr, "@" <> name}

  defp node_path(%Node{} = root, %Node{exporter_id: id}) do
    root
    |> path_nodes([])
    |> Enum.find_value(fn {path, n} -> if n.exporter_id == id, do: path end)
  end

  # A compiled binding is a helper of the surface module; its free
  # variables are assigns on a page, attributes of a component (passed down
  # from the page, see required_vars/2).
  defp binding_slot(node, name, binding, ctx, acc) do
    case ctx.expressions[binding.id] do
      %{source: source, bindings: vars} ->
        helper = helper_name(name, node, acc)
        args = Enum.map(vars, & &1.var)
        acc = Enum.reduce(args, acc, &need_var(&2, &1, ctx))

        acc = %{
          acc
          | helpers: [
              %{name: helper, args: args, source: source, node: node, slot: name}
              | acc.helpers
            ],
            counts: Map.update!(acc.counts, "bindings_compiled", &(&1 + 1))
        }

        call = helper <> "(" <> Enum.map_join(args, ", ", &("@" <> &1)) <> ")"
        {{:expr, call}, acc}

      _ ->
        {{:static, ""}, mark_binding(acc, node, name, binding)}
    end
  end

  # A page assigns a variable (nil until workflows set it; the signed-in
  # user comes from on_mount); a component declares it as an attribute.
  defp need_var(acc, "current_user", %{surface: :page}), do: acc
  defp need_var(acc, var, %{surface: :page}), do: add_assign(acc, var, "nil")
  defp need_var(acc, _var, _ctx), do: acc

  defp mark_binding(acc, node, name, binding) do
    acc = mark(acc, node, "#{name}: dynamic #{binding.kind} not compiled")
    %{acc | counts: Map.update!(acc.counts, "bindings_marked", &(&1 + 1))}
  end

  defp helper_name(slot, node, acc) do
    base = "#{ident(slot)}_#{ident(bid(node))}"
    taken = MapSet.new(acc.helpers, & &1.name)

    if MapSet.member?(taken, base),
      do:
        Enum.find_value(
          2..(MapSet.size(taken) + 2),
          &if(MapSet.member?(taken, "#{base}_#{&1}"), do: nil, else: "#{base}_#{&1}")
        ),
      else: base
  end

  defp static_or_empty({:static, text}), do: text
  defp static_or_empty(_), do: ""

  defp slot_attr({:static, ""}), do: nil
  defp slot_attr({:static, text}), do: text
  defp slot_attr({:expr, expr}), do: {:raw, "{" <> expr <> "}"}

  defp text_html(raw) do
    cond do
      Bbcode.present?(raw) -> raw |> Bbcode.to_html() |> escape_braces()
      String.contains?(raw, "\n") -> raw |> escape() |> String.replace("\n", "<br>")
      true -> escape(raw)
    end
  end

  defp text_tag(:h1), do: "h1"
  defp text_tag(:h2), do: "h2"
  defp text_tag(:h3), do: "h3"
  defp text_tag(:h4), do: "h4"
  defp text_tag(_), do: "p"

  defp button_inner(%Node{variant: variant} = node, text, ctx)
       when variant in [:icon, :label_icon] do
    svg = icon_svg(node, ctx)

    label =
      case text do
        {:static, ""} -> []
        {:static, t} -> escape(t)
        {:expr, expr} -> ["{", expr, "}"]
      end

    cond do
      svg == "" -> label
      label == [] -> svg
      node.attributes["icon_placement"] == "right" -> [label, svg]
      true -> [svg, label]
    end
  end

  defp button_inner(_node, {:static, text}, _ctx), do: escape(text)
  defp button_inner(_node, {:expr, expr}, _ctx), do: ["{", expr, "}"]

  # An icon's symbol inline, as the exporter does. Its ID is unique per
  # page: inside a component it includes the `scope` callers pass down.
  defp icon_svg(node, ctx) do
    fragment = node.attributes["asset_fragment"]

    with %{bytes: bytes} <- ctx.assets[node.exporter_id],
         [attrs, inner] <- inline_icon(bytes, fragment) do
      icon_set = escape_attr(node.attributes["icon_set"] || "fa")

      {id, href} =
        if ctx.surface == :page,
          do:
            {~s("bubble-icon-#{escape_attr(bid(node))}"),
             ~s("#bubble-icon-#{escape_attr(bid(node))}")},
          else:
            {~s({"bubble-icon-\#{@scope}-" <> #{literal(bid(node))}}),
             ~s({"#bubble-icon-\#{@scope}-" <> #{literal(bid(node))}})}

      [
        ~s(<svg viewBox="0 0 32 32" data-icon-set="#{icon_set}" aria-hidden="true"><defs>),
        "<symbol id=",
        id,
        escape_braces(attrs),
        ">",
        escape_braces(inner),
        ~s(</symbol></defs><use width="32" height="32" href=),
        href,
        "></use></svg>"
      ]
    else
      _ -> ""
    end
  end

  defp inline_icon(bytes, fragment) when is_binary(bytes) and is_binary(fragment) do
    regex =
      Regex.compile!("<symbol\\s+id=\"#{Regex.escape(fragment)}\"([^>]*)>(.*?)</symbol>", "s")

    Regex.run(regex, bytes, capture: :all_but_first)
  end

  defp inline_icon(_bytes, _fragment), do: nil

  defp image(node, ctx, acc) do
    alt = resolved(node, "alt") || node.attributes["alt"] || ""
    attrs = [{"src", image_src(node, ctx)}, {"alt", alt}]

    sources =
      node
      |> ResponsiveImages.variants()
      |> Enum.reverse()
      |> Enum.map(fn variant ->
        src = asset_url(ctx.assets[variant.id]) || "data:,"

        [
          "<source media=\"",
          escape_attr(variant.media),
          "\" srcset=\"",
          escape_attr(src),
          "\">\n"
        ]
      end)

    {img, acc} = void("img", node, attrs, ctx, acc)

    case sources do
      [] -> {img, acc}
      _ -> {["<picture style=\"display: contents\">\n", sources, img, "\n</picture>"], acc}
    end
  end

  defp image_src(node, ctx) do
    case ctx.assets[node.exporter_id] do
      %{path: _} = asset -> asset_url(asset)
      %{failed?: true} -> nil
      _ -> Map.get(node.attributes, "asset_src") || resolved(node, "src") || ""
    end
  end

  defp asset_url(%{path: path}) when is_binary(path), do: "/images/bubble/" <> Path.basename(path)
  defp asset_url(_), do: nil

  defp search(node, ctx, acc) do
    choices = choices(node)
    list_id = "list-" <> bid(node)
    placeholder = resolved(node, "placeholder")

    attrs =
      node.attributes
      |> Enum.to_list()
      |> put_attr("type", "search")
      |> put_attr("placeholder", placeholder)
      |> put_new_attr("aria-label", placeholder || node.name || "Search")
      |> then(&if choices == [], do: &1, else: put_attr(&1, "list", list_id))

    {input, acc} = void("input", node, attrs, ctx, acc)

    if choices == [] do
      {input, acc}
    else
      options =
        Enum.map(choices, fn choice ->
          [
            "<option value=\"",
            escape_attr(to_string(choice["value"] || choice["label"] || "")),
            "\"></option>"
          ]
        end)

      {[input, "<datalist id=\"", escape_attr(list_id), "\">", options, "</datalist>"], acc}
    end
  end

  defp input_attrs(%Node{kind: :slider} = node, _ctx, acc) do
    {node.attributes |> Map.drop(["placeholder"]) |> Enum.to_list() |> put_attr("type", "range"),
     acc}
  end

  defp input_attrs(%Node{kind: :file_input} = node, _ctx, acc) do
    label = resolved(node, "placeholder") || node.name || "File"

    {node.attributes
     |> Map.drop(["value", "placeholder"])
     |> Enum.to_list()
     |> put_attr("type", "file")
     |> put_new_attr("aria-label", label), acc}
  end

  defp input_attrs(node, ctx, acc) do
    {placeholder, acc} = slot(node, "placeholder", ctx, acc)
    placeholder_text = nonblank(static_or_empty(placeholder))

    {value, acc} =
      if node.bindings["value"], do: slot(node, "value", ctx, acc), else: {nil, acc}

    value =
      case value do
        {:expr, _} = expr -> slot_attr(expr)
        _ -> input_display_value(node)
      end

    attrs =
      node.attributes
      |> Enum.to_list()
      |> put_new_attr("type", "text")
      |> put_attr("value", value)
      |> put_attr("placeholder", slot_attr(placeholder))
      |> put_new_attr("aria-label", placeholder_text)

    {attrs, acc}
  end

  defp range_slider(node, ctx, acc) do
    min = node.attributes["min"]
    max = node.attributes["max"]
    low = node.attributes["value"] || min
    high = node.attributes["value_high"] || max
    base = node.attributes |> Map.take(["min", "max", "step", "disabled"]) |> Enum.to_list()

    input = fn value, label ->
      attrs =
        base
        |> put_attr("type", "range")
        |> put_attr("value", value)
        |> put_attr("aria-label", label)

      ["<input", attrs_html(sorted_attrs(attrs)), ">"]
    end

    attrs =
      node.attributes
      |> Map.drop(["min", "max", "step", "value", "value_high", "type"])
      |> Enum.to_list()
      |> put_attr("role", "group")

    element("div", node, attrs, [input.(low, "Range start"), input.(high, "Range end")], ctx, acc)
  end

  defp link_attrs(node, ctx) do
    node.attributes
    |> Map.drop(["disabled", "asset_src", "asset_fragment", "icon_set", "href"])
    |> Enum.to_list()
    |> put_attr("href", link_href(node, ctx))
  end

  defp link_href(%Node{attributes: %{"disabled" => true}}, _ctx), do: nil

  defp link_href(node, ctx) do
    case {override(node, "destination", ctx), node.content} do
      # The instance's destination, checked by the caller (override_expr/3).
      {%{name: name}, _} -> {:expr, "@" <> name}
      {nil, %{"destination" => %{binding_id: _}}} -> nil
      {nil, _} -> static_href(resolved(node, "destination"), ctx)
    end
  end

  defp static_href(dest, ctx) do
    case href(dest, ctx) do
      {:page, path} -> {:expr, "~p" <> inspect(path)}
      {:url, url} -> url
      nil -> nil
    end
  end

  # A destination: a page of the app (its locked path) or an allowlisted
  # URL (`Safety.safe_href?/1`); anything else is dropped.
  defp href(dest, ctx) when is_binary(dest) do
    cond do
      page = ctx.names.page_by_ref[dest] -> {:page, page.path}
      Safety.safe_href?(dest) -> {:url, dest}
      true -> nil
    end
  end

  defp href(_dest, _ctx), do: nil

  defp navigation_button?(
         %Node{kind: :button, content: %{"destination" => %{resolved: dest}}},
         _ctx
       )
       when is_binary(dest) and dest != "",
       do: true

  # In a reusable, an instance may give the button its destination.
  defp navigation_button?(%Node{kind: :button} = node, ctx),
    do: override(node, "destination", ctx) != nil

  defp navigation_button?(_node, _ctx), do: false

  defp choices(node) do
    case resolved(node, "choices") do
      choices when is_list(choices) -> choices
      _ -> []
    end
  end

  defp dropdown_placeholder("", _selected), do: ""

  defp dropdown_placeholder(placeholder, selected) do
    attrs = [
      {"disabled", true},
      {"selected", is_nil(selected) or selected == ""},
      {"value", ""}
    ]

    ["<option", attrs_html(attrs), ">", escape(placeholder), "</option>"]
  end

  defp option_html(%{"label" => label, "value" => value}, selected) do
    value = to_string(value)
    attrs = [{"selected", to_string(selected) == value}, {"value", value}]
    ["<option", attrs_html(attrs), ">", escape(label), "</option>"]
  end

  defp option_html(_choice, _selected), do: ""

  defp radio_option(%{"label" => label, "value" => value}, selected, name, index, node) do
    value = to_string(value)
    option_id = "#{name}_option_#{index}"

    attrs =
      node.attributes
      |> Enum.to_list()
      |> put_attr("type", "radio")
      |> put_attr("id", option_id)
      |> put_attr("name", name)
      |> put_attr("value", value)
      |> put_attr("checked", to_string(selected) == value)
      |> sorted_attrs()

    [
      "<input",
      attrs_html(attrs),
      ">",
      "<label for=\"",
      escape_attr(option_id),
      "\">",
      escape(label),
      "</label>"
    ]
  end

  defp radio_option(_choice, _selected, _name, _index, _node), do: ""

  # Static en-US presentation of the frozen Input formats (as the exporter).
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
        if String.match?(value, ~r/^[0-9]{10}$/), do: "(#{area}) #{prefix}-#{line}", else: value

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

  defp nonblank(value) when is_binary(value) and value != "", do: value
  defp nonblank(_), do: nil

  # The element's authored HTML ID, once per page: Bubble allows
  # duplicates (a reusable element instanced twice), a LiveView does not.
  defp put_authored_id(attrs, node, ctx, acc) do
    case authored_id(node) do
      nil ->
        {attrs, acc}

      id when ctx.surface == :reusable ->
        {attrs,
         mark(acc, node, "HTML ID #{id} dropped: a reusable element renders once per instance")}

      id ->
        if MapSet.member?(acc.dom_ids, id),
          do: {attrs, mark(acc, node, "duplicate HTML ID #{id} dropped")},
          else: {put_attr(attrs, "id", id), %{acc | dom_ids: MapSet.put(acc.dom_ids, id)}}
    end
  end

  defp authored_id(%Node{kind: :placeholder}), do: nil

  defp authored_id(node) do
    case resolved(node, "html_id") do
      id when is_binary(id) and byte_size(id) in 1..256 ->
        if Regex.match?(~r/^[A-Za-z_-][A-Za-z0-9_-]*$/, id), do: id

      _ ->
        nil
    end
  end

  # --- markers --------------------------------------------------------------------

  defp mark(acc, node, note) do
    markers = Map.get(acc, :markers, %{})
    id = bid(node)

    %{
      acc
      | counts: Map.update!(acc.counts, "markers", &(&1 + 1))
    }
    |> Map.put(:markers, Map.update(markers, id, [note], &(&1 ++ [note])))
  end

  defp marker_html(acc, node) do
    case get_in(acc, [Access.key(:markers, %{}), bid(node)]) do
      nil ->
        ""

      notes ->
        Enum.map(notes, fn note ->
          ["<%!-- TODO(bubble:", comment_safe(bid(node)), ") ", comment_safe(note), " --%>"]
        end)
    end
  end

  # Text inside a HEEx comment: it cannot end it or open an EEx tag.
  defp comment_safe(text),
    do: text |> to_string() |> String.replace("--%>", "-- %>") |> String.replace("<%", "< %")

  # Text for a `#` comment of generated Elixir: one line.
  defp comment_line(text),
    do: text |> to_string() |> String.replace(~r/[\x00-\x1f\x7f\x{2028}\x{2029}]/u, " ")

  # Text inside a generated heredoc (`@moduledoc """`): what `inspect/1`
  # escapes (quotes, backslashes, `\#{`, control characters) without its
  # quotes.
  defp doc_text(text) do
    text |> to_string() |> comment_line() |> inspect() |> String.slice(1..-2//1)
  end

  # An Elixir string literal of `value` for generated source: `inspect/1`
  # escapes quotes, backslashes, `\#{` and control characters (or prints a
  # binary). Braces and `<` become hex escapes too: HEEx finds the end of a
  # `{…}` expression by counting braces, strings included, and EEx reads
  # `<%` anywhere in a template.
  defp literal(value) do
    value
    |> to_string()
    |> inspect()
    |> String.replace("{", "\\x7B")
    |> String.replace("}", "\\x7D")
    |> String.replace("<", "\\x3C")
  end

  defp runtime_note(runtime) do
    type = runtime["type"] || "container"

    if runtime["repeats"],
      do: "#{type}: its items come from its data source (one template per item)",
      else: "#{type}: its content is rendered at runtime"
  end

  defp item_assign(node), do: "items_" <> ident(bid(node))

  defp add_assign(acc, name, default),
    do: %{acc | assigns: MapSet.put(acc.assigns, {name, default})}

  # --- attributes and escaping ----------------------------------------------------

  defp put_attr(attrs, key, value), do: List.keystore(attrs, key, 0, {key, value})

  defp put_new_attr(attrs, key, value) do
    if List.keymember?(attrs, key, 0) and elem(List.keyfind(attrs, key, 0), 1) not in [nil, ""],
      do: attrs,
      else: put_attr(attrs, key, value)
  end

  defp sorted_attrs(attrs) do
    attrs
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == false or v == "" end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
  end

  # A component call's attributes: a component receives a quoted value as
  # is (HEEx decodes no character reference there) and escapes it when it
  # renders it, so a value that would need escaping is an Elixir literal.
  defp component_attrs_html(attrs) do
    Enum.map(attrs, fn
      {key, value} when is_binary(value) ->
        if Regex.match?(~r/[&<>"'{}\r\n]/, value),
          do: {key, {:expr, literal(value)}},
          else: {key, value}

      other ->
        other
    end)
    |> attrs_html()
  end

  defp attrs_html(attrs) do
    attrs
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == false or v == "" end)
    |> Enum.map(fn
      {key, true} -> [" ", key]
      {key, {:raw, code}} -> [" ", key, "=", code]
      {key, {:expr, code}} -> [" ", key, "={", code, "}"]
      {key, value} -> [" ", key, "=\"", escape_attr(to_string(value)), "\""]
    end)
  end

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

  defp blank?(iodata), do: iodata |> IO.iodata_to_binary() |> String.trim() == ""

  defp escape_textarea(value) do
    value
    |> escape()
    |> String.replace("\r\n", "&#10;")
    |> String.replace("\r", "&#10;")
    |> String.replace("\n", "&#10;")
  end

  # HTML-escaped text that HEEx reads literally: braces would interpolate.
  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> escape_braces()
  end

  # An attribute value: escaped, with line breaks as character references
  # (the template's indentation would otherwise change a multi-line value).
  defp escape_attr(value) do
    value
    |> escape()
    |> String.replace("\r", "&#13;")
    |> String.replace("\n", "&#10;")
  end

  defp escape_braces(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> String.replace("{", "&lbrace;")
    |> String.replace("}", "&rbrace;")
  end

  defp ident(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "x"
      <<d, _::binary>> = s when d in ?0..?9 -> "n" <> s
      s -> s
    end
  end

  # --- modules --------------------------------------------------------------------

  defp live_view_module(module, entry, acc, base) do
    imports = Enum.map(Enum.sort(acc.imports), &"  import #{base.web}.Reusables.#{&1}\n")
    title = entry.node.attributes["title"] || entry.node.name || entry.label

    pipeline =
      ["socket", "|> assign(:page_title, #{inspect(title)})"] ++
        Enum.map(Enum.sort(acc.assigns), fn {name, default} ->
          "|> assign(:#{name}, #{default})"
        end)

    helpers = acc.helpers |> Enum.reverse() |> Enum.map(&helper_source(&1, base))

    [
      "defmodule #{module} do\n",
      "  @moduledoc \"\"\"\n",
      "  The Bubble page #{inspect(entry.label)} (bubble:#{doc_text(entry.id)}), at #{entry.path}.\n\n",
      "  Scaffolded by bubble_ex (WTF-370); this module and its template\n",
      "  (#{entry.file}.html.heex) are yours: later generations never overwrite\n",
      "  them. Elements keep their `data-bubble-id`; `TODO(bubble:<id>)`\n",
      "  markers in the template are what was not lowered yet.\n",
      "  \"\"\"\n",
      "  use #{base.web}, :live_view\n\n",
      "  alias #{base.web}.Bubble, warn: false\n",
      imports,
      "\n  @impl true\n",
      "  def mount(_params, _session, socket) do\n",
      "    {:ok,\n",
      "     ",
      Enum.join(pipeline, "\n     "),
      "}\n",
      "  end\n",
      helpers,
      "end\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp helper_source(%{name: name, args: args, source: source, node: node, slot: slot}, base) do
    body = if text?(source), do: source, else: "#{base.runtime}.text(#{source})"
    params = Enum.join(args, ", ")

    """

      # bubble:#{comment_line(bid(node))} #{slot}
      defp #{name}(#{params}) do
        #{String.replace(body, "\n", "\n    ")}
      end
    """
  end

  # Whether compiled source is already shown text: a concatenation or a
  # runtime `text/1` call.
  defp text?(source) do
    case Code.string_to_quoted(source) do
      {:ok, {:<>, _, _}} -> true
      {:ok, {{:., _, [_module, :text]}, _, [_]}} -> true
      _ -> false
    end
  end

  defp component_module(module, entry, acc, base) do
    imports =
      acc.imports
      |> Enum.sort()
      |> Enum.map_join("", &"  import #{base.web}.Reusables.#{&1}\n")

    # Parameter values and binding variables default to nil, runtime
    # containers' items to [].
    overrides = Map.values(base.overrides[entry.node.map_key] || %{})

    slots =
      overrides
      |> Enum.filter(&(&1.as == :slot))
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join("", &"  slot :#{&1}\n")

    params =
      (Enum.map(Enum.reject(overrides, &(&1.as == :slot)), & &1.name) ++
         Map.get(base.required, entry.node.map_key, []))
      |> Enum.map(&{&1, "nil"})
      |> Kernel.++(Enum.to_list(acc.assigns))
      |> Kernel.++(
        if MapSet.member?(base.scoped, entry.node.map_key), do: [{"scope", ~s("")}], else: []
      )
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.map_join("", fn {name, default} ->
        "  attr :#{name}, :any, default: #{default}\n"
      end)

    helpers = acc.helpers |> Enum.reverse() |> Enum.map_join("", &helper_source(&1, base))

    """
    defmodule #{module} do
      @moduledoc \"\"\"
      The Bubble reusable element #{inspect(entry.node.name || entry.id)} (bubble:#{doc_text(entry.id)}).

      Scaffolded by bubble_ex (WTF-370); this module and its template
      (#{entry.file}.html.heex) are yours: later generations never overwrite
      them. An instance passes its size and place as `class` and its
      `data-bubble-id`; attributes named after an element and a slot carry
      the values an instance's parameters resolve to.
      \"\"\"
      use #{base.web}, :html

      alias #{base.web}.Bubble, warn: false
    #{imports}
      embed_templates "#{entry.file}.html"

      attr :class, :any, default: nil
    #{params}  attr :rest, :global
    #{slots}
      def #{entry.function}(assigns)
    #{helpers}end
    """
    |> String.replace(~r/\n\n\n+/, "\n\n")
  end

  # Elixir source as `mix format` leaves it (with Phoenix's formatter
  # imports), so the owner's first format changes nothing.
  defp format(source) do
    IO.iodata_to_binary([
      Code.format_string!(source,
        locals_without_parens: [
          attr: 2,
          attr: 3,
          slot: 1,
          slot: 2,
          embed_templates: 1,
          embed_templates: 2,
          pipe_through: 1,
          live: 2,
          live: 3,
          ash_authentication_live_session: 1,
          ash_authentication_live_session: 2
        ]
      ),
      "\n"
    ])
  end

  # --- generated files ------------------------------------------------------------

  defp stylesheet(frontend) do
    tokens = Css.tokens(frontend)

    theme =
      tokens
      |> Enum.flat_map(fn {name, value} ->
        case theme_name(name) do
          nil -> []
          theme -> ["  #{theme}: #{value};\n"]
        end
      end)

    aliases =
      Enum.map(tokens, fn {name, value} ->
        case theme_name(name) do
          nil -> "    #{name}: #{value};\n"
          theme -> "    #{name}: var(#{theme});\n"
        end
      end)

    {base_rules, closing, text_defaults} = split_base()

    components =
      frontend
      |> Css.style_rules()
      |> Enum.map(fn {style, declarations, breakpoints} ->
        own =
          if declarations == [],
            do: "",
            else: "  .#{style.class_name} {\n#{decls(declarations, "    ")}  }\n"

        media =
          Enum.map_join(breakpoints, "", fn {op, width, decls} ->
            "  @media (width #{op} #{width}px) {\n    .#{style.class_name} {\n#{decls(decls, "      ")}    }\n  }\n"
          end)

        own <> media
      end)

    """
    /* The Bubble app's design tokens and named styles as Tailwind v4
       (WTF-359 Q4): tokens are theme variables (`text-bubble-primary`,
       `font-bubble-default`), Bubble's own variable names alias them, and
       every named style is a component class. No daisyUI. Styles the
       elements' utilities cannot express are in bubble_residue.css. */

    @theme static {
    #{Enum.join(theme)}}

    @layer base {
      :root {
    #{Enum.join(aliases)}  }

    #{indent_block(base_rules, "  ")}
      /* Bubble's modal focus trap guards take no room. */
      [data-overlay][aria-modal] > [tabindex="0"][aria-hidden="true"] { position: absolute; }
    }

    @layer components {
    #{indent_block(text_defaults, "  ")}
    #{Enum.join(components)}}

    /* A closed overlay stays closed whatever its display utility. */
    #{closing}
    """
    |> String.replace(~r/\n\n\n+/, "\n\n")
  end

  # The exporter's base: element resets (base layer), the overlay closing
  # rule (unlayered: it must win over display utilities) and the default
  # text classes (component classes).
  defp split_base do
    lines = Css.base() |> String.split("\n", trim: true)
    {closing, rest} = Enum.split_with(lines, &String.starts_with?(&1, "[data-overlay]"))
    {classes, base} = Enum.split_with(rest, &String.starts_with?(&1, "."))
    {Enum.join(base, "\n"), Enum.join(closing, "\n"), Enum.join(classes, "\n")}
  end

  defp indent_block(text, prefix),
    do: text |> String.split("\n") |> Enum.map_join("\n", &(prefix <> &1))

  defp decls(declarations, prefix),
    do: Enum.map_join(declarations, "", fn {k, v} -> "#{prefix}#{k}: #{v};\n" end)

  # `--color_primary_default` → `--color-bubble-primary`; `--font_default`
  # → `--font-bubble-default`; RGB triplets stay Bubble's.
  defp theme_name("--font_default"), do: "--font-bubble-default"

  defp theme_name("--color_" <> rest) do
    if String.ends_with?(rest, "_rgb"),
      do: nil,
      else: "--color-bubble-" <> theme_suffix(String.replace_suffix(rest, "_default", ""))
  end

  defp theme_name("--font_" <> rest),
    do: "--font-bubble-" <> theme_suffix(String.replace_suffix(rest, "_default", ""))

  defp theme_name(_), do: nil

  defp theme_suffix(name), do: name |> String.replace("_", "-") |> String.downcase()

  # Color variables with a theme utility: `--color_primary_default` → `bubble-primary`.
  defp token_utilities(frontend) do
    for {name, _value} <- Css.tokens(frontend),
        theme = theme_name(name),
        String.starts_with?(theme, "--color-"),
        into: %{},
        do: {name, String.replace_prefix(theme, "--color-", "")}
  end

  defp residue(surfaces) do
    rules =
      Enum.map(surfaces, &surface_residue/1)
      |> Enum.reject(&(&1 == ""))

    """
    /* Styles Tailwind utilities cannot carry (WTF-359 Q4): media rules,
       child and pseudo-element rules, anchor positioning and values a class
       cannot hold, one rule per element (by data-bubble-id). Unlayered, so
       they win over utilities, as in the Bubble page. Move a rule into the
       template when you refine its element. */

    #{Enum.join(rules, "\n")}
    """
    |> String.replace(~r/\n\n\n+/, "\n\n")
  end

  defp surface_residue(%{acc: %{residue: []}}), do: ""

  defp surface_residue(%{acc: %{residue: rules}, entry: entry} = surface) do
    label =
      if surface.kind == :page,
        do: "page #{entry.label} (#{entry.id})",
        else: "reusable #{entry.node.name || entry.id} (#{entry.id})"

    "/* #{String.replace(label, "*/", "* /")} */\n" <> Enum.join(Enum.reverse(rules), "\n")
  end

  # <Web>.Bubble: the overlay JS commands and the Escape hook.
  defp helpers(ctx, frontend) do
    modals =
      (frontend.pages ++ frontend.reusables)
      |> Enum.flat_map(&overlay_nodes/1)
      |> Enum.filter(&match?(%Node{runtime: %{"overlay" => "popup", "modal" => true}}, &1))
      |> Enum.map(&literal(bid(&1)))
      |> Enum.uniq()
      |> Enum.sort()

    Templates.render("lib/web/components/bubble.ex", %{web: ctx.web, modals: modals})
  end

  defp overlay_nodes(%Node{runtime: %{"boundary" => "overlay"}} = node),
    do: [node | Enum.flat_map(node.children, &overlay_nodes/1)]

  defp overlay_nodes(%Node{children: children}), do: Enum.flat_map(children, &overlay_nodes/1)

  defp traceability_test(ctx, pages, reusables, base) do
    cases =
      Enum.map_join(pages, ",\n", fn page ->
        "    {#{literal(page.entry.id)}, #{inspect(page.entry.path)}, #{literal(page.entry.label)},\n" <>
          "     #{ctx.web}.#{page.entry.module}, #{ids_literal(page.acc.ids)}}"
      end)

    components =
      Enum.map_join(reusables, ",\n", fn reusable ->
        entry = reusable.entry
        label = entry.node.name || entry.id

        "    {#{literal(entry.id)}, #{literal(label)},\n" <>
          "     &#{base.web}.Reusables.#{entry.module}.#{entry.function}/1, #{ids_literal(reusable.acc.ids)}}"
      end)

    """
    defmodule #{ctx.web}.BubbleSurfacesTest do
      # Every page scaffolded from Bubble is routed, mounts and renders each
      # of its elements (data-bubble-id), and every reusable element renders
      # its elements with its defaults, unless a decision removed them
      # (WTF-370). Each test is tagged `bubble: <the surface's Bubble ID>`.
      use #{ctx.web}.ConnCase, async: true

      import Phoenix.LiveViewTest

      @pages [
    #{cases}
      ]

      @reusables [
    #{components}
      ]

      for {id, path, label, module, ids} <- @pages do
        @path path
        @module module
        @ids ids
        # The task CLI binds a surface's render check by its Bubble ID.
        @tag bubble: id
        test "the Bubble page \#{label} (\#{path}) renders every element", %{conn: conn} do
          assert_routed(@path, @module)
          {:ok, view, _html} = live(conn, @path)
          assert missing(render(view), @ids) == []
        end
      end

      for {id, label, component, ids} <- @reusables do
        @component component
        @ids ids
        @tag bubble: id
        test "the Bubble reusable element \#{label} renders every element" do
          assert missing(render_component(@component, %{}), @ids) == []
        end
      end

      # The generated #{ctx.web}.BubbleRoutes routes every page; a router
      # scaffolded before WTF-370 does not call it.
      def assert_routed(path, module) do
        case Phoenix.Router.route_info(#{ctx.web}.Router, "GET", path, "www.example.com") do
          %{phoenix_live_view: live} when elem(live, 0) == module ->
            :ok

          %{plug: plug} ->
            flunk(\"\"\"
            \#{inspect(module)} is not routed at \#{path}: \#{inspect(plug)} takes
            the path in #{ctx.web}.Router (defined before the Bubble routes).
            Remove that route to serve the Bubble page there.
            \"\"\")

          _ ->
            flunk(\"\"\"
            \#{inspect(module)} is not routed at \#{path}. Call the generated
            routes once in #{ctx.web}.Router (after the browser scope):

                require #{ctx.web}.BubbleRoutes
                #{ctx.web}.BubbleRoutes.bubble_routes()
            \"\"\")
        end
      end

      # The expected Bubble IDs no element of `html` carries. (Public: a
      # frontend without pages or reusables leaves one of them unused.)
      def missing(html, ids) do
        found =
          html
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("[data-bubble-id]")
          |> LazyHTML.attribute("data-bubble-id")
          |> MapSet.new()

        Enum.reject(ids, &MapSet.member?(found, &1))
      end
    end
    """
    |> String.replace("@pages [\n\n  ]", "@pages []")
    |> String.replace("@reusables [\n\n  ]", "@reusables []")
  end

  # The Bubble IDs a surface renders, as a list of string literals.
  defp ids_literal(ids) do
    ids
    |> Enum.reverse()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map_join(", ", &literal/1)
    |> then(&("[" <> &1 <> "]"))
  end

  # --- report ---------------------------------------------------------------------

  defp report(frontend, surfaces) do
    counts =
      Enum.reduce(surfaces, %{}, fn surface, acc ->
        Map.merge(acc, surface.acc.counts, fn _k, a, b -> a + b end)
      end)

    Map.merge(counts, %{
      "pages" => Enum.count(surfaces, &(&1.kind == :page)),
      "reusables" => Enum.count(surfaces, &(&1.kind == :reusable)),
      "named_styles" => length(frontend.styles)
    })
  end
end
