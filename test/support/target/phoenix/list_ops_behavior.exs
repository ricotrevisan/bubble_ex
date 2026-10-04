defmodule PhxCheckWeb.ListOpsBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Behavior of the list operators of page data sources (WTF-495), lowered
  # from test/support/target/phoenix/list_ops.json, run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/list_ops_behavior_test.exs, with a database), with privacy: :omit
  # and :enforced. With enforced policies a secret task is neither found
  # nor viewed: it is in no list.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhxCheck.Bubble.Runtime

  @p1 "1700000000000x100000000000000001"
  @t1 "1700000000000x200000000000000001"
  @t2 "1700000000000x200000000000000002"
  @t3 "1700000000000x200000000000000003"
  @t4 "1700000000000x200000000000000004"
  @t5 "1700000000000x200000000000000005"

  setup do
    on_exit(fn ->
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleData)
    end)

    for {id, title, rank, done, secret} <- [
          {@t1, "Bake", 2, false, false},
          {@t2, "Answer", 5, true, false},
          {@t3, "Clean", 2, false, false},
          {@t4, "Draw", 1, true, false},
          {@t5, "Eat", 9, false, true}
        ],
        do:
          Ash.Seed.seed!(PhxCheck.Task, %{
            id: id,
            title: title,
            rank: rank,
            done: done,
            secret: secret
          })

    # A list field holds a thing twice and a secret one.
    Ash.Seed.seed!(PhxCheck.Project, %{id: @p1, name: "Apollo", tasks: [@t3, @t1, @t5, @t2, @t1]})
    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    :ok
  end

  defp enforced?, do: Ash.Resource.Info.authorizers(PhxCheck.Task) != []

  # The titles a list's cells show, `prefix` naming the list.
  defp shown(html, prefix),
    do:
      ~r/#{prefix}: (\w+)/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

  # Without what the user may not read (the secret task, with policies).
  defp visible(titles), do: if(enforced?(), do: titles -- ["Eat"], else: titles)

  test "a sorted search sorted again is one query by both keys", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert shown(html, "S") == visible(["Eat", "Answer", "Bake", "Clean", "Draw"])
  end

  test "a search's further sort keys, with the editor's unset settings", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert shown(html, "M") == visible(["Draw", "Clean", "Bake", "Answer", "Eat"])
  end

  test "merged searches: the first's items, then the second's new ones", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert shown(html, "G") == ["Answer", "Draw", "Bake", "Clean"]
    # item #2 of the same list, a group's thing
    assert html =~ "I: Draw"
  end

  test "a list field: unique elements and items until #, in its order", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert shown(html, "U") == visible(["Clean", "Bake", "Eat", "Answer"])
    assert shown(html, "L") == ["Clean", "Bake"]
  end

  test "a list field sorted and filtered in the database, as the user", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert shown(html, "F") == visible(["Answer", "Bake", "Clean", "Eat"])
    # Filtered: the list's own order, each thing once.
    assert shown(html, "K") == visible(["Clean", "Bake", "Eat"])
  end

  test "a filtered search with an empty input matches nothing (option unstated)", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert shown(html, "Q") == []

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "a"}
    })

    Process.sleep(200)
    assert view |> render() |> shown("Q") == visible(["Bake", "Clean", "Draw", "Eat"])
  end

  test "options filtered by an attribute", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert shown(html, "O") == ["Red", "Amber"]
  end

  test "every query a list reads stops at :max_items", %{conn: conn} do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, max_items: 2)
    {:ok, _view, html} = live(conn, "/")
    # Each merged search reads 2: Answer, Draw and Bake, Clean.
    assert shown(html, "G") == ["Answer", "Draw"]
    assert shown(html, "F") == ["Answer", "Bake"]
    assert shown(html, "S") == visible(["Eat", "Answer", "Bake"]) |> Enum.take(2)
  end

  test "a change to a searched type reads the merged list again", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    PhxCheck.Task
    |> Ash.get!(@t4, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{done: false})
    |> Ash.update!(authorize?: false)

    Process.sleep(200)
    assert view |> render() |> shown("G") == ["Answer", "Bake", "Clean", "Draw"]
  end

  test "the runtime's list operators" do
    a = %{id: @t1}
    assert Runtime.merge([@t1, @t2], [a, @t3]) == [@t1, @t2, @t3]
    assert Runtime.unique([@t1, a, @t2, @t1]) == [@t1, @t2]
    assert Runtime.intersect([@t2, @t1, @t1], [a]) == [a]
    assert Runtime.minus_list([@t1, @t2, @t1], [a]) == [@t2]
    assert Runtime.minus_item([@t1, @t2, @t1], a) == [@t2]
    assert Runtime.plus_item([@t1], a) == [@t1]
    assert Runtime.plus_item([@t1], @t2) == [@t1, @t2]
    assert Runtime.plus_item([@t1], nil) == [@t1]
    assert Runtime.limit([1, 2, 3], 2.0) == [1, 2]
    assert Runtime.limit([1, 2, 3], nil) == []
    assert Runtime.item_at([1, 2, 3], 3) == 3
    assert Runtime.item_at([1, 2, 3], 0) == nil
    assert Runtime.as_list(nil) == []
    assert Runtime.as_list("x") == ["x"]
    assert Runtime.merge(nil, nil) == []
  end
end
