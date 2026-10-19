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
    assert summary =~ "5 on other hosts (linked)"
    assert summary =~ "1 icon libraries (need --app-url)"

    hosts = Stream.repeatedly(fn -> receive do: ({:requested, h} -> h), after: (0 -> nil) end)
    hosts = hosts |> Enum.take_while(& &1) |> Enum.uniq() |> Enum.sort()
    assert hosts == ["a1b2c3d4e5f6.cdn.bubble.io", "s3.amazonaws.com"]

    assert {:ok, %{entries: entries, errors: []}} = StaticAssets.load_store(store)
    assert map_size(entries) == 5
  end

  @tag :tmp_dir
  test "reports only diagnostic code counts, not raw source or diagnostic details", %{
    tmp_dir: tmp
  } do
    app = Path.join(tmp, "private-app.bubble")
    store = Path.join(tmp, "store")

    File.write!(
      app,
      Jason.encode!(%{
        "_id" => "private-app",
        "user_types" => %{"secret-subject-one" => 42, "secret-subject-two" => 43},
        "settings" => %{"private" => "unscanned-secret-value"}
      })
    )

    Mix.Tasks.Bubble.FetchAssets.run([app, "--store", store])

    assert_received {:mix_shell, :info, [diagnostics]}
    assert diagnostics == "Import diagnostics: malformed_node=2, model_synthesized_user_type=1"
    assert_received {:mix_shell, :info, [summary]}
    assert summary =~ "0 assets"

    refute diagnostics =~ "secret"
    refute diagnostics =~ tmp
    refute_received {:mix_shell, :info, _}
  end

  @tag :tmp_dir
  test "rejects malformed JSON without echoing the source or path", %{tmp_dir: tmp} do
    app = Path.join(tmp, "private-app.bubble")
    File.write!(app, "{unscanned-secret-value")

    error =
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Bubble.FetchAssets.run([app, "--store", Path.join(tmp, "store")])
      end

    assert error.message =~ "JSON object"
    refute error.message =~ tmp
    refute error.message =~ "unscanned-secret-value"
  end

  test "requires a store directory" do
    assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Bubble.FetchAssets.run(["app.json"]) end
  end
end
