defmodule PhxCheckWeb.JoinPageDataBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Generated app runtime regression checks for the decided cut-3 joins.
  use PhxCheck.DataCase, async: false

  alias PhxCheck.Bubble.Changes

  @project "1700000000000x100000000000000001"

  defmodule JoinPage do
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
          element: "project",
          instance: nil,
          fun: :project,
          read: :url_thing,
          cell: nil,
          loads: [["tasks"]],
          cell_loads: [],
          topic: "Project",
          blocked: []
        },
        %{
          element: "tasks",
          instance: nil,
          fun: :tasks,
          read: :value,
          cell: nil,
          loads: [],
          cell_loads: [],
          topic: "Task",
          blocked: []
        }
      ]

    def project(ctx), do: PhxCheckWeb.BubbleData.url_thing(ctx, PhxCheck.Project)
    def tasks(ctx), do: ctx.data[{"", "project"}].tasks
  end

  test "a join-backed page relationship reads at most 100 rows in the database" do
    project = Ash.Seed.seed!(PhxCheck.Project, %{id: @project})

    for i <- 1..105 do
      id = "1700000000000x#{String.pad_leading(Integer.to_string(i), 18, "0")}"
      Ash.Seed.seed!(PhxCheck.Task, %{id: id})
      Ash.Seed.seed!(PhxCheck.ProjectTasks, %{project_id: project.id, task_id: id, position: i})
    end

    handler = "join-limit-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phx_check, :repo, :query],
        fn _, _, metadata, _ ->
          send(parent, {:sql, metadata.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)
    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    page = PhxCheckWeb.IndexLive.Workflows
    socket = PhxCheckWeb.BubbleWorkflows.mount(socket, page)

    socket =
      PhxCheckWeb.BubbleWorkflows.handle_params(
        socket,
        page,
        %{"bubble_thing" => @project},
        "http://localhost/index/#{@project}"
      )

    loaded = socket.assigns.bubble_data[{"", "rgJoinedTasks"}]
    assert length(loaded) == 100
    assert Enum.all?(loaded, &match?(%PhxCheck.Task{}, &1))

    queries = sql_queries()
    assert Enum.any?(queries, &String.contains?(&1, "project_tasks"))

    refute Enum.any?(queries, fn sql ->
             String.contains?(sql, "project_tasks") and
               String.match?(sql, ~r/^SELECT\b/i) and
               not String.match?(sql, ~r/\bLIMIT\b/i)
           end),
           inspect(queries)
  end

  test "creating and destroying a join row refresh the subscribed page with its own read" do
    Ash.Seed.seed!(PhxCheck.Project, %{id: @project})
    task_id = "1700000000000x200000000000000001"
    Ash.Seed.seed!(PhxCheck.Task, %{id: task_id})
    topic = Changes.topic("Project", @project)
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)

    socket = %Phoenix.LiveView.Socket{transport_pid: self()}
    socket = PhxCheckWeb.BubbleWorkflows.mount(socket, JoinPage)
    params = %{"bubble_thing" => @project}
    url = "http://localhost/project/#{@project}"
    socket = PhxCheckWeb.BubbleWorkflows.handle_params(socket, JoinPage, params, url)
    assert socket.assigns.bubble_data == %{}
    refute MapSet.member?(socket.assigns[:bubble_topics] || MapSet.new(), topic)

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    socket = PhxCheckWeb.BubbleWorkflows.handle_params(socket, JoinPage, params, url)
    assert socket.assigns.bubble_data[{"", "tasks"}] == []
    assert MapSet.member?(socket.assigns.bubble_topics, topic)

    row =
      Ash.create!(PhxCheck.ProjectTasks, %{project_id: @project, task_id: task_id, position: 1},
        authorize?: false
      )

    assert_receive {:bubble, :data_changed, ^topic}
    socket = refresh(socket, topic)
    assert Enum.map(socket.assigns.bubble_data[{"", "tasks"}], & &1.id) == [task_id]

    assert {:ok, _} = Ash.destroy(row, authorize?: false, return_destroyed?: true)
    assert_receive {:bubble, :data_changed, ^topic}
    socket = refresh(socket, topic)
    assert socket.assigns.bubble_data[{"", "tasks"}] == []
    refute_receive {:bubble, :data_changed, _}
  end

  defp refresh(socket, topic) do
    socket = PhxCheckWeb.BubbleData.changed(socket, topic)
    assert_receive {:bubble, :data_refresh, ref}
    PhxCheckWeb.BubbleData.refresh(socket, JoinPage, ref)
  end

  defp sql_queries do
    receive do
      {:sql, query} -> [query | sql_queries()]
    after
      0 -> []
    end
  end
end
