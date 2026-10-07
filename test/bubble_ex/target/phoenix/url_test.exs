defmodule BubbleEx.Target.Phoenix.UrlTest do
  # `Get data from page URL` (WTF-508, replayed 2026-10-07), from the
  # synthetic test/support/target/phoenix/url.json.
  # scripts/phoenix_compile_check.sh compiles the output and runs
  # test/support/target/phoenix/url_behavior.exs against it.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model}
  alias BubbleEx.Target.Elixir.{Frontend, FrontendWorkflows}
  alias BubbleEx.Target.Phoenix

  @fixture "test/support/target/phoenix/url.json"

  setup_all do
    app = @fixture |> File.read!() |> Jason.decode!()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :enforced)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    {:ok, lowered} = BubbleEx.Workflows.Frontend.build(app, model, index)
    {:ok, backend_lowered} = BubbleEx.Workflows.Backend.build(app, model, index)

    {:ok, backend} =
      BubbleEx.Target.Ash.Workflows.map(backend_lowered, project, namespace: "Shop")

    {:ok, page_data} = BubbleEx.PageData.build(app, model)

    {:ok, spec} =
      FrontendWorkflows.map(lowered, project,
        namespace: "Shop",
        frontend: frontend,
        backend: backend,
        page_data: page_data
      )

    opts = [
      module: "Shop",
      frontend: frontend,
      expressions: expressions,
      workflows: backend,
      frontend_workflows: spec
    ]

    {:ok, files} = Phoenix.render(project, opts)
    %{files: files, spec: spec}
  end

  defp tag(template, id) do
    [open] = Regex.run(~r/<[a-z.]+\s[^>]*data-bubble-id="#{id}"[^>]*>/s, template)
    open
  end

  test "texts and conditions read typed parameters and the path from what the page keeps", %{
    files: files
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]
    read = "Bubble.url_value(@bubble_url, @bubble_segments, "

    assert template =~ ~s|{text_bq(Map.get(@bubble_url, "q"))}|
    assert template =~ ~s|{text_btags(Map.get(@bubble_url, "tags[]"))}|
    assert template =~ read <> ~s|{:query, "n"}, "number")|
    assert template =~ read <> ~s|{:query, "d"}, "date")|
    assert tag(template, "bOn") =~ read <> ~s|{:query, "on"}, "boolean")|
    assert tag(template, "bSegX") =~ read <> ~s|:segments, "list.text")|
    assert template =~ read <> ~s|:first, "text")|
    # Pages route up to /<page>/<x>: a third segment is not read.
    assert template =~ "TODO(bubble:bSeg3) text: dynamic value not compiled"

    # "Is a list" was not replayed.
    assert template =~ "TODO(bubble:bMany) text: dynamic value not compiled"

    # Path segments are a 1-based list.
    assert files["lib/shop_web/live/index_live.ex"] =~
             "Shop.Bubble.Runtime.item_at(url_parameter_segments, 2)"
  end

  test "a reusable element gets the URL from its caller", %{files: files} do
    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bNav") =~
             "bubble_segments={@bubble_segments}"

    assert files["lib/shop_web/components/reusables/nav.ex"] =~
             "attr :bubble_segments, :any, default: []"

    assert files["lib/shop_web/components/reusables/nav.html.heex"] =~
             ~s|Bubble.url_value(@bubble_url, @bubble_segments, :first, "text")|
  end

  test "a thing in the URL is read through Ash as the user, by data sources and workflows", %{
    files: files,
    spec: spec
  } do
    workflows = files["lib/shop_web/live/index_live/workflows.ex"]
    assert workflows =~ ~s|BubbleWorkflows.url_thing(ctx, {:query, "note"}, Shop.Note, [])|
    assert workflows =~ ~s|BubbleWorkflows.url_value(ctx, {:query, "n"}, "number")|

    assert [%{residue: [], read: {:value, _}}] =
             for(d <- spec.surfaces["bUrl"].data, d.element == "bNote", do: d)

    assert [%{residue: []}] = spec.surfaces["bUrl"].workflows

    # The page names itself: the first of its URL's segments, whatever
    # its route.
    assert workflows =~ ~s|name: "index"|
    assert files["lib/shop_web/live/api_live/workflows.ex"] =~ ~s|name: "api"|
    assert files["lib/shop_web/bubble_routes.ex"] =~ ~s|live "/api-page/:bubble_thing"|
  end

  test "the URL never becomes an atom, a field name or a query", %{files: files} do
    helpers = files["lib/shop_web/components/bubble.ex"]
    runtime = files["lib/shop_web/bubble_workflows.ex"]

    for source <- [helpers, runtime] do
      refute source =~ "String.to_atom("
      refute source =~ "binary_to_atom("
    end

    # Phoenix's params keep a repeated key's last value: the page reads the
    # query as written.
    assert runtime =~ "Bubble.url_query(query)"
    refute runtime =~ ~s|k != "bubble_thing"|
  end
end
