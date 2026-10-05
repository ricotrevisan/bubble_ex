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
  #     equal: every coach was sent away)
  #   * two "Go to page" of one page load (LiveView raised on the second)
  use PhxCheckWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias PhxCheck.Bubble.Runtime
  alias PhxCheck.Enums.{Kind, Status}

  @coach "1700000000000x100000000000000001"
  @other "1700000000000x100000000000000002"
  @r1 "1700000000000x200000000000000001"
  @r2 "1700000000000x200000000000000002"

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)

    Ash.Seed.seed!(PhxCheck.Role, %{
      id: @r1,
      name: "Lead",
      account_id: @coach,
      integrations: ["linear", "slack"]
    })

    Ash.Seed.seed!(PhxCheck.Role, %{id: @r2, name: "Member", account_id: @other})

    coach =
      Ash.Seed.seed!(PhxCheck.User, %{
        id: @coach,
        email: "coach@example.com",
        name: "Bo",
        coach: true,
        current_role_id: @r1
      })

    other =
      Ash.Seed.seed!(PhxCheck.User, %{
        id: @other,
        email: "other@example.com",
        name: "Ada",
        coach: false,
        current_role_id: @r2
      })

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    %{coach: coach, other: other}
  end

  defp enforced?, do: Ash.Resource.Info.authorizers(PhxCheck.Role) != []

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

  test "an option-set list attribute stored by position is a list: counted and labelled",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    refute hidden?(view, "bKindCount")
    assert shown(html, "L") == ["Active", "Resolved", "Cancelled"]
  end

  test "enum lookups never raise on a value that is not one of the set's" do
    assert Kind.attributes("action").statuses == ["active", "resolved", "cancelled"]
    assert Kind.attributes("goal").statuses == ["resolved"]
    assert Status.label("active") == "Active"

    for stray <- [nil, "gone", %{"0" => "active"}, ["active"]] do
      assert Kind.attributes(stray) == %{statuses: nil}
      assert Status.label(stray) == nil
    end
  end

  test "a field the user may not view reads as an empty list", %{conn: conn, coach: coach} do
    {html, log} = with_log(fn -> live_html(sign_in(conn, coach), "/tools") end)
    assert html =~ if(enforced?(), do: "Tools: 0", else: "Tools: 2")
    refute log =~ "page data"
    assert Runtime.as_list(%Ash.ForbiddenField{field: :integrations, type: :attribute}) == []
  end

  test "a field of a list of things is each item's, as one list", %{conn: conn, coach: coach} do
    {html, log} = with_log(fn -> live_html(sign_in(conn, coach), "/accounts") end)
    assert shown(html, "A") == ["Ada", "Bo"]
    refute log =~ "page data"
  end

  test "JSON-safe is text: a coach stays on the coach page", %{conn: conn, coach: coach} do
    {:ok, view, _html} = live(sign_in(conn, coach), "/coach")
    assert_patch(view, "/coach?v=actions")
    assert render(view) =~ "Coach page"
  end

  test "JSON-safe is text: anyone else is sent home", %{conn: conn, other: other} do
    {:ok, view, _html} = live(sign_in(conn, other), "/coach")
    assert_redirect(view, "/")
  end

  test "two navigations of one page load: the first wins, the page does not crash",
       %{conn: conn} do
    # Logged out, both of the page's page-load workflows go home.
    {:ok, view, _html} = live(conn, "/coach")
    assert_redirect(view, "/")
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
