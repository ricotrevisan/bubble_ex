defmodule BubbleEx.Editor.TransportTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Editor
  alias BubbleEx.Editor.{Client, Target}
  alias BubbleEx.{Error, HTTP}
  alias Plug.Conn

  setup do
    Process.put({HTTP, :options}, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Process.delete({HTTP, :options}) end)
    {:ok, target: elem(Target.new("demo", "child", "session=private-cookie"), 1)}
  end

  test "editor credentials can only target the exact Bubble editor origin", %{target: target} do
    for origin <- [
          "https://evil.example",
          "https://bubble.io:444",
          "https://bubble.io@evil.example",
          "https://bubble.io?secret=x",
          "https://bubble.io#x",
          "https://bubble.io/path",
          "http://bubble.io",
          "https://BUBBLE.io"
        ] do
      assert {:error, %Error{context: %{reason: :invalid_origin}}} =
               Target.new("demo", "child", "cookie", origin: origin)
    end

    Req.Test.stub(__MODULE__, fn _ -> flunk("invalid target reached transport") end)

    assert {:error, %Error{kind: :invalid_input}} =
             Editor.versions(%{target | origin: "https://evil.example"})

    assert {:error, %Error{kind: :invalid_input}} =
             Client.plugin(%{target | appname: "../other"}, "plugin", "current")
  end

  test "read POST never follows even same-origin redirects", %{target: target} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "bubble.io"
      assert conn.request_path == "/appeditor/get_versions"
      assert Conn.get_req_header(conn, "cookie") == ["session=private-cookie"]

      conn
      |> Conn.put_resp_header("location", "https://bubble.io/secret?token=private-body")
      |> Conn.resp(302, "private-body")
    end)

    assert {:error, %Error{context: %{status: 302}} = error} = Editor.versions(target)
    refute inspect(error) =~ "private-body"
    refute inspect(error) =~ "private-cookie"
  end

  test "transport errors never expose raw body, exception, URL query or nested reason", %{
    target: target
  } do
    for status <- [401, 403, 429, 500] do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, status, "private-body") end)
      assert {:error, %Error{context: %{status: ^status}} = error} = Editor.versions(target)
      refute inspect(error) =~ "private-body"
    end

    post = fn _, _, _, opts ->
      assert opts[:follow_redirect] == false
      assert opts[:retry] == false
      {:error, Error.new(:request_failed, "private-body", %{reason: {:secret, "private-body"}})}
    end

    assert {:error, error} = Editor.versions(target, post_fun: post)
    refute inspect(error) =~ "private-body"

    assert {:error, error} =
             Editor.versions(target,
               post_fun: fn _, _, _, _ -> {:error, {:secret, "private-body"}} end
             )

    refute inspect(error) =~ "private-body"
  end

  test "write failures submit once with no redirects or automatic retry", %{target: target} do
    for status <- [302, 307, 308, 429, 500] do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/appeditor/get_versions" ->
            Conn.resp(conn, 200, Jason.encode!(%{"child" => %{"parent_version" => "test"}}))

          "/appeditor/write" ->
            send(self(), {:submitted, status})

            conn
            |> Conn.put_resp_header("location", "https://evil.example/write")
            |> Conn.resp(status, "private-body")

          _ ->
            flunk("redirect followed")
        end
      end)

      assert {:error, %Error{context: %{status: ^status}} = error} = Client.write(target, [%{}])
      assert_received {:submitted, ^status}
      refute_received {:submitted, ^status}
      refute inspect(error) =~ "private-body"
    end
  end

  test "plugin denial and malformed bodies are sanitized and redirects stay disabled", %{
    target: target
  } do
    for {status, body} <- [
          {302, "private-body"},
          {403, "private-body"},
          {200, "private-body"},
          {200, "[]"}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "bubble.io"
        assert conn.request_path == "/appeditor/get_raw_plugin"

        conn
        |> Conn.put_resp_header("location", "https://evil.example/?token=private-body")
        |> Conn.resp(status, body)
      end)

      assert {:error, %Error{} = error} = Client.plugin(target, "plugin", "current")
      refute inspect(error) =~ "private-body"
    end
  end

  test "inherited auth and redirect defaults cannot contaminate anonymous runtime discovery", %{
    target: target
  } do
    Process.put({HTTP, :options},
      plug: {Req.Test, __MODULE__},
      auth: {:basic, "private-user:private-password"},
      headers: [{"cookie", "private-cookie"}],
      redirect: true
    )

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.host do
        "bubble.io" ->
          assert Conn.get_req_header(conn, "authorization") == []
          Conn.resp(conn, 200, Jason.encode!(%{"child" => %{}}))

        "demo.bubbleapps.io" ->
          assert Conn.get_req_header(conn, "cookie") == []
          assert Conn.get_req_header(conn, "authorization") == []

          conn
          |> Conn.put_resp_header("location", "https://evil.example/")
          |> Conn.resp(302, "private-body")

        _ ->
          flunk("redirect followed")
      end
    end)

    assert {:error, %Error{context: %{status: 302}}} = Editor.discover_pages(target)
  end

  test "malformed successful JSON is a sanitized parse error", %{target: target} do
    for body <- ["private-body", "[]", "null", "\"private-body\""] do
      Req.Test.stub(__MODULE__, fn conn -> Conn.resp(conn, 200, body) end)
      assert {:error, %Error{kind: :parse_failed} = error} = Editor.versions(target)
      refute inspect(error) =~ "private-body"
    end
  end
end
