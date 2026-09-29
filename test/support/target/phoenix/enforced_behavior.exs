defmodule PhxCheckWeb.EnforcedBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Enforcement of the privacy policies compiled from Bubble (WTF-423), in
  # the app generated from test/support/target/phoenix/enforced.json.
  # scripts/phoenix_compile_check.sh copies it to
  # test/enforced_behavior_test.exs and runs it twice:
  #
  #   * rendered with privacy: :enforced, every test must pass
  #   * rendered with privacy: :omit (no policies), every test must FAIL:
  #     each one asserts something only the policies make true, so
  #     enforcement that silently turned off would not pass
  #
  # Task's privacy rules: `watching_` (the Task's Watchers contain the
  # Current User) views, finds and opens the attachments of everything;
  # everyone else views the Title only, finds nothing and opens nothing.
  # Project has no rules (Bubble's public defaults). All data is invented.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhxCheck.Workflows.Runtime

  @u1 "1700000000000x900000000000000001"
  @u2 "1700000000000x900000000000000002"
  @p1 "1700000000000x100000000000000001"
  @t1 "1700000000000x200000000000000001"
  @t2 "1700000000000x200000000000000002"
  @t3 "1700000000000x200000000000000003"
  @sha String.duplicate("ab", 32)

  setup do
    on_exit(fn ->
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      Application.delete_env(:phx_check, PhxCheckWeb.Uploads)
      Application.delete_env(:phx_check, PhxCheck.Workflows)
      System.delete_env("WORKFLOW_API_ADMIN_TOKEN")
    end)

    u1 = Ash.Seed.seed!(PhxCheck.User, %{id: @u1, email: "one@example.com"})
    u2 = Ash.Seed.seed!(PhxCheck.User, %{id: @u2, email: "two@example.com"})
    Ash.Seed.seed!(PhxCheck.Project, %{id: @p1, name: "Apollo"})

    for {id, title, watcher} <- [{@t1, "Bake", @u1}, {@t2, "Answer", @u2}, {@t3, "Clean", @u1}],
        do:
          Ash.Seed.seed!(PhxCheck.Task, %{
            id: id,
            title: title,
            done: false,
            project_id: @p1,
            watchers: [watcher],
            attachment: "private/#{@sha}/notes.txt"
          })

    %{u1: u1, u2: u2}
  end

  # The generated Privacy module exists only with policies: called at
  # runtime so this file compiles, and fails on its assertions, against an
  # :omit render too (the user as is there).
  defp actor(user) do
    privacy = Module.concat(PhxCheck, Privacy)

    if Code.ensure_loaded?(privacy),
      do: apply(privacy, :load_actor, [user]),
      else: user
  end

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(
      Ash.Resource.put_metadata(user, :token, token)
    )
  end

  defp data_access_on,
    do: Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)

  defp cells(html),
    do: ~r/Task: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

  test "only the generated runtime writes; direct writes and listings are forbidden",
       %{u1: u1} do
    # A write by the user, not by a workflow: forbidden.
    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(PhxCheck.Task, %{id: Runtime.new_id(), title: "Mine"}, actor: actor(u1))

    task = Ash.get!(PhxCheck.Task, @t1, authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             task
             |> Ash.Changeset.for_update(:update, %{title: "Hijack"})
             |> Ash.update(actor: actor(u1))

    assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(task, actor: actor(u1))

    # The same write by a workflow (the runtime's context flag): allowed.
    assert {:ok, %{}} =
             Ash.create(PhxCheck.Task, %{id: Runtime.new_id(), title: "By workflow"},
               actor: actor(u1),
               context: %{bubble: %{workflow_write: true}}
             )

    # Direct view reaches records by ID; a listing through :read does not.
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(PhxCheck.Task, actor: actor(u1))
  end

  test "reads follow the rules: a record by ID, its fields, and searches", %{u1: u1} do
    u1 = actor(u1)

    # Not watching t2: its Title (everyone), nothing else.
    t2 = Ash.get!(PhxCheck.Task, @t2, actor: u1)
    assert t2.title == "Answer"
    assert %Ash.ForbiddenField{} = t2.done
    assert %Ash.ForbiddenField{} = t2.project_id

    # Watching t1: every field.
    assert Ash.get!(PhxCheck.Task, @t1, actor: u1).done == false

    # Searches find what the user may find: the watched tasks only.
    found = PhxCheck.Task |> Ash.read!(action: :search, actor: u1) |> Enum.map(& &1.id)
    assert Enum.sort(found) == [@t1, @t3]

    # Logged out: found nothing (everyone finds nothing).
    assert PhxCheck.Task |> Ash.read!(action: :search, actor: nil) == []
  end

  test "pages show what the rules let the current user find and view", %{conn: conn, u1: u1} do
    data_access_on()

    # Logged out: the search finds nothing.
    {:ok, _view, html} = live(conn, "/")
    assert cells(html) == []

    # Signed in: the watched tasks only.
    {:ok, _view, html} = live(sign_in(conn, u1), "/")
    assert cells(html) == ["Bake", "Clean"]

    # A task the user does not watch, by its URL: its title, not its
    # project (the reference is hidden, so the group reads nothing).
    {:ok, _view, html} = live(sign_in(conn, u1), "/task/#{@t2}")
    assert html =~ "Title: Answer"
    refute html =~ "Apollo"
  end

  test "workflows read with the caller's privacy; the admin token bypasses it", %{conn: conn} do
    Application.put_env(:phx_check, PhxCheck.Workflows, serve_workflow_api: true)
    System.put_env("WORKFLOW_API_ADMIN_TOKEN", "admin-secret")

    # Anonymous caller: the task's Title (everyone), not its Done.
    anonymous = post(conn, "/api/1.1/wf/peek", %{"task" => @t1})

    assert %{"status" => "success", "response" => %{"title" => "Bake", "done" => nil}} =
             json_response(anonymous, 200)

    # The admin token: privacy ignored, as in Bubble.
    admin =
      conn
      |> put_req_header("authorization", "Bearer admin-secret")
      |> post("/api/1.1/wf/peek", %{"task" => @t1})

    assert %{"response" => %{"title" => "Bake", "done" => false}} = json_response(admin, 200)

    # A workflow's write is allowed (its conditions are the guard).
    created = post(conn, "/api/1.1/wf/create%20task", %{"title" => "From the API"})
    assert %{"response" => %{"task" => id}} = json_response(created, 200)
    assert Ash.get!(PhxCheck.Task, id, authorize?: false).title == "From the API"
  end

  @tag :tmp_dir
  test "private files follow the view attached files rule", %{
    conn: conn,
    u1: u1,
    u2: u2,
    tmp_dir: root
  } do
    dir = Path.join([root, "private", @sha])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "notes.txt"), "secret notes")

    Application.put_env(:phx_check, PhxCheckWeb.Uploads, root: root, private: :privacy_rules)
    path = "/uploads/private/#{@sha}/notes.txt"

    # u1 watches the tasks holding the file: served.
    assert response(get(sign_in(conn, u1), path), 200) == "secret notes"

    # u2 watches t2, which holds it too: served.
    assert response(get(sign_in(conn, u2), path), 200) == "secret notes"

    # Nobody else may open it (everyone: no attachments).
    assert response(get(conn, path), 404)

    # A file no record holds: nobody.
    other = String.duplicate("cd", 32)
    File.mkdir_p!(Path.join([root, "private", other]))
    File.write!(Path.join([root, "private", other, "x.txt"]), "orphan")
    assert response(get(sign_in(conn, u1), "/uploads/private/#{other}/x.txt"), 404)
  end
end
