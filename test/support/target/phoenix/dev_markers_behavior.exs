defmodule PhxCheckWeb.DevMarkersBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # WTF-520: elements whose dynamic value is left out, lowered from
  # test/support/target/phoenix/dev_markers.json (all data invented), run
  # by scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/dev_markers_behavior_test.exs, with a database), with privacy:
  # :omit and :enforced. A value that reads data the page does not load, or
  # whose expression does not compile, renders empty (a text mixing literal
  # parts keeps them), as in production; with the developer markers on the
  # element is marked and its tooltip says why.
  use PhxCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # Element ID => the tooltip with the markers on.
  @marked %{
    "bBoxTitle" => "Text not migrated: reads data that is not loaded",
    "bBoxPartial" => "Text not migrated: reads data that is not loaded",
    "bBoxPhoto" => "Image source not migrated: reads data that is not loaded",
    "bBroken" => "Text not migrated: expression does not compile",
    "bBrokenPartial" => "Text not migrated: expression does not compile",
    "bInput" =>
      "Placeholder not migrated: expression does not compile; " <>
        "Value not migrated: expression does not compile",
    "bButton" => "Label not migrated: expression does not compile",
    "bImage" => "Image source not migrated: expression does not compile",
    "bLink" => "Link not migrated: expression does not compile",
    "bAvatar" =>
      "Image source not migrated: not one image or file value; " <>
        "Alt text not migrated: dynamic value not lowered"
  }

  setup do
    on_exit(fn ->
      Application.delete_env(:phx_check, PhxCheckWeb.BubbleWorkflows)
      Application.delete_env(:phx_check, :bubble_dev_markers)
    end)

    Application.put_env(:phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true)
    :ok
  end

  defp markers(on), do: Application.put_env(:phx_check, :bubble_dev_markers, on)

  defp html(view, id), do: view |> element(~s([data-bubble-id="#{id}"])) |> render()

  # The element's opening tag.
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

  # What production shows: empty values, literal parts kept, no tooltip.
  defp assert_values(view) do
    assert text(view, "bBoxTitle") == ""
    assert text(view, "bBoxPartial") == "Title:"
    assert text(view, "bBroken") == ""
    assert text(view, "bBrokenPartial") == "Hello !"
    assert text(view, "bButton") == "Open"
    assert text(view, "bLink") == "Docs"
    assert text(view, "bPlain") == "Plain"

    refute tag(view, "bInput") =~ "placeholder="
    refute tag(view, "bInput") =~ "value="
    refute tag(view, "bLink") =~ "href="
    refute tag(view, "bImage") =~ ~r/\ssrc=/
    refute tag(view, "bBoxPhoto") =~ ~r/\ssrc=/
    refute tag(view, "bAvatar") =~ ~r/\ssrc=/
  end

  test "markers off (production): the values left out render as before, unmarked", %{conn: conn} do
    markers(false)
    {:ok, view, _html} = live(conn, "/")
    assert_values(view)

    for id <- ["bPlain" | Map.keys(@marked)] do
      refute tag(view, id) =~ "title=", id
      refute tag(view, id) =~ "data-bubble-dev-marker", id
      refute tag(view, id) =~ "data-bubble-dev-note", id
    end
  end

  test "markers on: each element left out is marked and says why; the rest is unchanged", %{
    conn: conn
  } do
    markers(true)
    {:ok, view, _html} = live(conn, "/")
    assert_values(view)

    for {id, why} <- @marked do
      open = tag(view, id)
      assert open =~ "data-bubble-dev-marker", id
      assert open =~ "data-bubble-dev-note", id
      assert open =~ ~s(title="#{why}"), id
      # Its layout box is kept: never a placeholder.
      refute open =~ "data-bubble-placeholder", id
    end

    refute tag(view, "bPlain") =~ "data-bubble-dev-marker"
    refute tag(view, "bPlain") =~ "title="
  end
end
