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
    {:ok, project} =
      Ash.create(PhxCheck.Project, %{id: Runtime.new_id(), name: "P"}, authorize?: false)

    %{project: project}
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
