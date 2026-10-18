defmodule PhxCheckWeb.VisibilityBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Visibility conditionals (WTF-477, WTF-509): elements not visible on
  # page load that a conditional shows, lowered from
  # test/support/target/phoenix/visibility.json, run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/visibility_behavior_test.exs, with a database).
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

  test "a conditional on a custom state follows the state", %{conn: conn} do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bFlagged")
    click(view, "bSetFlag")
    refute hidden?(view, "bFlagged")
    click(view, "bUnflag")
    assert hidden?(view, "bFlagged")
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
                 ~r/project is read by a visibility condition but not loaded/,
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
end
