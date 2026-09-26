defmodule PhxCheck.WorkflowsBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Copied into the generated app of the `workflows_backend` fixture by
  # scripts/phoenix_compile_check/render.exs (WTF-373): the lowered
  # workflows of test/support/target/workflows/backend.json behave as the
  # Bubble app describes them.
  use PhxCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: PhxCheck.Repo

  alias PhxCheck.Workflows.{Registry, Runtime, Scheduler}

  setup do
    config = Application.get_env(:phx_check, PhxCheck.Workflows, [])
    configure(:serve_workflow_api, true)
    on_exit(fn -> Application.put_env(:phx_check, PhxCheck.Workflows, config) end)

    {:ok, project} =
      Ash.create(PhxCheck.Project, %{id: Runtime.new_id(), name: "P"}, authorize?: false)

    %{project: project}
  end

  defp configure(key, value) do
    config = Application.get_env(:phx_check, PhxCheck.Workflows, [])
    Application.put_env(:phx_check, PhxCheck.Workflows, Keyword.put(config, key, value))
  end

  defp task_titled(title) do
    PhxCheck.Task
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.title == title))
  end

  defp create_task(conn, project) do
    conn = post(conn, "/api/1.1/wf/create%20task", %{"title" => "Hello", "project" => project.id})
    assert %{"status" => "success", "response" => %{"task" => id}} = json_response(conn, 200)
    Ash.get!(PhxCheck.Task, id, authorize?: false)
  end

  test "an exposed workflow creates a thing and returns it", %{conn: conn, project: project} do
    task = create_task(conn, project)
    assert task.title == "Hello"
    assert task.project_id == project.id
    assert task.count == 1.0
    assert %DateTime{} = task.created_date
    assert task.done == false
    assert task.watchers in [nil, []]
  end

  test "the workflow API is off unless the owner serves it", %{conn: conn} do
    configure(:serve_workflow_api, false)
    conn = post(conn, "/api/1.1/wf/create%20task", %{"title" => "Nope"})
    assert %{"status" => "NOT_SERVED"} = json_response(conn, 503)
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert task_titled("Nope") == []
  end

  test "a body parameter called name is the workflow's, not the route's", %{conn: conn} do
    conn = post(conn, "/api/1.1/wf/create%20task", %{"title" => "T", "name" => "Zed"})
    assert %{"response" => %{"name" => "Zed"}} = json_response(conn, 200)
  end

  test "each workflow answers its HTTP method only", %{conn: conn} do
    assert %{"response" => %{"reply" => "pong"}} =
             conn |> get("/api/1.1/wf/ping") |> json_response(200)

    assert build_conn() |> post("/api/1.1/wf/ping") |> json_response(405)
    # No setting means POST.
    assert build_conn()
           |> get("/api/1.1/wf/create%20task", %{"title" => "G"})
           |> json_response(405)

    assert task_titled("G") == []
  end

  test "a workflow that reaches residue fails before its first step" do
    assert {:error, _} = Runtime.run("wBlocked", %{})
    assert task_titled("must not exist") == []
    assert all_enqueued(worker: Scheduler) == []
  end

  test "scheduling on a list spaces the jobs and splits the budget", %{
    conn: conn,
    project: project
  } do
    ids = for _ <- 1..3, do: create_task(conn, project).id
    Enum.each(all_enqueued(worker: Scheduler), &PhxCheck.Repo.delete!/1)

    assert {:ok, %{status: :done}} = Runtime.run("wFanOut", %{"tasks" => ids})
    jobs = all_enqueued(worker: Scheduler, args: %{"workflow" => "wNote"})
    assert length(jobs) == 3
    [a, b, c] = jobs |> Enum.map(& &1.scheduled_at) |> Enum.sort(DateTime)
    assert DateTime.diff(b, a) == 60 and DateTime.diff(c, b) == 60
    assert Enum.all?(jobs, &(&1.args["budget"] < 10_000))
  end

  test "the job budget bounds fan-out", %{conn: conn, project: project} do
    ids = for _ <- 1..3, do: create_task(conn, project).id
    Enum.each(all_enqueued(worker: Scheduler), &PhxCheck.Repo.delete!/1)

    assert {:error, _} = Runtime.run("wFanOut", %{"tasks" => ids}, budget: 2)
    assert all_enqueued(worker: Scheduler) == []
  end

  test "the call budget bounds synchronous calls", %{conn: conn, project: project} do
    task = create_task(conn, project)
    configure(:max_calls, 0)
    assert {:error, _} = Runtime.run("wClose", %{"task" => task.id})
  end

  test "a required parameter is required", %{conn: conn} do
    conn = post(conn, "/api/1.1/wf/create%20task", %{})
    assert %{"status" => "MISSING_DATA"} = json_response(conn, 400)
  end

  test "a workflow that ignores privacy rules is the one bypass" do
    assert Registry.privacy_bypasses() == ["wClose"]
    assert Registry.workflow("wClose").authorize == false
    assert Registry.workflow("wCreate").authorize == true
    assert Registry.workflow("wNotify").authorize == :inherit
  end

  test "a change, a custom event and the database trigger", %{conn: conn, project: project} do
    task = create_task(conn, project)

    assert {:ok, %{status: :terminated, data: %{"rTitle" => "Hello"}}} =
             Runtime.run("wNotify", %{"pTask" => task.id})

    assert {:ok, %{status: :done}} = Runtime.run("wClose", %{"task" => task.id})
    task = Ash.get!(PhxCheck.Task, task.id, authorize?: false)
    assert task.done == true
    assert task.tags == ["closed"]

    # The update enqueued the trigger with the values before the change.
    jobs = all_enqueued(worker: Scheduler)

    job =
      Enum.find(jobs, &(&1.args["workflow"] == "wOnDone" and &1.args["trigger"]["before"] != nil))

    assert job

    assert :ok = perform_job(Scheduler, job.args)
    assert Ash.get!(PhxCheck.Project, project.id, authorize?: false).closed == true

    # Closing again: the step's condition (not done yet) is false.
    assert {:ok, %{status: :done}} = Runtime.run("wClose", %{"task" => task.id})
    assert Ash.get!(PhxCheck.Task, task.id, authorize?: false).tags == ["closed"]
  end

  test "a self-scheduling workflow runs until its condition stops it", %{
    conn: conn,
    project: project
  } do
    task = create_task(conn, project)

    assert {:ok, %{status: :done}} = Runtime.run("wTick", %{"task" => task.id})
    assert Ash.get!(PhxCheck.Task, task.id, authorize?: false).count == 2.0
    assert [job] = all_enqueued(worker: Scheduler, args: %{"workflow" => "wTick"})
    assert job.args["chain"] == 1

    assert :ok = perform_job(Scheduler, job.args)
    assert Ash.get!(PhxCheck.Task, task.id, authorize?: false).count == 3.0
    assert [_same] = all_enqueued(worker: Scheduler, args: %{"workflow" => "wTick"})
  end

  test "a step bubble_ex did not lower fails loudly" do
    assert {:error, _} = Runtime.run("wExternal", %{})
  end
end
