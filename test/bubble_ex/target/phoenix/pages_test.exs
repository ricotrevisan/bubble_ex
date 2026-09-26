defmodule BubbleEx.Target.Phoenix.PagesTest do
  # The HEEx emitter (WTF-370): pages as LiveViews, reusables as function
  # components, Tailwind styles and residue, overlays, compiled bindings.
  # scripts/phoenix_compile_check.sh compiles and mounts the output and
  # scripts/heex_fidelity.sh runs the frozen cases against it.
  use ExUnit.Case, async: true

  alias BubbleEx.Target.Phoenix
  alias BubbleEx.Target.Phoenix.Tailwind

  defp app(path), do: path |> File.read!() |> Jason.decode!()
  defp case_app(id), do: app("test/support/fidelity/cases/#{id}/source/payload.json")

  defp render(app, opts \\ []) do
    {:ok, model} = BubbleEx.Model.build(app)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    opts = [module: "Shop", frontend: frontend, expressions: expressions] ++ opts
    {:ok, files} = Phoenix.render(project, opts)
    {:ok, ^files} = Phoenix.render(project, opts)
    {files, project, opts}
  end

  describe "pages and components" do
    setup do
      {files, project, opts} = render(case_app("bpgwgmpz"))
      %{files: files, project: project, opts: opts}
    end

    test "pages are owned LiveViews routed at their Bubble paths", %{files: files} do
      live = files["lib/shop_web/live/bubbleex_complex_demo_live.ex"]
      assert live =~ "defmodule ShopWeb.BubbleexComplexDemoLive do"
      assert live =~ "use ShopWeb, :live_view"
      template = files["lib/shop_web/live/bubbleex_complex_demo_live.html.heex"]
      assert template =~ ~s(<main data-bubble-id="bpgwgmpz")

      # The owned router calls the generated routes, which hold the pages.
      assert files["lib/shop_web/router.ex"] =~ "ShopWeb.BubbleRoutes.bubble_routes()"
      routes = files["lib/shop_web/bubble_routes.ex"]
      assert routes =~ "ash_authentication_live_session :bubble_pages"
      assert routes =~ ~s(live "/bubbleex-complex-demo", ShopWeb.BubbleexComplexDemoLive)

      manifest = Jason.decode!(files[".wtf/generated.json"])
      assert Map.has_key?(manifest["owned"], "lib/shop_web/live/bubbleex_complex_demo_live.ex")
      assert Map.has_key?(manifest["owned"], "lib/shop/bubble/runtime.ex")

      for path <-
            ~w(assets/css/bubble.css assets/css/bubble_residue.css .wtf/surfaces.json
               lib/shop_web/components/bubble.ex lib/shop_web/bubble_routes.ex
               test/shop_web/bubble_surfaces_test.exs),
          do: assert(Map.has_key?(manifest["generated"], path), path)

      assert manifest["inputs"]["frontend"]["bubble_id"] == "tiptap-plugin"
    end

    test "every rendered element carries its data-bubble-id", %{files: files} do
      template = files["lib/shop_web/live/bubbleex_complex_demo_live.html.heex"]
      test = files["test/shop_web/bubble_surfaces_test.exs"]

      {:ok, quoted} = Code.string_to_quoted(test)

      {_, [ids]} =
        Macro.prewalk(quoted, [], fn
          {:{}, _, ["bpgwgmpz", "/bubbleex-complex-demo", _label, _module, ids]} = node, acc ->
            {node, [ids | acc]}

          node, acc ->
            {node, acc}
        end)

      assert "bpgwgmpz" in ids and length(ids) > 20

      components =
        files
        |> Enum.filter(fn {p, _} -> String.ends_with?(p, ".html.heex") end)
        |> Enum.map_join(&elem(&1, 1))

      for id <- ids, do: assert(components =~ ~s(data-bubble-id="#{id}"), id)
      assert template =~ "<.bubbleex_complex_card data-bubble-id="
    end

    test "reusables are function components with embedded templates", %{files: files} do
      card = files["lib/shop_web/components/reusables/bubbleex_complex_card.ex"]
      assert card =~ "defmodule ShopWeb.Reusables.BubbleexComplexCard do"
      assert card =~ ~s(embed_templates "bubbleex_complex_card.html")
      assert card =~ "def bubbleex_complex_card(assigns)"
      assert card =~ "import ShopWeb.Reusables.BubbleexComplexBadge"

      assert files["lib/shop_web/components/reusables/bubbleex_complex_card.html.heex"] =~
               ~s(<div class={@class} {@rest}>)
    end

    test "styles: theme tokens, named styles as component classes, residue", %{files: files} do
      css = files["assets/css/bubble.css"]
      assert css =~ "@theme static {"
      assert css =~ "--color-bubble-primary: rgb(79, 70, 229);"
      assert css =~ "--color_primary_default: var(--color-bubble-primary);"
      assert css =~ "@layer components {"
      assert css =~ ".s-button-primary-button {"
      assert css =~ "[data-overlay][hidden] { display: none; }"
      refute css =~ "daisyui"

      residue = files["assets/css/bubble_residue.css"]
      assert residue =~ ~r/\[data-bubble-id="[^"]+"\] \{/
    end

    test "names are locked by the previous surface map", %{
      files: files,
      project: project,
      opts: opts
    } do
      names =
        files[".wtf/surfaces.json"]
        |> Jason.decode!()
        |> put_in(["pages", "bpgwgmpz"], %{"module" => "DemoLive", "path" => "/demo"})

      {:ok, relocked} = Phoenix.render(project, Keyword.put(opts, :surface_names, names))
      assert relocked["lib/shop_web/live/demo_live.ex"] =~ "defmodule ShopWeb.DemoLive do"
      assert relocked["lib/shop_web/bubble_routes.ex"] =~ ~s(live "/demo", ShopWeb.DemoLive)
    end

    test "counts the frontend it rendered", %{project: project, opts: opts} do
      {:ok, report} = Phoenix.frontend_report(project, opts)
      assert report["pages"] == 55 and report["reusables"] == 2

      assert report["elements"] ==
               report["native"] + report["placeholder"] + report["in_runtime_template"]

      assert report["utilities"] > 0
    end
  end

  describe "overlays" do
    setup do
      {files, _, _} = render(case_app("bptvorpv"))
      [template] = for {p, c} <- files, p =~ ~r{live/.*\.heex$}, do: c
      %{files: files, template: template}
    end

    test "follow the runtime model", %{files: files, template: template} do
      assert template =~ ~r/<\.focus_wrap id="bubble-overlay-bptvorpw"[^>]* hidden/
      assert template =~ ~s(data-overlay="popup")
      assert template =~ ~s(aria-modal="true")
      assert template =~ ~s(data-overlay="group_focus")

      helpers = files["lib/shop_web/components/bubble.ex"]
      assert helpers =~ "def show_overlay(js \\\\ %JS{}, id)"
      assert helpers =~ ~s(bubble:overlay-opened)
      # One Group Focus at a time; a Popup closes every Group Focus.
      assert helpers =~ ~s|[data-overlay="group_focus"]:not(\#{target})|
    end

    test "a modal Popup is a named dialog that gives the focus back", %{
      files: files,
      template: template
    } do
      [popup] = Regex.run(~r/<\.focus_wrap id="bubble-overlay-bptvorpw"[^>]*>/, template)
      assert popup =~ ~s(role="dialog")
      # Its Bubble name (it has no heading).
      assert popup =~ ~s(aria-label="Overlay__Popup")
      assert popup =~ "data-bubble-escape={Bubble.dismiss_modal()}"

      helpers = files["lib/shop_web/components/bubble.ex"]
      assert helpers =~ ~s|@modals MapSet.new(["bptvorpw"])|
      assert helpers =~ "JS.push_focus(js)"
      assert helpers =~ "JS.pop_focus(js)"
      assert helpers =~ "|> JS.pop_focus()\n    |> JS.dispatch(\"bubble:overlay-closed\")"
    end

    test "Escape closes only the topmost open overlay; closed ones never listen", %{
      files: files,
      template: template
    } do
      # No overlay binds window keys (a closed one would react too): the
      # page's one Escape hook runs the topmost open overlay's command.
      refute template =~ "phx-window-keydown"
      refute template =~ "phx-key"
      assert length(String.split(template, "<Bubble.overlay_keys />")) == 2

      # The Group Focus is not modal: it keeps the focus where it is.
      [focus] = Regex.run(~r/<div data-bubble-id="bptvorqc"[^>]*>/, template)
      assert focus =~ "phx-click-away={Bubble.dismiss_overlay()}"

      helpers = files["lib/shop_web/components/bubble.ex"]
      assert helpers =~ ~s|<script :type={Phoenix.LiveView.ColocatedHook} name=".OverlayKeys">|
      assert helpers =~ ~s(phx-hook=".OverlayKeys")
      assert helpers =~ ~s|window.addEventListener("bubble:overlay-opened", this.opened)|
      assert helpers =~ "this.stack = this.stack.filter(isOpen)"
      assert helpers =~ ~s|top.getAttribute("data-bubble-escape")|
    end

    test "pages without Escape-dismissible overlays render no hook" do
      {files, _, _} = render(case_app("bpgwgmpz"))

      for {path, content} <- files,
          path =~ ~r{live/.*\.heex$},
          do: refute(content =~ "overlay_keys", path)
    end
  end

  test "compiled bindings are helpers over assigns; others are markers" do
    {files, _, _} = render(app("test/support/expression/app.json"))
    live = files["lib/shop_web/live/task_live.ex"]
    template = files["lib/shop_web/live/task_live.html.heex"]

    assert live =~ "defp text_bt2(element_state_bi1_get_data) do"
    assert live =~ "|> assign(:element_state_bi1_get_data, nil)"
    assert live =~ "|> assign(:items_br1, [])"
    assert template =~ "{text_bt2(@element_state_bi1_get_data)}"
    assert template =~ "<%!-- TODO(bubble:bT5) text: dynamic value not compiled --%>"
    assert template =~ "<div :for={_item <- @items_br1}>"

    component = files["lib/shop_web/components/reusables/team_card.ex"]
    assert component =~ "attr :element_state_bu1_get_group_data, :any, default: nil"
    assert template =~ "element_state_bu1_get_group_data={@element_state_bu1_get_group_data}"
    assert files["lib/shop/bubble/runtime.ex"] =~ "defmodule Shop.Bubble.Runtime do"
  end

  describe "routes" do
    setup do
      app = case_app("bptvorpv")
      {with_pages, project, opts} = render(app)
      {:ok, without} = Phoenix.render(project, Keyword.drop(opts, [:frontend, :expressions]))
      %{with_pages: with_pages, without: without}
    end

    test "are generated, so pages added later are routed without touching the router", %{
      with_pages: with_pages,
      without: without
    } do
      router = "lib/shop_web/router.ex"
      routes = "lib/shop_web/bubble_routes.ex"

      # The owned router is the same whether the pages came at the first
      # scaffold or later: it calls the generated routes once.
      assert with_pages[router] == without[router]

      assert without[router] =~
               "require ShopWeb.BubbleRoutes\n  ShopWeb.BubbleRoutes.bubble_routes()"

      assert without[routes] =~ "defmacro bubble_routes, do: nil"
      assert with_pages[routes] =~ ~s(live "/bubbleex-overlay-boundaries", ShopWeb.)

      for files <- [with_pages, without] do
        manifest = Jason.decode!(files[".wtf/generated.json"])
        assert Map.has_key?(manifest["generated"], routes)
        assert Map.has_key?(manifest["owned"], router)
      end
    end

    test "a router without the call leaves the pages unrouted, and says so", %{
      with_pages: files
    } do
      manifest = files[".wtf/generated.json"]
      router = "lib/shop_web/router.ex"
      assert Jason.decode!(manifest)["routes"]["pages"] == ["bptvorpv"]
      assert {:ok, %{unrouted: []}} = Phoenix.check_manifest(manifest, files)

      # An owned router scaffolded before WTF-370 (no call to the routes).
      old = String.replace(files[router], ~r/  require ShopWeb.BubbleRoutes\n.*\n/, "")
      refute old =~ "bubble_routes"

      assert {:ok, %{clean?: true, unrouted: ["bptvorpv"]}} =
               Phoenix.check_manifest(manifest, Map.put(files, router, old))

      # The generated test checks the route before mounting, with the fix.
      test = files["test/shop_web/bubble_surfaces_test.exs"]
      assert test =~ "assert_routed(@path, @module)"
      assert test =~ "Phoenix.Router.route_info(ShopWeb.Router"
      assert test =~ "ShopWeb.BubbleRoutes.bubble_routes()"
    end

    test "hand-edited locked names are not trusted" do
      {files, project, opts} = render(case_app("bptvorpv"))

      names =
        files[".wtf/surfaces.json"]
        |> Jason.decode!()
        |> put_in(["pages", "bptvorpv"], %{
          "module" => "Evil do\nend\ndefmodule Owned",
          "path" => ~s(/x", Evil\n  live "/y)
        })

      {:ok, relocked} = Phoenix.render(project, Keyword.put(opts, :surface_names, names))
      assert relocked == files
    end
  end

  test "reusable elements have their own render check, tagged by Bubble ID" do
    {files, _, _} = render(case_app("bpgwgmpz"))
    test = files["test/shop_web/bubble_surfaces_test.exs"]

    assert test =~
             ~s|{"bpmvuzce", "bubbleex-complex-card",\n     &ShopWeb.Reusables.BubbleexComplexCard.bubbleex_complex_card/1,|

    assert test =~ "render_component(@component, %{})"
    assert test =~ ~s(test "the Bubble reusable element \#{label} renders every element")
  end

  describe "reusable instance parameters" do
    setup do
      text = fn parts ->
        %{
          "%x" => "TextExpression",
          "%e" => parts |> Enum.with_index() |> Map.new(fn {v, i} -> {to_string(i), v} end)
        }
      end

      param = fn name ->
        %{
          "%x" => "GetElement",
          "%p" => %{"%ei" => "card"},
          "%n" => %{"%nm" => name, "%x" => "Message"}
        }
      end

      instances = [
        {"one", "[b]One[/b] {@x}", "https://example.test/one?a=1&b={2}"},
        {"two", "Two\n<script>bad()</script>", "javascript:alert(1)"},
        {"three", "Three", "other"}
      ]

      element = fn {id, name, dest} ->
        {id,
         %{
           "id" => id,
           "%x" => "CustomElement",
           "%p" => %{
             "definition" => "card",
             "param_name" => text.([name]),
             "param_dest" => text.([dest])
           }
         }}
      end

      page = fn name, elements ->
        %{
          "type" => "Page",
          "name" => name,
          "properties" => %{"container_layout" => "column"},
          "elements" => elements
        }
      end

      payload = %{
        "_id" => "parameter-app",
        "pages" => %{
          "index" => page.("index", Map.new(instances, element)),
          "other" => page.("other", %{})
        },
        "element_definitions" => %{
          "card" => %{
            "id" => "card",
            "%x" => "CustomDefinition",
            "%p" => %{"container_layout" => "column"},
            "%el" => %{
              "label" => %{
                "id" => "label",
                "%x" => "Text",
                "%p" => %{"text" => text.([param.("param_name")])}
              },
              "link" => %{
                "id" => "link",
                "%x" => "Link",
                "%p" => %{"text" => "Go", "destination" => text.([param.("param_dest")])}
              }
            }
          }
        }
      }

      {_, project, _} = render(app("test/support/expression/app.json"))
      {:ok, frontend} = BubbleEx.Frontend.normalize(payload)
      {:ok, files} = Phoenix.render(project, module: "Shop", frontend: frontend)

      %{
        files: files,
        page: files["lib/shop_web/live/index_live.html.heex"],
        card: files["lib/shop_web/components/reusables/card.html.heex"]
      }
    end

    test "a link's destination per instance: page paths and allowlisted URLs only", %{
      files: files,
      page: page,
      card: card
    } do
      assert card =~ ~s(<a data-bubble-id="link")
      assert card =~ "href={@destination_link}"
      assert files["lib/shop_web/components/reusables/card.ex"] =~ "attr :destination_link, :any"

      assert page =~ ~S|destination_link={"https://example.test/one?a=1&b=\x7B2\x7D"}|
      assert page =~ ~s|destination_link={~p"/other"}|
      refute page =~ "javascript"
      [two] = Regex.run(~r/<\.card data-bubble-id="two"[^>]*>/, page)
      refute two =~ "destination_link"
    end

    test "a Text's content per instance goes through the static text path", %{
      files: files,
      page: page,
      card: card
    } do
      assert card =~ "{render_slot(@text_label)}"
      assert files["lib/shop_web/components/reusables/card.ex"] =~ "slot :text_label"
      refute card =~ "{@text_label}"

      # BBCode as HTML, braces and markup escaped, line breaks as <br>.
      assert page =~ "<:text_label><strong>One</strong> &lbrace;@x&rbrace;</:text_label>"
      assert page =~ "<:text_label>Two<br>&lt;script&gt;bad()&lt;/script&gt;</:text_label>"
      refute page =~ "<script>"
      refute page =~ "raw("
    end
  end

  test "hostile Bubble IDs are quoted in generated source, never spliced in" do
    alias BubbleEx.Test.HostileIds

    cases = [
      # A page, a reusable, an instance inside a reusable (its `scope`
      # expression), a Text inside a reusable.
      {case_app("bpgwgmpz"), ~w(bpgwgmpz bpmvuzce bpcjyrzt bpcjyrzr)},
      # A modal Popup (its DOM ID, the helpers' @modals) and a Group Focus.
      {case_app("bptvorpv"), ~w(bptvorpv bptvorpw bptvorqc)},
      # A compiled binding (its helper's comment).
      {app("test/support/expression/app.json"), ~w(bT2)}
    ]

    for {app, ids} <- cases do
      {files, _, _} = render(HostileIds.rename(app, ids))
      hostile = Enum.map(ids, &HostileIds.hostile/1)

      for {path, content} <- files, Path.extname(path) in [".ex", ".exs"] do
        # Every generated or scaffolded Elixir file still parses, and no
        # injected code became code.
        assert {:ok, quoted} = Code.string_to_quoted(content), path

        {_, calls} =
          Macro.prewalk(quoted, [], fn
            {:raise, _, ["injected"]} = node, acc -> {node, [path | acc]}
            node, acc -> {node, acc}
          end)

        assert calls == [], path
      end

      # The IDs survive as data: the traceability test expects them.
      {:ok, test} = Code.string_to_quoted(files["test/shop_web/bubble_surfaces_test.exs"])

      {_, strings} =
        Macro.prewalk(test, [], fn
          binary, acc when is_binary(binary) -> {binary, [binary | acc]}
          node, acc -> {node, acc}
        end)

      for id <- hostile, do: assert(id in strings, inspect(id))

      for {path, content} <- files, String.ends_with?(path, ".heex") do
        # HEEx: attribute values are escaped, expressions hold literals with
        # braces and `<` as hex escapes, comments cannot be ended early: no
        # EEx tag but the markers' comments.
        refute content =~ ~s("\#{raise), path
        refute content =~ ~r/<%(?!!-- TODO\(bubble:)/, path
        # A line break in a value is a character reference: indentation
        # cannot change it.
        refute content =~ ~r/\bid="[^"]*\n/, path
      end
    end

    {files, _, _} = render(HostileIds.rename(case_app("bpgwgmpz"), ~w(bpcjyrzt)))
    card = files["lib/shop_web/components/reusables/bubbleex_complex_card.html.heex"]

    assert card =~
             ~S|scope={"#{@scope}-" <> "bpcjyrzt\"\#\x7Braise \"injected\"\x7D a\nb*/--%>\x3C%= raise \"eex\" %>\x7D\x7B"}|

    {files, _, _} = render(HostileIds.rename(case_app("bptvorpv"), ~w(bptvorpw)))

    assert files["lib/shop_web/components/bubble.ex"] =~
             ~S|"bptvorpw\"\#\x7Braise \"injected\"\x7D a\nb*/--%>\x3C%= raise \"eex\" %>\x7D\x7B"|

    assert files["assets/css/bubble_residue.css"] =~
             ~S|[data-bubble-id="bptvorpw\"#{raise \"injected\"} a\a b*/--%><%= raise \"eex\" %>}{"]|
  end

  describe "Tailwind.utilities/2" do
    test "exact utilities, arbitrary values and arbitrary properties" do
      assert {["flex", "w-[240px]", "[box-shadow:0_2px_4px_#0003]"], []} =
               Tailwind.utilities([
                 {"display", "flex"},
                 {"width", "240px"},
                 {"box-shadow", "0 2px 4px #0003"}
               ])

      assert {["text-bubble-primary"], []} =
               Tailwind.utilities([{"color", "var(--color_primary_default)"}], %{
                 "--color_primary_default" => "bubble-primary"
               })
    end

    test "leaves values a class cannot carry, and shorthand conflicts, to the residue" do
      assert {[], [{"font-family", ~s("Open Sans")}]} =
               Tailwind.utilities([{"font-family", ~s("Open Sans")}])

      assert {[], [{"content", "a_b"}]} = Tailwind.utilities([{"content", "a_b"}])

      assert {["p-[4px]"], [{"border", "1px solid red"}, {"border-color", "blue"}]} =
               Tailwind.utilities([
                 {"border", "1px solid red"},
                 {"border-color", "blue"},
                 {"padding", "4px"}
               ])
    end
  end
end
