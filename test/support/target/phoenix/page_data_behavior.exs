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

  # What an input change reads again (WTF-475), source by source: each
  # reports its read. `a` reads input `q`, `b` reads `a` (a group reading a
  # group), `c` reads `b`; `kept` reads no input.
  defmodule NarrowPage do
    def __bubble__(:instances), do: []

    def __bubble__(:surface),
      do: %{
        states: %{{"x", "s"} => nil},
        inputs: %{"q" => {:text, nil}, "other" => {:text, nil}},
        loaded: [],
        intervals: [],
        clicks: %{"set_input" => ["set_input"], "both" => ["both"], "noop" => ["noop"]},
        changes: %{"q" => ["noop"]},
        conditions: []
      }

    def __bubble__(:data),
      do: [
        source("a", ["q"], []),
        source("b", [], ["a"]),
        source("c", [], ["b"]),
        source("kept", [], [])
      ]

    def __bubble__(:workflows),
      do: %{
        "set_input" => %{condition: nil, run: :set_input, blocked: [], data: false},
        "both" => %{condition: nil, run: :both, blocked: [], data: false},
        "noop" => %{condition: nil, run: :noop, blocked: [], data: false}
      }

    def source(element, inputs, reads),
      do: %{
        element: element,
        instance: nil,
        fun: String.to_atom("read_" <> element),
        read: :value,
        cell: nil,
        loads: [],
        cell_loads: [],
        topic: nil,
        inputs: inputs,
        reads: reads,
        blocked: []
      }

    def read_a(ctx), do: report(:a, PhxCheckWeb.BubbleWorkflows.input(ctx, [], "q"))
    def read_b(ctx), do: report(:b, {:b, PhxCheckWeb.BubbleWorkflows.data(ctx, [], "a")})
    def read_c(ctx), do: report(:c, {:c, PhxCheckWeb.BubbleWorkflows.data(ctx, [], "b")})
    def read_kept(_ctx), do: report(:kept, :kept)

    # A workflow setting the input (as "Reset relevant inputs" does).
    def set_input(ctx), do: {:done, %{ctx | inputs: Map.put(ctx.inputs, {"", "q"}, "set")}}

    # A custom state and the input in one event.
    def both(ctx) do
      {:cont, ctx} = PhxCheckWeb.BubbleWorkflows.set_state(ctx, "set", [{[], "x", "s", 1}])
      set_input(ctx)
    end

    def noop(ctx) do
      send(self(), :narrow_noop)
      {:done, ctx}
    end

    defp report(name, value) do
      send(self(), {:narrow_read, name})
      value
    end
  end

  # NarrowPage scaffolded before WTF-475: `kept` lists no `inputs`.
  defmodule UnlistedPage do
    def __bubble__(:instances), do: []
    def __bubble__(:surface), do: NarrowPage.__bubble__(:surface)
    def __bubble__(:workflows), do: NarrowPage.__bubble__(:workflows)

    def __bubble__(:data) do
      Enum.map(NarrowPage.__bubble__(:data), fn
        %{element: "kept"} = source -> Map.drop(source, [:inputs, :reads])
        source -> source
      end)
    end

    defdelegate read_a(ctx), to: NarrowPage
    defdelegate read_b(ctx), to: NarrowPage
    defdelegate read_c(ctx), to: NarrowPage
    defdelegate read_kept(ctx), to: NarrowPage
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

  defp strict(html),
    do: ~r/Strict: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

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

    # The index page takes no thing: as in Bubble, the data is appended
    # all the same (WTF-466), under /index, and the page ignores it.
    {:ok, view, _html} = live(conn, "/")
    render_click(view, "bubble:click", %{"scope" => "bCard1", "element" => "bCardSelf"})
    assert assert_patch(view) =~ ~r{\A/index/[0-9]+x[0-9]+\z}
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

  test "an input change reads again only the sources reading the input (WTF-475)", %{
    conn: conn
  } do
    on()
    {:ok, view, _html} = live(conn, "/")
    handler = "page-data-narrow-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, meta, _ -> send(parent, {:page_data_sql, self(), meta.query}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # A whole read: a change notification of the type every source searches.
    send(view.pid, {:bubble, :data_changed, PhxCheck.Bubble.Changes.topic("Task")})
    Process.sleep(150)
    _ = render(view)
    whole = sql(view.pid)

    # Only bList and bStrict read bQuery (and bList's cells' group reads
    # bList): the two instances' searches, bFirstOpen and bRandom are not
    # read again.
    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "ea", "on" => "blur"}
    })

    Process.sleep(200)
    narrowed = render(view)
    queries = sql(view.pid)

    IO.puts(
      "page data: a whole read took #{length(whole)} queries, an input change #{length(queries)}"
    )

    assert cells(narrowed) == ["Clean"]
    assert narrowed =~ "Strict: Clean"

    # Each source's own query, told apart by what it asks: bRandom's MD5
    # order, bFirstOpen's `done` constraint, bCard2's descending title,
    # bCard1's plain one (as bList's with an empty input), bList's and
    # bStrict's `contains` once typed (bStrict reads nothing while the
    # input is empty: it does not ignore empty constraints, WTF-478).
    random? = &(&1 =~ "md5(")
    first_open? = &(&1 =~ ~r/WHERE \(t0\."done"/)
    card2? = &(&1 =~ ~r/ORDER BY t0\."title" DESC LIMIT/)
    plain? = &(&1 =~ ~r/FROM "task" AS t0 ORDER BY t0\."title" LIMIT/)
    list? = &(&1 =~ ~r/strpos|like/i)

    for {source?, n} <- [{random?, 1}, {first_open?, 1}, {card2?, 1}, {plain?, 2}, {list?, 0}],
        do: assert(Enum.count(whole, source?) == n)

    for {source?, n} <- [{random?, 0}, {first_open?, 0}, {card2?, 0}, {plain?, 0}, {list?, 2}],
        do: assert(Enum.count(queries, source?) == n)
  end

  defp sql(pid, acc \\ []) do
    receive do
      {:page_data_sql, ^pid, query} -> sql(pid, [query | acc])
      {:page_data_sql, _other, _query} -> sql(pid, acc)
    after
      0 -> Enum.reverse(acc)
    end
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

  # WTF-478, replayed on Bubble (2026-10-01): bList states
  # ignore_empty_constraints true (an empty query drops the constraint),
  # bStrict states false (an empty query matches nothing, though every
  # title contains "").
  test "an empty constraint value: ignored when the search says so, else nothing", %{conn: conn} do
    on()
    {:ok, view, html} = live(conn, "/")
    # No value yet (nil).
    assert cells(html) == ["Answer", "Bake", "Clean"]
    assert strict(html) == []

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "ea"}
    })

    Process.sleep(200)
    html = render(view)
    assert cells(html) == ["Clean"]
    assert strict(html) == ["Clean"]

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => ""}
    })

    Process.sleep(200)
    html = render(view)
    assert cells(html) == ["Answer", "Bake", "Clean"]
    assert strict(html) == []
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

  defp narrow_socket(page) do
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    socket = PhxCheckWeb.BubbleWorkflows.mount(socket, page)
    socket = PhxCheckWeb.BubbleWorkflows.handle_params(socket, page, %{}, "http://localhost/")
    assert narrow_reads() == [:a, :b, :c, :kept]
    socket
  end

  defp narrow_reads(acc \\ []) do
    receive do
      {:narrow_read, name} -> narrow_reads([name | acc])
    after
      0 -> Enum.sort(acc)
    end
  end

  # Typing: the debounced change of a text input, then the page's read.
  defp narrow_type(socket, page, value) do
    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, page, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "q", "value" => value, "on" => "blur"}
      })

    narrow_flush(socket, page)
  end

  # The page's debounced read: the latest timer (earlier ones are superseded).
  defp narrow_flush(socket, page) do
    assert_receive {:bubble, :data_refresh, ref}, 500
    ref = latest_refresh(ref)

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_info(socket, page, {:bubble, :data_refresh, ref})

    socket
  end

  defp latest_refresh(ref) do
    receive do
      {:bubble, :data_refresh, later} -> latest_refresh(later)
    after
      200 -> ref
    end
  end

  defp narrow_click(socket, page, element) do
    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, page, "bubble:click", %{
        "scope" => "",
        "element" => element
      })

    socket
  end

  test "typing reads again the sources reading the input, through groups reading groups" do
    on()
    socket = narrow_page_typed(NarrowPage, "x")
    assert narrow_reads() == [:a, :b, :c]
    assert socket.assigns.bubble_data[{"", "c"}] == {:c, {:b, "x"}}
    assert socket.assigns.bubble_data[{"", "kept"}] == :kept

    # Another input, read by no source: nothing is read.
    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, NarrowPage, "bubble:change", %{
        "bubble" => %{"scope" => "", "element" => "other", "value" => "y", "on" => "blur"}
      })

    _socket = narrow_flush(socket, NarrowPage)
    assert narrow_reads() == []
  end

  defp narrow_page_typed(page, value) do
    page |> narrow_socket() |> narrow_type(page, value)
  end

  test "a source that does not list its inputs reads the whole page on any input change" do
    on()
    _socket = narrow_page_typed(UnlistedPage, "x")
    assert narrow_reads() == [:a, :b, :c, :kept]
  end

  test "an input a workflow sets reads again only the sources reading it" do
    on()
    socket = narrow_click(narrow_socket(NarrowPage), NarrowPage, "set_input")
    assert narrow_reads() == [:a, :b, :c]
    assert socket.assigns.bubble_data[{"", "a"}] == "set"
  end

  test "a custom state and an input changed in one event read the whole page" do
    on()
    _socket = narrow_click(narrow_socket(NarrowPage), NarrowPage, "both")
    assert narrow_reads() == [:a, :b, :c, :kept]
  end

  test "typing runs no input workflow; committing (blur) runs it once per value" do
    on()
    socket = narrow_page_typed(NarrowPage, "x")
    assert narrow_reads() == [:a, :b, :c]
    refute_received :narrow_noop

    blur = fn socket, value ->
      {:noreply, socket} =
        PhxCheckWeb.BubbleWorkflows.handle_event(socket, NarrowPage, "bubble:commit", %{
          "element" => "q",
          "value" => value
        })

      narrow_flush(socket, NarrowPage)
    end

    # The page's scope is empty: blur sends no `scope` value.
    socket = blur.(socket, "x")
    assert_received :narrow_noop
    # The value was read while typing: committing it reads nothing more.
    assert narrow_reads() == []

    # The same value again: nothing runs.
    socket = blur.(socket, "x")
    refute_received :narrow_noop

    # Two other values committed before the page reads: each runs, once.
    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, NarrowPage, "bubble:commit", %{
        "element" => "q",
        "value" => "y"
      })

    _socket = blur.(socket, "z")
    assert_received :narrow_noop
    assert_received :narrow_noop
    refute_received :narrow_noop
    assert narrow_reads() == [:a, :b, :c]
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
    # ignored; an input value is only ever a constraint's value. Every
    # name sent carries a fresh random suffix, so none of them (nor what
    # the page could derive from them) is an atom unless the page made it
    # one (WTF-490: unlike the VM's atom count, which anything running
    # alongside may move).
    suffix = "Wtf490" <> Base.encode16(:crypto.strong_rand_bytes(8))
    resource = "PhxCheck.User#{suffix}"
    element = "bList#{suffix}"
    function = "data_blist#{suffix}"
    query = "%' OR 1=1 --#{suffix}"
    topic = "User#{suffix}"

    render_click(view, "bubble:data", %{"resource" => resource, "id" => @t1})
    render_click(view, "bubble:click", %{"scope" => "", "element" => element})
    render_click(view, "bubble:click", %{"scope" => "", "element" => function})

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => query}
    })

    send(view.pid, {:bubble, :data_changed, "bubble:" <> topic})
    send(view.pid, {:bubble, :data_changed, :not_a_topic})

    Process.sleep(200)
    assert cells(render(view)) == []
    assert Process.alive?(view.pid)

    names = [resource, element, function, query, topic, "bubble:" <> topic]

    derived =
      Enum.flat_map(names, fn name ->
        [name, "Elixir." <> name, "read_" <> name, String.downcase(name), Macro.underscore(name)]
      end)

    assert existing_atom?("data_changed")
    assert Enum.reject(derived, &existing_atom?/1) == derived
  end

  defp existing_atom?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end

  # --- Display data (WTF-492) ----------------------------------------------------------------

  defp shown(html, label),
    do: ~r/#{label}: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

  defp click(view, element, scope \\ ""),
    do: render_click(view, "bubble:click", %{"scope" => scope, "element" => element})

  test "Display data shows a thing in a group with no data source, until a reset", %{
    conn: conn
  } do
    on()
    {:ok, view, html} = live(conn, "/shown")
    assert shown(html, "SrcA") == ["Answer"]
    assert shown(html, "SrcB") == ["Eat"]
    assert shown(html, "Shown") == []

    # The group shows the step's thing, and what reads it (a group inside
    # whose source is its parent's project) follows.
    html = click(view, "bShowA")
    assert shown(html, "Shown") == ["Answer"]
    assert shown(html, "Shown project") == ["Apollo"]

    # Another step replaces it.
    assert shown(click(view, "bShowB"), "Shown") == ["Eat"]

    # The page kept its unique ID, not the record: a change shows.
    PhxCheck.Task
    |> Ash.get!("1700000000000x200000000000000005", authorize?: false)
    |> Ash.Changeset.for_update(:update, %{title: "Eaten"})
    |> Ash.update!(authorize?: false)

    Process.sleep(150)
    assert shown(render(view), "Shown") == ["Eaten"]

    # A reset forgets it: the group shows nothing again.
    html = click(view, "bResetShown")
    assert shown(html, "Shown") == []
    assert shown(html, "Shown project") == []
  end

  test "Display data wins over a group's own data source until a reset", %{conn: conn} do
    on()
    {:ok, view, _html} = live(conn, "/shown")
    assert shown(click(view, "bOverride"), "SrcA") == ["Eat"]
    assert shown(click(view, "bResetSrc"), "SrcA") == ["Answer"]
  end

  test "Display data then Show popup opens the popup on its thing", %{conn: conn} do
    on()
    {:ok, view, html} = live(conn, "/shown")
    assert shown(html, "Popup") == []

    assert shown(click(view, "bOpenPop"), "Popup") == ["Eat"]
    assert_push_event(view, "bubble:exec", %{ops: [%{op: "show"}]})
  end

  test "Display list shows a list in a repeating group with no data source", %{conn: conn} do
    on()
    {:ok, view, html} = live(conn, "/shown")
    assert shown(html, "Listed") == []
    # Its repeating group shows one row: the list keeps its page size.
    assert shown(click(view, "bShowList"), "Listed") == ["Answer"]
  end

  test "Display data in a reusable element: its own group, or the instance's thing", %{
    conn: conn
  } do
    on()
    {:ok, view, html} = live(conn, "/shown")
    assert shown(html, "Panel") == []

    # The reusable element's custom event shows its parameter in its group.
    assert shown(click(view, "bShowPanel"), "Panel") == ["Answer"]

    # The page shows a thing in the instance: the reusable element's own.
    html = click(view, "bShowCard")
    assert shown(html, "Panel own") == ["Eat"]
    assert shown(html, "Panel") == ["Answer"]

    # Resetting the instance forgets both.
    html = click(view, "bResetPanel")
    assert shown(html, "Panel own") == []
    assert shown(html, "Panel") == []
  end

  test "a later step reads the data a Display data step just set", %{conn: conn} do
    on()
    {:ok, view, _html} = live(conn, "/shown")
    # Step 1 shows B in bShown; step 2 shows bShown's thing in the popup.
    html = click(view, "bChain")
    assert shown(html, "Shown") == ["Eat"]
    assert shown(html, "Popup") == ["Eat"]
  end

  test "resetting an outer group clears what was shown in a group inside it", %{conn: conn} do
    on()
    {:ok, view, _html} = live(conn, "/shown")
    assert shown(click(view, "bShowInner"), "Inner") == ["Answer"]
    assert shown(click(view, "bResetOuter"), "Inner") == []
  end

  test "Display data keeps only unique IDs: another type, a crafted ID or a number shows nothing" do
    on()
    alias PhxCheckWeb.BubbleWorkflows, as: BW
    project = Ash.get!(PhxCheck.Project, @p1, authorize?: false)
    task = Ash.get!(PhxCheck.Task, @t1, authorize?: false)
    ctx = %BW.Ctx{}

    for bad <- [project, "../#{@t1}", "1x", 42, %{id: @t1}, nil] do
      {:cont, ctx} = BW.display(ctx, "s", [], "g", false, PhxCheck.Task, false, bad)
      assert ctx.displayed[{"", "g"}] == {PhxCheck.Task, false, nil}, inspect(bad)
      assert ctx.data[{"", "g"}] == nil
    end

    # A record of the type, or its ID: kept as the ID, read as the user.
    {:cont, ctx} = BW.display(ctx, "s", [], "g", false, PhxCheck.Task, false, task)
    assert ctx.displayed[{"", "g"}] == {PhxCheck.Task, false, @t1}
    assert ctx.data[{"", "g"}].title == "Bake"

    # A list keeps only IDs (non-text values dropped), at most its page size.
    t2 = "1700000000000x200000000000000002"
    list = [123, project, "bad", task, t2, %{id: t2}]
    {:cont, ctx} = BW.display(ctx, "s", [], "l", false, PhxCheck.Task, true, list, nil)
    assert ctx.displayed[{"", "l"}] == {PhxCheck.Task, true, [@t1, t2]}
    assert Enum.map(ctx.data[{"", "l"}], & &1.title) == ["Bake", "Answer"]

    {:cont, ctx} = BW.display(ctx, "s", [], "l", false, PhxCheck.Task, true, list, 1)
    assert ctx.displayed[{"", "l"}] == {PhxCheck.Task, true, [@t1]}

    # What the loader reads drops anything but an ID too.
    assert PhxCheckWeb.BubbleData.show(ctx, {PhxCheck.Task, true, [42, %{id: @t1}, "x"]}, nil) ==
             []

    assert PhxCheckWeb.BubbleData.show(ctx, {PhxCheck.Task, false, 42}, nil) == nil

    # With data access off, nothing is read.
    Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
    {:cont, ctx} = BW.display(ctx, "s", [], "g", false, PhxCheck.Task, false, task)
    assert ctx.displayed[{"", "g"}] == {PhxCheck.Task, false, @t1}
    assert ctx.data[{"", "g"}] == nil
  end

  # A group in a repeating group's cell, set per cell (WTF-492): keyed by
  # the cell's thing, so re-sorting the list keeps what each thing showed.
  defmodule CellShownPage do
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

    def __bubble__(:workflows), do: %{}

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
          inputs: [],
          reads: [],
          blocked: []
        },
        %{
          element: "g",
          instance: nil,
          fun: nil,
          read: :displayed,
          cell: "list",
          loads: [],
          cell_loads: [],
          topic: "Task",
          inputs: [],
          reads: [],
          blocked: [],
          display: %{page_size: nil}
        }
      ]

    def tasks(ctx) do
      desc? = PhxCheckWeb.BubbleWorkflows.state(ctx, [], "x", "desc") == true

      PhxCheck.Task
      |> Ash.Query.sort(title: if(desc?, do: :desc, else: :asc))
      |> PhxCheckWeb.BubbleData.read(ctx, :all, 100)
    end
  end

  test "a cell's displayed group is keyed by the cell's thing, not its position" do
    on()
    alias PhxCheckWeb.BubbleWorkflows, as: BW
    task = Ash.get!(PhxCheck.Task, @t1, authorize?: false)

    # The step, run in a cell: kept under the cell's thing.
    ctx = %BW.Ctx{cell: task, cell_index: 2}
    {:cont, ctx} = BW.display(ctx, "s", [], "g", true, PhxCheck.Task, false, task)
    assert Map.keys(ctx.displayed) == [{"", "g", {:cell, @t1}}]
    assert ctx.data[{"", "g", 2}].title == "Bake"

    # Outside a cell it fails, never guesses a cell.
    assert {:halt, {:error, {"s", :not_in_cell}}, _} =
             BW.display(%BW.Ctx{}, "s", [], "g", true, PhxCheck.Task, false, task)

    load = fn desc? ->
      %Phoenix.LiveView.Socket{transport_pid: self()}
      |> BW.mount(CellShownPage)
      |> Phoenix.Component.assign(:bubble_states, %{{"", "x", "desc"} => desc?})
      |> Phoenix.Component.assign(:bubble_displayed, ctx.displayed)
      |> PhxCheckWeb.BubbleData.load(CellShownPage)
    end

    shown = fn socket ->
      for {{"", "g", i}, %{title: title}} <- socket.assigns.bubble_data, do: {i, title}
    end

    # Bake is 2nd in title order, 4th in reverse: it follows its thing.
    assert shown.(load.(false)) == [{2, "Bake"}]
    assert shown.(load.(true)) == [{4, "Bake"}]
  end

  test "Display data runs only with data access: off, nothing is kept or shown", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/shown")
    html = click(view, "bShowA")
    assert shown(html, "Shown") == []
    assert_push_event(view, "bubble:notice", %{text: "This action isn't available yet."})
  end
end
