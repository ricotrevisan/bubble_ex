defmodule PhxCheckWeb.TablesBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Bubble's Table element, lowered from
  # test/support/target/phoenix/tables.json, run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/tables_behavior_test.exs, with a database), with privacy: :omit
  # and :enforced.
  #
  # bTable lists the tasks (by rank) under a header row: one repeated row
  # per task, read as the user, as a repeating group's cells are. Its row
  # holds texts reading "Current row's thing", a group showing it, a
  # column hidden on page load and the reusable element Tag (bRowTag) in
  # the row's scope (`bTable~2<task id>-bRowTag`). bStatic has no data
  # source; bFixed shows a fixed number of rows; bUnloaded's list does not
  # load. With enforced policies a secret task is in no row.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @t1 "1700000000000x200000000000000001"
  @t2 "1700000000000x200000000000000002"
  @t3 "1700000000000x200000000000000003"

  setup do
    on_exit(fn ->
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleData)
    end)

    for {id, title, rank, secret} <- [
          {@t1, "Bake", 2, false},
          {@t2, "Answer", 1, false},
          {@t3, "Cut", 3, true}
        ],
        do: Ash.Seed.seed!(PhxCheck.Task, %{id: id, title: title, rank: rank, secret: secret})

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    :ok
  end

  defp enforced?, do: Ash.Resource.Info.authorizers(PhxCheck.Task) != []

  # Without what the user may not find (with policies: the secret task).
  defp found(titles), do: if(enforced?(), do: titles -- ["Cut"], else: titles)

  defp shown(html, prefix),
    do: ~r/#{prefix}: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

  defp row(task), do: "bTable~2#{task}-bRowTag"

  defp text(view, scope, id) do
    view
    |> element(~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"]))
    |> render()
    |> then(&Regex.replace(~r/<[^>]*>/, &1, ""))
    |> String.trim()
  end

  defp states(view), do: :sys.get_state(view.pid).socket.assigns.bubble_states

  # The opening tags of the elements with Bubble ID `id`.
  defp tags(html, id), do: Regex.scan(~r/<[a-z]+ [^>]*data-bubble-id="#{id}"[^>]*>/, html)

  test "a header row once, then a row per task the user finds, in the list's order",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert [_] = tags(html, "bHead")
    assert html =~ ~r/<thead>\s*<tr [^>]*data-bubble-id="bHead"/
    assert html =~ ~r/<th [^>]*data-bubble-id="bHeadTitle"[^>]*scope="col"/
    assert shown(html, "R") == found(["Answer", "Bake", "Cut"])
    # A group in the row whose data source is its parent: the row's thing.
    assert shown(html, "N") ==
             Enum.take(["1", "2", "3"], length(found(["Answer", "Bake", "Cut"])))

    # Each row keyed by its task, not its position.
    tasks = if enforced?(), do: [@t2, @t1], else: [@t2, @t1, @t3]
    assert length(tags(html, "bRow")) == length(tasks)

    for task <- tasks,
        do: assert(html =~ ~s(id="bubble-cell--bTable-t-#{task}"))
  end

  test "a column hidden on page load hides its cells; a header reads no row", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert [[col]] = tags(html, "bColNote")
    assert col =~ ~r/\shidden[\s>="\/]/

    cells = tags(html, "bCellNote") ++ tags(html, "bHeadNote")
    assert length(cells) == length(found(["Answer", "Bake", "Cut"])) + 1
    assert Enum.all?(cells, fn [tag] -> tag =~ ~r/\shidden[\s>="\/]/ end)
    # "Current row's thing" in the header is not lowered: it shows nothing.
    refute html =~ "X: "
  end

  test "a static table shows its rows; a list the page does not load shows none",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "K: Colour"
    assert html =~ "V: Blue"
    assert shown(html, "U") == []
  end

  test "a fixed number of rows is the table's page; every list stops at :max_items",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert shown(html, "F") == Enum.take(found(["Answer", "Bake", "Cut"]), 2)

    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, max_items: 1)
    {:ok, _view, html} = live(conn, "/")
    assert shown(html, "R") == ["Answer"]
    assert shown(html, "F") == ["Answer"]
  end

  # The database queries `fun` makes (the page's own, in the LiveView).
  defp queries(fun) do
    counter = :counters.new(1, [])
    id = "bubble-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:phx_check, :repo, :query],
      fn _event, _measurements, _meta, c -> :counters.add(c, 1, 1) end,
      counter
    )

    try do
      {:ok, view, _html} = fun.()
      _ = render(view)
      :counters.get(counter, 1)
    after
      :telemetry.detach(id)
    end
  end

  test "the rows are read together: more rows make no more queries", %{conn: conn} do
    fewer = queries(fn -> live(conn, "/") end)

    for n <- 4..9,
        do:
          Ash.Seed.seed!(PhxCheck.Task, %{
            id: "1700000000000x20000000000000000#{n}",
            title: "Extra#{n}",
            rank: 10 + n,
            secret: false
          })

    more = queries(fn -> live(conn, "/") end)
    {:ok, _view, html} = live(conn, "/")
    assert length(shown(html, "R")) == length(found(["Answer", "Bake", "Cut"])) + 6
    assert more == fewer
  end

  test "an instance in a row reads the row's thing in the row's scope; a scope of no row the page read runs nothing",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert text(view, row(@t1), "bTagLabel") == "Label: Row Bake"
    assert text(view, row(@t2), "bTagLabel") == "Label: Row Answer"
    refute enforced?() and has_element?(view, ~s([data-bubble-scope="#{row(@t3)}"]))

    render_click(view, "bubble:click", %{"scope" => row(@t1), "element" => "bTagPick"})
    assert text(view, row(@t1), "bTagPicked") == "Picked: Row Bake"
    assert text(view, row(@t2), "bTagPicked") == "Picked:"

    # Scopes of no row the page read: a task not in the list, the
    # template's, the instance's without a row (and with policies, the
    # task the user may not find).
    before = states(view)
    crafted = [row("1700000000000x200000000000000099"), "bRowTag", "bTable-bRowTag"]
    crafted = if enforced?(), do: [row(@t3) | crafted], else: crafted

    for scope <- crafted,
        do: render_click(view, "bubble:click", %{"scope" => scope, "element" => "bTagPick"})

    assert states(view) == before
    refute Enum.any?(Map.keys(states(view)), &(elem(&1, 0) in crafted))
  end
end
