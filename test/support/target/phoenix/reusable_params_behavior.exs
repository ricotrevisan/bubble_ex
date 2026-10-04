defmodule PhxCheckWeb.ReusableParamsBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Reusable element properties (WTF-493), lowered from
  # test/support/target/phoenix/reusable_params.json, run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/reusable_params_behavior_test.exs, with a database), with
  # privacy: :omit and :enforced.
  #
  # The page `task` renders two instances of the reusable element Card:
  # bCardA sets every property but Note (static text, yes/no and number
  # values, the page's thing, a search, the thing's date), bCardB only
  # static ones; Card shows them in texts, conditions, a group's data
  # source, a nested reusable's property and a workflow.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @u1 "1700000000000x100000000000000001"
  @p1 "1700000000000x200000000000000001"
  @t1 "1700000000000x300000000000000001"
  @t2 "1700000000000x300000000000000002"

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)
    user = Ash.Seed.seed!(PhxCheck.User, %{id: @u1, email: "one@example.com"})
    Ash.Seed.seed!(PhxCheck.Project, %{id: @p1, name: "Apollo"})

    Ash.Seed.seed!(PhxCheck.Task, %{
      id: @t1,
      title: "Alpha",
      owner_id: @u1,
      project_id: @p1,
      due: ~U[2026-10-01 12:00:00.000000Z]
    })

    Ash.Seed.seed!(PhxCheck.Task, %{id: @t2, title: "Bravo"})
    %{user: user}
  end

  # With privacy: :enforced a task is visible (and findable) only to its
  # owner; everyone else sees nothing of it.
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

  defp text(view, scope, id) do
    view
    |> element(~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"]))
    |> render()
    |> then(&Regex.replace(~r/<[^>]*>/, &1, ""))
    |> String.trim()
  end

  defp hidden?(view, scope, id) do
    html =
      view |> element(~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"])) |> render()

    [open] = Regex.run(~r/\A<[^>]*>/s, html)
    open =~ ~r/\shidden(\s|>|=)/
  end

  test "an instance's values: static, expressions, defaults, a nested reusable's",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")

    assert text(view, "bCardA", "bTitle") == "Title: Hello A"
    # Not set: its default.
    assert text(view, "bCardA", "bNote") == "Note: Default note"
    assert text(view, "bCardA", "bHeading") == "Heading: Custom heading"
    assert text(view, "bCardA", "bCount") == "Count: 3"
    # A thing, read where the instance is (the page's thing).
    assert text(view, "bCardA", "bTaskT") == "Task: Alpha"
    # A list of things: a search, with the actor's policies.
    assert text(view, "bCardA", "bTasksN") == "Tasks: #{if enforced?(), do: 1, else: 2}"
    refute hidden?(view, "bCardA", "bFlagT")
    # A date, in a condition.
    refute hidden?(view, "bCardA", "bDueSet")
    # A group whose data source is the property.
    assert text(view, "bCardA", "bGroupT") == "Group: Alpha"
    # A nested reusable's property, set from this one's.
    assert text(view, "bCardA-bBadge", "bBadgeT") == "Badge: Alpha"

    assert text(view, "bCardB", "bTitle") == "Title: Hello B"
    assert text(view, "bCardB", "bNote") == "Note: Given B"
    # A default reading another property.
    assert text(view, "bCardB", "bHeading") == "Heading: Re: Hello B"
    assert text(view, "bCardB", "bCount") == "Count: 7"
    # Not set, no default: empty.
    assert text(view, "bCardB", "bTaskT") == "Task:"
    assert hidden?(view, "bCardB", "bFlagT")
    assert hidden?(view, "bCardB", "bDueSet")
    assert text(view, "bCardB-bBadge", "bBadgeT") == "Badge:"

    # Read from outside the instance.
    assert view |> element(~s([data-bubble-id="bOutside"])) |> render() =~ "Outside: Hello A"
  end

  test "properties nest: a reusable two levels down takes its default; IDs are per reusable",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")

    assert text(view, "bCardA-bBadge-bChip", "bChipT") == "Chip: Chip default"
    assert text(view, "bCardB-bBadge-bChip", "bChipT") == "Chip: Chip default"
    # Badge's own Task (text) is not Card's Task (a thing) of the same ID.
    assert text(view, "bCardA-bBadge", "bBadgeTask") == "Badge task: Badge task"
    # A relationship read through Card's Task.
    assert text(view, "bCardA", "bProject") == "Project: Apollo"
  end

  test "typing into an input a property reads re-reads what reads the property",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    assert text(view, "bCardA", "bQueryT") == "Query:"
    # An empty constraint value matches nothing (WTF-478).
    assert text(view, "bCardA", "bFoundT") == "Found:"

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "Alp", "on" => "blur"}
    })

    Process.sleep(250)
    assert text(view, "bCardA", "bQueryT") == "Query: Alp"
    assert text(view, "bCardA", "bFoundT") == "Found: Alpha"
    # bCardB sets no Query: unchanged.
    assert text(view, "bCardB", "bQueryT") == "Query:"
    assert text(view, "bCardB", "bTitle") == "Title: Hello B"
  end

  test "a workflow inside the reusable reads its instance's value", %{conn: conn} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/task/#{@t1}")

    render_click(view, "bubble:click", %{"scope" => "bCardA", "element" => "bBump"})
    assert text(view, "bCardA", "bN") == "N: 4"
    assert text(view, "bCardB", "bN") == "N:"

    render_click(view, "bubble:click", %{"scope" => "bCardB", "element" => "bBump"})
    assert text(view, "bCardB", "bN") == "N: 8"
  end

  test "Display data sets an instance's own thing, not its properties",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    assert text(view, "bCardB", "bOwn") == "Own:"

    render_click(view, "bubble:click", %{"scope" => "", "element" => "bShowB"})

    assert text(view, "bCardB", "bOwn") == "Own: Alpha"
    # Its properties stay the values the page computed for it.
    assert text(view, "bCardB", "bTitle") == "Title: Hello B"
    assert text(view, "bCardB", "bTaskT") == "Task:"
    assert text(view, "bCardB", "bGroupT") == "Group:"
    assert text(view, "bCardA", "bOwn") == "Own:"
  end

  test "a thing property is read with the actor's policies", %{conn: conn} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/task/#{@t1}")

    if enforced?() do
      assert text(view, "bCardA", "bTaskT") == "Task:"
      assert text(view, "bCardA", "bTasksN") == "Tasks: 0"
      assert text(view, "bCardA", "bGroupT") == "Group:"
      assert text(view, "bCardA-bBadge", "bBadgeT") == "Badge:"
      assert hidden?(view, "bCardA", "bDueSet")
    else
      assert text(view, "bCardA", "bTaskT") == "Task: Alpha"
      assert text(view, "bCardA", "bTasksN") == "Tasks: 2"
      assert text(view, "bCardA", "bGroupT") == "Group: Alpha"
      refute hidden?(view, "bCardA", "bDueSet")
    end

    # Static values do not depend on the user.
    assert text(view, "bCardA", "bTitle") == "Title: Hello A"
  end

  test "without data access, no property is loaded", %{conn: conn, user: user} do
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t2}")
    assert text(view, "bCardA", "bTitle") == "Title:"
    assert text(view, "bCardB", "bNote") == "Note:"
  end
end
