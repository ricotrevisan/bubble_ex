defmodule BubbleEx.AppsDeadRedirectTest do
  use ExUnit.Case, async: true
  alias BubbleEx.HTTP
  alias Plug.Conn

  @bundle_path ~r"\A/package/dynamic_js/([0-9a-f]{64})/deadsite/test/index/xnull/xfalse/xtrue/en_us/xfalse/xfalse/dynamic\.js\z"

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    :ok
  end

  test "fetches the bundle from bubbleapps.io when the custom-domain redirect is dead" do
    stub_dead_redirect(fn conn ->
      [_, hash] = Regex.run(@bundle_path, conn.request_path)
      send(self(), {:bundle_hash, hash})
      bubble_response(conn, script_body("deadsite", "test"))
    end)

    assert {:ok, %{valid?: true, bubble_id: "deadsite", url: "deadsite.bubbleapps.io"}} =
             BubbleEx.fetch_app("https://deadsite.bubbleapps.io/version-test", max_retries: 0)

    assert_received {:bundle_hash, first}
    BubbleEx.fetch_app("https://deadsite.bubbleapps.io/version-test", max_retries: 0)
    assert_received {:bundle_hash, second}
    assert first != second
  end

  test "keeps the original error when the bundle belongs to another app" do
    stub_dead_redirect(fn conn -> bubble_response(conn, script_body("otherapp", "test")) end)

    assert {:error, %BubbleEx.Error{kind: :request_failed, context: %{reason: :nxdomain}}} =
             BubbleEx.fetch_app("https://deadsite.bubbleapps.io/version-test", max_retries: 0)
  end

  test "keeps the original error when the bundle is another version" do
    stub_dead_redirect(fn conn -> bubble_response(conn, script_body("deadsite", "live")) end)

    assert {:error, %BubbleEx.Error{kind: :request_failed, context: %{reason: :nxdomain}}} =
             BubbleEx.fetch_app("https://deadsite.bubbleapps.io/version-test", max_retries: 0)
  end

  test "does not fall back for hosts outside bubbleapps.io" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "dead.example"
      Req.Test.transport_error(conn, :nxdomain)
    end)

    assert {:error, %BubbleEx.Error{kind: :request_failed, context: %{reason: :nxdomain}}} =
             BubbleEx.fetch_app("https://dead.example/version-test", max_retries: 0)
  end

  defp stub_dead_redirect(bundle_fun) do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.host, conn.request_path} do
        {"deadsite.bubbleapps.io", "/version-test"} ->
          conn
          |> Conn.put_resp_header("location", "https://dead.example/version-test")
          |> Conn.send_resp(301, "")

        {"dead.example", _path} ->
          Req.Test.transport_error(conn, :nxdomain)

        {"deadsite.bubbleapps.io", "/package/dynamic_js/" <> _} ->
          bundle_fun.(conn)
      end
    end)
  end

  defp bubble_response(conn, body),
    do: conn |> Conn.put_resp_header("x-bubble-app", "yes") |> Conn.send_resp(200, body)

  defp script_body(id, version),
    do: ~s|const app = JSON.parse('{"_id":"#{id}","app_version":"#{version}"}');|
end
