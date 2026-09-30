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
        clicks: %{
          "read" => ["observe"],
          "write" => ["write", "observe"],
          "final" => ["final_write"]
        },
        changes: %{"query" => ["consume", "observe"]},
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
        "observe" => %{condition: nil, run: :observe, blocked: [], data: true},
        "write" => %{condition: nil, run: :write, blocked: [], data: true},
        "final_write" => %{condition: nil, run: :final_write, blocked: [], data: true},
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

    def updated(ctx) do
      send(self(), {:updated_budget, ctx.backend.calls})
      fire(ctx, :updated)
    end

    def input_updated(ctx) do
      send(self(), {:condition_budget, ctx.backend.calls})
      {:done, ctx}
    end

    def consume(ctx) do
      {:cont, ctx} = PhxCheckWeb.BubbleWorkflows.call(ctx, "consume", __MODULE__, "noop", [], %{})
      {:done, ctx}
    end

    def observe(ctx) do
      send(
        self(),
        {:observed, title(ctx), PhxCheckWeb.BubbleWorkflows.input(ctx, [], "query"),
         ctx.backend.calls}
      )

      {:done, ctx}
    end

    @task_id "1700000000000x200000000000000001"
    def write(ctx) do
      PhxCheck.Task
      |> Ash.get!(@task_id, authorize?: false)
      |> Ash.Changeset.for_update(:update, %{title: "Bread"})
      |> Ash.update!(authorize?: false)

      {:done, ctx}
    end

    def final_write(ctx) do
      {:cont, ctx} = PhxCheckWeb.BubbleWorkflows.call(ctx, "consume", __MODULE__, "noop", [], %{})
      write(ctx)
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

  defmodule ValuePage do
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
          fun: :list,
          read: :value,
          cell: nil,
          loads: [],
          cell_loads: [],
          topic: "Task",
          blocked: []
        }
      ]

    def list(ctx),
      do:
        PhxCheckWeb.BubbleData.records(
          ctx,
          PhxCheck.Task,
          [
            "1700000000000x200000000000000001",
            "1700000000000x200000000000000002",
            "1700000000000x200000000000000003"
          ],
          true,
          2
        )
  end

  # Read budgets (post-audit of WTF-420): one source (the page's thing,
  # one query per read); `task/1` reports each read.
  defmodule BudgetPage do
    @task_id "1700000000000x200000000000000001"

    def __bubble__(:instances), do: []

    def __bubble__(:surface),
      do: %{
        states: %{},
        inputs: %{},
        loaded: ["on_load"],
        intervals: [],
        clicks: %{
          "five" => ["n1", "n2", "n3", "n4", "n5"],
          "tick" => ["tick"],
          "write" => ["write", "observe"],
          "write_direct" => ["write_direct", "observe"],
          "state" => ["set", "observe"]
        },
        changes: %{},
        conditions: []
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
      do:
        Map.new(
          [
            {"on_load", :observe, true},
            {"tick", :tick, false},
            {"write", :write, true},
            {"write_direct", :write_direct, true},
            {"set", :set, false},
            {"observe", :observe, true}
          ] ++ for(i <- 1..5, do: {"n#{i}", :noop, false}),
          fn {id, run, data} -> {id, %{condition: nil, run: run, blocked: [], data: data}} end
        )

    def task(ctx) do
      send(self(), :budget_page_read)
      PhxCheckWeb.BubbleData.url_thing(ctx, PhxCheck.Task)
    end

    def noop(ctx) do
      send(self(), :budget_page_noop)
      {:done, ctx}
    end

    def observe(ctx) do
      task = PhxCheckWeb.BubbleWorkflows.data(ctx, [], "task")
      send(self(), {:budget_page_observed, task && task.title})
      {:done, ctx}
    end

    # A custom event that schedules itself: it ends on its budgets.
    def tick(ctx) do
      send(self(), :budget_page_tick)

      case PhxCheckWeb.BubbleWorkflows.schedule_custom(ctx, "s", __MODULE__, "tick", [], 0, %{}) do
        {:cont, ctx} -> {:done, ctx}
        {:halt, status, ctx} -> {status, ctx}
      end
    end

    # A data step on the workflow runtime.
    def write(ctx) do
      {:cont, ctx} =
        PhxCheckWeb.BubbleWorkflows.backend(ctx, fn run ->
          retitle("Bread")
          {:cont, run}
        end)

      {:done, ctx}
    end

    # A write in owned code, through Ash but outside the runtime.
    def write_direct(ctx) do
      retitle("Brioche")
      {:done, ctx}
    end

    def set(ctx),
      do: PhxCheckWeb.BubbleWorkflows.set_state(ctx, "set", [{[], "x", "s", 1}]) |> done()

    defp done({:cont, ctx}), do: {:done, ctx}

    defp retitle(title) do
      PhxCheck.Task
      |> Ash.get!(@task_id, authorize?: false)
      |> Ash.Changeset.for_update(:update, %{title: title})
      |> Ash.update!(authorize?: false)
    end
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

  defp picks(html),
    do: ~r/Pick: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

  defp cells(html),
    do: ~r/Task: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

  test "data access is off by default: the pages load nothing", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert cells(html) == []
    refute html =~ "First open: B"
    assert picks(html) == []

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

  # Bubble's random sort (WTF-452): ordered by md5(id || seed) in the
  # database, then limited to the list's 2 rows; a fixed seed gives a
  # fixed order.
  test "a randomly sorted list shows a seeded random page of its search", %{conn: conn} do
    on()
    tasks = PhxCheck.Task |> Ash.read!(authorize?: false)
    assert length(tasks) > 2

    for seed <- ["one", "two", "three"] do
      Application.put_env(:phx_check, PhxCheckWeb.BubbleData, random_seed: seed)

      expected =
        tasks
        |> Enum.sort_by(&Base.encode16(:crypto.hash(:md5, &1.id <> seed), case: :lower))
        |> Enum.take(2)
        |> Enum.map(& &1.title)

      {:ok, _view, html} = live(conn, "/")
      assert picks(html) == expected
      {:ok, _view, html} = live(conn, "/")
      assert picks(html) == expected
    end

    # Unseeded: a new order on every read, still one page of the search.
    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, [])
    titles = Enum.map(tasks, & &1.title)

    for _ <- 1..3 do
      {:ok, _view, html} = live(conn, "/")
      assert [_, _] = picks = picks(html)
      assert Enum.all?(picks, &(&1 in titles))
    end
  end

  test "reusable instances keep distinct things in their nested scopes", %{conn: conn} do
    on()
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Card: Answer"
    assert html =~ "Card: Eat"
  end

  test "go to the current page with a thing replaces the URL's thing (WTF-454)", %{conn: conn} do
    on()
    {:ok, view, html} = live(conn, "/task/#{@t1}")
    assert html =~ "Title: Bake"
    render_click(view, "bubble:click", %{"scope" => "", "element" => "bSelf"})
    assert_patch(view, "/task/#{@t1}")

    # A query parameter named like the route's segment is not the page's
    # thing: its own path stays /task (review M1: it went to "/", another
    # view, and crashed the patch).
    {:ok, view, _html} = live(conn, "/task?bubble_thing=task")
    render_click(view, "bubble:click", %{"scope" => "", "element" => "bSelf"})
    assert_patch(view, "/task")
    assert Process.alive?(view.pid)

    # The index page takes no thing: the reusable's step fails, logged,
    # and the page stays.
    {:ok, view, _html} = live(conn, "/")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        render_click(view, "bubble:click", %{"scope" => "bCard1", "element" => "bCardSelf"})
      end)

    assert log =~ "data sent to the current page, which takes none"
    assert render(view) =~ "Card: Answer"
  end

  test "value-backed lists obey page size and the global cap before looking up IDs" do
    on()
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}

    socket =
      socket
      |> PhxCheckWeb.BubbleWorkflows.mount(ValuePage)
      |> PhxCheckWeb.BubbleData.load(ValuePage)

    assert Enum.map(socket.assigns.bubble_data[{"", "list"}], & &1.title) == ["Bake", "Answer"]

    assert PhxCheckWeb.BubbleData.records(nil, nil, Enum.to_list(1..5), true, 2) == [1, 2]
    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, max_items: 1)
    assert PhxCheckWeb.BubbleData.records(nil, nil, Enum.to_list(1..5), true, 2) == [1]

    assert length(
             PhxCheckWeb.BubbleData.records(
               PhxCheckWeb.BubbleWorkflows.data_ctx(socket, ValuePage, "", %{}),
               PhxCheck.Task,
               [@t1, "1700000000000x200000000000000002"],
               true,
               2
             )
           ) == 1
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

  test "clicks reload before running and between workflows after a write" do
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

    PhxCheck.Task
    |> Ash.get!(@t1, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{title: "Changed"})
    |> Ash.update!(authorize?: false)

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, ConditionPage, "bubble:click", %{
        "scope" => "",
        "element" => "read"
      })

    assert_received {:observed, "Changed", nil, _}

    {:noreply, _socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, ConditionPage, "bubble:click", %{
        "scope" => "",
        "element" => "write"
      })

    assert_received {:observed, "Bread", nil, _}
  end

  test "the last write settles on freshly loaded data with the same call budget" do
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

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, ConditionPage, "bubble:click", %{
        "scope" => "",
        "element" => "final"
      })

    assert_received {:condition_fired, :updated}
    assert_received {:updated_budget, calls}
    assert calls == Runtime.root(nil, nil).calls - 1

    # A later PubSub refresh cannot fire the same edge with a fresh budget.
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

    refute_received {:condition_fired, :updated}
  end

  test "input workflow waits for the debounced read and retains the shared budget" do
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

    PhxCheck.Task
    |> Ash.get!(@t1, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{title: "Bread"})
    |> Ash.update!(authorize?: false)

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, ConditionPage, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "query", "value" => "g"}
      })

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, ConditionPage, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "query", "value" => "go"}
      })

    refute_received {:observed, _, _, _}
    assert_receive {:bubble, :data_refresh, stale_ref}, 500

    {:noreply, _} =
      PhxCheckWeb.BubbleWorkflows.handle_info(
        socket,
        ConditionPage,
        {:bubble, :data_refresh, stale_ref}
      )

    refute_received {:observed, _, _, _}
    assert_receive {:bubble, :data_refresh, ref}, 500

    {:noreply, _} =
      PhxCheckWeb.BubbleWorkflows.handle_info(
        socket,
        ConditionPage,
        {:bubble, :data_refresh, ref}
      )

    assert_received {:observed, "Bread", "go", calls}
    assert calls == Runtime.root(nil, nil).calls - 1
  end

  test "a click flushes a pending input workflow once with fresh data and its shared budget" do
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

    PhxCheck.Task
    |> Ash.get!(@t1, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{title: "Bread"})
    |> Ash.update!(authorize?: false)

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, ConditionPage, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "query", "value" => "go"}
      })

    refute_received {:observed, _, _, _}

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, ConditionPage, "bubble:click", %{
        "scope" => "",
        "element" => "read"
      })

    assert_received {:observed, "Bread", "go", calls}
    assert calls == Runtime.root(nil, nil).calls - 1
    assert_received {:observed, "Bread", "go", ^calls}
    refute_received {:observed, _, _, _}

    assert_receive {:bubble, :data_refresh, ref}, 500

    {:noreply, _} =
      PhxCheckWeb.BubbleWorkflows.handle_info(
        socket,
        ConditionPage,
        {:bubble, :data_refresh, ref}
      )

    refute_received {:observed, _, _, _}
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

  # --- read budgets (post-audit of WTF-420) ---------------------------------------------

  defp count_queries(fun) do
    handler = "page-data-budget-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, _, _ -> send(parent, {:page_data_query, self()}) end,
        nil
      )

    try do
      result = fun.()
      {result, flush_queries(self())}
    after
      :telemetry.detach(handler)
    end
  end

  defp count(message, n \\ 0) do
    receive do
      ^message -> count(message, n + 1)
    after
      0 -> n
    end
  end

  defp budget_socket do
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    socket = PhxCheckWeb.BubbleWorkflows.mount(socket, BudgetPage)

    PhxCheckWeb.BubbleWorkflows.handle_params(
      socket,
      BudgetPage,
      %{"bubble_thing" => @t1},
      "http://localhost/task/#{@t1}"
    )
  end

  defp budget_click(socket, element) do
    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, BudgetPage, "bubble:click", %{
        "scope" => "",
        "element" => element
      })

    socket
  end

  test "a page-load workflow runs on the mount's read: one read" do
    on()

    {_socket, queries} =
      count_queries(fn ->
        {:noreply, socket} =
          PhxCheckWeb.BubbleWorkflows.handle_info(
            budget_socket(),
            BudgetPage,
            {:bubble, :page_loaded}
          )

        socket
      end)

    reads = count(:budget_page_read)
    IO.puts("page data: a page-load workflow mount read #{reads} times, #{queries} queries")
    assert_received {:budget_page_observed, "Bake"}
    assert reads == 1
    assert queries == 1
  end

  test "a click running five workflows that change nothing reads nothing" do
    on()
    socket = budget_socket()
    count(:budget_page_read)

    {_socket, queries} = count_queries(fn -> budget_click(socket, "five") end)
    reads = count(:budget_page_read)

    IO.puts(
      "page data: a click with 5 no-write workflows read #{reads} times, #{queries} queries"
    )

    assert count(:budget_page_noop) == 5
    assert reads == 0
    assert queries == 0
  end

  test "a self-scheduling custom event ends on its budget and reads nothing per round" do
    on()
    socket = budget_socket()
    count(:budget_page_read)

    run_all = fn run_all, socket, rounds ->
      receive do
        {:bubble, :run, _, _, _, _, _} = message ->
          {:noreply, socket} =
            PhxCheckWeb.BubbleWorkflows.handle_info(socket, BudgetPage, message)

          run_all.(run_all, socket, rounds + 1)
      after
        100 -> rounds
      end
    end

    {rounds, queries} =
      count_queries(fn -> run_all.(run_all, budget_click(socket, "tick"), 0) end)

    reads = count(:budget_page_read)
    ticks = count(:budget_page_tick)

    IO.puts(
      "page data: a self-scheduling custom event ran #{rounds} rounds, " <>
        "read #{reads} times, #{queries} queries"
    )

    assert rounds > 0 and ticks == rounds + 1
    assert rounds <= Runtime.root(nil, nil).calls
    assert reads == 0
    assert queries == 0
  end

  test "a write and its own notification are one read" do
    on()

    for element <- ["write", "write_direct"] do
      socket = budget_socket()
      count(:budget_page_read)

      socket = budget_click(socket, element)
      expected = if element == "write", do: "Bread", else: "Brioche"
      assert_received {:budget_page_observed, ^expected}

      # The notification the write sent was covered by the read before
      # "observe": nothing is left to read again.
      refute_received {:bubble, :data_changed, _}
      refute socket.assigns.bubble_data_stale
      reads = count(:budget_page_read)
      IO.puts("page data: a click that writes (#{element}) read #{reads} times")
      assert reads == 1
    end
  end

  test "a custom state a workflow changes makes the next workflow read again" do
    on()
    socket = budget_socket()
    count(:budget_page_read)

    _socket = budget_click(socket, "state")
    assert_received {:budget_page_observed, "Bake"}
    assert count(:budget_page_read) == 1
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

    # Listing is the :search action's under enforced policies (WTF-423).
    action = if Ash.Resource.Info.action(PhxCheck.Task, :search), do: :search, else: :read

    records =
      PhxCheck.Task |> Ash.Query.limit(100) |> Ash.read!(action: action, authorize?: true)

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
