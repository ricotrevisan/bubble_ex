defmodule PhxCheckWeb.CellSearchesBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # WTF-520: searches in a repeating group's cells, lowered from
  # test/support/target/phoenix/cell_searches.json (all data invented), run
  # by scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/cell_searches_behavior_test.exs, with a database), with privacy:
  # :omit and :enforced. The customers page lists every customer; each cell
  # shows the count of that customer's orders, its first and last order,
  # its open orders' count, how many of its first two there are, the open
  # orders its own list holds and the newest of them, a reusable card
  # counting its orders, and how many of the first two of its orders its
  # owner has (two keys: the customer and its owner; Dune has no owner,
  # which the strict search reads as nothing and the loose one drops), and
  # how many orders the first customer its owner owns has (a search of
  # orders keyed on another search's first record, read a round later).
  # Each of those searches is read for every cell together: one query per
  # round of cells, never one per cell.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @ada "1700000000000x100000000000000001"
  @bo "1700000000000x100000000000000002"

  # The searches the cells read (count, first, last, open, two, listed,
  # the card's count, and the newest open order of a cell's own list: its
  # records, then those sorted): one query of orders each, whatever the
  # number of cells.
  @order_queries 12

  # The customers' owners (Dune has none).
  @owners %{"Acme" => @ada, "Bolt" => @bo, "Core" => @ada, "Dune" => nil, "Echo" => @bo}

  setup do
    on_exit(fn ->
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleData)
    end)

    users =
      for {id, name} <- [{@ada, "Ada"}, {@bo, "Bo"}], into: %{} do
        user =
          Ash.Seed.seed!(PhxCheck.User, %{
            id: id,
            email: "#{String.downcase(name)}@example.com",
            name: name
          })

        {name, user}
      end

    orders =
      for {n, title, customer, open, owner} <- [
            {1, "Anvil", "Acme", true, @ada},
            {2, "Arrow", "Acme", false, @bo},
            {3, "Axe", "Acme", true, @ada},
            {4, "Bell", "Bolt", true, @bo},
            {5, "Drum", "Dune", false, @ada},
            {6, "Ear", "Echo", true, @ada},
            {7, "Elk", "Echo", true, @bo},
            {8, "Emu", "Echo", true, @ada}
          ],
          into: %{} do
        {title,
         %{
           id: "1700000000000x30000000000000000#{n}",
           customer: customer,
           open: open,
           owner: owner
         }}
      end

    # Each customer's own list of orders (not all of them: Echo's lacks Elk;
    # Bolt's holds Acme's Anvil too, which two cells' lists then share).
    lists = %{
      "Acme" => ~w(Axe Anvil Arrow),
      "Bolt" => ~w(Bell Anvil),
      "Core" => [],
      "Dune" => ~w(Drum),
      "Echo" => ~w(Emu Ear)
    }

    customers =
      for {{name, list}, n} <- Enum.with_index(Enum.sort(lists), 1), into: %{} do
        id = "1700000000000x20000000000000000#{n}"

        Ash.Seed.seed!(PhxCheck.Customer, %{
          id: id,
          name: name,
          owner_id: @owners[name],
          orders: Enum.map(list, &orders[&1].id)
        })

        {name, id}
      end

    for {title, o} <- orders do
      Ash.Seed.seed!(PhxCheck.Order, %{
        id: o.id,
        title: title,
        open: o.open,
        customer_id: customers[o.customer],
        owner_id: o.owner
      })
    end

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

  defp enforced?, do: Ash.Resource.Info.authorizers(PhxCheck.Order) != []

  # What each cell shows after `prefix`, in the cells' order (empty when
  # it shows nothing).
  defp shown(html, prefix),
    do:
      ~r/#{prefix}: (\w*)/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

  # The queries `fun` makes, in any process (the LiveView's own included),
  # by table.
  defp queries(fun) do
    handler = "cell-searches-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, meta, _ -> send(parent, {:cell_searches_query, meta.source}) end,
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
      {:cell_searches_query, source} -> collect([source | acc])
    after
      0 -> Enum.frequencies(acc)
    end
  end

  defp customers(conn) do
    {:ok, view, _html} = live(conn, "/customers")
    {view, render(view)}
  end

  test "each cell shows its customer's orders, one query per search for every cell", %{
    conn: conn,
    users: users
  } do
    {{_view, html}, by_table} = queries(fn -> customers(sign_in(conn, users["Ada"])) end)
    IO.puts("cell searches: /customers made #{inspect(by_table)}")

    assert shown(html, "Customer") == ~w(Acme Bolt Core Dune Echo)

    if enforced?() do
      # Ada finds only her own orders: Anvil, Axe, Drum, Ear and Emu.
      assert shown(html, "Count") == ~w(2 0 0 1 2)
      assert shown(html, "First") == ["Anvil", "", "", "Drum", "Ear"]
      assert shown(html, "Last") == ["Axe", "", "", "Drum", "Emu"]
      assert shown(html, "Open") == ~w(2 0 0 0 2)
      assert shown(html, "Two") == ~w(2 0 0 1 2)
      assert shown(html, "Listed") == ~w(2 1 0 0 2)
      assert shown(html, "Card") == ~w(2 0 0 1 2)
      assert shown(html, "Newest") == ["Axe", "Anvil", "", "", "Emu"]
      assert shown(html, "Pair") == ~w(2 0 0 0 0)
      assert shown(html, "Loose") == ~w(2 0 0 1 0)
      assert shown(html, "Chain") == ~w(2 0 2 0 0)
    else
      assert shown(html, "Count") == ~w(3 1 0 1 3)
      assert shown(html, "First") == ["Anvil", "Bell", "", "Drum", "Ear"]
      assert shown(html, "Last") == ["Axe", "Bell", "", "Drum", "Emu"]
      assert shown(html, "Open") == ~w(2 1 0 0 3)
      assert shown(html, "Two") == ~w(2 1 0 1 2)
      assert shown(html, "Listed") == ~w(2 2 0 0 2)
      assert shown(html, "Card") == ~w(3 1 0 1 3)
      assert shown(html, "Newest") == ["Axe", "Bell", "", "", "Emu"]
      assert shown(html, "Pair") == ~w(2 1 0 0 1)
      assert shown(html, "Loose") == ~w(2 1 0 1 1)
      assert shown(html, "Chain") == ~w(3 1 3 0 1)
    end

    # Five cells, twelve searches of orders each: one query per search, not
    # one per cell (60).
    orders = Map.get(by_table, "order", 0)

    assert orders > 0 and orders <= @order_queries,
           "/customers read orders #{orders} times, more than #{@order_queries}: #{inspect(by_table)}"
  end

  test "the queries do not grow with the cells", %{conn: conn, users: users} do
    {_, before} = queries(fn -> customers(sign_in(conn, users["Ada"])) end)

    for n <- 1..6 do
      Ash.Seed.seed!(PhxCheck.Customer, %{
        id: "1700000000000x40000000000000000#{n}",
        name: "Zed#{n}",
        orders: []
      })
    end

    {{_view, html}, now} = queries(fn -> customers(sign_in(build_conn(), users["Ada"])) end)

    assert length(shown(html, "Customer")) == 10
    assert Map.get(before, "order", 0) > 0
    assert Map.get(now, "order", 0) == Map.get(before, "order", 0)
  end

  test "a page size is per cell: a cell is not left short by another", %{
    conn: conn,
    users: users
  } do
    {_, before} = queries(fn -> customers(sign_in(conn, users["Ada"])) end)

    # Many orders of Acme sorted before every other customer's: the query
    # of all cells reaches its limit with Acme's alone, and the cells left
    # short are read again, together.
    for n <- 1..9 do
      Ash.Seed.seed!(PhxCheck.Order, %{
        id: "1700000000000x50000000000000000#{n}",
        title: "Aa#{n}",
        open: true,
        customer_id: "1700000000000x200000000000000001",
        owner_id: @ada
      })
    end

    {{_view, html}, now} = queries(fn -> customers(sign_in(build_conn(), users["Ada"])) end)

    if enforced?() do
      assert shown(html, "Two") == ~w(2 0 0 1 2)
      assert shown(html, "Pair") == ~w(2 0 0 0 0)
      assert shown(html, "Loose") == ~w(2 0 0 1 0)
    else
      assert shown(html, "Two") == ~w(2 1 0 1 2)
      assert shown(html, "Pair") == ~w(2 1 0 0 1)
      assert shown(html, "Loose") == ~w(2 1 0 1 1)
    end

    assert hd(shown(html, "First")) == "Aa1"
    assert hd(shown(html, "Count")) == if(enforced?(), do: "11", else: "12")

    # The cells left short are read again together: one more query for each
    # of the three searches with a page (Two, Pair, Loose), not one per cell.
    extra = Map.get(now, "order", 0) - Map.get(before, "order", 0)
    assert extra <= 3, "the short cells cost #{extra} more queries of orders"
  end

  test "two keys: no record of one cell's customer and another's owner is read", %{
    conn: conn,
    users: users
  } do
    # Acme's (owner Ada) orders that Bo owns, sorted first: neither Acme's
    # cell (Acme, Ada) nor Bolt's (Bolt, Bo) holds them. Nine fill the
    # first read's limit (the four keyed cells' two each, plus one): with
    # each key compared alone (not the cells' combinations), they filled
    # every round's, and the page never loaded.
    for n <- 1..9 do
      Ash.Seed.seed!(PhxCheck.Order, %{
        id: "1700000000000x60000000000000000#{n}",
        title: "Aaa#{n}",
        open: false,
        customer_id: "1700000000000x200000000000000001",
        owner_id: @bo
      })
    end

    {{_view, html}, by_table} = queries(fn -> customers(sign_in(conn, users["Ada"])) end)

    if enforced?() do
      assert shown(html, "Pair") == ~w(2 0 0 0 0)
    else
      assert shown(html, "Pair") == ~w(2 1 0 0 1)
      assert shown(html, "Count") == ~w(12 1 0 1 3)
    end

    # One more for Two: Aaa1-3 fill its first read, and the cells left
    # short are read again together.
    assert Map.get(by_table, "order", 0) <= @order_queries + 1
  end

  test "past :max_batched records, each cell's count is read on its own, once", %{
    conn: conn,
    users: users
  } do
    # Five cells' keys fit; their orders do not (three more of Echo's, Ada's,
    # so that Ada too finds more than five). The doubled limits are capped
    # too (Two needs 2 per cell, more than 5 in all).
    for n <- 1..3 do
      Ash.Seed.seed!(PhxCheck.Order, %{
        id: "1700000000000x70000000000000000#{n}",
        title: "Eel#{n}",
        open: true,
        customer_id: "1700000000000x200000000000000005",
        owner_id: @ada
      })
    end

    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, max_batched: 5)

    {by_table, log} =
      ExUnit.CaptureLog.with_log(fn ->
        {{_view, html}, by_table} = queries(fn -> customers(sign_in(conn, users["Ada"])) end)

        if enforced?() do
          assert shown(html, "Count") == ~w(2 0 0 1 5)
          assert shown(html, "Two") == ~w(2 0 0 1 2)
        else
          assert shown(html, "Count") == ~w(3 1 0 1 6)
          assert shown(html, "Two") == ~w(2 1 0 1 2)
        end

        by_table
      end)

    warnings = Regex.scan(~r/reached :max_batched/, log)
    # One warning per count search (Count, Open, Card, Chain), never per round.
    assert length(warnings) in 1..4

    # Each count search: one batch, then each cell's own count; nothing read
    # again in a later round.
    # (and Two, whose capped limit may leave its short cells to read alone)
    assert Map.get(by_table, "order", 0) <= @order_queries + 4 * 5 + 5
  end

  test "past :max_batched key combinations, the cells are read in chunks, once logged", %{
    conn: conn,
    users: users
  } do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, max_batched: 2)

    {html, log} =
      ExUnit.CaptureLog.with_log(fn ->
        {_view, html} = customers(sign_in(conn, users["Ada"]))
        html
      end)

    assert log =~
             "key combinations, past :max_batched (2); its cells are read in chunks of at most 2"

    if enforced?() do
      assert shown(html, "Count") == ~w(2 0 0 1 2)
      assert shown(html, "Pair") == ~w(2 0 0 0 0)
    else
      assert shown(html, "Count") == ~w(3 1 0 1 3)
      assert shown(html, "Pair") == ~w(2 1 0 0 1)
    end
  end

  test "past :max_cell_rounds, the next round is read together once (logged)", %{
    conn: conn,
    users: users
  } do
    # The orders of the first customer a cell's owner owns read that
    # customer first: two rounds. With one, the second is still read
    # together, once; a third would be read cell by cell.
    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, max_cell_rounds: 1)

    {html, log} =
      ExUnit.CaptureLog.with_log(fn ->
        {_view, html} = customers(sign_in(conn, users["Ada"]))
        html
      end)

    {{_view, _html}, by_table} =
      queries(fn -> customers(sign_in(build_conn(), users["Ada"])) end)

    assert log =~ "past 1 rounds (:max_cell_rounds): the next round is read together, once"
    # The chain's second search is one query, not one per cell.
    assert Map.get(by_table, "order", 0) <= @order_queries

    if enforced?(),
      do: assert(shown(html, "Chain") == ~w(2 0 2 0 0)),
      else: assert(shown(html, "Chain") == ~w(3 1 3 0 1))
  end

  test "each user's cells read as that user", %{conn: conn, users: users} do
    {_view, bo} = customers(sign_in(conn, users["Bo"]))

    if enforced?() do
      assert shown(bo, "Count") == ~w(1 1 0 0 1)
      assert shown(bo, "First") == ["Arrow", "Bell", "", "", "Elk"]
      assert shown(bo, "Listed") == ~w(0 1 0 0 0)
      assert shown(bo, "Pair") == ~w(0 1 0 0 1)
    else
      assert shown(bo, "Count") == ~w(3 1 0 1 3)
    end
  end

  test "with data access off, no cell reads anything", %{conn: conn, users: users} do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: false)
    {{_view, html}, by_table} = queries(fn -> customers(sign_in(conn, users["Ada"])) end)

    assert shown(html, "Customer") == []
    assert Map.get(by_table, "order", 0) == 0
  end
end
