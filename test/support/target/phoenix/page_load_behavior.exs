defmodule PhxCheckWeb.PageLoadBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # WTF-501: what a signed-in page load costs, lowered from
  # test/support/target/phoenix/page_load.json (all data invented), run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/page_load_behavior_test.exs, with a database), with privacy: :omit
  # and :enforced. Its board page has eight sources: three read the
  # current user's team (one its lead), three the same search of the
  # team's tasks (a list, the same list again, its first item) and one
  # its open ones, one the user's own tasks; the lists' cells read each
  # task's owner and team. A page load (the disconnected render, the
  # connected mount and its page-loaded event) reads the current user
  # once per mount, each relationship path of theirs once, and each query
  # once, and shows the same as before.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @north "1700000000000x100000000000000001"
  @south "1700000000000x100000000000000002"
  @ada "1700000000000x200000000000000001"
  @bo "1700000000000x200000000000000002"
  @cy "1700000000000x200000000000000003"

  # The most queries one signed-in load of /board may make, the
  # disconnected render and the connected mount together, sign-in token
  # checks included (WTF-501: 51 without privacy and 54 with privacy
  # enforced before the current user, their relationships and repeated
  # queries were read once per page load; 24 and 26 since).
  @budget 30

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)

    Ash.Seed.seed!(PhxCheck.Team, %{id: @north, name: "North", lead_id: @ada})
    Ash.Seed.seed!(PhxCheck.Team, %{id: @south, name: "South", lead_id: @cy})

    users =
      for {id, name, team} <- [{@ada, "Ada", @north}, {@bo, "Bo", @north}, {@cy, "Cy", @south}],
          into: %{} do
        user =
          Ash.Seed.seed!(PhxCheck.User, %{
            id: id,
            email: "#{String.downcase(name)}@example.com",
            name: name,
            team_id: team
          })

        {name, user}
      end

    for {n, title, owner, team, done} <- [
          {1, "Alpha", @ada, @north, false},
          {2, "Beta", @bo, @north, true},
          {3, "Gamma", @ada, @north, false},
          {4, "Delta", @cy, @south, false},
          {5, "Echo", @cy, @south, true}
        ],
        do:
          Ash.Seed.seed!(PhxCheck.Task, %{
            id: "1700000000000x30000000000000000#{n}",
            title: title,
            owner_id: owner,
            team_id: team,
            done: done
          })

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
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

  defp shown(html, prefix),
    do:
      ~r/#{prefix}: (\w+)/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

  # The queries `fun` makes, in any process (the LiveView's own included),
  # by table.
  defp queries(fun) do
    handler = "page-load-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, meta, _ -> send(parent, {:page_load_query, meta.source}) end,
        nil
      )

    try do
      result = fun.()
      {result, collect([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect(acc) do
    receive do
      {:page_load_query, source} -> collect([source | acc])
    after
      0 -> Enum.frequencies(acc)
    end
  end

  # The connected page once its data has loaded and its page-loaded event
  # has run (`render/1` waits for the LiveView to handle what it was sent).
  defp board(conn) do
    {:ok, view, _html} = live(conn, "/board")
    {view, render(view)}
  end

  test "a signed-in page load reads each query once and shows its data", %{
    conn: conn,
    users: users
  } do
    {{_view, html}, by_table} = queries(fn -> board(sign_in(conn, users["Ada"])) end)
    total = by_table |> Map.values() |> Enum.sum()
    IO.puts("page load: /board made #{total} queries #{inspect(by_table)}")

    assert shown(html, "Team") == ["North"]
    assert shown(html, "Lead") == ["Ada"]
    assert shown(html, "Again") == ["North"]
    assert shown(html, "Task") == ["Alpha", "Beta", "Gamma"]
    assert shown(html, "Owner") == ["Ada", "Bo", "Ada"]
    assert shown(html, "First") == ["Alpha"]
    assert shown(html, "Mine") == ["Alpha", "Gamma"]
    assert shown(html, "In") == ["North", "North"]
    assert shown(html, "Open") == ["Alpha"]

    assert shown(html, "Listed") == ["Alpha", "Beta", "Gamma"]

    assert total <= @budget,
           "/board made #{total} queries, more than #{@budget}: #{inspect(by_table)}"
  end

  test "each user's page load reads as that user, never what another's read", %{
    conn: conn,
    users: users
  } do
    {_view, ada} = board(sign_in(conn, users["Ada"]))
    {_view, cy} = board(sign_in(build_conn(), users["Cy"]))

    assert shown(ada, "Team") == ["North"]
    assert shown(cy, "Team") == ["South"]
    assert shown(cy, "Lead") == ["Cy"]
    assert shown(cy, "Task") == ["Delta", "Echo"]
    assert shown(cy, "Mine") == ["Delta", "Echo"]
    assert shown(cy, "Open") == ["Delta"]
  end

  test "a read pass serves a read once per actor, and forgets it when it ends" do
    alias PhxCheckWeb.BubbleData

    ran = :counters.new(1, [])

    read = fn actor ->
      BubbleData.once(:key, actor, fn ->
        :counters.add(ran, 1, 1)
        actor
      end)
    end

    BubbleData.read_pass(fn ->
      assert read.(:ada) == :ada
      assert read.(:ada) == :ada
      # Another actor never gets what the first one read.
      assert read.(:cy) == :cy
      assert read.(:ada) == :ada
    end)

    assert :counters.get(ran, 1) == 3

    # Outside a pass, every read is made.
    read.(:ada)
    read.(:ada)
    assert :counters.get(ran, 1) == 5
  end

  test "the next page load reads again: a changed record shows", %{conn: conn, users: users} do
    {view, html} = board(sign_in(conn, users["Ada"]))
    assert shown(html, "Team") == ["North"]

    PhxCheck.Team
    |> Ash.get!(@north, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{name: "Northwest"})
    |> Ash.update!(authorize?: false)

    # The change notification makes the page read again (coalesced).
    Process.sleep(100)
    html = render(view)
    assert shown(html, "Team") == ["Northwest"]
    assert shown(html, "Again") == ["Northwest"]
    assert shown(html, "In") == ["Northwest", "Northwest"]
  end
end
