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

  defp build(app, workflow_opts \\ []) do
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
      FrontendWorkflows.map(
        lowered,
        project,
        [
          namespace: "Shop",
          frontend: frontend,
          backend: backend,
          page_data: page_data
        ] ++ workflow_opts
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

  test "a reusable element's workflow reads its instance's visibility, which the page computes (WTF-605)" do
    app = app()
    {:ok, model} = Model.build(app)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    index = Frontend.visibility_index(app, model, frontend)
    %{files: files} = build(app, element_visibility: index)

    spot = files["lib/shop_web/components/reusables/spot/workflows.ex"]
    assert spot =~ "BubbleWorkflows.instance_visible(ctx)"

    page = files["lib/shop_web/live/index_live/workflows.ex"]
    # One clause per instance the reusable element's workflows read, each
    # level read in its host's scope; nil for any other scope.
    assert squash(page) =~
             squash(
               ~s|def __bubble_visible__("bSpotA", ctx), do: __visible_1__(BubbleWorkflows.host_ctx(ctx, ""))|
             )

    assert squash(page) =~
             squash(
               ~s|def __bubble_visible__("bSpotB", ctx), do: __visible_2__(BubbleWorkflows.host_ctx(ctx, ""))|
             )

    assert squash(page) =~ squash("def __bubble_visible__(_scope, _ctx), do: nil")
    assert page =~ ~s|BubbleWorkflows.state(ctx, [], "bVis", "custom.flag_")|
    refute page =~ ~s|__bubble_visible__("bMember"|

    # Without the reusable element's reads, the page computes none.
    refute build(app)[:files]["lib/shop_web/live/index_live/workflows.ex"] =~ "__bubble_visible__"
  end

  test "a reusable element two levels down: each level in its host's scope (WTF-605)" do
    badge = ["element_definitions", "badge"]

    app =
      app()
      |> update_in(badge, &Map.put(&1, "custom_states", %{"seen_" => %{"value" => "boolean"}}))
      |> update_in(badge ++ ["workflows"], fn workflows ->
        Map.put(workflows || %{}, "wBadgeDo", %{
          "id" => "wBadgeDo",
          "type" => "ConditionTrue",
          "properties" => %{
            "condition" => %{
              "type" => "GetElement",
              "properties" => %{"element_id" => "bBadge"},
              "next" => %{"type" => "Message", "name" => "is_visible"}
            },
            "run_when" => "every_time"
          },
          "actions" => %{
            "0" => %{
              "id" => "aBadgeDo1",
              "type" => "SetCustomState",
              "properties" => %{
                "custom_state" => "custom.seen_",
                "element_id" => "bBadge",
                "value" => true
              }
            }
          }
        })
      end)

    {:ok, model} = Model.build(app)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    %{files: files} =
      build(app, element_visibility: Frontend.visibility_index(app, model, frontend))

    page = squash(files["lib/shop_web/live/index_live/workflows.ex"])

    assert page =~
             ~r/def__bubble_visible__\("bMember-bCardBadge",ctx\),do:__visible_\d+__\(BubbleWorkflows.host_ctx\(ctx,""\)\)and__visible_\d+__\(BubbleWorkflows.host_ctx\(ctx,"bMember"\)\)/
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

  test "a group hidden by its conditions renders its contents only while they show it (WTF-559)",
       %{files: files, project: project, opts: opts} do
    template = files["lib/shop_web/live/index_live.html.heex"]

    # Nothing in the browser shows bIn or bOut, and nothing reads what is
    # inside: their own element always, their contents with the same
    # expression as `hidden`.
    for {id, child, helper} <- [
          {"bIn", "bInT", "visible_bin"},
          {"bOut", "bOutT", "visible_bout"},
          {"bCollOut", "bCollOutT", "visible_bcollout"}
        ] do
      [group] =
        Regex.run(~r/<div[^>]*data-bubble-id="#{id}".*?<\/Bubble.contents>\s*<\/div>/s, template)

      assert squash(group) =~
               squash(
                 ~s|<Bubble.contents :if={#{helper}(@bubble_viewer)}><p data-bubble-id="#{child}"|
               )
    end

    # A text with conditionals has no contents to leave out.
    refute tag(template, "bFlagged") =~ "Bubble.contents"

    # The traceability test expects their contents only where they render.
    surfaces = files["test/shop_web/bubble_surfaces_test.exs"]
    refute surfaces =~ ~s("bInT")
    assert surfaces =~ ~s("bIn")

    {:ok, report} = Phoenix.frontend_report(project, opts)
    assert %{"visibility_contents_skipped" => 3} = report
  end

  test "only a group whose conditions compiled leaves its contents out; the surface test expects the others' (WTF-559)" do
    group = fn id, condition ->
      %{
        "id" => id,
        "type" => "Group",
        "properties" => %{"height" => 40, "is_visible" => false, "order" => 4, "width" => 300},
        "states" => %{
          "0" => %{
            "type" => "State",
            "condition" => condition,
            "properties" => %{"is_visible" => true}
          }
        },
        "elements" => %{
          (id <> "T") => %{
            "id" => id <> "T",
            "type" => "Text",
            "properties" => %{
              "height" => 40,
              "order" => 1,
              "width" => 300,
              "text" => %{"entries" => %{"0" => "Inside"}, "type" => "TextExpression"}
            }
          }
        }
      }
    end

    logged_in = %{
      "type" => "CurrentUser",
      "next" => %{"type" => "Message", "name" => "logged_in"}
    }

    # A state no page keeps: the conditional is marked, the group rendered whole.
    hovered = %{
      "type" => "GetElement",
      "properties" => %{"element_id" => "bSetFlag"},
      "next" => %{"type" => "Message", "name" => "is_hovered"}
    }

    files =
      app()
      |> put_in(
        ["element_definitions", "card", "elements", "bCardIn"],
        group.("bCardIn", logged_in)
      )
      |> put_in(
        ["element_definitions", "card", "elements", "bCardBad"],
        group.("bCardBad", hovered)
      )
      |> build()
      |> Map.fetch!(:files)

    card = files["lib/shop_web/components/reusables/card.html.heex"]
    [inner] = Regex.run(~r/data-bubble-id="bCardIn".*?<\/div>\s*<\/div>/s, card)
    assert inner =~ "<Bubble.contents :if={visible_bcardin(@bubble_viewer)}>"
    [bad] = Regex.run(~r/data-bubble-id="bCardBad".*?<\/div>/s, card)
    refute bad =~ "Bubble.contents"

    # The index page renders the card (bMember): its test expects what
    # the card renders whole, never what renders only while shown.
    [index] =
      Regex.run(
        ~r/@tag bubble: "page:bVis".*?\n  end\n/s,
        files["test/shop_web/bubble_surfaces_test.exs"]
      )

    assert index =~ ~s("bCardBadT")
    assert index =~ ~s("bCardIn")
    refute index =~ ~s("bCardInT")
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

  # The a361e4e regression: an element hidden on page load that collapses
  # when hidden had a static `hidden` class besides the attribute, so
  # neither its conditionals nor a step could show it.
  test "hidden on page load and collapsing when hidden: only the attribute, never a class", %{
    files: files
  } do
    template = files["lib/shop_web/live/index_live.html.heex"]

    # Server-evaluated: the conditional's helper sets the attribute.
    assert tag(template, "bCollOut") =~ "hidden={!visible_bcollout(@bubble_viewer)}"
    # A workflow step removes the attribute.
    assert tag(template, "bCollWf") =~ ~r/\shidden[\s>]/

    for id <- ~w(bCollOut bCollWf) do
      refute tag(template, id) =~ ~r/class="[^"]*\b(hidden|invisible)\b/
    end

    assert files["assets/css/bubble.css"] =~ "[data-bubble-id][hidden] { display: none; }"
  end

  # The same two elements in the pinned browser, through the generated hook
  # (test/support/fidelity/collapse-show.mjs): their condition's render or
  # a Show step makes them visible.
  @tag :fidelity
  @tag :tmp_dir
  test "hidden on page load and collapsing when hidden: shown once a condition or a step shows it",
       %{files: files, tmp_dir: tmp} do
    template = files["lib/shop_web/live/index_live.html.heex"]

    [rule] =
      Regex.run(
        ~r/\[data-bubble-id\]\[hidden\] \{ display: none; \}/,
        files["assets/css/bubble.css"]
      )

    [_, script] =
      String.split(files["lib/shop_web/components/bubble.ex"], ~s(name=".BubbleRuntime">))

    [hook | _] = String.split(script, "</script>")

    elements =
      Enum.map_join(
        [{"bCollOut", "Collapsed sign in"}, {"bCollWf", "Collapsed, shown by a step"}],
        "\n",
        fn {id, text} ->
          open = template |> tag(id) |> static_html()
          [_, name] = Regex.run(~r/\A<([a-z]+)/, open)
          "#{open}#{text}</#{name}>"
        end
      )

    # Tailwind's display and visibility utilities, in their layer.
    page = """
    <!doctype html><html><head><style>
    @layer utilities {
      .hidden { display: none; } .invisible { visibility: hidden; } .block { display: block; }
      .flex { display: flex; } .grid { display: grid; } .inline-flex { display: inline-flex; }
    }
    #{rule}
    </style></head><body>
    #{elements}
    <div id="bubble-runtime" hidden></div>
    </body></html>
    """

    File.write!(Path.join(tmp, "hook.js"), hook)
    File.write!(Path.join(tmp, "page.html"), page)

    {output, status} =
      System.cmd(
        "node",
        [
          "test/support/fidelity/collapse-show.mjs",
          Path.join(tmp, "hook.js"),
          Path.join(tmp, "page.html")
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "PASS collapse-when-hidden shows"
  end

  # An opening tag as the browser gets it while hidden: `hidden={...}` is
  # the attribute, other `{...}` attributes are left out.
  defp static_html(tag), do: static_html(tag, "")

  defp static_html("", acc), do: acc

  defp static_html(<<" ", rest::binary>> = tag, acc) do
    case Regex.run(~r/\A\s+([a-zA-Z_:.\-]+)=\{/, tag) do
      [match, name] ->
        after_expression =
          skip_braces(binary_part(tag, byte_size(match), byte_size(tag) - byte_size(match)), 1)

        static_html(after_expression, if(name == "hidden", do: acc <> " hidden", else: acc))

      nil ->
        static_html(rest, acc <> " ")
    end
  end

  defp static_html(<<char::utf8, rest::binary>>, acc),
    do: static_html(rest, acc <> <<char::utf8>>)

  defp skip_braces(rest, 0), do: rest
  defp skip_braces(<<"{", rest::binary>>, depth), do: skip_braces(rest, depth + 1)
  defp skip_braces(<<"}", rest::binary>>, depth), do: skip_braces(rest, depth - 1)
  defp skip_braces(<<_::utf8, rest::binary>>, depth), do: skip_braces(rest, depth)

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
    # breakpoint test); bTextBad's conditional text does not compile
    # (WTF-582).
    assert residue == [
             %{subject: "element:bBpMissing", reason: :element_condition, detail: %{states: 1}},
             %{subject: "element:bBad", reason: :element_condition, detail: %{states: 1}},
             %{
               subject: "element:bTextBad",
               reason: :element_condition,
               detail: %{states: 1, property: "text"}
             }
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

  # Replay 2026-10-19: Bubble offers Current page name only inside a
  # reusable element, where it is the host page's name.
  test "a reusable element reads its host page's name, passed down", %{files: files} do
    host = files["lib/shop_web/components/reusables/host.html.heex"]
    host_ex = files["lib/shop_web/components/reusables/host.ex"]
    inner = files["lib/shop_web/components/reusables/host_in.html.heex"]

    assert tag(host, "bHostIs") =~ "hidden={!visible_bhostis(@bubble_page_name)}"
    assert host =~ "{text_bhostname(@bubble_page_name)}"
    assert host_ex =~ "attr :bubble_page_name, :any, default: nil"
    assert squash(host_ex) =~ squash(~s|unhidden(page_data_current_page_name) == "cells"|)

    # Each page passes its own Bubble name; a reusable element passes it on.
    assert tag(host, "bHostInI") =~ "bubble_page_name={@bubble_page_name}"
    assert tag(inner, "bHostInIs") =~ "hidden={!visible_bhostinis(@bubble_page_name)}"

    assert tag(files["lib/shop_web/live/index_live.html.heex"], "bHostI") =~
             ~s(bubble_page_name="index")

    assert tag(files["lib/shop_web/live/cells_live.html.heex"], "bHostC") =~
             ~s(bubble_page_name="cells")

    refute host =~ "TODO(bubble:bHost"
  end

  test "Current page name on a page itself is marked with why", %{files: files} do
    template = files["lib/shop_web/live/index_live.html.heex"]
    why = "it reads Current page name on a page: Bubble offers it only inside a reusable element"

    assert template =~
             "TODO(bubble:bPageName) visibility: 1 conditional not lowered (#{why}); " <>
               "shown as on page load"

    assert tag(template, "bPageName") =~ ~r/\shidden[\s>]/
    assert template =~ "TODO(bubble:bPageNameText) text: #{why}"
    refute files["lib/shop_web/live/index_live.ex"] =~ "visible_bpagename"
  end

  # Replay 2026-10-19: computed once per evaluation, no timer, never empty.
  test "Current date/time compiles against the time of the render", %{files: files} do
    template = files["lib/shop_web/live/index_live.html.heex"]
    live = files["lib/shop_web/live/index_live.ex"]

    assert tag(template, "bNow") =~ "hidden={!visible_bnow(DateTime.utc_now())}"
    assert tag(template, "bNowEmpty") =~ "hidden={!visible_bnowempty(DateTime.utc_now())}"
    assert live =~ "Shop.Bubble.Runtime.empty?(page_data_current_date_time) == true -> true"
    refute template =~ "TODO(bubble:bNow"
    refute live =~ "setInterval"
  end

  # Replay 2026-10-19: no while a search runs, yes only for a flicker.
  test "a repeating group's is loading is a constant no", %{files: files} do
    template = files["lib/shop_web/live/index_live.html.heex"]
    live = files["lib/shop_web/live/index_live.ex"]

    assert tag(template, "bLoaded") =~ "hidden={!visible_bloaded()}"
    assert tag(template, "bLoading") =~ "hidden={!visible_bloading()}"
    assert live =~ "false == false == true -> true"
    assert live =~ "false == true == true -> true"
    refute template =~ "TODO(bubble:bLoad"
  end

  test "a breakpoint shown as text is its width", %{files: files} do
    assert files["lib/shop_web/live/cells_live.ex"] =~
             ~s|"Tablet: " <> Shop.Bubble.Runtime.display(992)|
  end

  test "the report counts compiled, marked and other conditional properties", %{
    project: project,
    opts: opts
  } do
    {:ok, report} = Phoenix.frontend_report(project, Keyword.delete(opts, :frontend_workflows))

    # Without the workflows the page keeps no custom state, input value or
    # URL and loads no data: bFlagged's, bFlagOff's, bVisSeen's,
    # bVisMet's, bSpotA's, bSpotSeen's, bSpotClicked's (WTF-605), bOpen's,
    # bCellNoProject's, bHasProject's, bTabOpen's,
    # bCardTab's, bBadgeTab's and the width's (bWidth, bNarrowTab, bBadgeNarrow and
    # the cells page's five, and its three breakpoint tests), the page
    # name's (bHostIs, bHostInIs, bPageName) and the date/time's (bNow,
    # bNowEmpty) conditionals are marked too (bKeep's only repeats its
    # visibility on page load: compiled, whatever it reads; bLoaded's and
    # bLoading's read a repeating group's "is loading", a constant). The
    # panel's two "isn't clickable" states are other properties. Of the
    # conditional texts (WTF-582), only those reading the current user
    # compile (bRoleText's, bBold's). bSpotT's reads the current user:
    # compiled. bVisG's and the three that read its visibility (WTF-578)
    # compile; bVisWf's (a step shows what it reads)
    # and bVisSelf's (it reads itself) are marked. The Floating Group
    # bOvFloat's and bOvFloatRead's, which reads inside it, compile
    # (WTF-587); bOvPopRead's reads bOvPop's open state, which a page
    # without workflows does not keep: marked.
    assert %{
             "visibility_conditions_compiled" => 19,
             "visibility_conditions_marked" => 33,
             "text_conditions_compiled" => 2,
             "text_conditions_marked" => 8,
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

  # WTF-582: conditionals that set a Text's content or a button's label.
  describe "conditional text" do
    defp text_element(template, id),
      do: hd(Regex.run(~r/<[a-z]+\s[^>]*data-bubble-id="#{id}".*?<\/[a-z]+>/s, template))

    test "is a helper folding the states from the content on page load, the last true winning",
         %{files: files} do
      template = files["lib/shop_web/live/index_live.html.heex"]
      live = files["lib/shop_web/live/index_live.ex"]

      greet = text_element(template, "bGreet")

      assert greet =~
               ~s|>{text_bgreet(@bubble_viewer, Bubble.state(@bubble_states, "", "bVis", "custom.flag_"))}</p>|

      refute greet =~ "not lowered"

      # With several states each condition is read first (no clause
      # narrows what a later one reads, WTF-555), tried last first.
      [greet_helper] = Regex.run(~r/  defp text_bgreet\(.*?\n  end\n/s, live)

      assert squash(greet_helper) =~
               squash("""
               defp text_bgreet(current_user, element_state_bvis_custom_flag) do
                 bubble_state_1 = not is_nil(current_user) == true
                 bubble_state_2 = element_state_bvis_custom_flag == true == true

                 cond do
                   bubble_state_2 -> "Flagged"
               """)

      assert greet_helper =~ ~r/bubble_state_1 ->\s+"Hello " <> Shop.Bubble.Runtime.display\(/
      assert greet_helper =~ ~r/true ->\s+"Signed out"\s+end/

      # A button's label, on a custom state.
      assert text_element(template, "bFlagLabel") =~
               ~s|>{label_bflaglabel(Bubble.state(@bubble_states, "", "bVis", "custom.flag_"))}</button>|

      assert live =~ ~s|element_state_bvis_custom_flag == true == true -> "Flag on"|

      # In a cell, on the cell's thing.
      assert text_element(template, "bCellLabel") =~ ">{text_bcelllabel(cell_btasks)}</p>"
      assert live =~ ~s|defp text_bcelllabel(cell_thing_btasks) do|
    end

    test "reads the current user as visibility conditionals do", %{files: files} do
      assert files["lib/shop_web/live/index_live.html.heex"]
             |> text_element("bRoleText") =~ ">{text_broletext(@bubble_viewer)}</p>"

      assert files["lib/shop_web/live/index_live.ex"] =~ "defp text_broletext(current_user) do"
    end

    test "with BBCode in its literal text, every value is Bubble.bbcode/1's nodes", %{
      files: files
    } do
      assert files["lib/shop_web/live/index_live.html.heex"] |> text_element("bBold") =~
               "><Bubble.bbcode nodes={text_bbold(@bubble_viewer)} /></p>"

      assert files["lib/shop_web/live/index_live.ex"] =~ """
               defp text_bbold(current_user) do
                 cond do
                   not is_nil(current_user) == true ->
                     [{:b, [Shop.Bubble.Runtime.display(get_in(current_user, [Access.key(:email)]))]}]

                   true ->
                     [{:b, ["Out"]}]
                 end
               end
             """
    end

    test "reading the page's data keeps the content on page load until it loads", %{
      files: files
    } do
      assert files["lib/shop_web/live/task_live.html.heex"] |> text_element("bProjectText") =~
               ~s|>{if(@bubble_data_pending, do: "No project", else: text_bprojecttext(|

      # Like the element's dynamic text, it reads a relationship that was
      # not loaded as empty: never Bubble.loaded!/2, which would crash the page.
      [helper] =
        Regex.run(
          ~r/  defp text_bprojecttext\(.*?\n  end\n/s,
          files["lib/shop_web/live/task_live.ex"]
        )

      refute helper =~ "loaded!"
      assert helper =~ "project"
    end

    test "with BBCode only the static path renders, keeps it, marked", %{files: files} do
      link = files["lib/shop_web/live/index_live.html.heex"] |> text_element("bLinkText")

      assert link =~
               "TODO(bubble:bLinkText) text: 1 conditional not lowered (its text has BBCode " <>
                 "other than bold, italic, underline or strikethrough); shown as on page load"

      assert link =~ ~s|<a href="https://example.com"|
    end

    test "that the page cannot decide keeps the content on page load, marked", %{files: files} do
      template = files["lib/shop_web/live/index_live.html.heex"]

      bad = text_element(template, "bTextBad")

      assert bad =~
               "TODO(bubble:bTextBad) text: 1 conditional not lowered (it does not compile); " <>
                 "shown as on page load --%>Kept</p>"

      assert bad =~ ~s|title={Bubble.dev_marker("Conditional text not lowered")}|

      assert text_element(template, "bHoverText") =~
               "TODO(bubble:bHoverText) text: 1 conditional not lowered (it reads a value the " <>
                 "page does not keep: element_state:is_hovered); shown as on page load --%>Still</p>"

      refute files["lib/shop_web/live/index_live.ex"] =~ "defp text_btextbad"
    end

    test "is counted, and what is left is plan residue", %{
      project: project,
      opts: opts,
      frontend: frontend,
      expressions: expressions
    } do
      {:ok, report} = Phoenix.frontend_report(project, opts)
      assert %{"text_conditions_compiled" => 7, "text_conditions_marked" => 3} = report

      texts =
        for %{reason: :element_condition, detail: %{property: "text"}} = r <-
              Frontend.residue(frontend, expressions),
            do: r.subject

      assert texts == ["element:bTextBad"]
    end
  end

  describe "an element's is visible (WTF-578)" do
    test "is its visibility folded from its conditionals, negated for isn't visible", %{
      files: files
    } do
      template = files["lib/shop_web/live/index_live.html.heex"]
      live = files["lib/shop_web/live/index_live.ex"]

      assert tag(template, "bVisOf") =~ "hidden={!visible_bvisof(@bubble_viewer)}"
      assert tag(template, "bNotVisOf") =~ "hidden={!visible_bnotvisof(@bubble_viewer)}"

      # bVisG is hidden on page load and shown when logged in: reading it
      # reads that.
      assert live =~ """
               defp visible_bvisof(current_user) do
                 cond do
                   if(not is_nil(current_user), do: true, else: false) == true -> true
                   true -> false
                 end
               end
             """

      assert squash(live) =~
               squash(
                 "defp visible_bnotvisof(current_user) do cond do " <>
                   "if(not is_nil(current_user), do: true, else: false) != true"
               )
    end

    test "inside a hidden group is not visible: the read folds the group's too", %{
      files: files
    } do
      template = files["lib/shop_web/live/index_live.html.heex"]
      live = files["lib/shop_web/live/index_live.ex"]

      # bVisGT has no conditional of its own; bVisG holds it.
      assert tag(template, "bVisChild") =~ "hidden={!visible_bvischild(@bubble_viewer)}"

      assert squash(live) =~
               squash(
                 "defp visible_bvischild(current_user) do cond do " <>
                   "if(not is_nil(current_user), do: true, else: false) == true -> true"
               )
    end

    test "is not decided where a step shows it, or where it reads itself", %{files: files} do
      template = files["lib/shop_web/live/index_live.html.heex"]

      assert template =~
               "TODO(bubble:bVisWf) visibility: 1 conditional not lowered (it reads a value " <>
                 "the page does not keep: element_state:is_visible); shown as on page load"

      assert template =~
               "TODO(bubble:bVisSelf) visibility: 1 conditional not lowered (it reads a value " <>
                 "the page does not keep: element_state:isnt_visible); shown as on page load"
    end

    test "of an element holding the reader is yes; a cell's stays", %{} do
      reads = fn element, state ->
        %{
          "type" => "GetElement",
          "properties" => %{"element_id" => element},
          "next" => %{"type" => "Message", "name" => state}
        }
      end

      app =
        app()
        # Inside bVisG, reading bVisG: shown only while bVisG is.
        |> put_in(["pages", "index", "elements", "bVisG", "elements", "bVisGT", "states"], %{
          "0" => %{
            "type" => "State",
            "condition" => reads.("bVisG", "isnt_visible"),
            "properties" => %{"is_visible" => false}
          }
        })
        # Hidden on page load, shown when bVisG is: always shown while
        # bVisG is, so shown.
        |> put_in(["pages", "index", "elements", "bVisG", "elements", "bVisGT2"], %{
          "id" => "bVisGT2",
          "type" => "Text",
          "properties" => %{
            "height" => 40,
            "width" => 300,
            "order" => 2,
            "is_visible" => false,
            "text" => %{"type" => "TextExpression", "entries" => %{"0" => "Also"}}
          },
          "states" => %{
            "0" => %{
              "type" => "State",
              "condition" => reads.("bVisG", "is_visible"),
              "properties" => %{"is_visible" => true}
            }
          }
        })
        # Outside the repeating group, reading an element of its cells.
        |> put_in(
          ["pages", "index", "elements", "bNotVisOf", "states", "0", "condition"],
          reads.("bCellTitle", "isnt_visible")
        )

      %{files: files} = build(app)
      template = files["lib/shop_web/live/index_live.html.heex"]

      # bVisGT never hides itself while shown: its conditional never
      # applies, so it is the visibility on page load, with no helper.
      refute template =~ "TODO(bubble:bVisGT)"
      refute files["lib/shop_web/live/index_live.ex"] =~ "defp visible_bvisgt"
      refute tag(template, "bVisGT") =~ ~r/\shidden[\s>=]/
      refute template =~ "TODO(bubble:bVisGT2)"
      refute files["lib/shop_web/live/index_live.ex"] =~ "defp visible_bvisgt2"
      refute tag(template, "bVisGT2") =~ ~r/\shidden[\s>=]/

      assert template =~
               "TODO(bubble:bNotVisOf) visibility: 1 conditional not lowered (it reads a value " <>
                 "the page does not keep: element_state:isnt_visible)"
    end

    test "is not decided where a group reads its own contents, or a step shows an ancestor",
         %{} do
      reads = fn element, state ->
        %{
          "type" => "GetElement",
          "properties" => %{"element_id" => element},
          "next" => %{"type" => "Message", "name" => state}
        }
      end

      # bVisG shown when its own child is: Bubble keeps it hidden.
      template =
        app()
        |> put_in(
          ["pages", "index", "elements", "bVisG", "states", "0", "condition"],
          reads.("bVisGT", "is_visible")
        )
        |> build()
        |> Map.fetch!(:files)
        |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

      assert template =~
               "TODO(bubble:bVisG) visibility: 1 conditional not lowered (it reads a value " <>
                 "the page does not keep: element_state:is_visible)"

      assert tag(template, "bVisG") =~ ~r/\shidden[\s>]/

      # A step shows bVisG: neither bVisG nor what is inside it is decided.
      template =
        app()
        |> put_in(
          ["pages", "index", "workflows", "wShow", "actions", "0", "properties", "element_id"],
          "bVisG"
        )
        |> build()
        |> Map.fetch!(:files)
        |> Map.fetch!("lib/shop_web/live/index_live.html.heex")

      for id <- ~w(bVisOf bVisChild) do
        assert template =~
                 "TODO(bubble:#{id}) visibility: 1 conditional not lowered (it reads a value " <>
                   "the page does not keep: element_state:is_visible)"
      end
    end

    test "isn't visible of an element and its group is either one hidden", %{} do
      app =
        put_in(
          app(),
          ["pages", "index", "elements", "bVisG", "elements", "bVisGT", "states"],
          %{
            "0" => %{
              "type" => "State",
              "condition" => %{
                "type" => "CurrentUser",
                "next" => %{
                  "type" => "Message",
                  "name" => "role_text",
                  "next" => %{"type" => "Message", "name" => "is_empty"}
                }
              },
              "properties" => %{"is_visible" => false}
            }
          }
        )
        |> put_in(["pages", "index", "elements", "bNotVisOf", "states", "0", "condition"], %{
          "type" => "GetElement",
          "properties" => %{"element_id" => "bVisGT"},
          "next" => %{"type" => "Message", "name" => "isnt_visible"}
        })

      live = build(app).files["lib/shop_web/live/index_live.ex"]
      [helper] = Regex.run(~r/defp visible_bnotvisof\(.*?\n  end\n/s, live)

      # Not (bVisGT shown and bVisG shown): either one's fold is not yes.
      assert helper =~ " or "
      assert length(Regex.scan(~r/!=\s+true/, helper)) == 2
    end

    test "a state decided when compiling sets the value also until the page has a width", %{} do
      app =
        put_in(app(), ["pages", "index", "elements", "bVisG", "elements", "bVisGW"], %{
          "id" => "bVisGW",
          "type" => "Text",
          "properties" => %{
            "height" => 40,
            "width" => 300,
            "order" => 3,
            "is_visible" => false,
            "text" => %{"type" => "TextExpression", "entries" => %{"0" => "Wide"}}
          },
          "states" => %{
            "0" => %{
              "type" => "State",
              "condition" => %{
                "type" => "GetElement",
                "properties" => %{"element_id" => "bVisG"},
                "next" => %{"type" => "Message", "name" => "is_visible"}
              },
              "properties" => %{"is_visible" => true}
            },
            "1" => %{
              "type" => "State",
              "condition" => %{
                "type" => "PageData",
                "properties" => %{"name" => "Current Page Width"},
                "next" => %{"type" => "Message", "name" => "less_than", "args" => 600}
              },
              "properties" => %{"is_visible" => false}
            }
          }
        })

      live = build(app).files["lib/shop_web/live/index_live.ex"]

      assert squash(live) =~
               squash("""
               defp visible_bvisgw(page_data_current_page_width) do
                 cond do
                   is_nil(page_data_current_page_width) -> true
               """)

      assert squash(live) =~
               squash("""
                   Shop.Bubble.Runtime.compare(:lt, page_data_current_page_width, 600) == true -> false
                   true -> true
                 end
               """)
    end
  end

  describe "an overlay's is visible (WTF-587)" do
    defp read_of(element, state) do
      %{
        "type" => "GetElement",
        "properties" => %{"element_id" => element},
        "next" => %{"type" => "Message", "name" => state}
      }
    end

    defp text(id, order, extra \\ %{}) do
      Map.merge(
        %{
          "id" => id,
          "type" => "Text",
          "properties" => %{
            "height" => 40,
            "width" => 300,
            "order" => order,
            "text" => %{"type" => "TextExpression", "entries" => %{"0" => id}}
          }
        },
        extra
      )
    end

    defp popup_app(type \\ "Popup") do
      app()
      |> put_in(["pages", "index", "elements", "bPop"], %{
        "id" => "bPop",
        "type" => type,
        "properties" => %{"height" => 200, "width" => 300, "order" => 60},
        "elements" => %{
          "bPopT" =>
            text("bPopT", 1, %{
              "states" => %{
                "0" => %{
                  "type" => "State",
                  "condition" => %{
                    "type" => "CurrentUser",
                    "next" => %{"type" => "Message", "name" => "logged_in"}
                  },
                  "properties" => %{"is_visible" => false}
                }
              }
            })
        }
      })
      |> put_in(
        ["pages", "index", "elements", "bVisOf", "states", "0", "condition"],
        read_of("bPop", "is_visible")
      )
      |> put_in(
        ["pages", "index", "elements", "bNotVisOf", "states", "0", "condition"],
        read_of("bPopT", "isnt_visible")
      )
    end

    test "of a Popup the page renders only while open is whether the page keeps it open", %{} do
      %{files: files} = build(popup_app())
      template = files["lib/shop_web/live/index_live.html.heex"]
      live = files["lib/shop_web/live/index_live.ex"]

      assert tag(template, "bPop") =~ "data-bubble-lazy"
      refute template =~ "TODO(bubble:bVisOf)"
      refute template =~ "TODO(bubble:bNotVisOf)"

      assert tag(template, "bVisOf") =~
               ~s|hidden={!visible_bvisof(Bubble.overlay_open?(@bubble_open, "", "bPop"))}|

      # Inside it: shown while it is open and its own conditionals show it.
      [helper] = Regex.run(~r/defp visible_bnotvisof\(.*?\n  end\n/s, live)
      assert helper =~ "current_user"
      assert tag(template, "bNotVisOf") =~ ~s|Bubble.overlay_open?(@bubble_open, "", "bPop")|

      # The open state is the page's alone: the static snapshot option
      # renders contents, it does not open the overlay.
      bubble = files["lib/shop_web/components/bubble.ex"]
      assert bubble =~ "def overlay_open?(open, scope, id) when is_map(open)"
    end

    test "of a Group Focus too", %{} do
      %{files: files} = build(popup_app("GroupFocus"))
      template = files["lib/shop_web/live/index_live.html.heex"]

      refute template =~ "TODO(bubble:bVisOf)"
      assert tag(template, "bVisOf") =~ ~s|Bubble.overlay_open?(@bubble_open, "", "bPop")|
    end

    test "of an overlay the page does not render only while open stays marked", %{} do
      # A step hides an element inside it: its contents are always rendered,
      # and only the browser knows whether it is open.
      app =
        popup_app()
        |> put_in(
          ["pages", "index", "workflows", "wHide", "actions", "0", "properties", "element_id"],
          "bPopT"
        )

      %{files: files} = build(app)
      template = files["lib/shop_web/live/index_live.html.heex"]

      refute tag(template, "bPop") =~ "data-bubble-lazy"

      assert template =~
               "TODO(bubble:bVisOf) visibility: 1 conditional not lowered (it reads a value " <>
                 "the page does not keep: element_state:is_visible)"

      refute tag(template, "bVisOf") =~ "overlay_open?"
      refute tag(template, "bNotVisOf") =~ "overlay_open?"
    end

    defp floating_app do
      app()
      |> put_in(["pages", "index", "elements", "bFloat"], %{
        "id" => "bFloat",
        "type" => "FloatingGroup",
        "properties" => %{
          "height" => 50,
          "width" => 300,
          "order" => 61,
          "is_visible" => false,
          "float_vertical" => "top"
        },
        "states" => %{
          "0" => %{
            "type" => "State",
            "condition" => %{
              "type" => "CurrentUser",
              "next" => %{"type" => "Message", "name" => "logged_in"}
            },
            "properties" => %{"is_visible" => true}
          }
        },
        "elements" => %{"bFloatT" => text("bFloatT", 1)}
      })
      |> put_in(
        ["pages", "index", "elements", "bVisOf", "states", "0", "condition"],
        read_of("bFloatT", "is_visible")
      )
    end

    test "a Floating Group no step shows or hides is decided by its conditionals", %{} do
      %{files: files} = build(floating_app())
      template = files["lib/shop_web/live/index_live.html.heex"]
      live = files["lib/shop_web/live/index_live.ex"]

      float = tag(template, "bFloat")
      assert float =~ ~s|data-overlay="floating_group"|
      assert float =~ "hidden={!visible_bfloat(@bubble_viewer)}"
      # One `hidden`: the conditionals', not the overlay's static one.
      assert length(Regex.scan(~r/\shidden[\s>=]/, float)) == 1
      refute template =~ "TODO(bubble:bFloat)"
      assert live =~ "defp visible_bfloat(current_user)"

      # Reading what is inside it folds its visibility.
      refute template =~ "TODO(bubble:bVisOf)"
      assert tag(template, "bVisOf") =~ "hidden={!visible_bvisof(@bubble_viewer)}"
    end

    test "a Floating Group a step shows keeps its workflow model; reads of it stay", %{} do
      app =
        floating_app()
        |> put_in(
          ["pages", "index", "workflows", "wShow", "actions", "0", "properties", "element_id"],
          "bFloat"
        )

      %{files: files} = build(app)
      template = files["lib/shop_web/live/index_live.html.heex"]

      assert tag(template, "bFloat") =~ ~r/\shidden[\s>]/
      refute template =~ "visible_bfloat"

      assert template =~
               "TODO(bubble:bFloat) visibility: 1 conditional not lowered (an overlay: " <>
                 "workflows show and hide it)"

      assert template =~
               "TODO(bubble:bVisOf) visibility: 1 conditional not lowered (it reads a value " <>
                 "the page does not keep: element_state:is_visible)"
    end

    test "isn't visible of a lazy Popup is that the page does not keep it open", %{} do
      app =
        put_in(
          popup_app(),
          ["pages", "index", "elements", "bNotVisOf", "states", "0", "condition"],
          read_of("bPop", "isnt_visible")
        )

      %{files: files} = build(app)
      template = files["lib/shop_web/live/index_live.html.heex"]

      # The page passes the open state; the helper negates it.
      assert tag(template, "bNotVisOf") =~
               ~s|visible_bnotvisof(Bubble.overlay_open?(@bubble_open, "", "bPop"))|

      [helper] =
        Regex.run(
          ~r/defp visible_bnotvisof\(.*?\n  end\n/s,
          files["lib/shop_web/live/index_live.ex"]
        )

      assert helper =~ ~r/!=\s+true|not /
    end

    test "in a reusable element, the open state is read in the instance's scope", %{} do
      app =
        app()
        |> update_in(["element_definitions", "card", "elements"], fn els ->
          Map.merge(els, %{
            "bCardPop" => %{
              "id" => "bCardPop",
              "type" => "Popup",
              "properties" => %{"height" => 200, "width" => 300, "order" => 20},
              "elements" => %{"bCardPopT" => text("bCardPopT", 1)}
            },
            "bCardOpen" => %{
              "id" => "bCardOpen",
              "type" => "Button",
              "properties" => %{
                "height" => 40,
                "width" => 300,
                "order" => 21,
                "text" => %{"type" => "TextExpression", "entries" => %{"0" => "Open"}}
              }
            },
            "bCardPopRead" =>
              text("bCardPopRead", 22, %{
                "states" => %{
                  "0" => %{
                    "type" => "State",
                    "condition" => read_of("bCardPop", "is_visible"),
                    "properties" => %{"is_visible" => false}
                  }
                }
              })
          })
        end)
        |> put_in(["element_definitions", "card", "workflows"], %{
          "wCardOpen" => %{
            "id" => "wCardOpen",
            "type" => "ButtonClicked",
            "properties" => %{"element_id" => "bCardOpen"},
            "actions" => %{
              "0" => %{
                "id" => "aCardOpen1",
                "type" => "ShowElement",
                "properties" => %{"element_id" => "bCardPop"}
              }
            }
          }
        })

      %{files: files} = build(app)

      {_path, template} =
        Enum.find(files, fn {path, body} ->
          String.ends_with?(path, ".heex") and body =~ ~s(data-bubble-id="bCardPopRead")
        end)

      # The popup's tag holds `<>` in its id: read its attributes as text.
      assert template =~ ~s|data-bubble-loaded={Bubble.open?(@bubble_open, @scope, "bCardPop")}|

      assert tag(template, "bCardPopRead") =~
               ~s|Bubble.overlay_open?(@bubble_open, @scope, "bCardPop")|
    end

    defp floater_app(stepped?) do
      definition = %{
        "id" => "bFloater",
        "type" => "CustomDefinition",
        "name" => "Floater",
        "properties" => %{"element_type" => "FloatingGroup", "height" => 50, "width" => 300},
        "elements" => %{
          "bFloaterT" => text("bFloaterT", 1),
          "bFloaterShow" => %{
            "id" => "bFloaterShow",
            "type" => "Button",
            "properties" => %{
              "height" => 40,
              "width" => 300,
              "order" => 2,
              "text" => %{"type" => "TextExpression", "entries" => %{"0" => "Show"}}
            }
          }
        }
      }

      definition =
        if stepped?,
          do:
            Map.put(definition, "workflows", %{
              "wFloaterShow" => %{
                "id" => "wFloaterShow",
                "type" => "ButtonClicked",
                "properties" => %{"element_id" => "bFloaterShow"},
                "actions" => %{
                  "0" => %{
                    "id" => "aFloaterShow1",
                    "type" => "ShowElement",
                    "properties" => %{"element_id" => "bFloater"}
                  }
                }
              }
            }),
          else: definition

      app()
      |> put_in(["element_definitions", "floater"], definition)
      |> put_in(["pages", "index", "elements", "bFloaterI"], %{
        "id" => "bFloaterI",
        "type" => "CustomElement",
        "properties" => %{
          "custom_id" => "bFloater",
          "height" => 50,
          "width" => 300,
          "order" => 62,
          "is_visible" => false
        },
        "states" => %{
          "0" => %{
            "type" => "State",
            "condition" => %{
              "type" => "CurrentUser",
              "next" => %{"type" => "Message", "name" => "logged_in"}
            },
            "properties" => %{"is_visible" => true}
          }
        }
      })
    end

    test "a Floating Group reusable's instance is decided unless its own steps show its root",
         %{} do
      template = build(floater_app(false)).files["lib/shop_web/live/index_live.html.heex"]
      assert tag(template, "bFloaterI") =~ "hidden={!visible_bfloateri(@bubble_viewer)}"
      refute template =~ "TODO(bubble:bFloaterI)"

      template = build(floater_app(true)).files["lib/shop_web/live/index_live.html.heex"]
      refute template =~ "visible_bfloateri"

      assert template =~
               "TODO(bubble:bFloaterI) visibility: 1 conditional not lowered (an overlay: " <>
                 "workflows show and hide it)"
    end

    test "a back-plane Floating Group is below its stacking context, off the pointer", %{
      files: files
    } do
      back = tag(files["lib/shop_web/live/index_live.html.heex"], "bOvBack")
      assert back =~ "pointer-events"
      assert back =~ "z-[-1]"
    end
  end
end
