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

  test "a job with a malformed budget fails closed", %{conn: conn, project: project} do
    task = create_task(conn, project)

    for budget <- [-1, "10", 1.5, nil] do
      args = %{"workflow" => "wTick", "params" => %{"task" => task.id}, "budget" => budget}
      # Its first step writes a Task, whose trigger needs a job.
      assert {:error, _} = perform_job(Scheduler, args)
    end

    assert Ash.get!(PhxCheck.Task, task.id, authorize?: false).count == 1.0
  end

  test "a job's budget is capped at max_jobs", %{conn: conn, project: project} do
    ids = for _ <- 1..3, do: create_task(conn, project).id
    Enum.each(all_enqueued(worker: Scheduler), &PhxCheck.Repo.delete!/1)
    configure(:max_jobs, 2)

    args = %{"workflow" => "wFanOut", "params" => %{"tasks" => ids}, "budget" => 1_000_000_000}
    assert {:error, _} = perform_job(Scheduler, args)
    assert all_enqueued(worker: Scheduler) == []

    configure(:max_jobs, 10_000)
    assert {:ok, _} = Runtime.enqueue("wFanOut", %{"tasks" => ids})
    [job] = all_enqueued(worker: Scheduler)
    assert job.args["budget"] == 10_000
    assert :ok = perform_job(Scheduler, job.args)
  end

  test "a trigger's job carries only the fields it reads", %{conn: conn, project: project} do
    task = create_task(conn, project)
    [job | _] = all_enqueued(worker: Scheduler, args: %{"workflow" => "wOnDone"})
    assert job.args["trigger"]["now"] |> Map.keys() |> Enum.sort() == ["done", "id", "project_id"]
    assert job.args["trigger"]["now"]["id"] == task.id
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

  # WTF-520: "Result of step N" is the step's own result: a changed
  # record (step 2 changes step 1's), a custom event's return values (a
  # text; a thing, read as a record).
  test "steps read earlier steps' results and custom events' returns", %{
    conn: conn,
    project: project
  } do
    task = create_task(conn, project)

    assert {:ok, %{status: :returned, data: data}} = Runtime.run("wChain", %{"task" => task.id})
    assert data == %{"title" => "Chained", "count" => 5.0, "again" => "Chained"}

    task = Ash.get!(PhxCheck.Task, task.id, authorize?: false)
    assert task.title == "Chained" and task.count == 5.0

    # A returned thing's unique ID is read as a record; anything else is
    # the value as returned; a step that did not run returns nothing.
    ctx = %{Runtime.root("wChain", nil) | steps: %{"aCall" => %{"rTask" => task.id}}}

    assert %PhxCheck.Task{title: "Chained"} =
             Runtime.step_return(ctx, "aCall", "rTask", PhxCheck.Task, false, [])

    assert Runtime.step_return(ctx, "aCall", "rTask", nil, false, []) == task.id
    assert Runtime.step_return(ctx, "aOther", "rTask", PhxCheck.Task, false, []) == nil
    assert Runtime.step_return(ctx, "aOther", "rTask", PhxCheck.Task, true, []) == []
  end

  # Review of #229: a returned list of IDs is read in one query, as the
  # actor, in the list's order (not one read per ID).
  test "a returned list of things is read in one query, in order", %{
    conn: conn,
    project: project
  } do
    ids = for _ <- 1..3, do: create_task(conn, project).id

    ctx = %{
      Runtime.root("wChain", nil)
      | steps: %{"aCall" => %{"rTasks" => Enum.reverse(ids) ++ [nil, 3]}}
    }

    {records, queries} =
      counting_queries(fn ->
        Runtime.step_return(ctx, "aCall", "rTasks", PhxCheck.Task, true, [])
      end)

    assert Enum.map(records, & &1.id) == Enum.reverse(ids)
    assert queries == 1
  end

  # A return whose value does not have its declared shape is shaped as
  # declared: never a list where a field is read (no BadMapError, WTF-500).
  test "a return declared single that receives a list reads its first item", %{
    conn: conn,
    project: project
  } do
    [a, b] = for _ <- 1..2, do: create_task(conn, project)
    ctx = %{Runtime.root("wChain", nil) | steps: %{"aCall" => %{"rTask" => [a.id, b.id]}}}

    assert %PhxCheck.Task{id: id} =
             Runtime.step_return(ctx, "aCall", "rTask", PhxCheck.Task, false, [])

    assert id == a.id

    one = %{ctx | steps: %{"aCall" => %{"rTask" => a.id, "rText" => ["x", "y"]}}}

    assert [%PhxCheck.Task{}] =
             Runtime.step_return(one, "aCall", "rTask", PhxCheck.Task, true, [])

    assert Runtime.step_return(one, "aCall", "rText", nil, false, []) == "x"

    assert Runtime.step_return(
             %{one | steps: %{"aCall" => %{"rTask" => []}}},
             "aCall",
             "rTask",
             PhxCheck.Task,
             false,
             []
           ) == nil
  end

  test "a step that fails stops the chain: no later step runs", %{conn: conn, project: project} do
    task = create_task(conn, project)

    # Step 1 changes a thing that does not exist (empty): it fails, so
    # step 2, which changes its result, and the rest never run.
    assert {:error, error} =
             Runtime.run("wChain", %{"task" => "1700000000000x999999999999999999"})

    assert Exception.message(error) =~ ~s({"aCh1", :empty_thing})

    assert task_titled("Chained") == []
    assert Ash.get!(PhxCheck.Task, task.id, authorize?: false).count == 1.0
  end

  defp counting_queries(fun) do
    ref = make_ref()
    me = self()
    handler = "count-queries-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:phx_check, :repo, :query],
      fn _, _, _, _ -> send(me, {ref, :query}) end,
      nil
    )

    try do
      result = fun.()
      {result, count_messages(ref, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(ref, n) do
    receive do
      {^ref, :query} -> count_messages(ref, n + 1)
    after
      0 -> n
    end
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
