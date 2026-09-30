defmodule PhxCheckWeb.IndexThingBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # An index page with a type of content (WTF-454): its thing's route is
  # /index/:bubble_thing and "Go to page" sends data to it and to the
  # current page. Lowered from test/support/target/phoenix/index_thing.json,
  # run by scripts/phoenix_compile_check.sh in the generated project (copied
  # to test/index_thing_behavior_test.exs, with a database).
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @t1 "1700000000000x300000000000000001"

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows) end)
    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    Ash.Seed.seed!(PhxCheck.Task, %{id: @t1, title: "Bake"})
    :ok
  end

  defp click(view, element),
    do: render_click(view, "bubble:click", %{"scope" => "", "element" => element})

  test "the index page reads its thing from /index/<unique id>", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/index/#{@t1}")
    assert html =~ "Index thing: Bake"

    {:ok, _view, html} = live(conn, "/")
    refute html =~ "Bake"

    # A query parameter is never the page's thing.
    {:ok, _view, html} = live(conn, "/?bubble_thing=#{@t1}")
    refute html =~ "Bake"
  end

  test "another page sends its thing to the index page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/task/#{@t1}")
    assert html =~ "Task: Bake"
    assert {:error, {:live_redirect, %{to: "/index/" <> @t1}}} = click(view, "bTaskHome")
  end

  test "the current page's thing stays under /index", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/index/#{@t1}")
    click(view, "bIdxSelf")
    assert_patch(view, "/index/#{@t1}")
    assert render(view) =~ "Index thing: Bake"
  end

  test "an empty thing sent to the current index page goes to /, never /index (review M2)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/index/#{@t1}")
    # Logged out: the current user is empty.
    click(view, "bIdxEmpty")
    assert_patch(view, "/")
    assert Process.alive?(view.pid)
    refute render(view) =~ "Bake"
  end

  test "a percent-encoded thing segment is still the route's segment", %{conn: conn} do
    # Sending data to the current page lands on the page's own path, never
    # on an unrouted one (push_patch would raise).
    for {path, button, expected} <- [
          {"/task/%2F%2Fevil.example", "bTaskSelf", "/task"},
          {"/task/a%20b", "bTaskSelf", "/task"},
          {"/task/%2E%2E", "bTaskSelf", "/task"},
          {"/index/%2F%2Fevil.example", "bIdxSelf", "/"},
          {"/index/a%20b", "bIdxEmpty", "/"}
        ] do
      {:ok, view, _html} = live(conn, path)
      click(view, button)
      assert_patch(view, expected)
      assert Process.alive?(view.pid), path
    end

    # Whatever `params` holds for it (decoded or not), the router decides.
    alias PhxCheckWeb.BubbleWorkflows
    socket = BubbleWorkflows.socket(PhxCheckWeb.TaskLive.Workflows)
    uri = "http://localhost/task/%2F%2Fevil.example"

    for value <- ["//evil.example", "%2F%2Fevil.example", "other"] do
      socket = BubbleWorkflows.handle_params(socket, %{"bubble_thing" => value}, uri)
      assert socket.assigns.bubble_page_path == "/task", value
    end
  end

  test "a query parameter named bubble_thing is no path segment (review M1)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/task?bubble_thing=task")
    click(view, "bTaskSelf")
    assert_patch(view, "/task")

    {:ok, view, _html} = live(conn, "/?bubble_thing=#{@t1}")
    click(view, "bIdxEmpty")
    assert_patch(view, "/")
    assert Process.alive?(view.pid)
  end
end
