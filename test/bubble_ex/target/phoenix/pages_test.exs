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

      router = files["lib/shop_web/router.ex"]
      assert router =~ "ash_authentication_live_session :bubble_pages"
      assert router =~ ~s(live "/bubbleex-complex-demo", BubbleexComplexDemoLive)

      manifest = Jason.decode!(files[".wtf/generated.json"])
      assert Map.has_key?(manifest["owned"], "lib/shop_web/live/bubbleex_complex_demo_live.ex")
      assert Map.has_key?(manifest["owned"], "lib/shop/bubble/runtime.ex")

      for path <-
            ~w(assets/css/bubble.css assets/css/bubble_residue.css .wtf/surfaces.json
               lib/shop_web/components/bubble.ex test/shop_web/bubble_surfaces_test.exs),
          do: assert(Map.has_key?(manifest["generated"], path), path)

      assert manifest["inputs"]["frontend"]["bubble_id"] == "tiptap-plugin"
    end

    test "every rendered element carries its data-bubble-id", %{files: files} do
      template = files["lib/shop_web/live/bubbleex_complex_demo_live.html.heex"]
      test = files["test/shop_web/bubble_surfaces_test.exs"]

      [ids] =
        Regex.run(~r/"\/bubbleex-complex-demo", "bubbleex-complex-demo",\s+~w\(([^)]*)\)/, test,
          capture: :all_but_first
        )

      ids = String.split(ids)
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
      assert relocked["lib/shop_web/router.ex"] =~ ~s(live "/demo", DemoLive)
    end

    test "counts the frontend it rendered", %{project: project, opts: opts} do
      {:ok, report} = Phoenix.frontend_report(project, opts)
      assert report["pages"] == 55 and report["reusables"] == 2

      assert report["elements"] ==
               report["native"] + report["placeholder"] + report["in_runtime_template"]

      assert report["utilities"] > 0
    end
  end

  test "overlays follow the runtime model" do
    {files, _, _} = render(case_app("bptvorpv"))
    [template] = for {p, c} <- files, p =~ ~r{live/.*\.heex$}, do: c

    assert template =~ ~r/<\.focus_wrap id="bubble-overlay-bptvorpw"[^>]* hidden/
    assert template =~ ~s(data-overlay="popup")
    assert template =~ ~s(aria-modal="true")
    assert template =~ ~s[phx-window-keydown={Bubble.dismiss_overlay()}]
    assert template =~ ~s(data-overlay="group_focus")

    helpers = files["lib/shop_web/components/bubble.ex"]
    assert helpers =~ "def show_overlay(js \\\\ %JS{}, id)"
    assert helpers =~ ~s(bubble:overlay-opened)
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
