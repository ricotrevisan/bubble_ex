defmodule BubbleEx.Target.Phoenix.SocketJoinTest do
  # WTF-554: a LiveView join slower than 2.5 s (a page's mount, its data
  # load and first render; the socket answers its heartbeat only after the
  # join) kept dropping the websocket: the generated app.js set
  # `longPollFallbackMs: 2500`, so Phoenix's client gave up on the
  # websocket and fell back to LongPoll, showing the error state. The
  # generated app.js, on Phoenix's own client in the pinned browser
  # (test/support/fidelity/socket-join.mjs), keeps it.
  use ExUnit.Case, async: true

  alias BubbleEx.Model

  @fixture "test/support/target/phoenix/page_data.json"

  defp app_js do
    app = @fixture |> File.read!() |> Jason.decode!()
    {:ok, model} = Model.build(app)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, files} = BubbleEx.Target.Phoenix.render(project, name: "Shop")
    files["assets/js/app.js"]
  end

  test "the generated LiveSocket sets no LongPoll fallback" do
    js = app_js()
    assert js =~ ~s|new LiveSocket("/live", Socket, {|
    refute js =~ ~r/^\s*longPollFallbackMs:/m
  end

  @tag :fidelity
  @tag :tmp_dir
  test "a join slower than 2.5 s keeps its websocket", %{tmp_dir: tmp} do
    path = Path.join(tmp, "app.js")
    File.write!(path, app_js())
    phoenix = Path.join(Mix.Project.deps_paths()[:phoenix], "priv/static/phoenix.mjs")

    {output, status} =
      System.cmd("node", ["test/support/fidelity/socket-join.mjs", phoenix, path],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "PASS control"
    assert output =~ "PASS generated"
  end
end
