defmodule PhxCheckWeb.NestedListsBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # WTF-520: repeating groups in a repeating group's cell, lowered from
  # test/support/target/phoenix/nested_lists.json (all data invented), run
  # by scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/nested_lists_behavior_test.exs, with a database), with privacy:
  # :omit and :enforced. The customers page lists every customer; each
  # cell lists that customer's orders (an inner list fed by a search keyed
  # on the outer cell's group), and each order shows its item count, its
  # position, its customer's name and owner (read from the outer cell's
  # group), and a reusable card whose click picks its order. Each cell
  # also counts its orders (the inner list read from the outer cell) and
  # lists the customer's own list of orders (an inner list fed by the
  # outer cell's list field). Every source is read for every cell of
  # every outer cell together: the queries do not grow with the cells.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @ada "1700000000000x100000000000000001"
  @bo "1700000000000x100000000000000002"

  @acme "1700000000000x200000000000000001"
  @bolt "1700000000000x200000000000000002"
  @core "1700000000000x200000000000000003"

  @orders %{
    "Anvil" => {"1700000000000x300000000000000001", @acme, @ada, 3},
    "Arrow" => {"1700000000000x300000000000000002", @acme, @bo, 1},
    "Axe" => {"1700000000000x300000000000000003", @acme, @ada, 0},
    "Bell" => {"1700000000000x300000000000000004", @bolt, @bo, 2},
    "Bike" => {"1700000000000x300000000000000005", @bolt, @ada, 1}
  }

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

    id = fn title -> elem(@orders[title], 0) end

    # Each customer's own list of orders (not all of them: Acme's lacks
    # Anvil; Bolt's holds Acme's Anvil).
    for {customer, name, owner, list} <- [
          {@acme, "Acme", @ada, ~w(Axe Arrow)},
          {@bolt, "Bolt", @bo, ~w(Bell Anvil)},
          {@core, "Core", @ada, []}
        ] do
      Ash.Seed.seed!(PhxCheck.Customer, %{
        id: customer,
        name: name,
        owner_id: owner,
        orders: Enum.map(list, id)
      })
    end

    for {title, {oid, customer, owner, items}} <- @orders do
      Ash.Seed.seed!(PhxCheck.Order, %{
        id: oid,
        title: title,
        customer_id: customer,
        owner_id: owner
      })

      seed_items(oid, title, items)
    end

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    %{users: users}
  end

  defp seed_items(order, prefix, n) do
    for i <- 1..n//1 do
      Ash.Seed.seed!(PhxCheck.Item, %{
        id: "1700000000000x9#{order |> String.split("x") |> List.last()}#{i}",
        name: "#{prefix}#{i}",
        order_id: order
      })
    end
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

  # What each cell shows after `prefix`, in the page's order.
  defp shown(html, prefix),
    do:
      ~r/#{prefix}: (\w*)/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

  # The scope of the order card in `order`'s cell of `customer`'s cell.
  defp card(customer, order),
    do: "bCustomers~2#{customer}-bOrders~2#{elem(@orders[order], 0)}-bOrderCard"

  defp text(view, scope, id) do
    view
    |> element(~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"]))
    |> render()
    |> then(&Regex.replace(~r/<[^>]*>/, &1, ""))
    |> String.trim()
  end

  defp states(view), do: :sys.get_state(view.pid).socket.assigns.bubble_states

  # The queries `fun` makes, in any process (the LiveView's own included),
  # by table.
  defp queries(fun) do
    handler = "nested-lists-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, meta, _ -> send(parent, {:nested_lists_query, meta.source}) end,
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
      {:nested_lists_query, source} -> collect([source | acc])
    after
      0 -> Enum.frequencies(acc)
    end
  end

  defp customers(conn) do
    {:ok, view, _html} = live(conn, "/customers")
    {view, render(view)}
  end

  test "each outer cell lists its own inner cells, each with its own values", %{
    conn: conn,
    users: users
  } do
    {{_view, html}, by_table} = queries(fn -> customers(sign_in(conn, users["Ada"])) end)
    IO.puts("nested lists: /customers made #{inspect(by_table)}")

    assert shown(html, "Customer") == ~w(Acme Bolt Core)

    if enforced?() do
      # Ada finds only her own orders: Anvil, Axe and Bike.
      assert shown(html, "Order") == ~w(Anvil Axe Bike)
      assert shown(html, "Items") == ~w(3 0 1)
      assert shown(html, "At") == ~w(1 2 1)
      assert shown(html, "Of") == ~w(Acme Acme Bolt)
      assert shown(html, "Owner") == ~w(Ada Ada Bo)
      assert shown(html, "Card") == ~w(Anvil Axe Bike)
      assert shown(html, "Orders") == ~w(2 1 0)
      # A customer's own list, read as the user: Arrow and Bell are Bo's.
      assert shown(html, "Listed") == ~w(Axe Anvil)
    else
      assert shown(html, "Order") == ~w(Anvil Arrow Axe Bell Bike)
      assert shown(html, "Items") == ~w(3 1 0 2 1)
      assert shown(html, "At") == ~w(1 2 3 1 2)
      assert shown(html, "Of") == ~w(Acme Acme Acme Bolt Bolt)
      assert shown(html, "Owner") == ~w(Ada Ada Ada Bo Bo)
      assert shown(html, "Card") == ~w(Anvil Arrow Axe Bell Bike)
      assert shown(html, "Orders") == ~w(3 2 0)
      assert shown(html, "Listed") == ~w(Axe Arrow Bell Anvil)
    end

    # One query of orders for every outer cell's inner list (and one for
    # the customers' own lists), one of items for every inner cell, the
    # customers and their group's things read again by ID once: never one
    # per cell.
    assert Map.get(by_table, "order", 0) in 1..2, inspect(by_table)
    assert Map.get(by_table, "item", 0) == 1, inspect(by_table)
    assert Map.get(by_table, "customer", 0) in 1..2, inspect(by_table)
  end

  test "the queries do not grow with the outer or the inner cells", %{conn: conn, users: users} do
    {_, before} = queries(fn -> customers(sign_in(conn, users["Ada"])) end)

    # Four more customers, each with three orders of Ada's with two items
    # each, and one more order of Acme's.
    for n <- 1..4 do
      customer = "1700000000000x40000000000000000#{n}"
      Ash.Seed.seed!(PhxCheck.Customer, %{id: customer, name: "Zed#{n}", orders: []})

      for m <- 1..3 do
        order = "1700000000000x5000000000000000#{n}#{m}"

        Ash.Seed.seed!(PhxCheck.Order, %{
          id: order,
          title: "Z#{m}",
          customer_id: customer,
          owner_id: @ada
        })

        seed_items(order, "Z#{n}#{m}x", 2)
      end
    end

    Ash.Seed.seed!(PhxCheck.Order, %{
      id: "1700000000000x600000000000000001",
      title: "Awl",
      customer_id: @acme,
      owner_id: @ada
    })

    {{_view, html}, now} = queries(fn -> customers(sign_in(build_conn(), users["Ada"])) end)

    assert length(shown(html, "Customer")) == 7
    assert length(shown(html, "Order")) == if(enforced?(), do: 4 + 12, else: 6 + 12)
    assert Enum.count(shown(html, "Items"), &(&1 == "2")) >= 12

    for table <- ~w(customer order item),
        do: assert(Map.get(now, table, 0) == Map.get(before, table, 0), inspect({before, now}))
  end

  test "a click in an inner cell's instance runs with that inner cell's thing; other scopes are ignored",
       %{conn: conn, users: users} do
    {:ok, view, _html} = live(sign_in(conn, users["Ada"]), "/customers")

    assert text(view, card(@acme, "Anvil"), "bCardTitle") == "Card: Anvil"
    render_click(view, "bubble:click", %{"scope" => card(@acme, "Anvil"), "element" => "bPick"})
    assert text(view, card(@acme, "Anvil"), "bPicked") == "Picked: Anvil"
    assert text(view, card(@acme, "Axe"), "bPicked") == "Picked:"

    render_click(view, "bubble:click", %{"scope" => card(@bolt, "Bike"), "element" => "bPick"})
    assert text(view, card(@bolt, "Bike"), "bPicked") == "Picked: Bike"
    assert text(view, card(@acme, "Anvil"), "bPicked") == "Picked: Anvil"

    # Scopes the page did not render: an order under another customer's
    # cell, a made-up order, the outer cell's own, the template's (and with
    # policies, an order the user may not read).
    before = states(view)

    crafted = [
      card(@bolt, "Anvil"),
      "bCustomers~2#{@acme}-bOrders~21700000000000x399999999999999999-bOrderCard",
      "bCustomers~2#{@acme}-bOrderCard",
      "bOrderCard",
      "bCustomers-bOrders-bOrderCard"
    ]

    crafted = if enforced?(), do: [card(@acme, "Arrow") | crafted], else: crafted

    for scope <- crafted,
        do: render_click(view, "bubble:click", %{"scope" => scope, "element" => "bPick"})

    assert states(view) == before
    refute Enum.any?(Map.keys(states(view)), &(elem(&1, 0) in crafted))
  end

  test "each user's inner cells are read as that user", %{conn: conn, users: users} do
    {_view, html} = customers(sign_in(conn, users["Bo"]))

    if enforced?() do
      assert shown(html, "Order") == ~w(Arrow Bell)
      assert shown(html, "Items") == ~w(1 2)
      assert shown(html, "Listed") == ~w(Arrow Bell)
    else
      assert shown(html, "Order") == ~w(Anvil Arrow Axe Bell Bike)
    end
  end

  test "with data access off, no cell reads anything and no inner scope takes a click", %{
    conn: conn,
    users: users
  } do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: false)

    {{view, html}, by_table} = queries(fn -> customers(sign_in(conn, users["Ada"])) end)

    assert shown(html, "Customer") == []
    assert shown(html, "Order") == []
    assert Map.get(by_table, "order", 0) == 0
    assert Map.get(by_table, "item", 0) == 0

    before = states(view)
    render_click(view, "bubble:click", %{"scope" => card(@acme, "Anvil"), "element" => "bPick"})
    assert states(view) == before
  end
end
