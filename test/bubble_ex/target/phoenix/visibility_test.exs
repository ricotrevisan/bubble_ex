defmodule BubbleEx.Target.Phoenix.VisibilityTest do
  # Visibility conditionals (WTF-477), from the synthetic
  # test/support/target/phoenix/visibility.json.
  # scripts/phoenix_compile_check.sh compiles the output and runs
  # test/support/target/phoenix/visibility_behavior.exs against it.
  use ExUnit.Case, async: true

  alias BubbleEx.{Index, Model, Plan}
  alias BubbleEx.Target.Elixir.{Frontend, FrontendWorkflows}
  alias BubbleEx.Target.Phoenix

  @fixture "test/support/target/phoenix/visibility.json"

  defp app, do: @fixture |> File.read!() |> Jason.decode!()

  defp build(app) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
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
    {:ok, ^files} = Phoenix.render(project, opts)

    %{
      files: files,
      model: model,
      index: index,
      project: project,
      frontend: frontend,
      expressions: expressions,
      opts: opts
    }
  end

  setup_all do
    build(app())
  end

  defp squash(text), do: String.replace(text, ~r/\s+/, "")

  # The opening tag of the element with Bubble ID `id`.
  defp tag(template, id) do
    [tag] = Regex.run(~r/<[.a-z_]+\s[^>]*data-bubble-id="#{id}"[^>]*>/s, template)
    tag
  end

  test "a conditional sets the hidden attribute from a helper, last true state winning", %{
    files: files
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]
    live = files["lib/shop_web/live/index_live.ex"]

    assert tag(template, "bOut") =~ "hidden={!visible_bout(@bubble_viewer)}"
    assert tag(template, "bIn") =~ "hidden={!visible_bin(@bubble_viewer)}"
    # Never a fixed `hidden` class.
    refute tag(template, "bOut") =~ ~r/class="[^"]*\bhidden\b/

    assert live =~ """
             defp visible_bout(current_user) do
               cond do
                 is_nil(current_user) == true -> true
                 true -> false
               end
             end
           """

    # Bubble's order: the last state listed decides, so the clauses are
    # tried from the last; none true keeps the visibility on page load.
    assert live =~ """
             defp visible_border(current_user) do
               cond do
                 not is_nil(current_user) == true -> false
                 is_nil(current_user) == true -> true
                 is_nil(current_user) == true -> false
                 true -> true
               end
             end
           """
  end

  test "a condition reads a custom state through the page's state map", %{files: files} do
    template = files["lib/shop_web/live/index_live.html.heex"]

    # bStyle's one visibility state sets what it has on page load: nothing
    # to evaluate (Elixir 1.20 warns on a constant helper).
    refute tag(template, "bStyle") =~ "hidden"
    refute files["lib/shop_web/live/index_live.ex"] =~ "visible_bstyle"

    assert tag(template, "bFlagged") =~
             ~s|hidden={!visible_bflagged(Bubble.state(@bubble_states, "", "bVis", "custom.flag_"))}|
  end

  test "in a reusable element, the condition's inputs are attributes", %{files: files} do
    card = files["lib/shop_web/components/reusables/card.ex"]
    assert card =~ "attr :bubble_viewer, :any, default: nil"
    assert card =~ "defp visible_bcardt(current_user) do"

    assert files["lib/shop_web/components/reusables/card.html.heex"] =~
             "hidden={!visible_bcardt(@bubble_viewer)}"

    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bMember") =~
             "bubble_viewer={@bubble_viewer}"
  end

  test "a URL parameter read as text is read from the URL the page keeps", %{files: files} do
    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bTabOpen") =~
             ~s|hidden={!visible_btabopen(Map.get(@bubble_url, "tab"))}|

    assert files["lib/shop_web/live/index_live.ex"] =~
             ~s|Shop.Bubble.Runtime.unhidden(url_parameter_tab) == "open"|

    # In a reusable element, from the map its caller passes down.
    assert files["lib/shop_web/components/reusables/card.ex"] =~
             "attr :bubble_url, :any, default: %{}"

    assert files["lib/shop_web/components/reusables/card.html.heex"] =~
             ~s|hidden={!visible_bcardtab(Map.get(@bubble_url, "tab"))}|

    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bMember") =~
             "bubble_url={@bubble_url}"

    # Two levels down: the outer component passes it on.
    assert tag(files["lib/shop_web/components/reusables/card.html.heex"], "bCardBadge") =~
             "bubble_url={@bubble_url}"

    assert files["lib/shop_web/components/reusables/badge.html.heex"] =~
             ~s|hidden={!visible_bbadgetab(Map.get(@bubble_url, "tab"))}|
  end

  test "a text shows a URL parameter as its type; a list one is not compiled", %{
    files: files
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]
    assert template =~ ~s|{text_btabtext(Map.get(@bubble_url, "tab"))}|

    # A number (WTF-508), read as Bubble reads one.
    assert template =~
             ~s|{text_btabcount(Bubble.url_value(@bubble_url, @bubble_segments, {:query, "n"}, "number"))}|

    assert template =~ "TODO(bubble:bTabMany) text: dynamic value not compiled"
    refute template =~ ~s|Map.get(@bubble_url, "tags")|
  end

  test "a URL parameter read as a list stays marked; a yes/no one compiles", %{} do
    list = %{
      "type" => "GetParamFromUrl",
      "properties" => %{
        "parameter_name" => %{"type" => "TextExpression", "entries" => %{"0" => "tab"}},
        "is_list" => true
      },
      "next" => %{
        "type" => "Message",
        "name" => "is_not_empty"
      }
    }

    template =
      app()
      |> put_in(["pages", "index", "elements", "bTabOpen", "states", "0", "condition"], list)
      |> build()
      |> Map.fetch!(:files)
      |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

    assert template =~
             "TODO(bubble:bTabOpen) visibility: 1 conditional not lowered (it does not compile)"

    condition = %{
      "type" => "GetParamFromUrl",
      "properties" => %{
        "parameter_name" => %{"type" => "TextExpression", "entries" => %{"0" => "on"}},
        "value" => "boolean"
      },
      "next" => %{"type" => "Message", "name" => "is_true"}
    }

    template =
      app()
      |> put_in(["pages", "index", "elements", "bTabOpen", "states", "0", "condition"], condition)
      |> build()
      |> Map.fetch!(:files)
      |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

    assert tag(template, "bTabOpen") =~
             ~s|Bubble.url_value(@bubble_url, @bubble_segments, {:query, "on"}, "boolean")|
  end

  test "not visible on page load is the hidden attribute, which workflow steps change", %{
    files: files
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]
    assert tag(template, "bWf") =~ ~r/\shidden[\s>]/
    refute tag(template, "bWf") =~ ~r/class="[^"]*\bhidden\b/

    css = files["assets/css/bubble.css"]
    assert css =~ "[data-bubble-id][hidden] { display: none; }"

    # A step on an element (not an overlay) is kept even when it changes
    # nothing now, as a sticky attribute, until a render changes the
    # element's condition-derived visibility (WTF-509).
    helpers = files["lib/shop_web/components/bubble.ex"]
    assert helpers =~ ~s|if (!overlay) this.override(el, false)|
    assert helpers =~ ~s|if (!el.getAttribute("data-overlay")) return this.override(el, true)|
    assert helpers =~ ~s|attributeFilter: ["data-bubble-visible"]|
    assert helpers =~ "this.conditionsChanged(this.conditions.takeRecords())"
  end

  test "a step holds until the condition-derived visibility changes (replay 2026-10-07)", %{
    files: files
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]
    flag = ~s|Bubble.state(@bubble_states, "", "bVis", "custom.flag_")|

    # T2 (hidden on load, shown when flagged) and T3 (shown on load,
    # hidden when flagged): the page hook compares data-bubble-visible
    # across renders and drops a step when it changes.
    for {id, helper} <- [{"bFlagged", "visible_bflagged"}, {"bFlagOff", "visible_bflagoff"}] do
      assert tag(template, id) =~ "hidden={!#{helper}(#{flag})}"
      # The HEEx formatter may break the attribute over lines.
      assert squash(tag(template, id)) =~
               squash("data-bubble-visible={to_string(#{helper}(#{flag}))}")
    end

    refute tag(template, "bFlagOff") =~ ~r/\shidden[\s>]/

    # T1's condition repeats its visibility on page load: nothing to
    # compare, so a step's hide holds through every change; nor has an
    # element with no conditionals.
    for id <- ~w(bKeep bWf) do
      refute tag(template, id) =~ "data-bubble-visible"
    end

    refute tag(template, "bKeep") =~ "hidden"
  end

  test "a conditional that does not compile is marked and residue, never dropped", %{
    files: files,
    frontend: frontend,
    expressions: expressions,
    model: model,
    index: index
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]

    assert template =~
             "<%!-- TODO(bubble:bBad) visibility: 1 conditional not lowered " <>
               "(it does not compile); shown as on page load --%>"

    # As on page load: hidden.
    assert tag(template, "bBad") =~ ~r/\shidden[\s>]/

    residue = Frontend.residue(frontend, expressions)

    # bBpMissing's breakpoint is not in the app's settings (see the
    # breakpoint test).
    assert residue == [
             %{subject: "element:bBpMissing", reason: :element_condition, detail: %{states: 1}},
             %{subject: "element:bBad", reason: :element_condition, detail: %{states: 1}}
           ]

    {:ok, plan} = Plan.build(model, index, frontend, [], residue: residue)
    page = Enum.find(plan.tasks, &(&1.id == "surface:page/bVis"))
    assert Enum.any?(page.residue, &(&1.reason == :element_condition))
  end

  test "a condition reads the viewport's width the runtime keeps (WTF-520)", %{files: files} do
    template = files["lib/shop_web/live/index_live.html.heex"]
    live = files["lib/shop_web/live/index_live.ex"]

    # A width test kept as an element conditional (the editor's form of a
    # state, not a breakpoint rule), alone or with another condition.
    assert tag(template, "bWidth") =~ "hidden={!visible_bwidth(@bubble_page_width)}"

    assert tag(template, "bNarrowTab") =~
             ~s|hidden={!visible_bnarrowtab(@bubble_page_width, Map.get(@bubble_url, "tab"))}|

    refute template =~ "TODO(bubble:bWidth)"
    refute template =~ "TODO(bubble:bNarrowTab)"

    assert live =~ """
             defp visible_bwidth(page_data_current_page_width) do
               cond do
                 is_nil(page_data_current_page_width) -> true
                 Shop.Bubble.Runtime.compare(:lt, page_data_current_page_width, 600) == true -> false
                 true -> true
               end
             end
           """

    # A reusable element two levels down reads it from the width its
    # caller passes down.
    assert tag(template, "bMember") =~ "bubble_page_width={@bubble_page_width}"
    card = files["lib/shop_web/components/reusables/card.html.heex"]
    assert card =~ "bubble_page_width={@bubble_page_width}"
    badge = files["lib/shop_web/components/reusables/badge.html.heex"]
    assert tag(badge, "bBadgeNarrow") =~ "visible_bbadgenarrow(@bubble_page_width)"

    assert files["lib/shop_web/components/reusables/badge.ex"] =~
             "attr :bubble_page_width, :any, default: nil"

    # The page says it reads the width: its hook reports it.
    assert files["lib/shop_web/live/index_live/workflows.ex"] =~ "page_width: true"
    refute files["lib/shop_web/live/task_live/workflows.ex"] =~ "page_width: true"
  end

  test "until the page has a width, a condition reading it keeps the page-load value", %{
    files: files
  } do
    live = files["lib/shop_web/live/cells_live.ex"]

    # Whatever the shape (is not, is empty, or, is no): an empty width
    # decides nothing.
    for {helper, initial} <- [
          {"visible_bwnot", true},
          {"visible_bwempty", false},
          {"visible_bwor", false},
          {"visible_bwno", false},
          {"visible_bcellnarrow", false}
        ] do
      assert live =~
               ~r/defp #{helper}\(page_data_current_page_width[^)]*\) do\s+cond do\s+is_nil\(page_data_current_page_width\) ->\s+#{initial}\n/,
             helper
    end

    # An "isn't clickable" conditional too: its value on page load.
    panel = files["lib/shop_web/components/reusables/panel.ex"]
    assert panel =~ "is_nil(page_data_current_page_width) -> false"
  end

  test "a reusable element whose only reads are \"isn't clickable\" conditionals gets them passed down",
       %{files: files} do
    # Its instance passes the width and the URL; without them the
    # component would render on assigns it never got.
    assert tag(files["lib/shop_web/live/cells_live.html.heex"], "bPanelI") =~
             "bubble_page_width={@bubble_page_width}"

    assert tag(files["lib/shop_web/live/cells_live.html.heex"], "bPanelI") =~
             "bubble_url={@bubble_url}"

    panel = files["lib/shop_web/components/reusables/panel.html.heex"]
    assert tag(panel, "bPanelWide") =~ "disabled={disabled_bpanelwide(@bubble_page_width)}"

    assert tag(panel, "bPanelTab") =~
             ~s|disabled={disabled_bpaneltab(Map.get(@bubble_url, "tab"))}|

    ex = files["lib/shop_web/components/reusables/panel.ex"]
    assert ex =~ "attr :bubble_page_width, :any, default: nil"
    assert ex =~ "attr :bubble_url, :any, default: %{}"
  end

  test "a page whose only width read is in a repeating group's cell reads the width", %{} do
    files =
      app()
      |> update_in(["pages", "cells", "elements"], &Map.take(&1, ["bCellsTasks"]))
      |> build()
      |> Map.fetch!(:files)

    assert tag(files["lib/shop_web/live/cells_live.html.heex"], "bCellNarrow") =~
             "hidden={!visible_bcellnarrow(@bubble_page_width)}"

    assert files["lib/shop_web/live/cells_live/workflows.ex"] =~ "page_width: true"
  end

  test "a width compared to a breakpoint reads the breakpoint's width in the app's settings",
       %{files: files} do
    template = files["lib/shop_web/live/cells_live.html.heex"]
    live = files["lib/shop_web/live/cells_live.ex"]

    # `Current page width < Tablet`: the app's Tablet is 992 pixels.
    assert tag(template, "bBpTablet") =~ "hidden={!visible_bbptablet(@bubble_page_width)}"

    assert live =~ """
             defp visible_bbptablet(page_data_current_page_width) do
               cond do
                 is_nil(page_data_current_page_width) -> true
                 Shop.Bubble.Runtime.compare(:lt, page_data_current_page_width, 992) == true -> false
                 true -> true
               end
             end
           """

    # With another condition: a custom breakpoint (640) and the URL.
    assert tag(template, "bBpWideTab") =~
             ~s|hidden={!visible_bbpwidetab(@bubble_page_width, Map.get(@bubble_url, "tab"))}|

    assert squash(live) =~
             squash("""
             (Shop.Bubble.Runtime.compare(:gte, page_data_current_page_width, 640) and
                Shop.Bubble.Runtime.unhidden(url_parameter_tab) == "open") == true ->
               true
             """)

    # A breakpoint the app's settings do not define (here the built-in
    # Mobile) does not compile: Bubble's default widths are not assumed.
    assert template =~
             "TODO(bubble:bBpMissing) visibility: 1 conditional not lowered (it does not compile)"

    refute live =~ "visible_bbpmissing"
  end

  # Real exports' compact form: a compound breakpoint test in `%s` is not
  # a breakpoint rule, so it stays an element conditional and compiles.
  test "a compact-form compound breakpoint state compiles as a conditional", %{} do
    state = %{
      "%x" => "State",
      "%p" => %{"%iv" => true},
      "%c" => %{
        "%x" => "PageData",
        "%p" => %{"%nm" => "Current Page Width"},
        "%n" => %{
          "%x" => "Message",
          "%nm" => "less_than",
          "%a" => %{"%x" => "Breakpoint", "%p" => %{"breakpoint_id" => "built-in-tablet"}},
          "%n" => %{
            "%x" => "Message",
            "%nm" => "and_",
            "%a" => %{"%x" => "CurrentUser", "%n" => %{"%x" => "Message", "%nm" => "logged_in"}}
          }
        }
      }
    }

    element = %{
      "id" => "bBpCompact",
      "%x" => "Text",
      "%p" => %{"%3" => "Compact", "%iv" => false, "order" => 10},
      "%s" => %{"0" => state}
    }

    %{files: files} =
      app() |> put_in(["pages", "cells", "elements", "bBpCompact"], element) |> build()

    template = files["lib/shop_web/live/cells_live.html.heex"]
    live = files["lib/shop_web/live/cells_live.ex"]
    assert tag(template, "bBpCompact") =~ "hidden={!visible_bbpcompact("
    refute template =~ "TODO(bubble:bBpCompact)"
    assert live =~ "Shop.Bubble.Runtime.compare(:lt, page_data_current_page_width, 992)"
    assert [helper] = Regex.run(~r/defp visible_bbpcompact\(.*?\n  end\n/s, live)
    assert helper =~ "compare(:lt, page_data_current_page_width, 992)"
    assert helper =~ "current_user"
  end

  test "without breakpoint settings, no breakpoint compiles", %{} do
    template =
      app()
      |> Map.delete("settings")
      |> build()
      |> Map.fetch!(:files)
      |> Map.fetch!("lib/shop_web/live/cells_live.html.heex")

    for id <- ~w(bBpTablet bBpWideTab bBpMissing) do
      assert template =~
               "TODO(bubble:#{id}) visibility: 1 conditional not lowered (it does not compile)",
             id
    end
  end

  test "other page values a condition reads do not compile", %{} do
    for name <- ["Current Page Name", "Current Date/Time"] do
      template =
        app()
        |> put_in(
          ["pages", "index", "elements", "bWidth", "states", "0", "condition", "properties"],
          %{"name" => name}
        )
        |> build()
        |> Map.fetch!(:files)
        |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

      assert template =~
               "TODO(bubble:bWidth) visibility: 1 conditional not lowered (it does not compile)",
             name
    end
  end

  test "the report counts compiled, marked and other conditional properties", %{
    project: project,
    opts: opts
  } do
    {:ok, report} = Phoenix.frontend_report(project, Keyword.delete(opts, :frontend_workflows))

    # Without the workflows the page keeps no custom state, input value or
    # URL and loads no data: bFlagged's, bFlagOff's, bOpen's,
    # bCellNoProject's, bHasProject's, bTabOpen's, bCardTab's,
    # bBadgeTab's and the width's (bWidth, bNarrowTab, bBadgeNarrow and
    # the cells page's five, and its three breakpoint tests) conditionals
    # are marked too (bKeep's only repeats its visibility on page load:
    # compiled, whatever it reads). The panel's two "isn't clickable"
    # states are other properties.
    assert %{
             "visibility_conditions_compiled" => 9,
             "visibility_conditions_marked" => 20,
             "conditions_other_properties" => 4
           } = report
  end

  test "a condition reading what the page does not keep is marked", %{files: files} do
    template =
      app()
      |> put_in(
        ["pages", "index", "elements", "bIn", "states", "0", "condition"],
        %{"type" => "GetParamFromUrl", "properties" => %{"parameter_name" => "tab"}}
      )
      |> build()
      |> Map.fetch!(:files)
      |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

    assert template =~
             "TODO(bubble:bIn) visibility: 1 conditional not lowered (it does not compile)"

    assert tag(template, "bIn") =~ ~r/\shidden[\s>]/
    refute files["lib/shop_web/live/index_live.ex"] =~ "defp visible_bin(url_parameter"

    # An element's built-in state compiles, but no page keeps it.
    template =
      app()
      |> put_in(
        ["pages", "index", "elements", "bIn", "states", "0", "condition"],
        %{
          "type" => "GetElement",
          "properties" => %{"element_id" => "bSetFlag"},
          "next" => %{"type" => "Message", "name" => "is_hovered"}
        }
      )
      |> build()
      |> Map.fetch!(:files)
      |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

    assert template =~
             "TODO(bubble:bIn) visibility: 1 conditional not lowered (it reads a value " <>
               "the page does not keep: element_state:is_hovered)"

    assert tag(template, "bIn") =~ ~r/\shidden[\s>]/
  end

  test "overlays keep their workflow model", %{} do
    app =
      put_in(app(), ["pages", "index", "elements", "bPop"], %{
        "id" => "bPop",
        "type" => "Popup",
        "properties" => %{"height" => 100, "width" => 200, "order" => 20},
        "states" => %{
          "0" => %{
            "condition" => %{
              "type" => "CurrentUser",
              "next" => %{"type" => "Message", "name" => "logged_in"}
            },
            "properties" => %{"is_visible" => true}
          }
        }
      })

    %{files: files, frontend: frontend, expressions: expressions} = build(app)
    template = files["lib/shop_web/live/index_live.html.heex"]

    assert template =~
             "TODO(bubble:bPop) visibility: 1 conditional not lowered (an overlay: workflows"

    refute template =~ "visible_bpop"
    assert Enum.any?(Frontend.residue(frontend, expressions), &(&1.subject == "element:bPop"))
  end

  test "an element a breakpoint shows keeps its hidden class; its conditionals are marked", %{
    project: project,
    frontend: frontend,
    expressions: expressions
  } do
    rule = %{"media" => %{"operator" => "<", "width" => 600}, "paint" => %{"display" => "revert"}}

    put_rule = fn
      %{source: %{bubble_id: id}} = node when id in ["bOut", "bWf"] ->
        %{node | responsive: [rule]}

      node ->
        node
    end

    pages =
      Enum.map(frontend.pages, fn page ->
        %{page | children: Enum.map(page.children, put_rule)}
      end)

    {:ok, files} =
      Phoenix.render(project,
        module: "Shop",
        frontend: %{frontend | pages: pages},
        expressions: expressions
      )

    template = files["lib/shop_web/live/index_live.html.heex"]

    for id <- ~w(bOut bWf) do
      # Not collapsing when hidden, it keeps its space: `invisible`.
      assert tag(template, id) =~ ~r/class="[^"]*\binvisible\b/
      refute String.replace(tag(template, id), ~r/class="[^"]*"/, "") =~ "hidden"
    end

    assert template =~
             "TODO(bubble:bOut) visibility: 1 conditional not lowered (a breakpoint also shows it)"
  end

  test "a condition reads the current user as the runtime refreshes it", %{files: files} do
    template = files["lib/shop_web/live/index_live.html.heex"]
    assert tag(template, "bAdmin") =~ "hidden={!visible_badmin(@bubble_viewer)}"
    refute files["lib/shop_web/live/index_live.ex"] =~ "assign(:bubble_viewer"

    helpers = files["lib/shop_web/components/bubble.ex"]
    assert helpers =~ "def viewer_loads, do: []"

    runtime = files["lib/shop_web/bubble_workflows.ex"]
    assert runtime =~ "def refresh_viewer(socket)"
    assert runtime =~ "Ash.get(resource, id, actor: actor, not_found_error?: false)"
    assert runtime =~ "defp unforbidden(%Ash.ForbiddenField{}), do: nil"
  end

  test "the relationships a condition reads are loaded with the page data", %{files: files} do
    index = files["lib/shop_web/live/index_live/workflows.ex"]
    assert index =~ ~r/element: "bTasks",.*?loads: \[\["project"\]\]/s

    task = files["lib/shop_web/live/task_live/workflows.ex"]
    assert task =~ ~r/element: "bTaskGroup",.*?loads: \[\["project"\]\]/s

    # ... and a condition helper refuses a relationship that was not.
    live = files["lib/shop_web/live/index_live.ex"]
    assert live =~ ~s|Bubble.loaded!(cell_thing_btasks, [["project"]])|

    assert files["lib/shop_web/live/task_live.ex"] =~
             ~s|Bubble.loaded!(element_state_btaskgroup_get_group_data, [["project"]])|

    assert files["lib/shop_web/components/bubble.ex"] =~
             "defp loaded_path!(%Ash.NotLoaded{}, _rest, path)"
  end

  test "a condition reads an input's value from the page's input map", %{files: files} do
    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bOpen") =~
             ~s|hidden={!visible_bopen(Bubble.input(@bubble_inputs, "", "bName"))}|
  end

  test "repeating group cells are keyed by their item", %{files: files} do
    assert files["lib/shop_web/live/index_live.html.heex"] =~
             ~s|id={Bubble.cell_id("", "bTasks", cell_btasks, cell_btasks_i)}|
  end
end
