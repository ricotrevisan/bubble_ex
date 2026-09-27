defmodule PhxCheckWeb.FrontendWorkflowsBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Behavior of the page workflows lowered from
  # test/support/target/phoenix/frontend_workflows.json (WTF-372), run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/frontend_workflows_behavior_test.exs, with a database).
  use PhxCheckWeb.ConnCase, async: false

  use Oban.Testing, repo: PhxCheck.Repo

  import Phoenix.LiveViewTest

  defp change(view, element, value, scope \\ "") do
    render_change(view, "bubble:change", %{
      "bubble" => %{"scope" => scope, "element" => element, "value" => value}
    })
  end

  defp click(view, element, scope \\ ""),
    do: render_click(view, "bubble:click", %{"scope" => scope, "element" => element})

  defp label(view), do: view |> element(~s([data-bubble-id="bLabel"])) |> render()

  defp count(view, scope) do
    view
    |> element(~s([data-bubble-scope="#{scope}"] [data-bubble-id="bCardCount"]))
    |> render()
  end

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)
  end

  test "custom states start at their defaults; page load runs", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Label: start"
    assert html =~ "Loaded: no"
    assert render(view) =~ "Loaded: yes"
  end

  test "an input change is kept per element; a click sets a state from it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert change(view, "bIn", "Ann") =~ "Typed: Ann"
    assert click(view, "bBtnState") =~ "Label: Ann"
  end

  test "a conditional element step is pushed to the browser only when its condition holds",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    click(view, "bBtnState")
    refute_push_event(view, "bubble:exec", _)

    change(view, "bCheck", "true")
    click(view, "bBtnState")

    assert_push_event(view, "bubble:exec", %{
      ops: [%{op: "show", to: ~s([data-bubble-id="bFocus"])}]
    })
  end

  test "an input change runs its workflow; a condition-true workflow fires", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    change(view, "bNum", "2")
    assert label(view) =~ "Label: start"
    change(view, "bNum", "10")
    assert label(view) =~ "Label: big"
  end

  test "a custom event runs with its parameters", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert click(view, "bBtnCall") =~ "Label: called"
  end

  test "a workflow with a step that was not lowered runs no step at all", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    click(view, "bBtnResidue")
    assert label(view) =~ "Label: start"
  end

  test "a workflow calling a custom event that was not lowered runs no step", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    click(view, "bBtnCallee")
    assert label(view) =~ "Label: start"
  end

  test "data access is off by default: a data workflow runs no step", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    change(view, "bIn", "A note")
    click(view, "bBtnData")
    assert label(view) =~ "Label: start"
    assert Ash.read!(PhxCheck.Note, authorize?: false) == []
  end

  test "with the opt-in, a data workflow creates the record", %{conn: conn} do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    {:ok, view, _html} = live(conn, "/")
    change(view, "bIn", "A note")
    assert click(view, "bBtnData") =~ "Label: saved"
    assert [%{title: "A note"}] = Ash.read!(PhxCheck.Note, authorize?: false)
  end

  test "a page schedules a backend workflow on the backend runtime, with the opt-in", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    click(view, "bBtnSchedule")
    refute_enqueued(worker: PhxCheck.Workflows.Scheduler)

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    click(view, "bBtnSchedule")

    assert_enqueued(
      worker: PhxCheck.Workflows.Scheduler,
      args: %{"workflow" => "wApiNote", "params" => %{"note" => "from the page"}}
    )
  end

  test "relationship loads in a data step and a step condition (review H2)", %{conn: conn} do
    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    {:ok, view, _html} = live(conn, "/")
    assert click(view, "bBtnRel") =~ "Label: Parent"

    notes = Ash.read!(PhxCheck.Note, authorize?: false)
    assert Enum.count(notes, &(&1.title == "Parent")) == 2
  end

  test "with data access off, a load reads nothing, even if a flag is wrong (review H1)" do
    alias PhxCheckWeb.BubbleWorkflows
    note = Ash.Seed.seed!(PhxCheck.Note, %{id: "1700000000000x100000000000000009", title: "x"})
    ctx = %BubbleWorkflows.Ctx{now: DateTime.utc_now()}
    assert BubbleWorkflows.load(note, [["parent"]], ctx) == nil
    assert BubbleWorkflows.load(note, [], ctx) == note

    assert {:halt, {:error, :data_access_disabled}, _} =
             BubbleWorkflows.backend(ctx, fn _run -> flunk("the backend step ran") end)
  end

  test "a scheduled custom event continues its run's budget; a self-scheduling chain ends" do
    alias PhxCheckWeb.BubbleWorkflows
    socket = BubbleWorkflows.socket(PhxCheckWeb.IndexLive.Workflows)

    ctx = %BubbleWorkflows.Ctx{
      now: DateTime.utc_now(),
      backend: PhxCheck.Workflows.Runtime.root(nil, nil)
    }

    ctx = %{ctx | backend: %{ctx.backend | calls: 1}}

    assert {:cont, ctx} =
             BubbleWorkflows.schedule_custom(
               ctx,
               "s1",
               PhxCheckWeb.IndexLive.Workflows,
               "wEvt",
               [],
               0,
               %{}
             )

    # The budget is spent: the next schedule fails instead of spinning.
    assert {:halt, {:error, {"s2", {:call_budget_exhausted, "wEvt"}}}, _} =
             BubbleWorkflows.schedule_custom(
               ctx,
               "s2",
               PhxCheckWeb.IndexLive.Workflows,
               "wEvt",
               [],
               0,
               %{}
             )

    # An unsafe URL fails its step (backslashes, control characters).
    for url <- ["/\\evil.example", "https://ok.example/\nx", "javascript:alert(1)"] do
      assert {:halt, {:error, {"u", {:unsafe_url, _}}}, _} =
               BubbleWorkflows.open_url(ctx, "u", url, false)
    end

    # A message without a well-formed budget is ignored.
    assert {:noreply, ^socket} =
             BubbleWorkflows.handle_info(
               socket,
               PhxCheckWeb.IndexLive.Workflows,
               {:bubble, :run, "", PhxCheckWeb.IndexLive.Workflows, "wEvt", %{}, %{calls: -1}}
             )
  end

  # WTF-421: "when flip is yes: set flip to no; schedule re-arm in 0s",
  # where re-arm sets flip back to yes. The condition-true runs inherit the
  # budget and chain of the run that fired them, so the loop spends one
  # call per round and ends; before, each got a fresh root budget and it
  # spun forever (about 900 runs a second).
  test "a condition-true loop through a scheduled custom event ends (WTF-421)", %{conn: conn} do
    Application.put_env(:phx_check, PhxCheck.Workflows, max_calls: 25)
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheck.Workflows) end)

    {:ok, view, _html} = live(conn, "/")
    click(view, "bBtnFlip")

    spins = settled_spins(view, nil, 200)
    assert spins > 1 and spins <= 25

    # Nothing is left running: the count stays where it stopped.
    Process.sleep(100)
    assert spins(view) == spins
    assert Process.alive?(view.pid)
  end

  defp spins(view) do
    [_, n] =
      Regex.run(~r/Spins: (\d+)/, view |> element(~s([data-bubble-id="bSpins"])) |> render())

    String.to_integer(n)
  end

  # The spin count once it stops changing (a round is a 0 ms message).
  defp settled_spins(_view, _last, 0), do: flunk("the loop did not end")

  defp settled_spins(view, last, tries) do
    Process.sleep(20)

    case spins(view) do
      ^last -> last
      n -> settled_spins(view, n, tries - 1)
    end
  end

  test "an oversized input value is ignored; stray messages do not crash the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    change(view, "bIn", String.duplicate("a", 100_001))
    refute render(view) =~ "aaaa"
    send(view.pid, :unexpected)
    send(view.pid, {:bubble, :run, "", :nope, "x", %{}, nil})
    assert render(view) =~ "Label: start"
  end

  test "custom states are kept per reusable-element instance", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    click(view, "bCardInc", "bInst1")
    click(view, "bCardInc", "bInst1")
    click(view, "bCardInc", "bInst2")
    assert count(view, "bInst1") =~ "Count: 2"
    assert count(view, "bInst2") =~ "Count: 1"

    # The page triggers the first instance's custom event.
    click(view, "bBtnReset")
    assert count(view, "bInst1") =~ "Count: 0"
    assert count(view, "bInst2") =~ "Count: 1"
  end

  test "resetting an instance's inputs resets them in the page and the browser", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")
    change(view, "bCardNote", "hi", "bInst1")
    change(view, "bCardNote", "there", "bInst2")

    echo =
      &(view |> element(~s([data-bubble-scope="#{&1}"] [data-bubble-id="bCardEcho"])) |> render())

    assert echo.("bInst1") =~ "Note: hi"

    click(view, "bBtnReset")
    assert echo.("bInst1") =~ "Note: </p>"
    assert echo.("bInst2") =~ "Note: there"

    assert_push_event(view, "bubble:exec", %{
      ops: [%{op: "reset", to: ~s([data-bubble-scope="bInst1"])}]
    })
  end

  test "go to page and change the current page's URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert {:error, {:live_redirect, %{to: "/other?q=hello"}}} = click(view, "bBtnNav")

    {:ok, view, _html} = live(conn, "/?keep=1")
    click(view, "bBtnUrl")
    assert_patch(view, "/?keep=1&tab=two")
  end

  test "element-only workflows run in the browser: the element carries the commands",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    open = view |> element(~s([data-bubble-id="bBtnOpen"])) |> render()
    assert open =~ "bubble:show"
    refute open =~ "bubble:click"

    card =
      view
      |> element(~s([data-bubble-scope="bInst2"] [data-bubble-id="bCardOpen"]))
      |> render()

    assert card =~ "bubble:show"
    assert card =~ "bInst2"
  end

  test "the browser cannot trigger anything the page does not list", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # An element or scope the page does not render, a workflow's own ID,
    # a disabled or browser-run workflow's element, an untracked input,
    # a value that is not text, an unknown event. Run once first: loading
    # code (the page data loader, WTF-420) creates atoms of its own.
    hostile = fn ->
      click(view, "bBtnState", "bInst9")
      click(view, "no-such-element-#{System.unique_integer()}")
      click(view, "wState")
      click(view, "bBtnOpen")
      change(view, "bLabel", "x")
      change(view, "bIn", %{"nested" => "x"})
      render_click(view, "bubble:anything", %{"workflow" => "wData#{System.unique_integer()}"})
      render_click(view, "bubble:click", %{"element" => ["bBtnState"]})
    end

    hostile.()
    atoms = :erlang.system_info(:atom_count)
    hostile.()

    assert label(view) =~ "Label: start"
    assert Process.alive?(view.pid)
    assert :erlang.system_info(:atom_count) == atoms
  end
end
