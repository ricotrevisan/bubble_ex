defmodule PhxCheckWeb.PluginStatesBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # A plugin element's states, lowered from
  # test/support/target/phoenix/plugin_states.json (all data invented), run
  # by scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/plugin_states_behavior_test.exs, with a database). The plugin
  # element is not migrated, so nothing holds its states: a text reading
  # one renders empty in production and is marked in dev, a visibility
  # conditional reading one keeps the page-load visibility, and a click
  # whose condition reads one is refused. None is read as empty.
  use PhxCheckWeb.ConnCase, async: false

  # `live/2` waits for the first load (WTF-559, behavior_helpers.exs).
  use PhxCheckWeb.BubbleBehavior

  setup do
    on_exit(fn -> Application.delete_env(:phx_check, :bubble_dev_markers) end)
    :ok
  end

  defp markers(on), do: Application.put_env(:phx_check, :bubble_dev_markers, on)

  defp html(view, id), do: view |> element(~s([data-bubble-id="#{id}"])) |> render()

  defp tag(view, id) do
    [open] = Regex.run(~r/\A<[^>]*>/s, html(view, id))
    open
  end

  defp text(view, id) do
    view
    |> html(id)
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  test "markers off: the state's text is empty and the conditional keeps the page-load visibility",
       %{conn: conn} do
    markers(false)
    {:ok, view, _html} = live(conn, "/")

    assert html(view, "bTimerStatus") =~
             ~r/\A<p data-bubble-id="bTimerStatus" class="[^"]*"><\/p>\z/

    assert text(view, "bTimerShown") == "Running"
    refute tag(view, "bTimerShown") =~ ~r/\shidden/
    assert text(view, "bTimerUndeclared") == "Undeclared"
    assert tag(view, "bTimer") =~ ~s(data-bubble-placeholder="plugin")
    # "isn't clickable" reading the state: disabled (fail closed).
    assert tag(view, "bTimerStop") =~ ~r/\sdisabled/
    # A conditional that only sets the page-load visibility.
    assert text(view, "bTimerAlways") == "Always"
    refute tag(view, "bTimerAlways") =~ ~r/\shidden/

    for id <- ~w(bTimerStatus bTimerShown bPlain) do
      refute tag(view, id) =~ "data-bubble-dev-marker", id
      refute tag(view, id) =~ "title=", id
    end
  end

  test "markers on: the state's text is marked and says why", %{conn: conn} do
    markers(true)
    {:ok, view, _html} = live(conn, "/")

    open = tag(view, "bTimerStatus")
    assert open =~ "data-bubble-dev-marker"

    assert open =~
             ~s(title="Text not migrated: reads the state of a plugin element, which is not migrated")

    assert text(view, "bTimerStatus") == "Status:"
    refute tag(view, "bPlain") =~ "data-bubble-dev-marker"
  end

  test "a click whose condition reads the plugin element's state is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert text(view, "bLabel") == "start"

    view |> element(~s([data-bubble-id="bGo"])) |> render_click()

    assert text(view, "bLabel") == "start"
  end
end
