defmodule PhxCheckWeb.VisibilityBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Visibility conditionals (WTF-477): elements not visible on page load
  # that a conditional shows, lowered from
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
    # The step's JS command removes the attribute in the browser (sticky
    # across renders); the server keeps rendering it as on page load.
    assert view |> element(~s([data-bubble-id="bShowWf"])) |> render() =~ "bubble:show"
  end

  test "a conditional that did not compile keeps the visibility on page load", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert hidden?(view, "bBad")
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
