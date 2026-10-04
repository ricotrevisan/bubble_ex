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
  # Project has no rules (Bubble's public defaults). Note's (WTF-457):
  # everyone finds every note and views its Title only; `owner_` (the
  # Note's Owner is the Current User) views everything. All data is
  # invented.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhxCheck.Workflows.Runtime

  @u1 "1700000000000x900000000000000001"
  @u2 "1700000000000x900000000000000002"
  @u3 "1700000000000x900000000000000003"
  @p1 "1700000000000x100000000000000001"
  @t1 "1700000000000x200000000000000001"
  @t2 "1700000000000x200000000000000002"
  @t3 "1700000000000x200000000000000003"
  @n1 "1700000000000x300000000000000001"
  @n2 "1700000000000x300000000000000002"
  @n3 "1700000000000x300000000000000003"
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
    u3 = Ash.Seed.seed!(PhxCheck.User, %{id: @u3, email: "three@example.com"})
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

    for {id, title, flagged, owner} <- [
          {@n1, "Alpha", true, @u1},
          {@n2, "Bravo", true, @u2},
          {@n3, "Charlie", false, @u1}
        ],
        do:
          Ash.Seed.seed!(PhxCheck.Note, %{id: id, title: title, flagged: flagged, owner_id: owner})

    %{u1: u1, u2: u2, u3: u3}
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

  # WTF-492: a page whose workflow came by records the user may not read
  # (as one ignoring privacy rules would) and shows them with "Display
  # data" in two groups with no data source of their own.
  defmodule ShownPage do
    @memo "1700000000000x400000000000000009"
    @task "1700000000000x200000000000000002"

    def __bubble__(:instances), do: []

    def __bubble__(:surface),
      do: %{
        states: %{},
        inputs: %{},
        loaded: [],
        intervals: [],
        clicks: %{"show" => ["show"]},
        changes: %{},
        conditions: []
      }

    def __bubble__(:workflows),
      do: %{"show" => %{condition: nil, run: :show, blocked: [], data: true}}

    def __bubble__(:data), do: [shown("memo", "Memo"), shown("task", "Task")]

    defp shown(element, topic),
      do: %{
        element: element,
        instance: nil,
        fun: nil,
        read: :displayed,
        cell: nil,
        loads: [],
        cell_loads: [],
        topic: topic,
        inputs: [],
        reads: [],
        blocked: [],
        display: %{page_size: nil}
      }

    def show(ctx) do
      memo = Ash.get!(PhxCheck.Memo, @memo, authorize?: false)
      task = Ash.get!(PhxCheck.Task, @task, authorize?: false)

      {:cont, ctx} =
        PhxCheckWeb.BubbleWorkflows.display(
          ctx,
          "a1",
          [],
          "memo",
          false,
          PhxCheck.Memo,
          false,
          memo
        )

      {:cont, ctx} =
        PhxCheckWeb.BubbleWorkflows.display(
          ctx,
          "a2",
          [],
          "task",
          false,
          PhxCheck.Task,
          false,
          task
        )

      {:done, ctx}
    end
  end

  defp data_access_on,
    do: Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)

  defp picks(html),
    do: ~r/Pick: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

  defp cells(html),
    do: ~r/Task: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

  defp flagged(html),
    do: ~r/Flagged: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

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

    # The same write by a workflow (the runtime's private context flag):
    # allowed.
    assert {:ok, %{}} =
             Ash.create(PhxCheck.Task, %{id: Runtime.new_id(), title: "By workflow"},
               actor: actor(u1),
               context: %{private: %{bubble_workflow_write: true}}
             )

    # The flag anywhere else does not count: in shared context (which Ash
    # passes on to nested actions), or outside private context.
    for context <- [
          %{shared: %{private: %{bubble_workflow_write: true}}},
          %{bubble: %{workflow_write: true}},
          %{bubble_workflow_write: true}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(PhxCheck.Task, %{id: Runtime.new_id(), title: "Forged"},
                 actor: actor(u1),
                 context: context
               ),
             inspect(context)
    end

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

  # Review M1: Ash's count aggregate under-counts with policies that read
  # the actor (a watcher found 2 tasks and counted 0): a page count reads
  # the keys through :search instead.
  defp memos(html),
    do: ~r/Memo: (\w+)/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()

  # WTF-475: typing reads again only the sources reading the input, and
  # keeps the rest as read. Not past an actor change: a user demoted while
  # the page is open (no notification reaches it: it reads no user) stops
  # finding the admins' memos at the next read, even an input's.
  test "a demoted user's next read, even an input's, drops what they may no longer find", %{
    conn: conn,
    u1: u1
  } do
    data_access_on()
    u1 = Ash.Seed.update!(u1, %{admin: true})
    Ash.Seed.seed!(PhxCheck.Memo, %{id: "1700000000000x400000000000000001", title: "Roadmap"})

    {:ok, view, html} = live(sign_in(conn, u1), "/")
    assert memos(html) == ["Roadmap"]

    Ash.Seed.update!(u1, %{admin: false})

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "a", "on" => "blur"}
    })

    Process.sleep(200)
    html = render(view)
    assert memos(html) == []
    # The input's own source read as usual.
    assert cells(html) == ["Bake", "Clean"]
  end

  test "a page count counts what the user finds", %{u1: u1} do
    query = Ash.Query.new(PhxCheck.Task)
    assert PhxCheckWeb.BubbleData.read(query, %{actor: actor(u1)}, :count, nil) == 2
    assert PhxCheckWeb.BubbleData.read(query, %{actor: nil}, :count, nil) == 0
  end

  test "pages show what the rules let the current user find and view", %{conn: conn, u1: u1} do
    data_access_on()

    # Logged out: the search finds nothing, in any order.
    {:ok, _view, html} = live(conn, "/")
    assert cells(html) == []
    assert picks(html) == []

    # Signed in: the watched tasks only. Bubble's random sort (WTF-452)
    # orders what :search finds: its 2 rows are the 2 watched tasks.
    {:ok, _view, html} = live(sign_in(conn, u1), "/")
    assert cells(html) == ["Bake", "Clean"]
    assert Enum.sort(picks(html)) == ["Bake", "Clean"]

    # A task the user does not watch, by its URL: its title, not its
    # project (the reference is hidden, so the group reads nothing).
    {:ok, _view, html} = live(sign_in(conn, u1), "/task/#{@t2}")
    assert html =~ "Title: Answer"
    refute html =~ "Apollo"
  end

  # WTF-457: a search constrained or sorted on a field some users may not
  # view (Note's Flagged: its owner only) runs for everyone, and finds only
  # the records where the user may view that field. Bubble matches the
  # stored value for every user who may search by it (it would find Bravo
  # too): stricter by the owner's decision (hidden_field_constraint_matches).
  test "a search on a field some users may not view finds only where they may", %{
    conn: conn,
    u1: u1
  } do
    require Ash.Query

    # The page's list (a search constrained on Flagged) is loaded: u1
    # finds the flagged note they own, not u2's (Bubble would list both);
    # logged out, nothing.
    data_access_on()
    {:ok, _view, html} = live(sign_in(conn, u1), "/")
    assert flagged(html) == ["Alpha"]

    {:ok, _view, html} = live(conn, "/")
    assert flagged(html) == []

    # The same through :search (what the user may find).
    u1 = actor(u1)

    # Unconstrained: everyone finds every note.
    all = PhxCheck.Note |> Ash.read!(action: :search, actor: u1) |> Enum.map(& &1.id)
    assert Enum.sort(all) == [@n1, @n2, @n3]

    # Constrained on Flagged: only the flagged note u1 owns, not u2's.
    found =
      PhxCheck.Note
      |> Ash.Query.filter(flagged == true)
      |> Ash.read!(action: :search, actor: u1)
      |> Enum.map(& &1.id)

    assert found == [@n1]

    # The negation does not reveal it either.
    refuted =
      PhxCheck.Note
      |> Ash.Query.filter(not (flagged == true))
      |> Ash.read!(action: :search, actor: u1)
      |> Enum.map(& &1.id)

    assert refuted == [@n3]

    # Sorted by it: only the notes whose Flagged u1 may view.
    sorted =
      PhxCheck.Note
      |> Ash.Query.sort(flagged: :asc)
      |> Ash.read!(action: :search, actor: u1)
      |> Enum.map(& &1.id)

    assert Enum.sort(sorted) == [@n1, @n3]

    # Logged out: nobody views Flagged, so nothing is found by it.
    assert PhxCheck.Note
           |> Ash.Query.filter(flagged == true)
           |> Ash.read!(action: :search, actor: nil) == []
  end

  # Review of #179: the other ways a read can name Note's hidden fields.
  # Under :omit the first assertion fails (u1 views u2's Owner there).
  test "a hidden field is guarded however a read names it", %{u1: u1} do
    require Ash.Query
    u1 = actor(u1)

    # u2's note by ID: its Title only.
    assert %Ash.ForbiddenField{} = Ash.get!(PhxCheck.Note, @n2, actor: u1).owner_id

    # Found by its Title (everyone), with its other fields hidden.
    [bravo] =
      PhxCheck.Note
      |> Ash.Query.filter(title == "Bravo")
      |> Ash.read!(action: :search, actor: u1)

    assert %Ash.ForbiddenField{} = bravo.owner_id
    assert %Ash.ForbiddenField{} = bravo.flagged

    ids = fn query -> query |> Ash.read!(action: :search, actor: u1) |> Enum.map(& &1.id) end

    # The gated belongs_to: its ID attribute, the relationship, and its
    # private twin (by path and through exists) reveal nothing of u2's.
    assert ids.(Ash.Query.filter(PhxCheck.Note, owner_id == ^@u2)) == []
    assert Enum.sort(ids.(Ash.Query.filter(PhxCheck.Note, owner_id == ^@u1))) == [@n1, @n3]
    assert ids.(Ash.Query.filter(PhxCheck.Note, owner.id == ^@u2)) == []
    assert ids.(Ash.Query.filter(PhxCheck.Note, owner_for_privacy.id == ^@u2)) == []

    assert ids.(Ash.Query.filter(PhxCheck.Note, exists(owner_for_privacy, id == ^@u2))) == []

    # is_nil and or: a record whose field u1 may not view matches nothing,
    # even where another branch would match it.
    assert ids.(Ash.Query.filter(PhxCheck.Note, is_nil(flagged))) == []

    assert Enum.sort(ids.(Ash.Query.filter(PhxCheck.Note, not is_nil(flagged)))) ==
             [@n1, @n3]

    assert ids.(Ash.Query.filter(PhxCheck.Note, title == "Bravo" or flagged == true)) == [@n1]

    # The page's count reads the same way.
    query = Ash.Query.filter(PhxCheck.Note, flagged == true)
    assert PhxCheckWeb.BubbleData.read(query, %{actor: u1}, :count, nil) == 1
    assert PhxCheckWeb.BubbleData.read(query, %{actor: nil}, :count, nil) == 0
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

  # WTF-492: what a "Display data" step shows is read again as the current
  # user: a workflow can never put into a group what the user may not read.
  test "Display data shows only what the current user may read", %{u1: u1} do
    data_access_on()
    Ash.Seed.seed!(PhxCheck.Memo, %{id: "1700000000000x400000000000000009", title: "Roadmap"})

    socket =
      %Phoenix.LiveView.Socket{transport_pid: self()}
      |> Phoenix.Component.assign(:current_user, u1)
      |> PhxCheckWeb.BubbleWorkflows.mount(ShownPage)

    {:noreply, socket} =
      PhxCheckWeb.BubbleWorkflows.handle_event(socket, ShownPage, "bubble:click", %{
        "scope" => "",
        "element" => "show"
      })

    # The page kept their unique IDs only.
    assert %{{"", "memo"} => {PhxCheck.Memo, false, _}, {"", "task"} => {PhxCheck.Task, false, _}} =
             socket.assigns.bubble_displayed

    # Not an admin: the memo reads as nothing.
    assert socket.assigns.bubble_data[{"", "memo"}] == nil

    # Not watching the task: its Title (everyone), nothing else.
    task = socket.assigns.bubble_data[{"", "task"}]
    assert task.title == "Answer"
    assert %Ash.ForbiddenField{} = task.done
  end

  @tag :tmp_dir
  test "private files follow the view attached files rule", %{
    conn: conn,
    u1: u1,
    u2: u2,
    u3: u3,
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

    # Nobody else may open it (everyone: no attachments): logged out, or
    # signed in without watching any task that holds it.
    assert response(get(conn, path), 404)
    assert response(get(sign_in(conn, u3), path), 404)

    # A file no record holds: nobody.
    other = String.duplicate("cd", 32)
    File.mkdir_p!(Path.join([root, "private", other]))
    File.write!(Path.join([root, "private", other, "x.txt"]), "orphan")
    assert response(get(sign_in(conn, u1), "/uploads/private/#{other}/x.txt"), 404)
  end
end
