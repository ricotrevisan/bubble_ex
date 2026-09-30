defmodule Mix.Tasks.Bubble.FetchAssetsTest do
  # `mix bubble.fetch_assets` (WTF-447) against a fake server (Req.Test).
  use ExUnit.Case, async: false

  alias BubbleEx.Frontend.StaticAssets
  alias BubbleEx.HTTP

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      HTTP.delete_process_options()
      Mix.shell(shell)
    end)

    :ok
  end

  @tag :tmp_dir
  test "writes the store of an app JSON file", %{tmp_dir: tmp} do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, {:requested, conn.host})

      conn
      |> Plug.Conn.put_resp_content_type("image/png", nil)
      |> Plug.Conn.send_resp(200, @png)
    end)

    app = Path.join(tmp, "app.json")
    store = Path.join(tmp, "store")
    File.cp!("test/support/target/phoenix/static_assets.json", app)

    Mix.Tasks.Bubble.FetchAssets.run([app, "--store", store])

    assert_received {:mix_shell, :info, [summary]}
    assert summary =~ "5 fetched"
    assert summary =~ "5 on other hosts"
    assert summary =~ "1 icon libraries (need --app-url)"

    hosts = Stream.repeatedly(fn -> receive do: ({:requested, h} -> h), after: (0 -> nil) end)
    hosts = hosts |> Enum.take_while(& &1) |> Enum.uniq() |> Enum.sort()
    assert hosts == ["a1b2c3d4e5f6.cdn.bubble.io", "s3.amazonaws.com"]

    assert {:ok, %{entries: entries, errors: []}} = StaticAssets.load_store(store)
    assert map_size(entries) == 5
  end

  test "requires a store directory" do
    assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Bubble.FetchAssets.run(["app.json"]) end
  end
end
