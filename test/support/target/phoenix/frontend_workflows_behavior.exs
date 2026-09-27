defmodule PhxCheckWeb.FrontendWorkflowsBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Behavior of the page workflows lowered from
  # test/support/target/phoenix/frontend_workflows.json (WTF-372), run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/frontend_workflows_behavior_test.exs, with a database).
  use PhxCheckWeb.ConnCase, async: false

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
    atoms = :erlang.system_info(:atom_count)

    # An element or scope the page does not render, a workflow's own ID,
    # a disabled or browser-run workflow's element, an untracked input,
    # a value that is not text, an unknown event.
    click(view, "bBtnState", "bInst9")
    click(view, "no-such-element-#{System.unique_integer()}")
    click(view, "wState")
    click(view, "bBtnOpen")
    change(view, "bLabel", "x")
    change(view, "bIn", %{"nested" => "x"})
    render_click(view, "bubble:anything", %{"workflow" => "wData"})
    render_click(view, "bubble:click", %{"element" => ["bBtnState"]})

    assert label(view) =~ "Label: start"
    assert Process.alive?(view.pid)
    assert :erlang.system_info(:atom_count) == atoms
  end
end
