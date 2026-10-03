defmodule BubbleEx.Editor.PagesTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Editor
  alias BubbleEx.Editor.{Snapshot, Target}
  alias BubbleEx.{Error, HTTP}
  alias Plug.Conn

  setup do
    Process.put({HTTP, :options}, plug: {Req.Test, __MODULE__})
    {:ok, target: elem(Target.readable("demo", "test", "private-cookie"), 1)}
  end

  test "native runtime parser discovers stable page keys, IDs and names without editor cookies",
       %{target: target} do
    stub_runtime()
    assert {:ok, [ref]} = Editor.discover_pages(target)

    assert Map.take(Map.from_struct(ref), [:appname, :version, :key, :id, :name, :path]) ==
             %{
               appname: "demo",
               version: "test",
               key: "map-key",
               id: "page-id",
               name: "index",
               path: ["%p3", "map-key"]
             }

    assert ref.source == %{
             kind: :runtime,
             url: "https://demo.bubbleapps.io/version-test/index",
             pointer: "/%p3/map-key"
           }
  end

  test "editor denial stops discovery, never falling back to runtime or another endpoint", %{
    target: target
  } do
    for status <- [401, 403, 302] do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "bubble.io"
        assert conn.request_path == "/appeditor/get_versions"
        Conn.resp(conn, status, "private-body")
      end)

      assert {:error, %Error{context: %{status: ^status}}} = Editor.discover_pages(target)
    end
  end

  test "runtime denial, redirect and invalid payload stop rather than guessing page identities",
       %{target: target} do
    for {status, body} <- [
          {401, "private-body"},
          {403, "private-body"},
          {302, "private-body"},
          {200, "const app = JSON.parse('private-body');"}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.host do
          "bubble.io" ->
            Conn.resp(conn, 200, Jason.encode!(%{"test" => %{}}))

          "demo.bubbleapps.io" ->
            assert conn.request_path == "/version-test/index"
            assert Conn.get_req_header(conn, "cookie") == []

            conn
            |> Conn.put_resp_header("location", "https://elsewhere.example/")
            |> Conn.resp(status, body)

          _ ->
            flunk("unexpected fallback")
        end
      end)

      assert {:error, %Error{} = error} = Editor.discover_pages(target)
      refute inspect(error) =~ "private-body"
    end
  end

  test "read_page reads one discovered editor path and returns raw page only after identity validation",
       %{target: target} do
    stub_runtime()
    {:ok, [ref]} = Editor.discover_pages(target)
    assert {:ok, %Snapshot{last_change: 42} = snapshot} = Editor.read_page(target, ref)

    assert {:ok, %{"id" => "page-id", "%x" => "Page", "%nm" => "index"}} =
             Snapshot.fetch(snapshot, ["%p3", "map-key"])
  end

  test "references bound to another app/version or unsafe path never reach network", %{
    target: target
  } do
    stub_runtime()
    {:ok, [ref]} = Editor.discover_pages(target)
    Req.Test.stub(__MODULE__, fn _ -> flunk("invalid reference reached transport") end)

    for bad <- [
          %{ref | appname: "other"},
          %{ref | version: "live"},
          %{ref | path: ["settings"]},
          %{ref | path: ["%p3", "other-key"]},
          %{ref | id: nil},
          %{ref | key: "../key"}
        ] do
      assert {:error, %Error{kind: :invalid_input}} = Editor.read_page(target, bad)
    end
  end

  test "missing, malformed, renamed or substituted editor pages fail closed without raw data", %{
    target: target
  } do
    stub_runtime()
    {:ok, [ref]} = Editor.discover_pages(target)

    for page <- [
          nil,
          %{},
          %{"id" => "wrong", "%x" => "Page", "%nm" => "index"},
          %{"id" => "page-id", "%x" => "Group", "%nm" => "index"},
          %{"id" => "page-id", "%x" => "Page", "%nm" => "renamed"}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        if String.ends_with?(conn.request_path, "/get_versions") do
          Conn.resp(conn, 200, Jason.encode!(%{"test" => %{}}))
        else
          Conn.resp(
            conn,
            200,
            Jason.encode!(%{
              "last_change" => 42,
              "data" => [%{"data" => page}],
              "private" => "private-body"
            })
          )
        end
      end)

      assert {:error, %Error{context: %{reason: :page_identity_mismatch}} = error} =
               Editor.read_page(target, ref)

      refute inspect(error) =~ "private-body"
      refute inspect(error) =~ "renamed"
    end
  end

  test "malformed or chunked page read responses are rejected without parser data", %{
    target: target
  } do
    stub_runtime()
    {:ok, [ref]} = Editor.discover_pages(target)

    for response <- [
          %{"data" => []},
          %{"last_change" => -1, "data" => [%{"data" => %{}}]},
          %{"last_change" => "private-body", "data" => [%{"data" => %{}}]},
          %{"last_change" => 1, "data" => [%{"url" => "https://evil.example/private-body"}]},
          %{"last_change" => 1, "data" => []}
        ] do
      post = fn url, _, _, _ ->
        if String.ends_with?(url, "/get_versions"),
          do: {:ok, %{"test" => %{}}},
          else: {:ok, response}
      end

      assert {:error, %Error{kind: :parse_failed} = error} =
               Editor.read_page(target, ref, post_fun: post)

      refute inspect(error) =~ "private-body"
    end
  end

  test "readable runtime keys and native editor keys remain distinct", %{target: target} do
    runtime = %{
      "pages" => %{"native_key" => %{"id" => "id1", "name" => "display", "type" => "Page"}},
      "mobile_views" => %{"mobile" => %{"id" => "m1", "name" => "Mobile"}},
      "element_definitions" => %{"reuse" => %{"id" => "r1", "name" => "Reusable"}}
    }

    post = fn _, _, _, _ -> {:ok, %{"test" => %{}}} end
    get = runtime_get(runtime)
    assert {:ok, [ref]} = Editor.discover_pages(target, post_fun: post, runtime_get_fun: get)
    assert ref.key == "native_key"
    assert ref.id == "id1"
    assert ref.name == "display"
    assert ref.path == ["%p3", "native_key"]
    assert ref.source.pointer == "/pages/native_key"
  end

  test "malformed inventories cannot invent IDs from names or map keys", %{target: target} do
    post = fn _, _, _, _ -> {:ok, %{"test" => %{}}} end

    for pages <- [
          %{},
          %{"key" => %{"%nm" => "index"}},
          %{"key" => %{"id" => "id", "%nm" => ""}},
          %{"unsafe/key" => %{"id" => "id", "%nm" => "index"}},
          %{"k1" => %{"id" => "same", "%nm" => "one"}, "k2" => %{"id" => "same", "%nm" => "two"}}
        ] do
      assert {:error, %Error{kind: :parse_failed}} =
               Editor.discover_pages(target,
                 post_fun: post,
                 runtime_get_fun: runtime_get(%{"%p3" => pages})
               )
    end
  end

  test "discovery rejects conflicting or malformed native/readable identity fields", %{
    target: target
  } do
    post = fn _, _, _, _ -> {:ok, %{"test" => %{}}} end
    page = %{"id" => "id", "name" => "index", "type" => "Page"}

    for {key, value} <- [
          {"%id", "other"},
          {"%id", nil},
          {"%nm", "other"},
          {"%nm", 42},
          {"default_name", "other"},
          {"%x", "Group"}
        ] do
      assert {:error, %Error{kind: :parse_failed}} =
               Editor.discover_pages(target,
                 post_fun: post,
                 runtime_get_fun: runtime_get(%{"pages" => %{"key" => Map.put(page, key, value)}})
               )
    end
  end

  test "discovery reads only shallow page metadata, not element descendants", %{target: target} do
    child = Enum.reduce(1..2000, %{}, fn _, node -> %{"%el" => %{"child" => node}} end)
    page = %{"id" => "id", "%id" => "id", "%nm" => "index", "name" => "index", "%el" => child}

    assert {:ok, [ref]} =
             Editor.discover_pages(target,
               post_fun: fn _, _, _, _ -> {:ok, %{"test" => %{}}} end,
               runtime_get_fun: runtime_get(%{"%p3" => %{"key" => page}})
             )

    assert ref.id == "id"
    assert ref.name == "index"
  end

  test "bundle denial and parsing failure expose neither payload nor fallback", %{target: target} do
    post = fn _, _, _, _ -> {:ok, %{"test" => %{}}} end

    for {status, body} <- [
          {403, "private-body"},
          {302, "private-body"},
          {200, "const app = JSON.parse('private-body');"}
        ] do
      get = fn url, headers, _ ->
        assert headers == []

        body =
          if String.contains?(url, "/package/"),
            do: body,
            else: "<script src='/package/dynamic_js/test/demo/index'></script>"

        status = if String.contains?(url, "/package/"), do: status, else: 200
        response(url, status, body)
      end

      assert {:error, %Error{} = error} =
               Editor.discover_pages(target, post_fun: post, runtime_get_fun: get)

      refute inspect(error) =~ "private-body"
    end
  end

  test "a malformed patched bundle cannot leak parser exception data", %{target: target} do
    post = fn _, _, _, _ -> {:ok, %{"test" => %{}}} end

    get = fn url, _, _ ->
      body =
        if String.contains?(url, "/package/"),
          do:
            "const app = JSON.parse('[\"private-body\"]');\napp['%p3'] = Object.assign(app['%p3'], JSON.parse('{}'));",
          else: "<script src='/package/dynamic_js/test/demo/index'></script>"

      response(url, 200, body)
    end

    assert {:error, %Error{kind: :parse_failed} = error} =
             Editor.discover_pages(target, post_fun: post, runtime_get_fun: get)

    refute inspect(error) =~ "private-body"
  end

  test "conflicting native/readable identity fields cannot authorize a page", %{target: target} do
    stub_runtime()
    {:ok, [ref]} = Editor.discover_pages(target)

    post = fn url, _, _, _ ->
      if String.ends_with?(url, "/get_versions") do
        {:ok, %{"test" => %{}}}
      else
        {:ok,
         %{
           "last_change" => 1,
           "data" => [
             %{
               "data" => %{
                 "id" => "page-id",
                 "%id" => "different",
                 "%nm" => "index",
                 "%x" => "Page"
               }
             }
           ]
         }}
      end
    end

    assert {:error, %Error{context: %{reason: :page_identity_mismatch}}} =
             Editor.read_page(target, ref, post_fun: post)
  end

  test "runtime route and URLs are bounded and never accept credential-bearing script URLs", %{
    target: target
  } do
    post = fn _, _, _, _ -> {:ok, %{"test" => %{}}} end
    never = fn _, _, _ -> flunk("unsafe runtime route reached transport") end

    assert {:error, %Error{kind: :invalid_input}} =
             Editor.discover_pages(target,
               post_fun: post,
               runtime_get_fun: never,
               runtime_page: "../admin"
             )

    for src <- [
          "http://evil.example/package/dynamic_js",
          "https://user:secret@evil.example/package/dynamic_js",
          "https://bubble.io/appeditor/write"
        ] do
      get = fn url, _, _ ->
        assert url == "https://demo.bubbleapps.io/version-test/index"
        response(url, 200, "<script src='#{src}'></script>")
      end

      assert {:error, %Error{kind: :parse_failed}} =
               Editor.discover_pages(target, post_fun: post, runtime_get_fun: get)
    end
  end

  test "live and child runtime discovery use their exact version routes" do
    for {version, expected} <- [
          {"live", "https://demo.bubbleapps.io/index"},
          {"child", "https://demo.bubbleapps.io/version-child/index"}
        ] do
      {:ok, target} = Target.readable("demo", version, "cookie")
      post = fn _, _, _, _ -> {:ok, %{version => %{}}} end

      get = fn url, _, _ ->
        assert url == expected
        response(url, 403, "private-body")
      end

      assert {:error, %Error{kind: :forbidden}} =
               Editor.discover_pages(target, post_fun: post, runtime_get_fun: get)
    end
  end

  defp runtime_get(app) do
    fn url, headers, opts ->
      assert headers == []
      assert opts[:auth] == nil
      assert opts[:follow_redirect] == false
      assert opts[:retry] == false

      body =
        if String.contains?(url, "/package/"),
          do: "const app = JSON.parse(#{Jason.encode!(Jason.encode!(app))});",
          else: "<script src='/package/dynamic_js/test/demo/index'></script>"

      response(url, 200, body)
    end
  end

  defp response(url, status, body),
    do: {:ok, %HTTP.Response{request_url: url, status_code: status, body: body, headers: []}}

  defp stub_runtime do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.host, conn.request_path} do
        {"bubble.io", "/appeditor/get_versions"} ->
          assert Conn.get_req_header(conn, "cookie") == ["private-cookie"]
          Conn.resp(conn, 200, Jason.encode!(%{"test" => %{}}))

        {"bubble.io", "/appeditor/load_multiple_paths/demo/test"} ->
          {:ok, body, conn} = Conn.read_body(conn)

          assert Jason.decode!(body) == %{
                   "no_chunking" => true,
                   "path_arrays" => [["%p3", "map-key"]]
                 }

          Conn.resp(
            conn,
            200,
            Jason.encode!(%{
              "last_change" => 42,
              "data" => [%{"data" => %{"id" => "page-id", "%x" => "Page", "%nm" => "index"}}]
            })
          )

        {"demo.bubbleapps.io", "/version-test/index"} ->
          assert conn.method == "GET"
          assert Conn.get_req_header(conn, "cookie") == []
          assert Conn.get_req_header(conn, "authorization") == []
          Conn.resp(conn, 200, "<script src='/package/dynamic_js/test/demo/index'></script>")

        {"demo.bubbleapps.io", "/package/dynamic_js/test/demo/index"} ->
          assert Conn.get_req_header(conn, "cookie") == []
          assert Conn.get_req_header(conn, "authorization") == []
          app = %{"%p3" => %{}, "_index" => %{}}
          patch = %{"map-key" => %{"id" => "page-id", "%x" => "Page", "%nm" => "index"}}

          js =
            "const app = JSON.parse(#{Jason.encode!(Jason.encode!(app))});\n" <>
              "app['%p3'] = Object.assign(app['%p3'], JSON.parse(#{Jason.encode!(Jason.encode!(patch))}));"

          Conn.resp(conn, 200, js)

        _ ->
          flunk("unexpected endpoint")
      end
    end)
  end
end
