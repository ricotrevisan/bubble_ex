defmodule PhxCheckWeb.HoverBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # "is hovered" conditionals lowered to the browser's hover (WTF-590),
  # from test/support/target/phoenix/hover.json (all data invented), run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/hover_behavior_test.exs, with a database). The server renders
  # what the page shows with nothing hovered and never hears of a hover;
  # the stylesheet the project serves holds the rules the browser applies
  # (scripts/hover_browser_check.sh hovers them in Chrome).
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

  defp stylesheet, do: File.read!("assets/css/bubble_residue.css")

  test "with nothing hovered: hover-shown elements hidden, their contents rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert tag(view, "bCardTools") =~ ~r/\shidden\b/
    assert html(view, "bCardTools") =~ ~s(data-bubble-id="bCardToolsText")
    assert tag(view, "bZeroShown") =~ ~r/\shidden\b/

    for id <- ~w(bCardTitle bCardDot bRow) do
      refute tag(view, id) =~ ~r/\shidden\b/, id
    end
  end

  test "no hover reaches the server: no event wired, no marker", %{conn: conn} do
    markers(true)
    {:ok, view, html} = live(conn, "/")

    refute html =~ ~r/phx-(mouse|hover|blur|focus)/

    for id <- ~w(bCardTitle bCardTools bCardDot bRow bZeroShown) do
      refute tag(view, id) =~ "data-bubble-dev-marker", id
    end
  end

  test "the stylesheet holds the hover rules" do
    css = stylesheet()

    assert css =~ ~s|[data-bubble-id="bCardTitle"]:where(:hover) {|

    assert css =~
             ~s|:where([data-bubble-id="bCard"]:hover) [data-bubble-id="bCardTools"][hidden] {|

    assert css =~
             ~s|:where([data-bubble-id="bCard"]:has([data-bubble-id="bCardTitle"]:hover)) [data-bubble-id="bCardDot"] {|

    assert css =~ ~s|[data-bubble-id="bRow"]:where(:has([data-bubble-id="bRowIcon"]:hover)) {|

    assert css =~
             ~s|:where([data-bubble-id="bZero"]:hover) [data-bubble-id="bZeroShown"][hidden] {|
  end
end
