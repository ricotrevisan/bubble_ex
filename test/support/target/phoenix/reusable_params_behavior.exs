defmodule PhxCheckWeb.ReusableParamsBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Reusable element properties (WTF-493), lowered from
  # test/support/target/phoenix/reusable_params.json, run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/reusable_params_behavior_test.exs, with a database), with
  # privacy: :omit and :enforced.
  #
  # The page `task` renders two instances of the reusable element Card:
  # bCardA sets every property but Note (static text, yes/no and number
  # values, the page's thing, a search, the thing's date), bCardB only
  # static ones; Card shows them in texts, conditions, a group's data
  # source, a nested reusable's property and a workflow.
  #
  # WTF-494: the repeating group bList renders the reusable element Row
  # (bRowC) once per cell, in the cell's scope (`bList~2<task id>-bRowC`):
  # its thing and properties are the cell's task's, its workflows and
  # "Display data" steps act on that cell only, and the cells are read
  # together (Card's bCardC is not rendered per cell: Card searches with
  # its instance's property).
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @u1 "1700000000000x100000000000000001"
  @p1 "1700000000000x200000000000000001"
  @t1 "1700000000000x300000000000000001"
  @t2 "1700000000000x300000000000000002"
  @t3 "1700000000000x300000000000000003"
  @t4 "1700000000000x300000000000000004"

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)
    user = Ash.Seed.seed!(PhxCheck.User, %{id: @u1, email: "one@example.com"})
    Ash.Seed.seed!(PhxCheck.Project, %{id: @p1, name: "Apollo"})

    Ash.Seed.seed!(PhxCheck.Task, %{
      id: @t1,
      title: "Alpha",
      owner_id: @u1,
      project_id: @p1,
      due: ~U[2026-10-01 12:00:00.000000Z]
    })

    Ash.Seed.seed!(PhxCheck.Task, %{id: @t2, title: "Bravo"})
    %{user: user}
  end

  # With privacy: :enforced a task is visible (and findable) only to its
  # owner; everyone else sees nothing of it.
  defp enforced? do
    privacy = Module.concat(PhxCheck, Privacy)

    Code.ensure_loaded?(privacy) and function_exported?(privacy, :mode, 0) and
      apply(privacy, :mode, []) == :enforced
  end

  defp data_access_on,
    do: Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(
      Ash.Resource.put_metadata(user, :token, token)
    )
  end

  defp text(view, scope, id) do
    view
    |> element(~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"]))
    |> render()
    |> then(&Regex.replace(~r/<[^>]*>/, &1, ""))
    |> String.trim()
  end

  defp hidden?(view, scope, id) do
    html =
      view |> element(~s([data-bubble-scope="#{scope}"] [data-bubble-id="#{id}"])) |> render()

    [open] = Regex.run(~r/\A<[^>]*>/s, html)
    open =~ ~r/\shidden(\s|>|=)/
  end

  test "an instance's values: static, expressions, defaults, a nested reusable's",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")

    assert text(view, "bCardA", "bTitle") == "Title: Hello A"
    # Not set: its default.
    assert text(view, "bCardA", "bNote") == "Note: Default note"
    assert text(view, "bCardA", "bHeading") == "Heading: Custom heading"
    assert text(view, "bCardA", "bCount") == "Count: 3"
    # A thing, read where the instance is (the page's thing).
    assert text(view, "bCardA", "bTaskT") == "Task: Alpha"
    # A list of things: a search, with the actor's policies.
    assert text(view, "bCardA", "bTasksN") == "Tasks: #{if enforced?(), do: 1, else: 2}"
    refute hidden?(view, "bCardA", "bFlagT")
    # A date, in a condition.
    refute hidden?(view, "bCardA", "bDueSet")
    # A group whose data source is the property.
    assert text(view, "bCardA", "bGroupT") == "Group: Alpha"
    # A nested reusable's property, set from this one's.
    assert text(view, "bCardA-bBadge", "bBadgeT") == "Badge: Alpha"

    assert text(view, "bCardB", "bTitle") == "Title: Hello B"
    assert text(view, "bCardB", "bNote") == "Note: Given B"
    # A default reading another property.
    assert text(view, "bCardB", "bHeading") == "Heading: Re: Hello B"
    assert text(view, "bCardB", "bCount") == "Count: 7"
    # Not set, no default: empty.
    assert text(view, "bCardB", "bTaskT") == "Task:"
    assert hidden?(view, "bCardB", "bFlagT")
    assert hidden?(view, "bCardB", "bDueSet")
    assert text(view, "bCardB-bBadge", "bBadgeT") == "Badge:"

    # Read from outside the instance.
    assert view |> element(~s([data-bubble-id="bOutside"])) |> render() =~ "Outside: Hello A"

    # An instance that sets no value of a property: its default, computed
    # in the instance (here reading its Title), read from outside too.
    assert view |> element(~s([data-bubble-id="bOutsideDefault"])) |> render() =~
             "Outside default: Re: Hello B"

    [open] =
      Regex.run(
        ~r/\A<[^>]*>/s,
        view |> element(~s([data-bubble-id="bOutsideShown"])) |> render()
      )

    refute open =~ ~r/\shidden(\s|>|=)/

    # From inside another reusable: Card reads its nested Badge's default.
    assert text(view, "bCardA", "bInnerDefault") == "Inner default: Badge task"
    assert text(view, "bCardB", "bInnerDefault") == "Inner default: Badge task"

    # From a repeating group's cell, an instance outside the list.
    html = render(view)
    cells = length(Regex.scan(~r/data-bubble-id="bCellOutside"/, html))
    assert cells > 0
    assert length(Regex.scan(~r/Cell outside: Re: Hello B/, html)) == cells
  end

  test "properties nest: a reusable two levels down takes its default; IDs are per reusable",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")

    assert text(view, "bCardA-bBadge-bChip", "bChipT") == "Chip: Chip default"
    assert text(view, "bCardB-bBadge-bChip", "bChipT") == "Chip: Chip default"
    # Badge's own Task (text) is not Card's Task (a thing) of the same ID.
    assert text(view, "bCardA-bBadge", "bBadgeTask") == "Badge task: Badge task"
    # A relationship read through Card's Task.
    assert text(view, "bCardA", "bProject") == "Project: Apollo"
  end

  test "typing into an input a property reads re-reads what reads the property",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    assert text(view, "bCardA", "bQueryT") == "Query:"
    # An empty constraint value matches nothing (WTF-478).
    assert text(view, "bCardA", "bFoundT") == "Found:"

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "Alp", "on" => "blur"}
    })

    Process.sleep(250)
    assert text(view, "bCardA", "bQueryT") == "Query: Alp"
    assert text(view, "bCardA", "bFoundT") == "Found: Alpha"
    # bCardB sets no Query: unchanged.
    assert text(view, "bCardB", "bQueryT") == "Query:"
    assert text(view, "bCardB", "bTitle") == "Title: Hello B"
  end

  test "a workflow inside the reusable reads its instance's value", %{conn: conn} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/task/#{@t1}")

    render_click(view, "bubble:click", %{"scope" => "bCardA", "element" => "bBump"})
    assert text(view, "bCardA", "bN") == "N: 4"
    assert text(view, "bCardB", "bN") == "N:"

    render_click(view, "bubble:click", %{"scope" => "bCardB", "element" => "bBump"})
    assert text(view, "bCardB", "bN") == "N: 8"
  end

  test "Display data sets an instance's own thing, not its properties",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    assert text(view, "bCardB", "bOwn") == "Own:"

    render_click(view, "bubble:click", %{"scope" => "", "element" => "bShowB"})

    assert text(view, "bCardB", "bOwn") == "Own: Alpha"
    # Its properties stay the values the page computed for it.
    assert text(view, "bCardB", "bTitle") == "Title: Hello B"
    assert text(view, "bCardB", "bTaskT") == "Task:"
    assert text(view, "bCardB", "bGroupT") == "Group:"
    assert text(view, "bCardA", "bOwn") == "Own:"
  end

  test "a thing property is read with the actor's policies", %{conn: conn} do
    data_access_on()
    {:ok, view, _html} = live(conn, "/task/#{@t1}")

    if enforced?() do
      assert text(view, "bCardA", "bTaskT") == "Task:"
      assert text(view, "bCardA", "bTasksN") == "Tasks: 0"
      assert text(view, "bCardA", "bGroupT") == "Group:"
      assert text(view, "bCardA-bBadge", "bBadgeT") == "Badge:"
      assert hidden?(view, "bCardA", "bDueSet")
    else
      assert text(view, "bCardA", "bTaskT") == "Task: Alpha"
      assert text(view, "bCardA", "bTasksN") == "Tasks: 2"
      assert text(view, "bCardA", "bGroupT") == "Group: Alpha"
      refute hidden?(view, "bCardA", "bDueSet")
    end

    # Static values do not depend on the user.
    assert text(view, "bCardA", "bTitle") == "Title: Hello A"
  end

  test "without data access, no property is loaded", %{conn: conn, user: user} do
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t2}")
    assert text(view, "bCardA", "bTitle") == "Title:"
    assert text(view, "bCardB", "bNote") == "Note:"
  end

  # --- WTF-494: a reusable instance in a repeating group's cell ---------------------------

  defp row(task), do: "bList~2#{task}-bRowC"

  defp states(view), do: :sys.get_state(view.pid).socket.assigns.bubble_states

  # The database queries `fun` makes (the page's own, in the LiveView).
  defp queries(fun) do
    counter = :counters.new(1, [])
    id = "bubble-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:phx_check, :repo, :query],
      fn _event, _measurements, _meta, c -> :counters.add(c, 1, 1) end,
      counter
    )

    try do
      {:ok, view, _html} = fun.()
      _ = render(view)
      :counters.get(counter, 1)
    after
      :telemetry.detach(id)
    end
  end

  test "an instance in a cell is the cell's: its thing, properties, default, nested reusable",
       %{conn: conn, user: user} do
    data_access_on()
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")

    # Computed in the cell: the cell's task.
    assert text(view, row(@t1), "bRowLabel") == "Label: Row: Alpha"
    assert text(view, row(@t1), "bRowOwn") == "Own: Alpha"
    # A relationship read through a property, loaded with the cells.
    assert text(view, row(@t1), "bRowProject") == "Project: Apollo"
    # A visibility conditional reading a property computed in the cell.
    refute hidden?(view, row(@t1), "bRowFlag")
    # Not set by the instance: its default, in the cell's scope.
    assert text(view, row(@t1), "bRowNote") == "Note: Row note"
    # A search that reads nothing of the instance.
    assert text(view, row(@t1), "bRowAnyT") == "Any: Apollo"
    # A reusable inside the cell's instance.
    assert text(view, row(@t1) <> "-bRowChip", "bChipT") == "Chip: Chip default"

    if enforced?() do
      # Not the user's task: no cell, no instance.
      refute has_element?(view, ~s([data-bubble-scope="#{row(@t2)}"]))
    else
      assert text(view, row(@t2), "bRowLabel") == "Label: Row: Bravo"
      assert text(view, row(@t2), "bRowProject") == "Project:"
      assert hidden?(view, row(@t2), "bRowFlag")
    end
  end

  test "a workflow in a cell's instance acts on that cell; a scope the page did not read is ignored",
       %{conn: conn, user: user} do
    data_access_on()
    Ash.Seed.seed!(PhxCheck.Task, %{id: @t3, title: "Charlie", owner_id: @u1})
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")

    render_click(view, "bubble:click", %{"scope" => row(@t1), "element" => "bRowPick"})
    assert text(view, row(@t1), "bRowPicked") == "Picked: Row: Alpha"
    assert text(view, row(@t3), "bRowPicked") == "Picked:"

    # "Display data" in the instance: that cell only.
    render_click(view, "bubble:click", %{"scope" => row(@t3), "element" => "bRowShow"})
    assert text(view, row(@t3), "bRowShownT") == "Shown: Charlie"
    assert text(view, row(@t1), "bRowShownT") == "Shown:"
    # "Display data" into the instance itself (its Page task, the page's
    # thing): its thing, in that cell only; its properties stay the cell's.
    render_click(view, "bubble:click", %{"scope" => row(@t3), "element" => "bRowSelf"})
    assert text(view, row(@t3), "bRowOwn") == "Own: Alpha"
    assert text(view, row(@t3), "bRowLabel") == "Label: Row: Charlie"
    assert text(view, row(@t1), "bRowOwn") == "Own: Alpha"

    # No due date: hidden in that cell; the other cell keeps its state.
    assert hidden?(view, row(@t3), "bRowFlag")
    assert text(view, row(@t1), "bRowPicked") == "Picked: Row: Alpha"

    # Scopes of no cell the page read: a task not in the list, the
    # template's, the instance's without a cell (and with policies, a task
    # the user may not find).
    before = states(view)
    shown = :sys.get_state(view.pid).socket.assigns.bubble_displayed
    crafted = [row("1700000000000x300000000000000099"), "bRowC", "bList-bRowC"]
    crafted = if enforced?(), do: [row(@t2) | crafted], else: crafted

    for scope <- crafted do
      render_click(view, "bubble:click", %{"scope" => scope, "element" => "bRowPick"})
      render_click(view, "bubble:click", %{"scope" => scope, "element" => "bRowShow"})
      render_click(view, "bubble:click", %{"scope" => scope, "element" => "bRowSelf"})
    end

    assert states(view) == before
    assert :sys.get_state(view.pid).socket.assigns.bubble_displayed == shown
    refute Enum.any?(Map.keys(states(view)), &(elem(&1, 0) in crafted))
  end

  test "typing into an input a cell's property reads re-reads it in every cell",
       %{conn: conn, user: user} do
    data_access_on()
    Ash.Seed.seed!(PhxCheck.Task, %{id: @t3, title: "Charlie", owner_id: @u1})
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    render_click(view, "bubble:click", %{"scope" => row(@t3), "element" => "bRowPick"})
    assert text(view, row(@t1), "bRowQuery") == "Query:"

    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => "bQuery", "value" => "Alp", "on" => "blur"}
    })

    Process.sleep(250)
    assert text(view, row(@t1), "bRowQuery") == "Query: Alp"
    assert text(view, row(@t3), "bRowQuery") == "Query: Alp"
    # The rest of the cell is as it was.
    assert text(view, row(@t3), "bRowPicked") == "Picked: Row: Charlie"
    assert text(view, row(@t3), "bRowLabel") == "Label: Row: Charlie"
  end

  test "the cells' instances are read together: three cells cost no more queries than one",
       %{conn: conn, user: user} do
    data_access_on()
    fewer = queries(fn -> live(sign_in(conn, user), "/task/#{@t1}") end)

    for {id, title} <- [{@t3, "Charlie"}, {@t4, "Delta"}],
        do: Ash.Seed.seed!(PhxCheck.Task, %{id: id, title: title, owner_id: @u1, project_id: @p1})

    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    # bList shows its first page, 3 rows.
    assert text(view, row(@t3), "bRowProject") == "Project: Apollo"
    assert view |> render() |> String.split(~s(data-bubble-id="bRowLabel")) |> length() == 4

    more = queries(fn -> live(sign_in(conn, user), "/task/#{@t1}") end)
    assert more == fewer
  end

  test "without data access, no cell and no instance in one", %{conn: conn, user: user} do
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    refute has_element?(view, ~s([data-bubble-scope="#{row(@t1)}"]))
    render_click(view, "bubble:click", %{"scope" => row(@t1), "element" => "bRowPick"})
    assert states(view) |> Map.keys() |> Enum.all?(&(elem(&1, 0) != row(@t1)))
  end

  defp type(view, element, value) do
    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => "", "element" => element, "value" => value, "on" => "blur"}
    })

    Process.sleep(250)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp with_data_config(config, fun) do
    before = Application.get_env(:phx_check, PhxCheckWeb.BubbleData, [])
    Application.put_env(:phx_check, PhxCheckWeb.BubbleData, Keyword.merge(before, config))

    try do
      fun.()
    after
      Application.put_env(:phx_check, PhxCheckWeb.BubbleData, before)
    end
  end

  test "a list an input changes reads its cells again; a cell that left it runs nothing",
       %{conn: conn, user: user} do
    data_access_on()
    Ash.Seed.seed!(PhxCheck.Task, %{id: @t3, title: "Charlie", owner_id: @u1})
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    module = PhxCheckWeb.Reusables.Row.Workflows
    budget = %{jobs: 1, calls: 1, chain: 0}

    frame = fn scope ->
      %{
        module: module,
        scope: scope,
        workflow: "wRowPick",
        at: 1,
        args: %{},
        steps: %{},
        call: nil,
        returns: nil
      }
    end

    # A scheduled run and a paused workflow's rest in a cell it shows run.
    send(view.pid, {:bubble, :run, row(@t3), module, "wRowPick", %{}, budget})
    assert text(view, row(@t3), "bRowPicked") == "Picked: Row: Charlie"
    send(view.pid, {:bubble, :resume, [frame.(row(@t1))], DateTime.utc_now(), budget})
    assert text(view, row(@t1), "bRowPicked") == "Picked: Row: Alpha"

    # The filter leaves Alpha only: the whole page reads again.
    type(view, "bFilter", "Alp")
    refute has_element?(view, ~s([data-bubble-scope="#{row(@t3)}"]))
    assert text(view, row(@t1), "bRowPicked") == "Picked: Row: Alpha"
    # What the page kept for Charlie's cell is gone.
    refute Enum.any?(Map.keys(assigns(view).bubble_states), &(elem(&1, 0) == row(@t3)))
    before = assigns(view).bubble_states

    # Its old scope: a click, a scheduled run, a paused workflow's rest.
    render_click(view, "bubble:click", %{"scope" => row(@t3), "element" => "bRowPick"})
    send(view.pid, {:bubble, :run, row(@t3), module, "wRowPick", %{}, budget})
    send(view.pid, {:bubble, :resume, [frame.(row(@t3))], DateTime.utc_now(), budget})
    _ = render(view)
    assert assigns(view).bubble_states == before

    # Back in the list: a new cell, its states from their defaults.
    type(view, "bFilter", "")
    assert text(view, row(@t3), "bRowPicked") == "Picked:"
    assert text(view, row(@t3), "bRowLabel") == "Label: Row: Charlie"
  end

  test "a list of texts: cells by position, duplicates included", %{conn: conn, user: user} do
    data_access_on()
    Ash.Seed.update!(Ash.get!(PhxCheck.Task, @t1, authorize?: false), %{tags: ~w(red blue red)})
    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    tag = fn i -> "bTags~2~3#{i}-bTagC" end

    assert Enum.map(1..3, &text(view, tag.(&1), "bTagT")) == ["Tag: red", "Tag: blue", "Tag: red"]
    refute has_element?(view, ~s([data-bubble-scope="#{tag.(4)}"]))

    render_click(view, "bubble:click", %{"scope" => tag.(3), "element" => "bTagPick"})
    assert text(view, tag.(3), "bTagPicked") == "Picked: red"
    assert text(view, tag.(1), "bTagPicked") == "Picked:"
  end

  test "instances in cells of an instance's own list; past the depth and scope caps none",
       %{conn: conn, user: user} do
    data_access_on()
    sub = row(@t1) <> "-bRowSubs~2#{@t1}-bSubChip"

    {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
    assert text(view, sub, "bChipT") == "Chip: Chip default"
    assert {sub, PhxCheckWeb.Reusables.Chip.Workflows} in assigns(view).bubble_cells

    # One level only: the instance in the cell is read, not those in its
    # own list's cells.
    with_data_config([max_cell_depth: 1], fn ->
      {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
      assert text(view, row(@t1), "bRowLabel") == "Label: Row: Alpha"
      assert text(view, sub, "bChipT") == "Chip:"
      refute Enum.any?(assigns(view).bubble_cells, &(elem(&1, 0) == sub))
    end)

    # At most 1 scope: the first cell's instance; logged once, not on every
    # read.
    with_data_config([max_cells: 1], fn ->
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, view, _html} = live(sign_in(conn, user), "/task/#{@t1}")
          assert [{scope, PhxCheckWeb.Reusables.Row.Workflows}] = assigns(view).bubble_cells
          assert scope == row(@t1)
          type(view, "bQuery", "x")
          type(view, "bQuery", "y")
        end)

      assert length(String.split(log, "are not read")) == 2
    end)
  end

  test "read together, a unique ID where a list is expected is read as one thing" do
    batch = %{batch: %{actor: nil, actor_paths: MapSet.new(), loaded: %{}}}

    assert PhxCheckWeb.BubbleData.records(batch, PhxCheck.Task, @t1, true, nil) ==
             {:bubble_ids, PhxCheck.Task, @t1, false, nil}

    assert PhxCheckWeb.BubbleData.records(batch, PhxCheck.Task, [@t1], true, 3) ==
             {:bubble_ids, PhxCheck.Task, [@t1], true, 3}
  end

  # A relationship read that fails reads as empty: never as the value
  # carried it before (the current user carries the relationships its
  # privacy policies read, loaded without authorization). The project
  # table is renamed inside the test's transaction (rolled back).
  test "a relationship read that fails fails closed, the current user's included" do
    data_access_on()
    # Loaded without authorization, as the current user's are.
    task = Ash.get!(PhxCheck.Task, @t1, authorize?: false)
    task = %{task | project: Ash.get!(PhxCheck.Project, @p1, authorize?: false)}
    assert task.project.name == "Apollo"
    Ecto.Adapters.SQL.query!(PhxCheck.Repo, ~s(ALTER TABLE "project" RENAME TO "project_off"))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # As the current user (the actor itself), and as any value.
        assert PhxCheckWeb.BubbleData.load_value(task, [["project"]], %{actor: task}).project ==
                 nil

        assert PhxCheckWeb.BubbleData.load_value(task, [["project"]], %{actor: nil}).project ==
                 nil

        # Read for every cell together: the batch's copy is read again too.
        batch = %{actor: nil, batch: %{actor: nil, actor_paths: MapSet.new(), loaded: %{}}}
        assert PhxCheckWeb.BubbleData.load_value(task, [["project"]], batch).project == nil

        assert [%{project: nil}] =
                 PhxCheck.Workflows.Runtime.load_page(
                   [task],
                   [["project"]],
                   PhxCheck.Workflows.Runtime.root(nil, nil),
                   10
                 )

        assert %{project: nil} =
                 PhxCheck.Workflows.Runtime.load(
                   task,
                   [["project"]],
                   PhxCheck.Workflows.Runtime.root(nil, nil)
                 )
      end)

    assert log =~ "a relationship load failed; its relationships read as empty"
  end
end
