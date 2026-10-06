defmodule PhxCheckWeb.ShapesBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # WTF-500: data shapes a generated page must never crash on, lowered from
  # test/support/target/phoenix/shapes.json (all data invented), run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/shapes_behavior_test.exs, with a database), with privacy: :omit
  # and :enforced. Each test reproduces a crash a private app's pages hit:
  #
  #   * an option-set list attribute stored as an object keyed by position
  #     (`length/1` and `label/1` raised on it)
  #   * a field the user may not view (`%Ash.ForbiddenField{}`) read as a
  #     list (`Enum` raised on it)
  #   * a field of a list of things (`get_in/2` raised on the list)
  #   * `:formatted as JSON-safe` of a yes/no compared with "true" (never
  #     equal: every admin was sent away)
  #   * two "Go to page" of one page load (LiveView raised on the second)
  #   * a same-page navigation (a URL parameter) and a page-leaving one on
  #     one trigger: the page-leaving one ("Log out", "Go to page") always
  #     wins, whichever runs first
  use PhxCheckWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias PhxCheck.Bubble.Runtime
  alias PhxCheck.Enums.{Kind, Status}

  @admin "1700000000000x100000000000000001"
  @other "1700000000000x100000000000000002"
  @m1 "1700000000000x200000000000000001"
  @m2 "1700000000000x200000000000000002"

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)

    Ash.Seed.seed!(PhxCheck.Membership, %{
      id: @m1,
      team: "North",
      member_id: @admin,
      features: ["feature_a", "feature_b"]
    })

    Ash.Seed.seed!(PhxCheck.Membership, %{id: @m2, team: "South", member_id: @other})

    admin =
      Ash.Seed.seed!(PhxCheck.User, %{
        id: @admin,
        email: "admin@example.com",
        name: "Bo",
        admin: true,
        membership_id: @m1
      })

    other =
      Ash.Seed.seed!(PhxCheck.User, %{
        id: @other,
        email: "other@example.com",
        name: "Ada",
        admin: false,
        membership_id: @m2
      })

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    %{admin: admin, other: other}
  end

  defp enforced?, do: Ash.Resource.Info.authorizers(PhxCheck.Membership) != []

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(
      Ash.Resource.put_metadata(user, :token, token)
    )
  end

  defp hidden?(view, id) do
    html = view |> element(~s([data-bubble-id="#{id}"])) |> render()
    [open] = Regex.run(~r/\A<[^>]*>/s, html)
    open =~ ~r/\shidden(\s|>|=)/
  end

  # The connected page's HTML once its page data has loaded.
  defp live_html(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render(view)
  end

  defp shown(html, prefix),
    do:
      ~r/#{prefix}: (\w+)/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

  defp click(view, element),
    do: render_click(view, "bubble:click", %{"scope" => "", "element" => element})

  test "an option-set list attribute stored by position is a list: counted and labelled",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    refute hidden?(view, "bKindCount")
    assert shown(html, "L") == ["Open", "Done", "Dropped"]
  end

  test "enum lookups never raise on a value that is not one of the set's" do
    assert Kind.attributes("bug").statuses == ["open", "done", "dropped"]
    assert Kind.attributes("chore").statuses == ["done"]
    assert Status.label("open") == "Open"

    for stray <- [nil, "gone", %{"0" => "open"}, ["open"]] do
      assert Kind.attributes(stray) == %{statuses: nil}
      assert Status.label(stray) == nil
    end
  end

  test "a field the user may not view reads as an empty list", %{conn: conn, admin: admin} do
    {html, log} = with_log(fn -> live_html(sign_in(conn, admin), "/features") end)
    assert html =~ if(enforced?(), do: "Features: 0", else: "Features: 2")
    refute log =~ "page data"
    assert Runtime.as_list(%Ash.ForbiddenField{field: :features, type: :attribute}) == []
  end

  test "a field of a list of things is each item's, as one list", %{conn: conn, admin: admin} do
    {html, log} = with_log(fn -> live_html(sign_in(conn, admin), "/members") end)
    assert shown(html, "M") == ["Ada", "Bo"]
    refute log =~ "page data"
  end

  test "JSON-safe is text: an admin stays on the console", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(sign_in(conn, admin), "/console")
    assert_patch(view, "/console?tab=overview")
    assert render(view) =~ "Console page"
  end

  test "JSON-safe is text: anyone else is sent home", %{conn: conn, other: other} do
    {:ok, view, _html} = live(sign_in(conn, other), "/console")
    assert_redirect(view, "/")
  end

  test "two navigations of one page load: the first wins, the page does not crash",
       %{conn: conn} do
    # Logged out, both of the page's page-load workflows go home.
    {:ok, view, _html} = live(conn, "/console")
    assert_redirect(view, "/")
  end

  # Bubble does not guarantee the order of workflows on one trigger: a
  # page-leaving navigation wins whichever runs first. The fixture's
  # workflows run the same-page one first where it matters (bPatchOut,
  # bPatchGo), which skipped the log out before the fix.
  test "patch, then log out: the user is logged out", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(sign_in(conn, admin), "/nav")
    click(view, "bPatchOut")
    assert_redirect(view, "/sign-out")
  end

  test "patch, then go to another page: the page changes", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(sign_in(conn, admin), "/nav")
    click(view, "bPatchGo")
    assert_redirect(view, "/")
  end

  test "log out, then patch: still logged out", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(sign_in(conn, admin), "/nav")
    click(view, "bOutPatch")
    assert_redirect(view, "/sign-out")
  end

  test "one workflow, log out, then a step that patches: still logged out",
       %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(sign_in(conn, admin), "/nav")
    click(view, "bStepsOut")
    assert_redirect(view, "/sign-out")
  end

  test "JSON-safe of a yes/no, a number or a date is its text" do
    assert Runtime.json_encode(true) == "true"
    assert Runtime.json_encode(false) == "false"
    assert Runtime.json_encode(3) == "3"
    assert Runtime.json_encode(1.5) == "1.5"
    assert Runtime.json_encode(~D[2026-01-02]) == "2026-01-02"
    assert Runtime.json_encode(~s(say "hi")) == ~S(say \"hi\")
    assert Runtime.json_encode(nil) == nil
  end
end
