defmodule PhxCheckWeb.PageDataBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Behavior of the page data lowered from
  # test/support/target/phoenix/page_data.json (WTF-420), run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/page_data_behavior_test.exs, with a database).
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhxCheck.Workflows.Runtime

  @p1 "1700000000000x100000000000000001"
  @t1 "1700000000000x200000000000000001"

  setup do
    on_exit(fn ->
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleData)
    end)

    project = Ash.Seed.seed!(PhxCheck.Project, %{id: @p1, name: "Apollo"})

    for {id, title, done} <- [
          {@t1, "Bake", false},
          {"1700000000000x200000000000000002", "Answer", true},
          {"1700000000000x200000000000000003", "Clean", false},
          {"1700000000000x200000000000000004", "Draw", false},
          {"1700000000000x200000000000000005", "Eat", false}
        ],
        do:
          Ash.Seed.seed!(PhxCheck.Task, %{
            id: id,
            title: title,
            done: done,
            project_id: project.id
          })

    :ok
  end

  defp on, do: Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)

  defp cells(html),
    do: ~r/Task: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

  test "data access is off by default: the pages load nothing", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert cells(html) == []
    refute html =~ "First open: B"

    {:ok, _view, html} = live(conn, "/task/#{@t1}")
    refute html =~ "Title: Bake"
    refute html =~ "Apollo"
  end

  test "a repeating group shows its search, sorted, one page of it", %{conn: conn} do
    on()
    {:ok, _view, html} = live(conn, "/")

    # Sorted by title, 3 rows a page; a cell's thing's project is loaded.
    assert cells(html) == ["Answer", "Bake", "Clean"]
    assert html =~ "In: Apollo"
    # The first open task, a group's data source.
    assert html =~ "First open: Bake"
  end

  test "a list stops at :max_items, whatever its page size", %{conn: conn} do
    on()
    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, max_items: 2)
    {:ok, _view, html} = live(conn, "/")
    assert cells(html) == ["Answer", "Bake"]
  end

  test "an input is a search constraint; an empty one is ignored", %{conn: conn} do
    on()
    {:ok, view, _html} = live(conn, "/")

    html =
      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "ea"}
      })

    assert cells(html) == ["Clean"]

    html =
      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "bQuery", "value" => ""}
      })

    assert cells(html) == ["Answer", "Bake", "Clean"]
  end

  test "a page's thing comes from the URL; its group reads through it", %{conn: conn} do
    on()
    {:ok, _view, html} = live(conn, "/task/#{@t1}")
    assert html =~ "Title: Bake"
    assert html =~ "Project: Apollo"

    # No thing, an unknown one, or a path segment that is not a unique ID.
    for path <- [
          "/task",
          "/task/1700000000000x999999999999999999",
          "/task/abc",
          "/task/%27%20or%201%3D1",
          "/task/#{String.duplicate("1", 70)}x1"
        ] do
      {:ok, _view, html} = live(conn, path)
      refute html =~ "Title: B", path
      refute html =~ "Apollo", path
    end
  end

  test "lists and things update when their records change", %{conn: conn} do
    on()
    {:ok, list, _html} = live(conn, "/")
    {:ok, thing, _html} = live(conn, "/task/#{@t1}")

    Ash.create!(PhxCheck.Task, %{id: Runtime.new_id(), title: "Aardvark", done: false},
      authorize?: false
    )

    assert cells(render(list)) == ["Aardvark", "Answer", "Bake"]
    assert render(list) =~ "First open: Aardvark"

    PhxCheck.Task
    |> Ash.get!(@t1, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{title: "Bread"})
    |> Ash.update!(authorize?: false)

    assert render(thing) =~ "Title: Bread"

    PhxCheck.Project
    |> Ash.get!(@p1, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{name: "Gemini"})
    |> Ash.update!(authorize?: false)

    assert render(thing) =~ "Project: Gemini"
  end

  test "the browser cannot choose what a page reads", %{conn: conn} do
    on()
    {:ok, view, _html} = live(conn, "/")

    # Events naming a resource, a record, a query or a data function are
    # ignored; an input value is only ever a constraint's value. (Run
    # once first: loading code creates atoms of its own.)
    hostile = fn suffix ->
      render_click(view, "bubble:data", %{"resource" => "PhxCheck.User#{suffix}", "id" => @t1})
      render_click(view, "bubble:click", %{"scope" => "", "element" => "bList#{suffix}"})
      render_click(view, "bubble:click", %{"scope" => "", "element" => "data_blist#{suffix}"})

      html =
        render_change(view, "bubble:change", %{
          "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "%' OR 1=1 --#{suffix}"}
        })

      send(view.pid, {:bubble, :data_changed, "bubble:User#{suffix}"})
      send(view.pid, {:bubble, :data_changed, :not_a_topic})
      html
    end

    hostile.("")
    atoms = :erlang.system_info(:atom_count)
    html = hostile.("#{System.unique_integer([:positive])}")

    assert cells(html) == []
    assert Process.alive?(view.pid)
    assert :erlang.system_info(:atom_count) == atoms
  end
end
