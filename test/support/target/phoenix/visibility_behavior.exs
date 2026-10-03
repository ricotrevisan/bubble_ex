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

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)
    %{user: Ash.Seed.seed!(PhxCheck.User, %{id: @u1, email: "one@example.com"})}
  end

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
      if scope,
        do: ~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"]),
        else: ~s([data-bubble-id="#{id}"])

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
end
