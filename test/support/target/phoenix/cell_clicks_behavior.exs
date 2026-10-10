defmodule PhxCheckWeb.CellClicksBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # WTF-520: clicks and input changes of the page's own elements in
  # repeating group cells, lowered from
  # test/support/target/phoenix/cell_clicks.json (all data invented), run
  # by scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/cell_clicks_behavior_test.exs, with a database), with privacy:
  # :omit and :enforced. The products page lists products; a row's "Show"
  # button shows that row's product in a detail group outside the list
  # (master-detail), a row's quantity input writes that row's product, and
  # a row's "Refuse" button runs a workflow that is not lowered. The
  # categories page lists categories, each with its products (a nested
  # repeating group); a product row's "Pick" button shows the product and
  # its category. The statuses page lists a board's statuses (options, one
  # of them twice): a row's "Pick" button, or a change of its note input,
  # shows that row's status in a detail group outside the list. The
  # browser's event names the cell's scope; the page accepts it only for a
  # cell it read as the user, and binds the cell's thing (or option) from
  # what it read, never from the browser.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @ada "1700000000000x100000000000000001"
  @bo "1700000000000x100000000000000002"

  @fruit "1700000000000x200000000000000001"
  @nuts "1700000000000x200000000000000002"

  # name => {id, category, owner, qty}
  @products %{
    "Apple" => {"1700000000000x300000000000000001", @fruit, @ada, 1},
    "Pear" => {"1700000000000x300000000000000002", @fruit, @ada, 2},
    "Plum" => {"1700000000000x300000000000000003", @fruit, @bo, 3},
    "Almond" => {"1700000000000x300000000000000004", @nuts, @ada, 4}
  }

  @board "1700000000000x400000000000000001"

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)

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

    for {id, name} <- [{@fruit, "Fruit"}, {@nuts, "Nuts"}],
        do: Ash.Seed.seed!(PhxCheck.Category, %{id: id, name: name})

    for {name, {id, category, owner, qty}} <- @products do
      Ash.Seed.seed!(PhxCheck.Product, %{
        id: id,
        name: name,
        qty: qty,
        category_id: category,
        owner_id: owner
      })
    end

    Ash.Seed.seed!(PhxCheck.Board, %{id: @board, name: "Main", statuses: ~w(todo doing todo done)})

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

  defp enforced?, do: Ash.Resource.Info.authorizers(PhxCheck.Product) != []

  defp id(name), do: elem(@products[name], 0)

  # The scope of `name`'s cell in the products list, and in `category`'s
  # cell of the categories list (`Bubble.cell_scope/5`).
  defp row(name), do: "bProducts~2#{id(name)}"
  defp nested(category, name), do: "bCats~2#{category}-bCatProducts~2#{id(name)}"

  # The DOM ID of `name`'s row (`Bubble.cell_id/5`).
  defp row_id(name), do: "bubble-cell--bProducts-t-#{id(name)}"

  # The scope of the `n`th of `count` cells holding option `value` in the
  # statuses list (`Bubble.cell_scope/5`: the option, then, when it is
  # listed more than once, its occurrence and count), and its DOM ID
  # (`Bubble.cell_id/5`).
  defp status_row(value, n \\ 1, count \\ 1),
    do: "bStatuses~2~4#{value}" <> if(count > 1, do: "~5#{n}~6#{count}", else: "")

  defp status_id(value, n \\ 1, count \\ 1),
    do: "bubble-cell--bStatuses-o-#{value}" <> if(count > 1, do: "-#{n}-#{count}", else: "")

  # The seeded list's two "todo" cells.
  defp todo(n), do: status_row("todo", n, 2)
  defp todo_id(n), do: status_id("todo", n, 2)

  defp row_input(view, id, element) do
    view
    |> element(~s(##{id} input[data-bubble-id="#{element}"]))
    |> render()
    |> then(&Regex.run(~r/value="([^"]*)"/, &1, capture: :all_but_first))
    |> then(&(&1 && hd(&1)))
  end

  defp cell_text(view, id, element) do
    view
    |> element(~s(##{id} [data-bubble-id="#{element}"]))
    |> render()
    |> then(&Regex.replace(~r/<[^>]*>/, &1, ""))
    |> String.trim()
  end

  defp statuses(conn, user) do
    {:ok, view, _html} = live(sign_in(conn, user), "/statuses")
    view
  end

  # The board's statuses, changed through its action: the page reads its
  # data again on the change notification.
  defp set_statuses(values) do
    PhxCheck.Board
    |> Ash.get!(@board, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{statuses: values})
    |> Ash.update!(authorize?: false)
  end

  defp pick(view, scope),
    do: render_click(view, "bubble:click", %{"scope" => scope, "element" => "bPickStatus"})

  defp text(view, id) do
    view
    |> element(~s([data-bubble-id="#{id}"]))
    |> render()
    |> then(&Regex.replace(~r/<[^>]*>/, &1, ""))
    |> String.trim()
  end

  # What each row shows after `prefix`, in the page's order.
  defp shown(html, prefix),
    do:
      ~r/#{prefix}: (\w*)/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

  # Waits for the page's debounced read (and the input workflows queued
  # behind it, `BubbleData.defer/2`).
  defp settle(view) do
    Process.sleep(250)
    render(view)
  end

  defp destroy(name),
    do:
      PhxCheck.Product |> Ash.get!(id(name), authorize?: false) |> Ash.destroy!(authorize?: false)

  defp scoped_text(view, scope, id) do
    view
    |> element(~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"]))
    |> render()
    |> then(&Regex.replace(~r/<[^>]*>/, &1, ""))
    |> String.trim()
  end

  defp row_text(view, name, id) do
    view
    |> element(~s(##{row_id(name)} [data-bubble-id="#{id}"]))
    |> render()
    |> then(&Regex.replace(~r/<[^>]*>/, &1, ""))
    |> String.trim()
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp qty(name) do
    PhxCheck.Product
    |> Ash.get!(id(name), authorize?: false)
    |> Map.get(:qty)
    |> then(&if(is_struct(&1, Decimal), do: Decimal.to_integer(&1), else: &1))
  end

  defp products(conn, user) do
    {:ok, view, _html} = live(sign_in(conn, user), "/products")
    view
  end

  test "a row's click shows that row's product in the detail group; another row's switches it",
       %{conn: conn, users: users} do
    view = products(conn, users["Ada"])
    html = render(view)

    assert shown(html, "Row") ==
             if(enforced?(), do: ~w(Almond Apple Pear), else: ~w(Almond Apple Pear Plum))

    # Before the click the detail group shows nothing, as in Bubble.
    assert text(view, "bDetailName") == "Detail:"

    # The row's own button, as rendered: its click names the row's scope.
    view |> element("##{row_id("Pear")} [data-bubble-id=\"bShow\"]") |> render_click()
    assert text(view, "bDetailName") == "Detail: Pear"
    assert text(view, "bDetailQty") == "DetailQty: 2"

    view |> element("##{row_id("Apple")} [data-bubble-id=\"bShow\"]") |> render_click()
    assert text(view, "bDetailName") == "Detail: Apple"

    # The detail group keeps the thing's unique ID only, re-read as the user.
    assert assigns(view).bubble_displayed[{"", "bDetail"}] ==
             {PhxCheck.Product, false, id("Apple")}
  end

  test "an input in a row keeps its own value and its change writes that row's product", %{
    conn: conn,
    users: users
  } do
    view = products(conn, users["Ada"])

    # Typing (debounced) only keeps the value; leaving the field commits it.
    view
    |> form(~s([id="bubble-input-#{row("Pear")}-bQty"]))
    |> render_change(%{"bubble" => %{"value" => "7"}})

    assert qty("Pear") == 2

    view
    |> element("##{row_id("Pear")} input[data-bubble-id=\"bQty\"]")
    |> render_blur(%{"value" => "7"})

    # The page runs an input's workflows after its debounced read.
    settle(view)
    assert qty("Pear") == 7
    assert qty("Apple") == 1
    assert assigns(view).bubble_inputs[{row("Pear"), "bQty"}] == 7
    assert assigns(view).bubble_inputs[{row("Apple"), "bQty"}] == nil

    # The page reads its data again after the write: the row shows it.
    assert row_text(view, "Pear", "bRowQty") == "Qty: 7"
    assert row_text(view, "Apple", "bRowQty") == "Qty: 1"

    # A commit of the same value runs nothing again.
    render_click(view, "bubble:commit", %{
      "scope" => row("Pear"),
      "element" => "bQty",
      "value" => "7"
    })

    settle(view)
    assert qty("Pear") == 7

    # Apple's own input, through the change event (a checkbox-style commit).
    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => row("Apple"), "element" => "bQty", "value" => "5"}
    })

    settle(view)
    assert qty("Apple") == 5
    assert qty("Pear") == 7
  end

  test "a click in a nested cell runs with the inner cell's thing and the outer cell's group", %{
    conn: conn,
    users: users
  } do
    {:ok, view, _html} = live(sign_in(conn, users["Ada"]), "/categories")
    html = render(view)

    assert shown(html, "Category") == ~w(Fruit Nuts)

    assert shown(html, "Product") ==
             if(enforced?(), do: ~w(Apple Pear Almond), else: ~w(Apple Pear Plum Almond))

    assert text(view, "bNestDetailName") == "Picked:"

    render_click(view, "bubble:click", %{
      "scope" => nested(@fruit, "Pear"),
      "element" => "bNestPick"
    })

    assert text(view, "bNestDetailName") == "Picked: Pear"
    assert text(view, "bPickedCat") == "From: Fruit"

    render_click(view, "bubble:click", %{
      "scope" => nested(@nuts, "Almond"),
      "element" => "bNestPick"
    })

    assert text(view, "bNestDetailName") == "Picked: Almond"
    assert text(view, "bPickedCat") == "From: Nuts"

    # As rendered: the button carries its inner cell's scope.
    assert render(view) =~ nested(@fruit, "Apple")
  end

  test "scopes the page did not render, or not for that element, are ignored", %{
    conn: conn,
    users: users
  } do
    view = products(conn, users["Ada"])
    before = assigns(view)

    forged = [
      # Made up: a thing ID that is no product, the list itself, the page.
      "bProducts~21700000000000x399999999999999999",
      "bProducts",
      "",
      "bProducts~2",
      # Another list's cell, an instance-shaped scope.
      "bCats~2#{@fruit}",
      row("Apple") <> "-bShow",
      # A real product under a scope shape the page does not use.
      "bOther~2#{id("Apple")}"
    ]

    # With privacy rules, Bo's Plum has no cell for Ada: its scope is
    # forged too. Without, it is a cell like any other.
    forged = if enforced?(), do: [row("Plum") | forged], else: forged

    for scope <- forged,
        element <- ["bShow", "bQty", "bNestPick"] do
      render_click(view, "bubble:click", %{"scope" => scope, "element" => element})

      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => scope, "element" => element, "value" => "9"}
      })
    end

    # A real cell, but an element of another cell (or of no cell).
    render_click(view, "bubble:click", %{"scope" => row("Apple"), "element" => "bNestPick"})
    render_click(view, "bubble:click", %{"scope" => row("Apple"), "element" => "bDetail"})
    # The page's own scope for an element listed per cell only.
    render_click(view, "bubble:click", %{"scope" => "", "element" => "bShow"})

    settle(view)
    after_ = assigns(view)
    assert after_.bubble_displayed == before.bubble_displayed
    assert after_.bubble_inputs == before.bubble_inputs
    assert text(view, "bDetailName") == "Detail:"
    assert qty("Apple") == 1 and qty("Pear") == 2 and qty("Plum") == 3

    # Nothing from the browser became an atom or a key the page keeps.
    refute Enum.any?(Map.keys(after_.bubble_inputs), &(elem(&1, 0) in forged))
  end

  test "a nested scope under another outer cell is ignored", %{conn: conn, users: users} do
    {:ok, view, _html} = live(sign_in(conn, users["Ada"]), "/categories")
    before = assigns(view)

    for scope <- [
          # Pear is Fruit's, Almond is Nuts': swapped outer cells.
          nested(@nuts, "Pear"),
          nested(@fruit, "Almond"),
          # The outer cell alone, and an inner cell without its outer one.
          "bCats~2#{@fruit}",
          "bCatProducts~2#{id("Pear")}",
          "bCats~2#{@fruit}-bCatProducts~21700000000000x399999999999999999"
        ] do
      render_click(view, "bubble:click", %{"scope" => scope, "element" => "bNestPick"})
    end

    after_ = assigns(view)
    assert after_.bubble_displayed == before.bubble_displayed
    assert after_.bubble_states == before.bubble_states
    assert text(view, "bNestDetailName") == "Picked:"
  end

  test "a row's scope is ignored once the list is read again without its product", %{
    conn: conn,
    users: users
  } do
    view = products(conn, users["Ada"])
    assert Map.has_key?(assigns(view).bubble_page_cells, row("Pear"))

    # Pear leaves the list: deleted, and the page reads its data again on
    # the change notification.
    destroy("Pear")
    Process.sleep(150)
    html = render(view)
    refute "Pear" in shown(html, "Row")
    refute Map.has_key?(assigns(view).bubble_page_cells, row("Pear"))

    before = assigns(view)
    render_click(view, "bubble:click", %{"scope" => row("Pear"), "element" => "bShow"})

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => row("Pear"), "element" => "bQty", "value" => "9"}
    })

    settle(view)
    assert assigns(view).bubble_displayed == before.bubble_displayed
    assert assigns(view).bubble_inputs == before.bubble_inputs
    assert text(view, "bDetailName") == "Detail:"
    assert qty("Apple") == 1

    # Apple's row still works.
    render_click(view, "bubble:click", %{"scope" => row("Apple"), "element" => "bShow"})
    assert text(view, "bDetailName") == "Detail: Apple"
  end

  test "a click or an input commit whose cell leaves the list before it runs runs nothing", %{
    conn: conn,
    users: users
  } do
    view = products(conn, users["Ada"])
    render_click(view, "bubble:click", %{"scope" => row("Apple"), "element" => "bShow"})
    assert text(view, "bDetailName") == "Detail: Apple"

    # An input commit queued behind the debounced read, then Pear leaves.
    render_click(view, "bubble:commit", %{
      "scope" => row("Pear"),
      "element" => "bQty",
      "value" => "9"
    })

    destroy("Pear")
    settle(view)
    refute Map.has_key?(assigns(view).bubble_page_cells, row("Pear"))
    assert qty("Apple") == 1

    # A click accepted before the page reads the change notification: the
    # cell is looked up again after the read, and is gone.
    destroy("Almond")
    render_click(view, "bubble:click", %{"scope" => row("Almond"), "element" => "bShow"})
    assert text(view, "bDetailName") == "Detail: Apple"

    assert assigns(view).bubble_displayed[{"", "bDetail"}] ==
             {PhxCheck.Product, false, id("Apple")}
  end

  test "a paused workflow resumes in its cell; whose cell left the list, its rest is dropped", %{
    conn: conn,
    users: users
  } do
    view = products(conn, users["Ada"])

    render_click(view, "bubble:click", %{"scope" => row("Pear"), "element" => "bLater"})
    assert text(view, "bDetailName") == "Detail:"
    Process.sleep(450)
    assert text(view, "bDetailName") == "Detail: Pear"

    render_click(view, "bubble:click", %{"scope" => row("Apple"), "element" => "bShow"})
    assert text(view, "bDetailName") == "Detail: Apple"

    # Pear leaves the list during the pause.
    render_click(view, "bubble:click", %{"scope" => row("Pear"), "element" => "bLater"})
    destroy("Pear")
    Process.sleep(450)
    assert text(view, "bDetailName") == "Detail: Apple"

    # The resume arrives while the change notification is not read yet:
    # the page reads its data first, then drops the rest.
    frame = %{
      module: PhxCheckWeb.ProductsLive.Workflows,
      scope: "",
      workflow: "wLater",
      at: 2,
      args: %{},
      steps: %{},
      returns: nil,
      call: nil,
      cell: row("Almond")
    }

    destroy("Almond")

    send(
      view.pid,
      {:bubble, :resume, [frame], DateTime.utc_now(), %{jobs: 5, calls: 5, chain: 1}}
    )

    Process.sleep(100)
    assert text(view, "bDetailName") == "Detail: Apple"

    assert assigns(view).bubble_displayed[{"", "bDetail"}] ==
             {PhxCheck.Product, false, id("Apple")}
  end

  test "a reusable element's own list takes clicks per cell, on the page and in a cell", %{
    conn: conn,
    users: users
  } do
    view = products(conn, users["Ada"])
    picker = "bPicker"

    render_click(view, "bubble:click", %{
      "scope" => "#{picker}-bPickList~2#{id("Pear")}",
      "element" => "bPickBtn"
    })

    assert scoped_text(view, picker, "bPickedName") == "Chosen: Pear"

    # Another instance's cell scope, or the page's list's, is not the picker's.
    render_click(view, "bubble:click", %{"scope" => row("Apple"), "element" => "bPickBtn"})
    assert scoped_text(view, picker, "bPickedName") == "Chosen: Pear"

    {:ok, cats, _html} = live(sign_in(build_conn(), users["Ada"]), "/categories")
    fruit = "bCats~2#{@fruit}-bCatPicker"
    nuts = "bCats~2#{@nuts}-bCatPicker"

    render_click(cats, "bubble:click", %{
      "scope" => "#{fruit}-bPickList~2#{id("Apple")}",
      "element" => "bPickBtn"
    })

    assert scoped_text(cats, fruit, "bPickedName") == "Chosen: Apple"
    assert scoped_text(cats, nuts, "bPickedName") == "Chosen:"

    # A made-up instance scope around a real product.
    render_click(cats, "bubble:click", %{
      "scope" => "bCats~21700000000000x299999999999999999-bCatPicker-bPickList~2#{id("Pear")}",
      "element" => "bPickBtn"
    })

    assert scoped_text(cats, nuts, "bPickedName") == "Chosen:"
    assert scoped_text(cats, fruit, "bPickedName") == "Chosen: Apple"
  end

  test "each user's rows are the products that user may read", %{conn: conn, users: users} do
    view = products(conn, users["Bo"])
    html = render(view)

    if enforced?() do
      assert shown(html, "Row") == ~w(Plum)

      # Ada's Apple has no cell for Bo.
      render_click(view, "bubble:click", %{"scope" => row("Apple"), "element" => "bShow"})
      assert text(view, "bDetailName") == "Detail:"
    else
      assert shown(html, "Row") == ~w(Almond Apple Pear Plum)
    end

    render_click(view, "bubble:click", %{"scope" => row("Plum"), "element" => "bShow"})
    assert text(view, "bDetailName") == "Detail: Plum"
  end

  test "a row's workflow the runtime refuses shows the notice and changes nothing", %{
    conn: conn,
    users: users
  } do
    view = products(conn, users["Ada"])
    before = assigns(view)

    view |> element("##{row_id("Apple")} [data-bubble-id=\"bRefuse\"]") |> render_click()
    assert_push_event(view, "bubble:notice", %{text: "This action isn't available yet."})
    assert assigns(view).bubble_displayed == before.bubble_displayed
  end

  test "with data access off, the list has no cells and no row takes a click", %{
    conn: conn,
    users: users
  } do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: false)

    view = products(conn, users["Ada"])
    assert shown(render(view), "Row") == []
    assert assigns(view).bubble_page_cells == %{}

    render_click(view, "bubble:click", %{"scope" => row("Apple"), "element" => "bShow"})
    assert text(view, "bDetailName") == "Detail:"
    assert assigns(view).bubble_displayed == %{}
  end

  test "a row's click in a list of options shows that row's status in the detail group", %{
    conn: conn,
    users: users
  } do
    view = statuses(conn, users["Ada"])
    assert shown(render(view), "Status") == ~w(Todo Doing Todo Done)
    assert text(view, "bStatusDetailName") == "Picked:"

    # Each cell is keyed by its option and its occurrence, read as the
    # user: the option is what the page read, not what the browser sent.
    cells = assigns(view).bubble_page_cells

    assert Map.new(cells, fn {scope, cell} -> {scope, {cell.item, cell.index}} end) == %{
             todo(1) => {"todo", 1},
             status_row("doing") => {"doing", 2},
             todo(2) => {"todo", 3},
             status_row("done") => {"done", 4}
           }

    # The row's own button, as rendered.
    view |> element("##{status_id("doing")} [data-bubble-id=\"bPickStatus\"]") |> render_click()
    assert text(view, "bStatusDetailName") == "Picked: Doing"
    assert assigns(view).bubble_displayed[{"", "bStatusDetail"}] == {nil, false, "doing"}

    # The second Todo is a cell of its own.
    view
    |> element("##{todo_id(2)} [data-bubble-id=\"bPickStatus\"]")
    |> render_click()

    assert text(view, "bStatusDetailName") == "Picked: Todo"

    # A row's input keeps its value per cell; its change runs in that cell.
    view
    |> element("##{status_id("done")} input[data-bubble-id=\"bStatusNote\"]")
    |> render_blur(%{"value" => "ship it"})

    settle(view)
    assert text(view, "bStatusDetailName") == "Picked: Done"
    assert assigns(view).bubble_inputs[{status_row("done"), "bStatusNote"}] == "ship it"
    assert assigns(view).bubble_inputs[{todo(1), "bStatusNote"}] == nil
  end

  test "a list of options reordered between render and click binds the same option, or none", %{
    conn: conn,
    users: users
  } do
    view = statuses(conn, users["Ada"])
    html = render(view)
    # As rendered: Doing's button carries Doing's scope, at position 2.
    assert html =~ status_row("doing")

    # Reordered before the click is read: the page reads its data again,
    # then looks the scope up. Doing is now third: still Doing.
    set_statuses(~w(done todo doing todo))
    pick(view, status_row("doing"))
    assert text(view, "bStatusDetailName") == "Picked: Doing"
    assert shown(render(view), "Status") == ~w(Done Todo Doing Todo)

    # Each scope still names its own option, wherever it now is.
    for {scope, item} <- [
          {status_row("done"), "done"},
          {todo(1), "todo"},
          {status_row("doing"), "doing"},
          {todo(2), "todo"}
        ],
        do: assert(assigns(view).bubble_page_cells[scope].item == item)

    pick(view, todo(2))
    assert text(view, "bStatusDetailName") == "Picked: Todo"

    # Doing and a Todo leave the list: their scopes are refused, never
    # given to the option now at their position. The Todo left is listed
    # once now: both old Todo scopes are gone, it has a new one.
    pick(view, status_row("done"))
    assert text(view, "bStatusDetailName") == "Picked: Done"
    set_statuses(~w(todo blocked))

    for scope <- [status_row("doing"), todo(1), todo(2), status_row("done")] do
      pick(view, scope)

      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => scope, "element" => "bStatusNote", "value" => "x"}
      })
    end

    settle(view)
    assert text(view, "bStatusDetailName") == "Picked: Done"
    assert shown(render(view), "Status") == ~w(Todo Blocked)

    assert Map.keys(assigns(view).bubble_page_cells) |> Enum.sort() == [
             status_row("blocked"),
             status_row("todo")
           ]

    refute Enum.any?(Map.keys(assigns(view).bubble_inputs), &(elem(&1, 0) == status_row("doing")))

    # An option new to the list is reached by its own scope only.
    pick(view, status_row("blocked"))
    assert text(view, "bStatusDetailName") == "Picked: Blocked"
  end

  test "a forged option scope is ignored", %{conn: conn, users: users} do
    view = statuses(conn, users["Ada"])
    pick(view, status_row("doing"))
    assert text(view, "bStatusDetailName") == "Picked: Doing"
    before = assigns(view)

    forged = [
      # A real option the list does not hold, a made-up one, its label.
      status_row("blocked"),
      status_row("bogus"),
      "bStatuses~2~4Todo",
      # An occurrence the list does not have, a wrong count, the first one
      # without its count, and the form of an option listed once.
      status_row("todo", 3, 2),
      status_row("todo", 1, 3),
      "bStatuses~2~4todo~51",
      status_row("todo"),
      # The bare value, a position, the list itself.
      "bStatuses~2todo",
      "bStatuses~2~31",
      "bStatuses~2~4",
      "bStatuses",
      # An instance-shaped scope, another list's cell, the products list.
      todo(1) <> "-bPickStatus",
      "bOther~2~4todo",
      "bProducts~2~4todo"
    ]

    for scope <- forged, element <- ["bPickStatus", "bStatusNote"] do
      render_click(view, "bubble:click", %{"scope" => scope, "element" => element})

      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => scope, "element" => element, "value" => "9"}
      })

      render_click(view, "bubble:commit", %{
        "scope" => scope,
        "element" => element,
        "value" => "9"
      })
    end

    # A real cell, but an element of no cell of it.
    render_click(view, "bubble:click", %{"scope" => todo(1), "element" => "bShow"})

    settle(view)
    after_ = assigns(view)
    assert after_.bubble_displayed == before.bubble_displayed
    assert after_.bubble_inputs == before.bubble_inputs
    assert after_.bubble_page_cells == before.bubble_page_cells
    assert text(view, "bStatusDetailName") == "Picked: Doing"
    refute Enum.any?(Map.keys(after_.bubble_inputs), &(elem(&1, 0) in forged))
  end

  test "a removed duplicate option carries nothing over to the one left; its stale change is refused",
       %{conn: conn, users: users} do
    view = statuses(conn, users["Ada"])

    # The user types in both Todo rows (each change runs the row's
    # workflow), and marks the second one.
    for {n, typed} <- [{1, "FIRST"}, {2, "SECOND"}] do
      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => todo(n), "element" => "bStatusNote", "value" => typed}
      })
    end

    view |> element("##{todo_id(2)} [data-bubble-id=\"bMark\"]") |> render_click()
    assert assigns(view).bubble_inputs[{todo(1), "bStatusNote"}] == "FIRST"
    assert assigns(view).bubble_inputs[{todo(2), "bStatusNote"}] == "SECOND"
    assert row_input(view, todo_id(1), "bStatusNote") == "FIRST"
    assert cell_text(view, todo_id(2), "bStatusMarkName") == "Marked: Todo"
    assert cell_text(view, todo_id(1), "bStatusMarkName") == "Marked:"

    # The first Todo is removed.
    set_statuses(~w(doing todo done))
    Process.sleep(150)
    assert shown(render(view), "Status") == ~w(Doing Todo Done)

    # The Todo left is a new cell: neither FIRST nor SECOND, not marked.
    inputs = assigns(view).bubble_inputs
    assert inputs[{status_row("todo"), "bStatusNote"}] == nil
    refute Map.has_key?(inputs, {todo(1), "bStatusNote"})
    refute Map.has_key?(inputs, {todo(2), "bStatusNote"})
    assert row_input(view, status_id("todo"), "bStatusNote") in [nil, ""]
    assert cell_text(view, status_id("todo"), "bStatusMarkName") == "Marked:"

    refute Enum.any?(Map.keys(assigns(view).bubble_displayed), fn
             {_, _, {:cell_scope, key}} -> key in [todo(1), todo(2)]
             _ -> false
           end)

    # A stale change (or click) of the removed first row, or of the old
    # second one, is refused: it lands nowhere.
    pick(view, status_row("doing"))
    assert text(view, "bStatusDetailName") == "Picked: Doing"
    before = assigns(view)

    for n <- [1, 2] do
      render_click(view, "bubble:commit", %{
        "scope" => todo(n),
        "element" => "bStatusNote",
        "value" => "STALE"
      })

      pick(view, todo(n))
    end

    settle(view)
    assert assigns(view).bubble_inputs == before.bubble_inputs
    assert assigns(view).bubble_displayed == before.bubble_displayed
    assert text(view, "bStatusDetailName") == "Picked: Doing"
    assert row_input(view, status_id("todo"), "bStatusNote") in [nil, ""]

    # The row left takes its own events.
    view
    |> element("##{status_id("todo")} input[data-bubble-id=\"bStatusNote\"]")
    |> render_blur(%{"value" => "fresh"})

    settle(view)
    assert text(view, "bStatusDetailName") == "Picked: Todo"
    assert assigns(view).bubble_inputs[{status_row("todo"), "bStatusNote"}] == "fresh"
  end

  test "Display data in a group of a row is kept per row: two equal options keep their own", %{
    conn: conn,
    users: users
  } do
    view = statuses(conn, users["Ada"])

    view |> element("##{todo_id(1)} [data-bubble-id=\"bMark\"]") |> render_click()
    assert cell_text(view, todo_id(1), "bStatusMarkName") == "Marked: Todo"
    assert cell_text(view, todo_id(2), "bStatusMarkName") == "Marked:"
    assert cell_text(view, status_id("doing"), "bStatusMarkName") == "Marked:"

    assert assigns(view).bubble_displayed[{"", "bStatusMark", {:cell_scope, todo(1)}}] ==
             {nil, false, "todo"}

    # A reorder keeps it with its row.
    set_statuses(~w(done todo doing todo))
    Process.sleep(150)
    render(view)
    assert cell_text(view, todo_id(1), "bStatusMarkName") == "Marked: Todo"
    assert cell_text(view, todo_id(2), "bStatusMarkName") == "Marked:"
  end

  test "a reusable instance in a row of options has the row's scope and keeps its own state", %{
    conn: conn,
    users: users
  } do
    view = statuses(conn, users["Ada"])
    chip = fn row -> row <> "-bStatusChip" end

    assert scoped_text(view, chip.(status_row("doing")), "bChipName") == "Chip: Doing"
    assert scoped_text(view, chip.(todo(1)), "bChipName") == "Chip: Todo"
    assert scoped_text(view, chip.(todo(2)), "bChipName") == "Chip: Todo"

    # The chip's own click, in the second Todo's chip only.
    render_click(view, "bubble:click", %{"scope" => chip.(todo(2)), "element" => "bChipBtn"})
    assert scoped_text(view, chip.(todo(2)), "bChipPicked") == "ChipPicked: yes"
    assert scoped_text(view, chip.(todo(1)), "bChipPicked") == "ChipPicked:"

    # Made-up chip scopes are ignored.
    before = assigns(view).bubble_states

    for scope <- [
          chip.(status_row("blocked")),
          chip.(status_row("todo")),
          chip.("bStatuses~2~31")
        ],
        do: render_click(view, "bubble:click", %{"scope" => scope, "element" => "bChipBtn"})

    assert assigns(view).bubble_states == before

    # Reordered: the state stays with its chip.
    set_statuses(~w(done todo doing todo))
    Process.sleep(150)
    render(view)
    assert scoped_text(view, chip.(todo(2)), "bChipPicked") == "ChipPicked: yes"
    assert scoped_text(view, chip.(todo(1)), "bChipPicked") == "ChipPicked:"

    # A Todo removed: the chip left starts over, nothing carried over.
    set_statuses(~w(done doing todo))
    Process.sleep(150)
    render(view)
    assert scoped_text(view, chip.(status_row("todo")), "bChipPicked") == "ChipPicked:"
    refute Enum.any?(Map.keys(assigns(view).bubble_states), &(elem(&1, 0) == chip.(todo(2))))
  end
end
