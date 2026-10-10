defmodule PhxCheckWeb.ButtonsBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # WTF-520: buttons, lowered from test/support/target/phoenix/buttons.json
  # (all data invented), run by scripts/phoenix_compile_check.sh in the
  # generated project (copied to test/buttons_behavior_test.exs, with a
  # database), with privacy: :omit and :enforced. Each note's edit button
  # "isn't clickable" unless the current user owns the note: it renders
  # disabled and the server refuses its click. A star swaps its icon when
  # logged in (not lowered: marked), a send button's workflow is refused,
  # a button with no text is named after its icon (marked) and one is never clickable.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @ada "1700000000000x100000000000000001"
  @bo "1700000000000x100000000000000002"

  setup do
    on_exit(fn ->
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      Application.delete_env(:phx_check, :bubble_dev_markers)
    end)

    users =
      for {id, name} <- [{@ada, "ada"}, {@bo, "bo"}], into: %{} do
        {name, Ash.Seed.seed!(PhxCheck.User, %{id: id, email: "#{name}@example.com"})}
      end

    for {n, title, owner} <- [{1, "Alpha", @ada}, {2, "Beta", @bo}] do
      Ash.Seed.seed!(PhxCheck.Note, %{
        id: "1700000000000x20000000000000000#{n}",
        title: title,
        owner_id: owner
      })
    end

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    Application.put_env(:phx_check, :bubble_dev_markers, false)
    %{users: users}
  end

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(
      Ash.Resource.put_metadata(user, :token, token)
    )
  end

  # The element's opening tag.
  defp tag(view, id) do
    html = view |> element(~s([data-bubble-id="#{id}"])) |> render()
    [open] = Regex.run(~r/\A<[^>]*>/s, html)
    open
  end

  defp disabled?(view, id), do: tag(view, id) =~ ~r/\sdisabled(\s|>|=)/

  defp click(view, id),
    do: render_click(view, "bubble:click", %{"scope" => "", "element" => id})

  defp label(view), do: view |> element(~s([data-bubble-id="bLabel"])) |> render()

  test "the owner's button is enabled and runs; the other is disabled and refused", %{
    conn: conn,
    users: users
  } do
    {:ok, view, _html} = live(sign_in(conn, users["ada"]), "/")

    refute disabled?(view, "bLockA")
    assert disabled?(view, "bLockB")

    # A click sent anyway (the browser sends none for a disabled button):
    # the server refuses it, nothing runs.
    click(view, "bLockB")
    assert label(view) =~ "Label: start"

    click(view, "bLockA")
    assert label(view) =~ "Label: alpha"
  end

  test "the other user: the other way round", %{conn: conn, users: users} do
    {:ok, view, _html} = live(sign_in(conn, users["bo"]), "/")

    assert disabled?(view, "bLockA")
    refute disabled?(view, "bLockB")

    click(view, "bLockA")
    assert label(view) =~ "Label: start"
    click(view, "bLockB")
    assert label(view) =~ "Label: beta"
  end

  test "a button that is never clickable is disabled and its click refused", %{
    conn: conn,
    users: users
  } do
    {:ok, view, _html} = live(sign_in(conn, users["ada"]), "/")
    assert disabled?(view, "bFixed")
    click(view, "bFixed")
    assert label(view) =~ "Label: start"
  end

  test "a state that cannot make it not clickable changes nothing: enabled, it runs", %{
    conn: conn,
    users: users
  } do
    {:ok, view, _html} = live(sign_in(conn, users["ada"]), "/")
    refute disabled?(view, "bNever")
    click(view, "bNever")
    assert label(view) =~ "Label: never"
  end

  test "an icon button keeps its click; a refused workflow stays refused", %{
    conn: conn,
    users: users
  } do
    {:ok, view, _html} = live(sign_in(conn, users["ada"]), "/")
    assert tag(view, "bBroken") =~ "phx-click="
    refute disabled?(view, "bBroken")

    click(view, "bBroken")
    assert_push_event(view, "bubble:notice", %{text: "This action isn't available yet."})
    assert label(view) =~ "Label: start"
  end

  test "icon buttons are named by their text; production shows no marker", %{
    conn: conn,
    users: users
  } do
    {:ok, view, _html} = live(sign_in(conn, users["ada"]), "/")

    assert tag(view, "bLockA") =~ ~s(aria-label="Edit Alpha")
    assert tag(view, "bStar") =~ ~s(aria-label="Favorite")
    # No text: named after its icon, never left without a name.
    assert tag(view, "bNoName") =~ ~s(aria-label="more vert")

    for id <- ~w(bLockA bStar bBroken bNoName) do
      refute tag(view, id) =~ "title=", id
      refute tag(view, id) =~ "data-bubble-dev-marker", id
    end
  end

  test "with the developer markers on, what is left out says so", %{conn: conn, users: users} do
    Application.put_env(:phx_check, :bubble_dev_markers, true)
    {:ok, view, _html} = live(sign_in(conn, users["ada"]), "/")

    # The star's icon swap is not lowered: it keeps its icon on page load.
    assert tag(view, "bStar") =~ "data-bubble-dev-marker"
    assert tag(view, "bStar") =~ "Conditional icon not lowered"
    assert tag(view, "bNoName") =~ "named after its icon"
  end
end
