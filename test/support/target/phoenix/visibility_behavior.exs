defmodule PhxCheckWeb.VisibilityBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Visibility conditionals (WTF-477, WTF-509): elements not visible on
  # page load that a conditional shows, lowered from
  # test/support/target/phoenix/visibility.json, run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/visibility_behavior_test.exs, with a database).
  use PhxCheckWeb.ConnCase, async: false

  # `live/2` waits for the first load (WTF-559, behavior_helpers.exs).
  use PhxCheckWeb.BubbleBehavior

  alias PhxCheckWeb.IndexLive.Workflows, as: IndexWorkflows

  @u1 "1700000000000x100000000000000001"
  @p1 "1700000000000x200000000000000001"
  @t1 "1700000000000x300000000000000001"
  @t2 "1700000000000x300000000000000002"

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)
    Ash.Seed.seed!(PhxCheck.Project, %{id: @p1, name: "Apollo"})
    Ash.Seed.seed!(PhxCheck.Task, %{id: @t1, title: "Alpha", project_id: @p1})
    Ash.Seed.seed!(PhxCheck.Task, %{id: @t2, title: "Bravo"})
    %{user: Ash.Seed.seed!(PhxCheck.User, %{id: @u1, email: "one@example.com", role: "admin"})}
  end

  # With privacy: :enforced the User's role is a field no one may view
  # (its privacy rules show only the email).
  defp enforced? do
    privacy = Module.concat(PhxCheck, Privacy)

    Code.ensure_loaded?(privacy) and function_exported?(privacy, :mode, 0) and
      apply(privacy, :mode, []) == :enforced
  end

  defp data_access_on,
    do: Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(
      Ash.Resource.put_metadata(user, :token, token)
    )
  end

  defp click(view, element),
    do: render_click(view, "bubble:click", %{"scope" => "", "element" => element})

  # Whether the element renders with the `hidden` attribute.
  defp hidden?(view, id, scope \\ nil) do
    selector =
      case scope do
        nil -> ~s([data-bubble-id="#{id}"])
        {:cell, thing} -> ~s(#bubble-cell--bTasks-t-#{thing} [data-bubble-id="#{id}"])
        {:cells, thing} -> ~s(#bubble-cell--bCellsTasks-t-#{thing} [data-bubble-id="#{id}"])
        scope -> ~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"])
      end

    html = view |> element(selector) |> render()
    [open] = Regex.run(~r/\A<[^>]*>/s, html)
    open =~ ~r/\shidden(\s|>|=)/
  end

  test "logged out: what a conditional shows when logged out, nothing else", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute hidden?(view, "bOut")
    assert hidden?(view, "bIn")
    # The last true conditional wins.
    refute hidden?(view, "bOrder")
    assert hidden?(view, "bCardT")
  end

  test "a URL parameter shows what reads it, on the page and in a reusable element",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bTabOpen")
    assert hidden?(view, "bCardTab", "bMember")

    {:ok, view, _html} = live(conn, "/?tab=open")
    refute hidden?(view, "bTabOpen")
    refute hidden?(view, "bCardTab", "bMember")
    # A reusable two levels down.
    refute hidden?(view, "bBadgeTab", "bMember-bCardBadge")

    # A text shows a parameter as its type (WTF-508); a list one stays
    # empty.
    {:ok, view, _html} = live(conn, "/?tab=open&n=7&tags=a")
    assert view |> element(~s([data-bubble-id="bTabText"])) |> render() =~ "Tab: open"
    assert view |> element(~s([data-bubble-id="bTabCount"])) |> render() =~ ~r/Count:\s*7/
    refute view |> element(~s([data-bubble-id="bTabMany"])) |> render() =~ ~r/Many:\s*a/

    # The URL changing on the same page (a patch) re-renders it.
    render_patch(view, "/?tab=closed")
    assert hidden?(view, "bTabOpen")
    assert hidden?(view, "bCardTab", "bMember")
    assert hidden?(view, "bBadgeTab", "bMember-bCardBadge")
    assert view |> element(~s([data-bubble-id="bTabText"])) |> render() =~ "Tab: closed"
  end

  # The viewport's width as the page's hook reports it (WTF-520).
  defp report_width(view, width) do
    render_hook(view, "bubble:page_width", %{"width" => width})
    Process.sleep(250)
  end

  test "a condition on the viewport's width follows it, on the page and in a reusable element",
       %{conn: conn} do
    {:ok, view, _html} =
      conn |> put_connect_params(%{"bubble_page_width" => 1024}) |> live("/?tab=open")

    refute hidden?(view, "bWidth")
    assert hidden?(view, "bNarrowTab")
    assert hidden?(view, "bBadgeNarrow", "bMember-bCardBadge")

    {:ok, view, _html} =
      conn |> put_connect_params(%{"bubble_page_width" => 500}) |> live("/?tab=open")

    assert hidden?(view, "bWidth")
    refute hidden?(view, "bNarrowTab")
    refute hidden?(view, "bBadgeNarrow", "bMember-bCardBadge")

    # With the other condition false, the width alone shows nothing.
    {:ok, view, _html} = conn |> put_connect_params(%{"bubble_page_width" => 500}) |> live("/")
    assert hidden?(view, "bNarrowTab")

    # A resize the hook reports re-renders what reads it.
    {:ok, view, html} =
      conn |> put_connect_params(%{"bubble_page_width" => 1024}) |> live("/?tab=open")

    assert html =~ "data-bubble-reads-width"
    report_width(view, 599)
    assert hidden?(view, "bWidth")
    refute hidden?(view, "bBadgeNarrow", "bMember-bCardBadge")
    report_width(view, 600)
    refute hidden?(view, "bWidth")
    assert hidden?(view, "bBadgeNarrow", "bMember-bCardBadge")

    # The static render has no width: as on page load.
    static = conn |> get("/?tab=open") |> html_response(200)
    [open] = Regex.run(~r/<p[^>]*data-bubble-id="bWidth"[^>]*>/s, static)
    refute open =~ ~r/\shidden(\s|>|=)/
  end

  test "a width compared to a breakpoint follows the app's breakpoint width", %{conn: conn} do
    # bBpTablet: hidden below the app's Tablet (992); bBpWideTab: shown
    # from the custom breakpoint (640) up, with the tab open.
    {:ok, view, _html} =
      conn |> put_connect_params(%{"bubble_page_width" => 1024}) |> live("/cells?tab=open")

    refute hidden?(view, "bBpTablet")
    refute hidden?(view, "bBpWideTab")

    report_width(view, 991)
    assert hidden?(view, "bBpTablet")
    refute hidden?(view, "bBpWideTab")

    report_width(view, 992)
    refute hidden?(view, "bBpTablet")

    report_width(view, 639)
    assert hidden?(view, "bBpTablet")
    assert hidden?(view, "bBpWideTab")

    report_width(view, 640)
    refute hidden?(view, "bBpWideTab")

    # The other condition false: the width alone shows nothing.
    {:ok, view, _html} =
      conn |> put_connect_params(%{"bubble_page_width" => 1024}) |> live("/cells")

    assert hidden?(view, "bBpWideTab")

    # A breakpoint the app does not define: as on page load, whatever the width.
    report_width(view, 100)
    refute hidden?(view, "bBpMissing")
  end

  defp disabled?(view, id) do
    html = view |> element(~s([data-bubble-id="#{id}"])) |> render()
    [open] = Regex.run(~r/\A<[^>]*>/s, html)
    open =~ ~r/\sdisabled(\s|>|=)/
  end

  test "with no width yet, a condition reading it keeps the page-load value, whatever its shape",
       %{conn: conn} do
    data_access_on()

    # No connect params: the page has no width until the hook reports.
    {:ok, view, _html} = live(conn, "/cells?tab=open")
    refute hidden?(view, "bWNot")
    assert hidden?(view, "bWEmpty")
    assert hidden?(view, "bWOr")
    assert hidden?(view, "bWNo")
    assert hidden?(view, "bCellNarrow", {:cells, @t1})
    refute disabled?(view, "bPanelWide")

    report_width(view, 1024)
    assert hidden?(view, "bWNot")
    assert hidden?(view, "bWEmpty")
    refute hidden?(view, "bWOr")
    refute hidden?(view, "bWNo")
    assert hidden?(view, "bCellNarrow", {:cells, @t1})
    refute disabled?(view, "bPanelWide")

    report_width(view, 500)
    refute hidden?(view, "bWOr")
    assert hidden?(view, "bWNo")
    refute hidden?(view, "bCellNarrow", {:cells, @t1})
    refute hidden?(view, "bCellNarrow", {:cells, @t2})
    assert disabled?(view, "bPanelWide")

    report_width(view, 600)
    refute hidden?(view, "bWNot")

    # The static render has none either.
    static = conn |> get("/cells?tab=open") |> html_response(200)
    [open] = Regex.run(~r/<p[^>]*data-bubble-id="bWNot"[^>]*>/s, static)
    refute open =~ ~r/\shidden(\s|>|=)/
  end

  test "a reusable element's \"isn't clickable\" conditionals read the width and the URL",
       %{conn: conn} do
    {:ok, view, _html} =
      conn |> put_connect_params(%{"bubble_page_width" => 500}) |> live("/cells")

    assert disabled?(view, "bPanelWide")
    refute disabled?(view, "bPanelTab")

    {:ok, view, _html} =
      conn |> put_connect_params(%{"bubble_page_width" => 1024}) |> live("/cells?tab=open")

    refute disabled?(view, "bPanelWide")
    assert disabled?(view, "bPanelTab")
  end

  test "logged in: the other group, and in a reusable element", %{conn: conn, user: user} do
    {:ok, view, _html} = live(sign_in(conn, user), "/")
    assert hidden?(view, "bOut")
    refute hidden?(view, "bIn")
    assert hidden?(view, "bOrder")
    refute hidden?(view, "bCardT")
  end

  # WTF-559: nothing in the browser shows bIn or bOut, nor reads inside
  # them: their contents render only while their conditionals show them,
  # in the static render too.
  test "a group hidden by its conditions renders its contents only while shown",
       %{conn: conn, user: user} do
    dead = conn |> get("/") |> html_response(200)
    refute dead =~ ~s(data-bubble-id="bInT")
    assert dead =~ ~s(data-bubble-id="bOutT")

    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bIn")
    refute has_element?(view, ~s([data-bubble-id="bInT"]))
    assert has_element?(view, ~s([data-bubble-id="bOutT"]))

    {:ok, view, _html} = live(sign_in(conn, user), "/")
    refute hidden?(view, "bIn")
    assert has_element?(view, ~s([data-bubble-id="bInT"]))
    assert hidden?(view, "bOut")
    refute has_element?(view, ~s([data-bubble-id="bOutT"]))
  end

  test "a conditional on a custom state follows the state", %{conn: conn} do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bFlagged")
    click(view, "bSetFlag")
    refute hidden?(view, "bFlagged")
    click(view, "bUnflag")
    assert hidden?(view, "bFlagged")
  end

  # Whether the element has a `hidden` or `invisible` class, which neither
  # its conditionals nor a step remove (the a361e4e regression).
  defp stuck?(view, id) do
    html = view |> element(~s([data-bubble-id="#{id}"])) |> render()
    [open] = Regex.run(~r/\A<[^>]*>/s, html)
    open =~ ~r/\sclass="[^"]*\b(hidden|invisible)\b/
  end

  test "hidden on page load and collapsing when hidden: shown by its conditional or a step",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/")
    refute hidden?(view, "bCollOut")
    refute stuck?(view, "bCollOut")
    assert has_element?(view, ~s([data-bubble-id="bCollOutT"]))

    {:ok, view, _html} = live(sign_in(conn, user), "/")
    assert hidden?(view, "bCollOut")

    # Shown by a step: the hook removes the attribute, and nothing else
    # keeps it hidden.
    assert hidden?(view, "bCollWf")
    refute stuck?(view, "bCollWf")
    assert view |> element(~s([data-bubble-id="bShowColl"])) |> render() =~ "bubble:show"
  end

  test "an element hidden on page load with no conditional is shown by a step", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bWf")
    # The step's JS command removes the attribute in the browser (a sticky
    # attribute: with no conditionals, kept until reload); the server
    # keeps rendering it as on page load.
    assert view |> element(~s([data-bubble-id="bShowWf"])) |> render() =~ "bubble:show"
  end

  # The visibility its conditionals give an element, which the page hook
  # compares across renders (WTF-509).
  defp condition(view, id) do
    html = view |> element(~s([data-bubble-id="#{id}"])) |> render()
    [open] = Regex.run(~r/\A<[^>]*>/s, html)

    case Regex.run(~r/\sdata-bubble-visible="([a-z]+)"/, open) do
      [_, value] -> value
      nil -> nil
    end
  end

  test "the condition-derived visibility follows the state (replay 2026-10-07)", %{conn: conn} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/")
    # T1 (bKeep) repeats its visibility on page load: nothing to compare.
    assert {condition(view, "bKeep"), condition(view, "bFlagged"), condition(view, "bFlagOff")} ==
             {nil, "false", "true"}

    refute hidden?(view, "bFlagOff")
    click(view, "bSetFlag")
    assert {condition(view, "bFlagged"), condition(view, "bFlagOff")} == {"true", "false"}
    assert hidden?(view, "bFlagOff")
    click(view, "bUnflag")
    assert {condition(view, "bFlagged"), condition(view, "bFlagOff")} == {"false", "true"}

    # Set the state, then hide: the step comes with the render that flips
    # the condition, and the hook applies it after that render.
    click(view, "bFlagHide")
    assert condition(view, "bFlagged") == "true"
    assert_push_event(view, "bubble:exec", %{ops: [%{op: "hide", to: to}]})
    assert to =~ "bFlagged"
  end

  test "a conditional that did not compile keeps the visibility on page load", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bBad")
    # bWidth compiles now (WTF-520); with no width yet it is as on page load.
    refute hidden?(view, "bWidth")
  end

  test "the current user is read afresh: a role change takes effect at the next event",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(sign_in(conn, user), "/")

    # A field the user may not view reads as empty, as in Bubble.
    assert hidden?(view, "bAdmin") == enforced?()

    Ash.Seed.update!(user, %{role: "guest"})
    click(view, "bUnflag")
    assert hidden?(view, "bAdmin")
  end

  test "a cell's condition reads its thing's relationship, loaded with the list",
       %{conn: conn} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bCellNoProject", {:cell, @t1})
    refute hidden?(view, "bCellNoProject", {:cell, @t2})
  end

  test "a group's condition reads its thing's relationship, loaded with the group",
       %{conn: conn} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/task/#{@t1}")
    refute hidden?(view, "bHasProject")
    {:ok, view, _html} = live(conn, "/task/#{@t2}")
    assert hidden?(view, "bHasProject")
  end

  test "a relationship a condition reads is never decided on unloaded" do
    task = Ash.get!(PhxCheck.Task, @t1, authorize?: false)
    assert %Ash.NotLoaded{} = task.project

    assert_raise ArgumentError,
                 ~r/project is read by a condition but not loaded/,
                 fn ->
                   PhxCheckWeb.Bubble.loaded!(task, [["project"]])
                 end

    loaded = Ash.load!(task, :project, authorize?: false)
    assert PhxCheckWeb.Bubble.loaded!(loaded, [["project"]]) == loaded
  end

  defp change(view, value, extra \\ %{}) do
    render_change(view, "bubble:change", %{
      "bubble" => Map.merge(%{"scope" => "", "element" => "bName", "value" => value}, extra)
    })
  end

  test "a condition reading an input re-renders as it is typed and committed", %{conn: conn} do
    # With page data and data access on, a change while typing is deferred
    # (WTF-475): the input's value still re-renders its conditions.
    data_access_on()
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bOpen")

    change(view, "open", %{"on" => "blur"})
    Process.sleep(200)
    refute hidden?(view, "bOpen")

    change(view, "closed", %{"on" => "blur"})
    Process.sleep(200)
    assert hidden?(view, "bOpen")

    render_blur(view, "bubble:commit", %{"element" => "bName", "value" => "open"})
    refute hidden?(view, "bOpen")
  end

  test "without data access, a change re-renders the input's conditions at once", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    change(view, "open", %{"on" => "blur"})
    refute hidden?(view, "bOpen")
    change(view, "x")
    assert hidden?(view, "bOpen")
  end

  defp text(view, id, scope),
    do: view |> element(~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"])) |> render()

  # Replay 2026-10-19: in a reusable element, Current page name is the host
  # page's Bubble name, whatever the path holds after it.
  test "a reusable element reads its host page's name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/cells")
    refute hidden?(view, "bHostIs", "bHostC")
    refute hidden?(view, "bHostInIs", "bHostC-bHostInI")
    assert text(view, "bHostName", "bHostC") =~ "Page: cells"

    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bHostIs", "bHostI")
    assert hidden?(view, "bHostInIs", "bHostI-bHostInI")
    assert text(view, "bHostName", "bHostI") =~ "Page: index"

    # The static render has it too: it is fixed per page.
    static = conn |> get("/cells") |> html_response(200)
    assert static =~ "Page: cells"

    # On a page itself Bubble refuses it: marked, as on page load.
    assert hidden?(view, "bPageName")
    refute view |> element(~s([data-bubble-id="bPageNameText"])) |> render() =~ "index"
  end

  # Replay 2026-10-19: computed when evaluated, never empty, no timer.
  test "Current date/time is never empty", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    refute hidden?(view, "bNow")
    assert hidden?(view, "bNowEmpty")
    refute html =~ "setInterval"
  end

  # Replay 2026-10-19: a repeating group's "is loading" is no.
  test "a repeating group's is loading is no", %{conn: conn} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/")
    refute hidden?(view, "bLoaded")
    assert hidden?(view, "bLoading")
  end

  test "a breakpoint shown as text is its width", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/cells")
    assert view |> element(~s([data-bubble-id="bBpText"])) |> render() =~ "Tablet: 992"
  end

  # WTF-582: conditionals that set a Text's content or a button's label.
  defp shown_text(view, id, scope \\ nil) do
    selector =
      case scope do
        nil -> ~s([data-bubble-id="#{id}"])
        {:cell, thing} -> ~s(#bubble-cell--bTasks-t-#{thing} [data-bubble-id="#{id}"])
      end

    view |> element(selector) |> render() |> String.replace(~r/<[^>]*>/, "") |> String.trim()
  end

  test "a conditional text follows the user and a custom state, the last true winning",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/")
    assert shown_text(view, "bGreet") == "Signed out"
    assert shown_text(view, "bFlagLabel") == "Flag off"
    assert view |> element(~s([data-bubble-id="bBold"] strong)) |> render() =~ "Out"

    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/")
    assert shown_text(view, "bGreet") == "Hello one@example.com"
    assert view |> element(~s([data-bubble-id="bBold"] strong)) |> render() =~ "one@example.com"

    click(view, "bSetFlag")
    assert shown_text(view, "bGreet") == "Flagged"
    assert shown_text(view, "bFlagLabel") == "Flag on"

    click(view, "bUnflag")
    assert shown_text(view, "bGreet") == "Hello one@example.com"
    assert shown_text(view, "bFlagLabel") == "Flag off"
  end

  test "a conditional text reads the current user afresh, as the privacy rules let it",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(sign_in(conn, user), "/")
    # A field the user may not view reads as empty, as in Bubble.
    assert shown_text(view, "bRoleText") == if(enforced?(), do: "Member", else: "Admin")

    Ash.Seed.update!(user, %{role: "guest"})
    click(view, "bUnflag")
    assert shown_text(view, "bRoleText") == "Member"
  end

  test "a conditional text in a cell reads its thing; one not lowered keeps its content",
       %{conn: conn} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/")
    assert shown_text(view, "bCellLabel", {:cell, @t1}) == "Task Alpha"
    assert shown_text(view, "bCellLabel", {:cell, @t2}) == "Task Bravo"
    assert shown_text(view, "bTextBad") == "Kept"
    assert shown_text(view, "bHoverText") == "Still"
  end

  test "a conditional text reading the page's data keeps its content until the data loads",
       %{conn: conn} do
    data_access_on()
    dead = conn |> get("/task/#{@t1}") |> html_response(200)
    assert dead =~ ~r/data-bubble-id="bProjectText"[^>]*>No project</

    {:ok, view, _html} = live(conn, "/task/#{@t1}")
    assert shown_text(view, "bProjectText") == "Project: Apollo"
    {:ok, view, _html} = live(conn, "/task/#{@t2}")
    assert shown_text(view, "bProjectText") == "No project"
  end

  # WTF-578: an element's "is visible" is its visibility as the page
  # computes it; inside a hidden group, not visible.
  test "a condition reading another element's visibility follows it", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bVisG")
    assert hidden?(view, "bVisOf")
    # Hidden while bVisG isn't visible.
    assert hidden?(view, "bNotVisOf")
    assert hidden?(view, "bVisChild")

    {:ok, view, _html} = live(sign_in(conn, user), "/")
    refute hidden?(view, "bVisG")
    refute hidden?(view, "bVisOf")
    refute hidden?(view, "bNotVisOf")
    refute hidden?(view, "bVisChild")
  end

  # WTF-587: a lazy Popup's "is visible" is whether the page keeps it
  # open; a Floating Group no step shows is decided by its conditionals.
  test "a condition reading a popup's visibility follows the page's open state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bOvPopRead")

    render_hook(view, "bubble:overlay", %{"scope" => "", "element" => "bOvPop", "open" => true})
    refute hidden?(view, "bOvPopRead")

    render_hook(view, "bubble:overlay", %{"scope" => "", "element" => "bOvPop", "open" => false})
    assert hidden?(view, "bOvPopRead")
  end

  # WTF-588: an element's "is visible" in a workflow's or a step's
  # condition, and a "Do when" condition, is its visibility as the page
  # computes it. bVisG shows for a signed-in user; bVisGT is inside it.
  test "a workflow's condition reading an element's visibility follows it",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/")
    # "Do when bVisG is visible" has not run.
    assert hidden?(view, "bVisMet")
    # "Only when bVisG is visible": not run.
    click(view, "bVisOnly")
    assert hidden?(view, "bVisSeen")
    # A step "only when bVisGT isn't visible": its group is hidden, so it is.
    click(view, "bVisStep")
    refute hidden?(view, "bVisSeen")

    {:ok, view, _html} = live(sign_in(conn, user), "/")
    refute hidden?(view, "bVisMet")
    click(view, "bVisStep")
    assert hidden?(view, "bVisSeen")
    click(view, "bVisOnly")
    refute hidden?(view, "bVisSeen")
  end

  test "a workflow reading the visibility of what a step shows is refused" do
    workflows = IndexWorkflows.__bubble__(:workflows)
    assert workflows["wVisTouched"].blocked != []
    assert workflows["wVisOnly"].blocked == []
  end

  test "a floating group's conditionals decide it and what reads it", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bOvFloat")
    assert hidden?(view, "bOvFloatRead")

    {:ok, view, _html} = live(sign_in(conn, user), "/")
    refute hidden?(view, "bOvFloat")
    refute hidden?(view, "bOvFloatRead")
  end
end
