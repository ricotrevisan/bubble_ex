defmodule PhxCheckWeb.AnimateBehaviorTest do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  # Bubble's "Animate an element" lowered for Phoenix (WTF-603), from
  # test/support/target/phoenix/animate.json (all data invented), run by
  # scripts/phoenix_compile_check.sh in the generated project (copied to
  # test/animate_behavior_test.exs, with a database). A transition shows or
  # hides its element as a show or hide step does, with Velocity UI's
  # motion run by the page's hook (test/support/fidelity/animate-hook.mjs
  # runs that part in Chrome); a callout only moves it.
  use PhxCheckWeb.ConnCase, async: false

  # `live/2` waits for the first load (WTF-559, behavior_helpers.exs).
  use PhxCheckWeb.BubbleBehavior

  defp click(view, element),
    do: render_click(view, "bubble:click", %{"scope" => "", "element" => element})

  defp html(view, id), do: view |> element(~s([data-bubble-id="#{id}"])) |> render()

  # The JS commands of an element's `phx-click`.
  defp commands(view, id) do
    [_, encoded] = Regex.run(~r/phx-click="([^"]*)"/, html(view, id))

    encoded
    |> String.replace("&quot;", ~s("))
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&#39;", "'")
    |> Jason.decode!()
  end

  test "a clicked exit runs in the browser: its transition and motion, no round trip",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert [["dispatch", fade]] = commands(view, "bBtnFade")

    assert %{
             "event" => "bubble:animate",
             "to" => ~s([data-bubble-id="bPanel"]),
             "detail" => %{
               "visibility" => "hide",
               "motion" => %{
                 "duration" => 300,
                 "easing" => "ease",
                 "frames" => [%{"opacity" => 1}, %{"opacity" => 0}]
               }
             }
           } = fade

    # A callout leaves the visibility alone; its duration is Velocity's
    # default when the step does not customize it.
    assert [["dispatch", %{"event" => "bubble:animate", "detail" => shake}]] =
             commands(view, "bBtnShake")

    assert %{"visibility" => nil, "motion" => %{"duration" => 800, "frames" => frames}} = shake
    assert Enum.map(frames, & &1["translate_x"]) == [0, -11, 11, -11, 11, -11, 11, -11, 0]

    # The panel is rendered shown; only the browser hides it.
    refute html(view, "bPanel") =~ ~r/<div[^>]*\shidden/
  end

  test "a server-side workflow's entrance is pushed to the hook after its other steps",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert html(view, "bDrawer") =~ ~r/<div[^>]*\shidden/

    assert click(view, "bBtnSlide") =~ "Count: 1"

    assert_push_event(view, "bubble:exec", %{
      ops: [
        %{
          op: "animate",
          to: ~s([data-bubble-id="bDrawer"]),
          visibility: "show",
          motion: %{
            duration: 400,
            easing: "ease",
            frames: [%{opacity: 0, translate_x: 20}, %{opacity: 1, translate_x: 0}]
          }
        }
      ]
    })
  end

  test "an entrance opens a popup rendered only while open, its contents in the same event",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    refute html =~ ~s(data-bubble-id="bPopText")

    html = click(view, "bBtnPop")
    assert html =~ "Count: 2"
    assert html =~ ~s(data-bubble-id="bPopText")
    assert html(view, "bPop") =~ "data-bubble-loaded"

    assert_push_event(view, "bubble:exec", %{
      ops: [%{op: "animate", to: ~s([data-bubble-id="bPop"]), visibility: "show"}]
    })
  end

  test "an effect bubble_ex does not lower refuses its workflow before any step",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    click(view, "bBtnFlip")
    assert_push_event(view, "bubble:notice", %{text: "This action isn't available yet."})
    refute_push_event(view, "bubble:exec", _)
  end
end
