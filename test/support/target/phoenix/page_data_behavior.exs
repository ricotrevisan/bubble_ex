defmodule PhxCheckWeb.PageDataBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Behavior of the page data lowered from
  # test/support/target/phoenix/page_data.json (WTF-420), run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/page_data_behavior_test.exs, with a database).
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhxCheck.Workflows.Runtime

  defmodule ConditionPage do
    def __bubble__(:instances), do: []

    def __bubble__(:surface),
      do: %{
        states: %{},
        inputs: %{"query" => {:text, nil}},
        loaded: [],
        intervals: [],
        clicks: %{},
        changes: %{"query" => ["consume"]},
        conditions: [
          {"initial", :every_time},
          {"updated", :every_time},
          {"input_updated", :every_time}
        ]
      }

    def __bubble__(:data),
      do: [
        %{
          element: "task",
          instance: nil,
          fun: :task,
          read: :url_thing,
          cell: nil,
          loads: [],
          cell_loads: [],
          topic: "Task",
          blocked: []
        }
      ]

    def __bubble__(:workflows),
      do: %{
        "initial" => %{condition: :initial?, run: :initial, blocked: [], data: true},
        "updated" => %{condition: :updated?, run: :updated, blocked: [], data: true},
        "input_updated" => %{
          condition: :input_updated?,
          run: :input_updated,
          blocked: [],
          data: true
        },
        "consume" => %{condition: nil, run: :consume, blocked: [], data: false},
        "noop" => %{condition: nil, run: :noop, blocked: [], data: false}
      }

    def task(ctx), do: PhxCheckWeb.BubbleData.url_thing(ctx, PhxCheck.Task)
    def initial?(ctx), do: title(ctx) == "Bake"
    def updated?(ctx), do: title(ctx) == "Bread"

    def input_updated?(ctx),
      do: updated?(ctx) and PhxCheckWeb.BubbleWorkflows.input(ctx, [], "query") == "go"

    defp title(ctx),
      do: PhxCheckWeb.BubbleWorkflows.data(ctx, [], "task") |> then(&(&1 && &1.title))

    def initial(ctx), do: fire(ctx, :initial)
    def updated(ctx), do: fire(ctx, :updated)

    def input_updated(ctx) do
      send(self(), {:condition_budget, ctx.backend.calls})
      {:done, ctx}
    end

    def consume(ctx) do
      {:cont, ctx} = PhxCheckWeb.BubbleWorkflows.call(ctx, "consume", __MODULE__, "noop", [], %{})
      {:done, ctx}
    end

    def noop(ctx), do: {:done, ctx}

    defp fire(ctx, kind) do
      send(self(), {:condition_fired, kind})
      {:done, ctx}
    end
  end

  defmodule CellPage do
    def __bubble__(:instances), do: []

    def __bubble__(:surface),
      do: %{
        states: %{},
        inputs: %{},
        loaded: [],
        intervals: [],
        clicks: %{},
        changes: %{},
        conditions: []
      }

    def __bubble__(:data),
      do: [
        %{
          element: "list",
          instance: nil,
          fun: :tasks,
          read: :query,
          cell: nil,
          loads: [],
          cell_loads: [],
          topic: "Task",
          blocked: []
        },
        %{
          element: "project",
          instance: nil,
          fun: :project,
          read: :value,
          cell: "list",
          loads: [],
          cell_loads: [["project"]],
          topic: "Project",
          blocked: []
        }
      ]

    def tasks(ctx),
      do: PhxCheck.Task |> Ash.Query.new() |> PhxCheckWeb.BubbleData.read(ctx, :all, 100)

    def project(ctx), do: ctx.cell.project
  end

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
    assert html =~ "Cell group: Apollo"
    # The first open task, a group's data source.
    assert html =~ "First open: Bake"
  end

  test "reusable instances keep distinct things in their nested scopes", %{conn: conn} do
    on()
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Card: Answer"
    assert html =~ "Card: Eat"
  end

  test "scalar lists without a resource are bounded too" do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, max_items: 2)
    assert PhxCheckWeb.BubbleData.records(nil, nil, Enum.to_list(1..1_000), true) == [1, 2]
  end

  test "a list stops at :max_items, whatever its page size", %{conn: conn} do
    on()
    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, max_items: 2)
    {:ok, _view, html} = live(conn, "/")
    assert cells(html) == ["Answer", "Bake"]
  end

  test "a burst of input changes performs one debounced read, not a read per keystroke", %{
    conn: conn
  } do
    on()
    {:ok, view, _html} = live(conn, "/")
    handler = "page-data-input-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, _, _ ->
          send(parent, {:page_data_query, self()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "e"}
    })

    assert flush_queries(view.pid) == 0, "input change must not read synchronously"

    for value <- ~w(en n ns nsw nsw) do
      render_change(view, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "bQuery", "value" => value}
      })
    end

    Process.sleep(200)
    assert cells(render(view)) == ["Answer"]
    queries = flush_queries(view.pid)
    IO.puts("page data: six input changes caused #{queries} view queries")
    assert queries < 24
  end

  test "an input is a search constraint; an empty one is ignored", %{conn: conn} do
    on()
    {:ok, view, _html} = live(conn, "/")

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "ea"}
    })

    Process.sleep(200)
    assert cells(render(view)) == ["Clean"]

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => ""}
    })

    Process.sleep(200)
    assert cells(render(view)) == ["Answer", "Bake", "Clean"]
  end

  test "conditions see freshly loaded data on page load and on notification" do
    on()
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    socket = PhxCheckWeb.BubbleWorkflows.mount(socket, ConditionPage)

    socket =
      PhxCheckWeb.BubbleWorkflows.handle_params(
        socket,
        ConditionPage,
        %{"bubble_thing" => @t1},
        "http://localhost/task/#{@t1}"
      )

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_info(socket, ConditionPage, {:bubble, :page_loaded})

    assert_received {:condition_fired, :initial}

    PhxCheck.Task
    |> Ash.get!(@t1, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{title: "Bread"})
    |> Ash.update!(authorize?: false)

    topic = PhxCheck.Bubble.Changes.topic("Task", @t1)

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_info(
        socket,
        ConditionPage,
        {:bubble, :data_changed, topic}
      )

    assert_receive {:bubble, :data_refresh, ref}, 500

    {:noreply, _socket} =
      PhxCheckWeb.BubbleWorkflows.handle_info(
        socket,
        ConditionPage,
        {:bubble, :data_refresh, ref}
      )

    assert_received {:condition_fired, :updated}
    refute_received {:condition_fired, :initial}
  end

  test "input-driven condition waits for fresh data and inherits the event's call budget" do
    on()
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    socket = PhxCheckWeb.BubbleWorkflows.mount(socket, ConditionPage)

    socket =
      PhxCheckWeb.BubbleWorkflows.handle_params(
        socket,
        ConditionPage,
        %{"bubble_thing" => @t1},
        "http://localhost/task/#{@t1}"
      )

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_info(socket, ConditionPage, {:bubble, :page_loaded})

    assert_received {:condition_fired, :initial}

    PhxCheck.Task
    |> Ash.get!(@t1, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{title: "Bread"})
    |> Ash.update!(authorize?: false)

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, ConditionPage, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "query", "value" => "go"}
      })

    refute_received {:condition_budget, _}
    assert_receive {:bubble, :data_refresh, ref}, 500

    {:noreply, _socket} =
      PhxCheckWeb.BubbleWorkflows.handle_info(
        socket,
        ConditionPage,
        {:bubble, :data_refresh, ref}
      )

    assert_received {:condition_budget, calls}
    assert calls == Runtime.root(nil, nil).calls - 1
  end

  test "a page's thing comes from the URL; its group reads through it", %{conn: conn} do
    on()
    {:ok, _view, html} = live(conn, "/task/#{@t1}")
    assert html =~ "Title: Bake"
    assert html =~ "Project: Apollo"

    # Query strings cannot provide a page thing; only the path can.
    {:ok, _view, html} = live(conn, "/task?bubble_thing=#{@t1}")
    refute html =~ "Title: Bake"

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

  test "the first load does not read twice across disconnected and connected mounts", %{
    conn: conn
  } do
    on()
    handler = "page-data-first-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, _, _ ->
          send(parent, {:page_data_query, self()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, _view, html} = live(conn, "/")
    assert cells(html) == ["Answer", "Bake", "Clean"]
    queries = flush_all_queries()
    IO.puts("page data: initial connected load used #{queries} queries")
    assert queries < 20
  end

  defp flush_all_queries do
    receive do
      {:page_data_query, _pid} -> 1 + flush_all_queries()
    after
      0 -> 0
    end
  end

  test "cell-source relation expressions batch reads across 100 cells" do
    on()

    for i <- 1..95 do
      Ash.Seed.seed!(PhxCheck.Task, %{
        id: Runtime.new_id(),
        title: "Bulk #{i}",
        done: false,
        project_id: @p1
      })
    end

    handler = "cell-source-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, _, _ ->
          send(parent, {:page_data_query, self()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    socket = PhxCheckWeb.BubbleWorkflows.mount(socket, CellPage)
    socket = PhxCheckWeb.BubbleData.load(socket, CellPage)
    assert map_size(socket.assigns.bubble_data) == 101
    assert socket.assigns.bubble_data[{"", "project", 100}].name == "Apollo"
    queries = flush_queries(self())
    IO.puts("page data: 100 cell sources used #{queries} queries")
    assert queries < 10
  end

  test "a hundred records preload their related fields in a batch" do
    for i <- 1..95 do
      Ash.Seed.seed!(PhxCheck.Task, %{
        id: Runtime.new_id(),
        title: "Bulk #{i}",
        done: false,
        project_id: @p1
      })
    end

    records = PhxCheck.Task |> Ash.Query.limit(100) |> Ash.read!(authorize?: true)
    handler = "page-data-batch-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, _, _ ->
          send(parent, {:page_data_query, self()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    loaded = Runtime.load_page(records, [["project"]], Runtime.root(nil, nil), 100)
    assert length(loaded) == 100
    assert Enum.all?(loaded, &(&1.project.name == "Apollo"))
    queries = flush_queries(self())
    IO.puts("page data: 100 related rows loaded with #{queries} queries")
    assert queries < 10
  end

  test "bursts of unrelated creates cause one re-read, not a re-read per notification", %{
    conn: conn
  } do
    on()
    {:ok, view, _html} = live(conn, "/")

    handler = "page-data-query-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, _, _ ->
          send(parent, {:page_data_query, self()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for i <- 1..50 do
      Ash.create!(PhxCheck.Task, %{id: Runtime.new_id(), title: "New #{i}", done: false},
        authorize?: false
      )
    end

    Process.sleep(100)
    assert cells(render(view)) == ["Answer", "Bake", "Clean"]
    queries = flush_queries(view.pid)
    IO.puts("page data: 50 creates caused #{queries} view queries")
    assert queries < 40
  end

  defp flush_queries(pid) do
    receive do
      {:page_data_query, ^pid} -> 1 + flush_queries(pid)
      {:page_data_query, _other} -> flush_queries(pid)
    after
      0 -> 0
    end
  end

  test "lists and things update when their records change", %{conn: conn} do
    on()
    {:ok, list, _html} = live(conn, "/")
    {:ok, thing, _html} = live(conn, "/task/#{@t1}")

    Ash.create!(PhxCheck.Task, %{id: Runtime.new_id(), title: "Aardvark", done: false},
      authorize?: false
    )

    Process.sleep(60)
    assert cells(render(list)) == ["Aardvark", "Answer", "Bake"]
    assert render(list) =~ "First open: Aardvark"

    PhxCheck.Task
    |> Ash.get!(@t1, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{title: "Bread"})
    |> Ash.update!(authorize?: false)

    Process.sleep(60)
    assert render(thing) =~ "Title: Bread"

    PhxCheck.Project
    |> Ash.get!(@p1, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{name: "Gemini"})
    |> Ash.update!(authorize?: false)

    Process.sleep(60)
    assert render(thing) =~ "Project: Gemini"
    # A related record preloaded for a repeating-group cell must refresh too.
    assert render(list) =~ "In: Gemini"
    assert render(list) =~ "Cell group: Gemini"
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
    hostile.("#{System.unique_integer([:positive])}")

    Process.sleep(200)
    assert cells(render(view)) == []
    assert Process.alive?(view.pid)
    assert :erlang.system_info(:atom_count) == atoms
  end
end
