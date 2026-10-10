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
      assert template =~ ~r/<main\s+data-bubble-id="bpgwgmpz"/

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

      assert manifest["inputs"]["frontend"]["bubble_id"] == "example-plugin"
    end

    test "every rendered element carries its data-bubble-id", %{files: files} do
      template = files["lib/shop_web/live/bubbleex_complex_demo_live.html.heex"]
      test = files["test/shop_web/bubble_surfaces_test.exs"]

      ids = tested_ids(test, "page:bpgwgmpz")
      assert "bpgwgmpz" in ids and length(ids) > 20

      components =
        files
        |> Enum.filter(fn {p, _} -> String.ends_with?(p, ".html.heex") end)
        |> Enum.map_join(&elem(&1, 1))

      for id <- ids, do: assert(components =~ ~s(data-bubble-id="#{id}"), id)
      assert template =~ ~r/<\.bubbleex_complex_card\s+data-bubble-id=/
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
      assert template =~ ~r/<\.focus_wrap\s+id="bubble-overlay-bptvorpw"[^>]*\s+hidden/
      assert template =~ ~s(data-overlay="popup")
      assert template =~ ~s(aria-modal="true")
      assert template =~ ~s(data-overlay="group_focus")

      helpers = files["lib/shop_web/components/bubble.ex"]
      assert helpers =~ "def show_overlay(js \\\\ %JS{}, id)"
      assert helpers =~ ~s(bubble:overlay-opened)
      # One Group Focus at a time; a Popup closes every Group Focus.
      assert helpers =~ ~s|document.querySelectorAll('[data-overlay="group_focus"]')|
      assert helpers =~ "if (other !== el && !other.hidden) this.hide(other)"
      # Through LiveView's JS commands: a later render keeps it open.
      assert helpers =~ ~s|this.js().removeAttribute(el, "hidden")|
      assert helpers =~ ~s|this.js().setAttribute(el, "hidden", "")|
    end

    test "a modal Popup with an authored HTML ID has one id, the authored one (WTF-378)" do
      app = case_app("bptvorpv")
      [page] = Map.keys(app["pages"])

      app =
        put_in(
          app,
          ["pages", page, "elements", "overlay__popup", "properties", "unique_id"],
          "savedViews"
        )

      {files, _, _} = render(app)
      [template] = for {p, c} <- files, p =~ ~r{live/.*\.heex$}, do: c
      [popup] = Regex.run(~r/<\.focus_wrap\s[^>]*data-bubble-id="bptvorpw"[^>]*>/, template)
      assert [_] = Regex.scan(~r/\sid=/, popup)
      assert popup =~ ~s(id="savedViews")
      refute template =~ "bubble-overlay-bptvorpw"
    end

    test "a modal Popup is a named dialog that gives the focus back", %{
      files: files,
      template: template
    } do
      [popup] = Regex.run(~r/<\.focus_wrap\s+id="bubble-overlay-bptvorpw"[^>]*>/, template)
      assert popup =~ ~s(role="dialog")
      # Its Bubble name (it has no heading).
      assert popup =~ ~s(aria-label="Overlay__Popup")
      assert popup =~ "data-bubble-escape={Bubble.dismiss_modal()}"

      helpers = files["lib/shop_web/components/bubble.ex"]
      # WTF-372: opening an open overlay does nothing, so its opener is the
      # first one (T5 saved the focus again); an opener hidden since (in a
      # Group Focus the Popup closed) gives way to what opened that one.
      assert helpers =~ "if (!el.hidden) {"
      assert helpers =~ ~s|if (!overlay) this.override(el, false)|
      assert helpers =~ "this.openers.set(el, document.activeElement)"
      assert helpers =~ "const closed = opener.closest && opener.closest(OVERLAYS)"
      assert helpers =~ "if (opener && isOpen(opener)) opener.focus()"
      refute helpers =~ "push_focus"
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
      [focus] = Regex.run(~r/<div\s+data-bubble-id="bptvorqc"[^>]*>/, template)
      assert focus =~ "phx-click-away={Bubble.dismiss_overlay()}"

      helpers = files["lib/shop_web/components/bubble.ex"]
      assert helpers =~ ~s|<script :type={Phoenix.LiveView.ColocatedHook} name=".BubbleRuntime">|
      assert helpers =~ ~s(phx-hook=".BubbleRuntime")
      assert helpers =~ "def overlay_keys(assigns), do: runtime(assigns)"
      assert helpers =~ "this.stack = this.stack.filter(isOpen)"
      # An overlay inside a hidden or invisible ancestor is not open.
      assert helpers =~ "el.getClientRects().length > 0"
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
    # The formatter must not turn indentation into visible text in a
    # whitespace-pre-wrap Bubble Text element.
    assert template =~
             ~r/<p\b[^>]*data-bubble-id="bT2"[^>]*>\{text_bt2\(@element_state_bi1_get_data\)\}<\/p>/s

    assert template =~ "<%!-- TODO(bubble:bT5) text: dynamic value not compiled --%>"

    # Bubble's date formats go to the runtime; an approximated one is
    # marked (WTF-456).
    assert live =~
             ~s|Shop.Bubble.Runtime.format_date(get_in(page_thing_bp1, [Access.key(:due)]), "mmm d")|

    assert live =~
             ~r/format_date\(\s*get_in\(page_thing_bp1, \[Access.key\(:due\)\]\),\s*"h:MMtt ZZ",\s*"UTC"\s*\)/

    assert template =~
             "<%!-- TODO(bubble:bT11) text: format approximated (date_format_token:ZZ) --%>"

    refute template =~ "TODO(bubble:bT7)"
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

      # Without pages the macro routes only the migrated files (WTF-415).
      refute without[routes] =~ "live "
      assert without[routes] =~ ~s(get "/:sha/:name", UploadsController, :public)
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

      # A commented-out call is no call.
      commented =
        String.replace(
          files[router],
          "  ShopWeb.BubbleRoutes.bubble_routes()",
          "  # ShopWeb.BubbleRoutes.bubble_routes()"
        )

      assert {:ok, %{unrouted: ["bptvorpv"]}} =
               Phoenix.check_manifest(manifest, Map.put(files, router, commented))

      # The generated test checks the route before mounting, with the fix.
      test = files["test/shop_web/bubble_surfaces_test.exs"]
      assert test =~ ~s|assert_routed("/bubbleex-overlay-boundaries", ShopWeb.|
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

      # A core module name is rejected, but the page keeps its locked path.
      names =
        put_in(names, ["pages", "bptvorpv"], %{"module" => "Router", "path" => "/kept"})

      {:ok, relocked} = Phoenix.render(project, Keyword.put(opts, :surface_names, names))
      routes = relocked["lib/shop_web/bubble_routes.ex"]
      assert routes =~ ~s(live "/kept", ShopWeb.BubbleexOverlayBoundariesLive)
      refute routes =~ "ShopWeb.Router"
    end
  end

  test "colliding page names keep their suffixed modules on regeneration" do
    page = fn name ->
      %{
        "type" => "Page",
        "name" => name,
        "properties" => %{"container_layout" => "column"},
        "elements" => %{}
      }
    end

    payload = %{
      "_id" => "collisions",
      "pages" => Map.new(["foo bar", "foo-bar", "foo_bar"], &{&1, page.(&1)})
    }

    {_, project, _} = render(app("test/support/expression/app.json"))
    {:ok, frontend} = BubbleEx.Frontend.normalize(payload)
    opts = [module: "Shop", frontend: frontend]
    {:ok, files} = Phoenix.render(project, opts)

    names = Jason.decode!(files[".wtf/surfaces.json"])
    modules = names["pages"] |> Map.values() |> Enum.map(& &1["module"]) |> Enum.sort()
    assert length(Enum.uniq(modules)) == 3
    assert Enum.any?(modules, &Regex.match?(~r/Live\d+\z/, &1)), inspect(modules)

    {:ok, again} = Phoenix.render(project, Keyword.put(opts, :surface_names, names))
    assert Jason.decode!(again[".wtf/surfaces.json"]) == names
    assert again == files
  end

  test "no page but the index page is routed under /index (WTF-466)" do
    page = fn name ->
      %{
        "type" => "Page",
        "name" => name,
        "properties" => %{"container_layout" => "column"},
        "elements" => %{}
      }
    end

    # "Index" slugs to "index": it would clash with /index/:bubble_thing.
    payload = %{
      "_id" => "index-clash",
      "pages" => %{"index" => page.("index"), "Index" => page.("Index")}
    }

    {_, project, _} = render(app("test/support/expression/app.json"))
    {:ok, frontend} = BubbleEx.Frontend.normalize(payload)
    {:ok, files} = Phoenix.render(project, module: "Shop", frontend: frontend)

    paths =
      files[".wtf/surfaces.json"]
      |> Jason.decode!()
      |> Map.fetch!("pages")
      |> Map.values()
      |> Enum.map(& &1["path"])
      |> Enum.sort()

    assert paths == ["/", "/index-page"]

    routes = files["lib/shop_web/bubble_routes.ex"]
    assert routes =~ ~s(live "/index/:bubble_thing")
    assert routes =~ ~s(live "/index-page/:bubble_thing")
    refute routes =~ ~s(live "/index",)
  end

  test "one literal test per surface, tagged as the task CLI reads it" do
    {files, _, _} = render(case_app("bpgwgmpz"))
    test = files["test/shop_web/bubble_surfaces_test.exs"]

    assert test =~
             """
               @tag bubble: "reusable:bpmvuzce"
               test "the Bubble reusable element bubbleex-complex-card (bubble:bpmvuzce) renders every element" do
                 html = render_component(&ShopWeb.Reusables.BubbleexComplexCard.bubbleex_complex_card/1, %{})
             """

    assert test =~ ~s(  @tag bubble: "page:bpgwgmpz"\n  test "the Bubble page )
    assert "bpcjyrzr" in tested_ids(test, "reusable:bpmvuzce")
    # No computed tags: 55 pages and 2 reusables, one @tag each.
    assert length(Regex.scan(~r/^  @tag bubble: "(page|reusable):/m, test)) == 57
  end

  test "the task CLI finds and runs the tests of a generated page and reusable" do
    {files, _, _} = render(case_app("bpgwgmpz"))
    root = Path.join(System.tmp_dir!(), "wtf370-checks-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), content)
    end

    test = self()

    ctx = %{
      root: root,
      task: %BubbleEx.Plan.Task{id: "surface:page/bpgwgmpz", kind: :surface, actor: :agent},
      results: [],
      app: "app1",
      now: ~U[2026-09-26 12:00:00Z],
      reviewers: [],
      resolved: nil,
      test_db: :project,
      cmd: fn args, env ->
        send(test, {:mix, args, env})
        {"1 test, 0 failures", 0}
      end
    }

    subjects = ~w(page:bpgwgmpz reusable:bpmvuzce element:bpcjyrzr)

    run = fn check, args ->
      {outcome, _} = BubbleEx.Target.Phoenix.Checks.run(%{check: check, args: args}, ctx, %{})
      outcome
    end

    assert %{status: :pass, source_only: false} = run.(:traceability, %{"elements" => subjects})
    assert_received {:mix, ["test", "--only", "bubble:page:bpgwgmpz"], _}
    assert_received {:mix, ["test", "--only", "bubble:reusable:bpmvuzce"], _}

    # render_smoke finds the reusable's tag; the page still has markers.
    assert %{status: :pass} = run.(:render_smoke, %{"surfaces" => ["reusable:bpmvuzce"]})
    assert_received {:mix, ["test", "--only", "bubble:reusable:bpmvuzce"], _}

    assert %{status: :fail, detail: "left in " <> _} =
             run.(:render_smoke, %{"surfaces" => ["page:bpgwgmpz"]})
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
        {"three", "Three", "other"},
        # Longer than inspect/1's default printable limit (4096).
        {"four", "Four", "https://example.test/" <> String.duplicate("a", 5000)}
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
      assert card =~ ~r/<a\s+data-bubble-id="link"/
      assert card =~ "href={@destination_link}"
      assert files["lib/shop_web/components/reusables/card.ex"] =~ "attr :destination_link, :any"

      assert page =~ ~S|destination_link={to_string("https://example.test/one?a=1&b=\x7B2\x7D")}|
      assert page =~ ~s|destination_link={~p"/other"}|
      refute page =~ "javascript"

      # Printed whole: a truncated literal ("…" <> ...) would not compile.
      long = "https://example.test/" <> String.duplicate("a", 5000)
      assert page =~ ~s("#{long}")
      refute page =~ "..."
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
      assert page =~
               "<:text_label phx-no-format><strong>One</strong> &lbrace;@x&rbrace;</:text_label>"

      assert page =~
               "<:text_label phx-no-format>Two<br>&lt;script&gt;bad()&lt;/script&gt;</:text_label>"

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
      # A modal Popup (its DOM ID) and a Group Focus.
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

      # (an element ID in an expected list, a surface ID in its tag)
      for id <- hostile,
          do:
            assert(id in strings or ("page:" <> id) in strings or ("reusable:" <> id) in strings)

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

    # The helpers hold no Bubble ID (WTF-372: the runtime finds modals by
    # their `aria-modal`).
    refute files["lib/shop_web/components/bubble.ex"] =~ "bptvorpw"

    assert files["assets/css/bubble_residue.css"] =~
             ~S|[data-bubble-id="bptvorpw\"#{raise \"injected\"} a\a b*/--%><%= raise \"eex\" %>}{"]|
  end

  # The Bubble IDs the tagged test of `tag` expects.
  defp tested_ids(test, tag) do
    {:ok, {:defmodule, _, [_, [do: {:__block__, _, body}]]}} = Code.string_to_quoted(test)

    [{:test, _, test_args} | _] =
      body
      |> Enum.drop_while(&(not match?({:@, _, [{:tag, _, [[bubble: ^tag]]}]}, &1)))
      |> Enum.drop(1)

    {_, ids} =
      Macro.prewalk(test_args, nil, fn
        {:missing, _, [_, ids]} = node, nil when is_list(ids) -> {node, ids}
        node, acc -> {node, acc}
      end)

    ids
  end

  # WTF-516: a side panel that is a Floating Group reusable, placed by a
  # fit-width instance with no horizontal reference, sits at the left edge
  # at its content's width instead of spanning the page over its content.
  test "a fit-width floating side panel is pinned left, not stretched over the page" do
    instance = fn props ->
      %{
        "id" => "panel-instance",
        "type" => "CustomElement",
        "properties" =>
          Map.merge(
            %{"custom_id" => "panel-root", "order" => 1, "min_width_css" => "248px"},
            props
          )
      }
    end

    payload = fn props ->
      %{
        "_id" => "side-panel",
        "pages" => %{
          "dashboard" => %{
            "id" => "page",
            "type" => "Page",
            "name" => "dashboard",
            "properties" => %{"container_layout" => "column"},
            "elements" => %{
              "panel" => instance.(props),
              "main" => %{
                "id" => "main",
                "type" => "Group",
                "properties" => %{"container_layout" => "column", "margin_left" => 248}
              }
            }
          }
        },
        "element_definitions" => %{
          "panel" => %{
            "id" => "panel-root",
            "type" => "CustomDefinition",
            "name" => "Side panel",
            "properties" => %{
              "element_type" => "FloatingGroup",
              "container_layout" => "row",
              "width" => 200
            },
            "elements" => %{
              "label" => %{"id" => "label", "type" => "Text", "properties" => %{"%3" => "Nav"}}
            }
          }
        }
      }
    end

    {_, project, _} = render(app("test/support/expression/app.json"))

    classes = fn props ->
      {:ok, frontend} = BubbleEx.Frontend.normalize(payload.(props))
      {:ok, files} = Phoenix.render(project, module: "Shop", frontend: frontend)
      [template] = for {p, c} <- files, p =~ ~r{live/dashboard_live\.html\.heex$}, do: c
      [call] = Regex.run(~r/<\.side_panel\s[^>]*data-bubble-id="panel-instance"[^>]*>/, template)
      [_, class] = Regex.run(~r/\sclass="([^"]*)"/, call)
      String.split(class)
    end

    fit = classes.(%{"fit_width" => true})
    assert "fixed" in fit and "top-[0]" in fit and "left-[0]" in fit
    assert "w-[fit-content]" in fit and "min-w-[248px]" in fit
    refute "right-[0]" in fit

    # Filling its width, the panel spans the viewport between both edges.
    fill = classes.(%{"fit_width" => false, "single_width" => false})
    assert "left-[0]" in fill and "right-[0]" in fill
    refute "w-[fit-content]" in fill
  end

  describe "icon buttons" do
    test "with conditionals, a button with a drawn icon is a button; another set is marked" do
      hovered = %{
        "0" => %{
          "condition" => %{
            "type" => "ThisElement",
            "next" => %{"type" => "Message", "name" => "is_hovered"}
          },
          "properties" => %{"icon" => "phosphor fill clock"}
        }
      }

      button = fn id, order, props ->
        %{
          "id" => id,
          "type" => "Button",
          "properties" => Map.merge(%{"order" => order, "width" => 120, "height" => 32}, props),
          "states" => hovered
        }
      end

      app = %{
        "pages" => %{
          "tools" => %{
            "id" => "bToolsPage",
            "name" => "tools",
            "type" => "Page",
            "properties" => %{"title" => "Tools"},
            "elements" => %{
              "bWrite" =>
                button.("bWrite", 1, %{
                  "button_type" => "label_icon",
                  "icon" => "phosphor regular note-pencil",
                  "text" => "Write"
                }),
              "bLock" =>
                button.("bLock", 2, %{"button_type" => "icon", "icon" => "feather lock"}),
              "bStar" =>
                button.("bStar", 3, %{
                  "button_type" => "icon",
                  "icon" => "material outlined star_border",
                  "text" => "LABEL KEPT FROM BEFORE"
                }),
              "bClose" =>
                button.("bClose", 4, %{
                  "button_type" => "icon",
                  "icon" => "material outlined close",
                  "text" => %{
                    "type" => "TextExpression",
                    "entries" => %{
                      "0" => %{
                        "type" => "CurrentUser",
                        "next" => %{"type" => "Message", "name" => "email"}
                      }
                    }
                  }
                }),
              "bSave" => %{
                "id" => "bSave",
                "type" => "Button",
                "properties" => %{"order" => 5, "width" => 120, "height" => 32, "text" => "Save"},
                "states" => %{
                  "0" => %{
                    "condition" => %{
                      "type" => "CurrentUser",
                      "next" => %{"type" => "Message", "name" => "logged_in"}
                    },
                    "properties" => %{"button_disabled" => true, "text" => "Saved"}
                  }
                }
              },
              "bHover" => %{
                "id" => "bHover",
                "type" => "Button",
                "properties" => %{"order" => 7, "width" => 120, "height" => 32, "text" => "Go"},
                "states" => %{
                  "0" => %{
                    "condition" => %{
                      "type" => "ThisElement",
                      "next" => %{"type" => "Message", "name" => "is_hovered"}
                    },
                    "properties" => %{"button_disabled" => true}
                  }
                }
              },
              "bBare" => %{
                "id" => "bBare",
                "type" => "Button",
                "name" => "Editor name only",
                "properties" => %{
                  "order" => 6,
                  "width" => 32,
                  "height" => 32,
                  "button_type" => "icon",
                  "icon" => "material outlined more_vert"
                }
              }
            }
          }
        }
      }

      {files, _project, _opts} = render(app)
      template = files["lib/shop_web/live/tools_live.html.heex"]

      button = fn id ->
        hd(Regex.run(~r/<button\s[^>]*data-bubble-id="#{id}".*?<\/button>/s, template))
      end

      # A conditional icon is not lowered: the button keeps its icon on page
      # load, marked; with no icon library here, the icon is marked missing.
      write = button.("bWrite")
      assert write =~ "Write"
      assert write =~ "TODO(bubble:bWrite) icon: 1 conditional not lowered; shown as on page load"
      assert write =~ ~s|data-bubble-dev-note={Bubble.dev_markers?()}|
      assert write =~ "Conditional icon not lowered; Icon not available (note-pencil)"

      # A label button's "isn't clickable" on the current user: lowered to
      # `disabled`; its conditional text is marked.
      save = button.("bSave")
      assert save =~ "disabled={disabled_bsave(@current_user)}"
      refute save =~ "isn't clickable"
      assert save =~ "TODO(bubble:bSave) text: 1 conditional not lowered"
      assert save =~ ~s|title={Bubble.dev_marker("Conditional text not lowered")}|

      # One the page cannot decide (hovering is not kept): disabled, fail
      # closed, and marked.
      hover = button.("bHover")
      assert hover =~ ~r/\sdisabled\s/
      assert hover =~ "TODO(bubble:bHover) isn't clickable: 1 conditional not lowered"
      assert hover =~ "Clickable conditionals not lowered: disabled"

      # Never named after the editor: no text, no name, marked.
      bare = button.("bBare")
      refute bare =~ "aria-label"
      refute bare =~ "Editor name only"
      assert bare =~ "Icon button with no text: no accessible name"

      # Icon only: the text Bubble keeps is not shown, it names the button.
      # No icon library here, so its icon cannot be drawn: marked in dev.
      [star] = Regex.run(~r/<button\s[^>]*data-bubble-id="bStar".*?<\/button>/s, template)
      assert star =~ ~s|aria-label="LABEL KEPT FROM BEFORE"|
      refute star =~ ~r/>\s*LABEL KEPT FROM BEFORE/
      assert star =~ ~s|data-bubble-placeholder="icon"|
      assert star =~ "Icon not available (star_border)"
      css = files["assets/css/bubble.css"]
      assert css =~ ~s|[data-bubble-placeholder="icon"][data-bubble-dev-marker] {|

      assert css =~ "min-width: var(--bubble-icon-size, 24px);"
      assert css =~ ~s|[data-bubble-dev-note][data-bubble-dev-marker] {|

      # A dynamic text names it too, its icon's name when empty: its helper
      # is read, never left unused, and the name is never empty.
      close = button.("bClose")
      assert close =~ ~r/aria-label=\{Bubble.name\(label_bclose\(.*\), "close"\)\}/s
      assert files["lib/shop_web/components/bubble.ex"] =~ "def name(value, fallback) do"

      # An icon set the generator does not draw: an empty box, marked in dev.
      assert template =~ "TODO(bubble:bLock) Button is not lowered"
      assert template =~ ~s|title={Bubble.dev_marker("Button (not migrated)")}|
    end
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
