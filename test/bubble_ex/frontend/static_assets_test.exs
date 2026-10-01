defmodule BubbleEx.Frontend.StaticAssetsTest do
  # The static-asset step of WTF-447: which references are Bubble's, the
  # download (against a fake HTTP server: Req.Test, never the network) and
  # the store it writes.
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.StaticAssets
  alias BubbleEx.Frontend.StaticAssets.Store
  alias BubbleEx.HTTP

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )
  @cdn "https://a1b2c3d4e5f6.cdn.bubble.io"

  setup do
    HTTP.put_process_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> HTTP.delete_process_options() end)
    :ok
  end

  # A page with one Image per source, and an Icon.
  defp frontend(sources, opts \\ []) do
    elements =
      sources
      |> Enum.with_index()
      |> Map.new(fn {src, i} ->
        {"img#{i}", %{"id" => "img#{i}", "%x" => "Image", "%p" => %{"src" => src}}}
      end)

    elements =
      if opts[:icon],
        do:
          Map.put(elements, "icon", %{
            "id" => "icon",
            "%x" => "Icon",
            "%p" => %{"icon" => "fa fa-star"}
          }),
        else: elements

    payload = %{
      "_id" => "static-assets",
      "pages" => %{
        "index" => %{
          "%x" => "Page",
          "%nm" => "index",
          "%p" => %{"container_layout" => "column"},
          "%el" => elements
        }
      }
    }

    {:ok, frontend} = Frontend.normalize(payload)
    frontend
  end

  # The fake server: `routes` maps host+path to a response; every request
  # is reported to the test process.
  defp serve(routes) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      key = conn.host <> conn.request_path
      send(test, {:requested, key})

      case Map.get(routes, key) do
        {:redirect, location} ->
          conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.send_resp(302, "")

        {type, body} ->
          conn |> Plug.Conn.put_resp_content_type(type, nil) |> Plug.Conn.send_resp(200, body)

        nil ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp requested do
    receive do
      {:requested, key} -> [key | requested()]
    after
      0 -> []
    end
  end

  describe "classify/2" do
    test "Bubble's storage hosts are fetched over HTTPS" do
      for {ref, url} <- [
            {"//x1.cdn.bubble.io/f1/a.png", "https://x1.cdn.bubble.io/f1/a.png"},
            {"http://x1.cdn.bubble.io/f1/a.png", "https://x1.cdn.bubble.io/f1/a.png"},
            {" https://X1.cdn.bubble.io/f1/a.png ", "https://x1.cdn.bubble.io/f1/a.png"},
            {"//s3.amazonaws.com/appforest_uf/f1/a.png",
             "https://s3.amazonaws.com/appforest_uf/f1/a.png"},
            {"https://appforest_uf.s3.amazonaws.com/f1/a.png",
             "https://appforest_uf.s3.amazonaws.com/f1/a.png"},
            {"https://dd7tel2830j4w.cloudfront.net/f1700000000000x1/a.png",
             "https://dd7tel2830j4w.cloudfront.net/f1700000000000x1/a.png"}
          ] do
        assert StaticAssets.classify(ref) == {:bubble, url}, ref
      end
    end

    test "look-alike and other hosts are external, never Bubble's" do
      for ref <- [
            "https://x1.cdn.bubble.io.evil.example/f1/a.png",
            "https://evilcdn.bubble.io.example/a.png",
            "https://evil.example/appforest_uf/f1/a.png",
            "https://s3.amazonaws.com/other-bucket/a.png",
            "https://dd7tel2830j4w.cloudfront.net/not-a-file/a.png",
            "https://imagedelivery.net/abc/def/public",
            "http://127.0.0.1/a.png",
            "https://x1.bubbleapps.io/fileupload/f1/a.png"
          ] do
        assert {:external, _} = StaticAssets.classify(ref), ref
      end
    end

    # WTF-465: linked to their original host, as in Bubble, over HTTPS.
    test "other hosts are linked over HTTPS, and only http(s) URLs are" do
      for {ref, url} <- [
            {"https://cdn.example.com/a.png", "https://cdn.example.com/a.png"},
            {"//cdn.example.com/a.png?w=200", "https://cdn.example.com/a.png?w=200"},
            {"http://cdn.example.com/a.png", "https://cdn.example.com/a.png"},
            {"http://cdn.example.com:80/a.png", "https://cdn.example.com/a.png"},
            {"https://cdn.example.com:8443/a.png", "https://cdn.example.com:8443/a.png"},
            {"HTTPS://CDN.Example.com/A.png", "https://cdn.example.com/A.png"}
          ] do
        assert StaticAssets.classify(ref) == {:external, url}, ref
      end

      for ref <- [
            "javascript:alert(1)",
            "data:text/html,<script>",
            "data:image/svg+xml,<svg/onload=alert(1)>",
            "ftp://cdn.example.com/a.png",
            "file:///etc/passwd",
            "blob:https://cdn.example.com/1",
            "//cdn.example.com/a.png?token=abc",
            "https://user:pw@cdn.example.com/a.png",
            # No HTTPS equivalent to link.
            "http://cdn.example.com:8080/a.png",
            "http://cdn.example.com:443/a.png",
            # Control characters inside the URL.
            "https://cdn.example.com/a\u0000.png",
            "https://cdn.example.com/a\u0001b.png",
            "https://cdn.example.com/a\u000Bb.png",
            "https://cdn.example.com/a\u001Fb.png",
            "https://cdn.example.com/a\u007Fb.png",
            "https://cdn.example.com/a\tb.png",
            "https://cdn.example.com/a\nb.png",
            "https://cdn.example.com/a b.png"
          ] do
        assert {:invalid, _} = StaticAssets.classify(ref), inspect(ref)
      end
    end

    test "loopback and private hosts are still linked, and noted as such" do
      for host <-
            ~w(127.0.0.1 10.1.2.3 172.16.0.1 192.168.1.1 169.254.169.254 0.0.0.0 100.64.0.1) ++
              ~w([::1] [fc00::1] [fe80::1] [::ffff:127.0.0.1] localhost cdn.localhost) do
        assert {:external, _} = StaticAssets.classify("https://#{host}/a.png"), host
        assert StaticAssets.local_host?(StaticAssets.host("https://#{host}/a.png")), host
      end

      for host <- ~w(cdn.example.com 10.example.com localhost.example.com) do
        refute StaticAssets.local_host?(host), host
      end

      refute StaticAssets.local_host?(nil)
    end

    test "hostile references are dropped" do
      for ref <- [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "data:image/svg+xml;base64,PHN2Zz4=",
            "vbscript:msgbox",
            "/relative/a.png",
            "a.png",
            "https://user:pw@x1.cdn.bubble.io/f1/a.png",
            "https://x1.cdn.bubble.io/f1/a.png?access_token=abc",
            "https://x1.cdn.bubble.io/f1/a.png?session=abc",
            ~s(https://x1.cdn.bubble.io/f1/a".png),
            "https://x1.cdn.bubble.io/f1/a{@x}.png",
            "https://x1.cdn.bubble.io/f1/a.png\n<script>",
            "",
            "   "
          ] do
        assert {:invalid, _} = StaticAssets.classify(ref), inspect(ref)
      end

      assert {:invalid, _} = StaticAssets.classify(nil)
      assert {:invalid, _} = StaticAssets.classify("/static/icon_libraries/../../x.svg", :icon)
      assert {:data, _} = StaticAssets.classify("data:image/png;base64,iVBORw0KGgo=")
    end
  end

  describe "fetch/3" do
    @tag :tmp_dir
    test "downloads Bubble-hosted images only, content-addressed and checked", %{tmp_dir: dir} do
      svg =
        ~S|<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><script>alert(1)</script><path d="M0 0"/></svg>|

      serve(%{
        "a1b2c3d4e5f6.cdn.bubble.io/f1/logo.png" => {"image/png", @png},
        "a1b2c3d4e5f6.cdn.bubble.io/f2/mark.svg" => {"image/svg+xml", svg},
        "s3.amazonaws.com/appforest_uf/f3/same.png" => {"application/octet-stream", @png},
        "a1b2c3d4e5f6.cdn.bubble.io/f4/page.png" => {"image/png", "<html><script>x</script>"},
        "a1b2c3d4e5f6.cdn.bubble.io/f5/page.html" => {"text/html", "<html></html>"},
        "images.example.org/hero.png" => {"image/png", @png}
      })

      frontend =
        frontend([
          "//a1b2c3d4e5f6.cdn.bubble.io/f1/logo.png",
          @cdn <> "/f2/mark.svg",
          "//s3.amazonaws.com/appforest_uf/f3/same.png",
          @cdn <> "/f4/page.png",
          @cdn <> "/f5/page.html",
          @cdn <> "/f6/missing.png",
          "https://images.example.org/hero.png",
          "javascript:alert(1)"
        ])

      assert {:ok, report} = StaticAssets.fetch(frontend, dir)
      assert report["fetched"] == 3
      assert report["external"] == 1
      assert report["invalid"] == 1

      assert Enum.map(report["failed"], &{&1["url"], &1["reason"]}) == [
               {@cdn <> "/f4/page.png", "not a PNG, JPEG, GIF, WebP or SVG image"},
               {@cdn <> "/f5/page.html", "asset returned an unexpected content type"},
               {@cdn <> "/f6/missing.png", "asset download returned HTTP 404"}
             ]

      # Never the outside host.
      refute "images.example.org/hero.png" in requested()

      assert {:ok, %Store{errors: [], entries: entries}} = StaticAssets.load_store(dir)
      png_sha = :crypto.hash(:sha256, @png) |> Base.encode16(case: :lower)

      assert %{file: file, content_type: "image/png", size: size} =
               entries[@cdn <> "/f1/logo.png"]

      assert file == png_sha <> ".png" and size == byte_size(@png)
      # Content-addressed: the same bytes are one file.
      assert entries["https://s3.amazonaws.com/appforest_uf/f3/same.png"].file == file

      %{bytes: clean, content_type: "image/svg+xml"} = entries[@cdn <> "/f2/mark.svg"]
      refute clean =~ "script"
      refute clean =~ "onload"
      assert File.read!(Path.join(dir, entries[@cdn <> "/f2/mark.svg"].file)) == clean

      # A second run reuses the store: no request.
      assert {:ok, again} = StaticAssets.fetch(frontend, dir)
      assert again["reused"] == 3 and again["fetched"] == 0
      requested = requested()
      refute Enum.any?(requested, &String.ends_with?(&1, ["logo.png", "mark.svg", "same.png"]))
    end

    @tag :tmp_dir
    test "redirects must stay on Bubble's storage and are bounded", %{tmp_dir: dir} do
      chain =
        for i <- 0..7, into: %{} do
          {"a1b2c3d4e5f6.cdn.bubble.io/f5/hop#{i}.png",
           {:redirect, @cdn <> "/f5/hop#{i + 1}.png"}}
        end

      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        key = conn.host <> conn.request_path
        send(test, {:requested, key})

        case Map.get(chain, key) do
          {:redirect, location} ->
            conn
            |> Plug.Conn.put_resp_header("location", location)
            |> Plug.Conn.send_resp(302, "")

          nil ->
            routed(conn, key)
        end
      end)

      frontend =
        frontend([
          @cdn <> "/f1/moved.png",
          @cdn <> "/f2/out.png",
          @cdn <> "/f3/meta.png",
          @cdn <> "/f4/loop.png",
          @cdn <> "/f5/hop0.png"
        ])

      assert {:ok, report} = StaticAssets.fetch(frontend, dir)
      assert report["fetched"] == 1
      reasons = Map.new(report["failed"], &{&1["url"], &1["reason"]})
      assert reasons[@cdn <> "/f2/out.png"] == "asset host is not allowed"
      assert reasons[@cdn <> "/f3/meta.png"] == "asset host is not allowed"
      assert reasons[@cdn <> "/f4/loop.png"] == "asset redirect loop detected"
      assert reasons[@cdn <> "/f5/hop0.png"] == "asset redirect limit exceeded"

      requested = requested()
      refute "evil.example/x.png" in requested
      refute Enum.any?(requested, &String.starts_with?(&1, "169.254.169.254"))
    end

    @tag :tmp_dir
    test "caps the size of a download", %{tmp_dir: dir} do
      serve(%{"a1b2c3d4e5f6.cdn.bubble.io/f1/big.png" => {"image/png", @png}})

      assert {:ok, report} =
               StaticAssets.fetch(frontend([@cdn <> "/f1/big.png"]), dir, max_asset_bytes: 16)

      assert [%{"reason" => "asset exceeded max_asset_bytes"}] = report["failed"]
      assert {:ok, %Store{entries: entries}} = StaticAssets.load_store(dir)
      assert entries == %{}
    end

    @tag :tmp_dir
    test "fetches icon libraries from the app's own origin only with app_url", %{tmp_dir: dir} do
      sprite =
        ~S|<svg xmlns="http://www.w3.org/2000/svg"><symbol id="fa-star" viewBox="0 0 32 32"><path d="M1 2L3 4Z"/></symbol></svg>|

      serve(%{
        "app.example.test/static/icon_libraries/fontawesome-4.7.0.svg" =>
          {"image/svg+xml", sprite}
      })

      frontend = frontend([], icon: true)

      assert {:ok, %{"skipped" => 1, "fetched" => 0}} = StaticAssets.fetch(frontend, dir)
      assert requested() == []

      assert {:error, %BubbleEx.Error{}} =
               StaticAssets.fetch(frontend, dir, app_url: "http://app.example.test")

      assert {:error, %BubbleEx.Error{}} =
               StaticAssets.fetch(frontend, dir, app_url: "https://u:p@app.example.test")

      assert {:ok, %{"fetched" => 1}} =
               StaticAssets.fetch(frontend, dir, app_url: "https://app.example.test/version-test")

      assert {:ok, %Store{entries: %{"/static/icon_libraries/fontawesome-4.7.0.svg" => entry}}} =
               StaticAssets.load_store(dir)

      assert entry.kind == :icon
      assert StaticAssets.icon_symbol(entry, "fa-star") =~ ~s(<symbol id="fa-star")
      assert StaticAssets.icon_symbol(entry, "fa-missing") == nil
    end
  end

  describe "verified_assets/1" do
    test "the exporter's downloads are checked like fetched ones" do
      svg =
        ~S|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><path d="M0 0"/></svg>|

      png_sha = :crypto.hash(:sha256, @png) |> Base.encode16(case: :lower)

      verified =
        StaticAssets.verified_assets(%{
          "png" => %{path: "assets/x.gif", bytes: @png, sha256: "stale"},
          "svg" => %{path: "assets/y.png", bytes: svg},
          "html" => %{path: "assets/z.png", bytes: "<html><script>alert(1)</script>"},
          "failed" => %{failed?: true}
        })

      # The extension and name come from the verified bytes, never the path.
      assert verified["png"] == %{path: "assets/#{png_sha}.png", bytes: @png, sha256: png_sha}
      assert %{path: "assets/" <> svg_file, bytes: clean} = verified["svg"]
      assert String.ends_with?(svg_file, ".svg")
      refute clean =~ "script"
      assert verified["html"] == %{failed?: true}
      assert verified["failed"] == %{failed?: true}
    end
  end

  describe "load_store/1" do
    @tag :tmp_dir
    test "drops entries whose files were tampered with", %{tmp_dir: dir} do
      serve(%{
        "a1b2c3d4e5f6.cdn.bubble.io/f1/a.png" => {"image/png", @png},
        "a1b2c3d4e5f6.cdn.bubble.io/f2/b.svg" =>
          {"image/svg+xml", ~S|<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0"/></svg>|}
      })

      {:ok, _} = StaticAssets.fetch(frontend([@cdn <> "/f1/a.png", @cdn <> "/f2/b.svg"]), dir)
      index = dir |> Path.join("index.json") |> File.read!() |> Jason.decode!()
      svg = index["assets"][@cdn <> "/f2/b.svg"]

      # Same size, other bytes: an active SVG in place of the sanitized one.
      File.write!(
        Path.join(dir, svg["file"]),
        ~S|<svg><script>alert(1)</script></svg>| |> String.pad_trailing(svg["size"])
      )

      extra = %{
        "https://x1.cdn.bubble.io/f9/c.png" =>
          Map.put(index["assets"][@cdn <> "/f1/a.png"], "file", "../../../etc/passwd"),
        "https://evil.example/c.png" => index["assets"][@cdn <> "/f1/a.png"]
      }

      File.write!(
        Path.join(dir, "index.json"),
        Jason.encode!(update_in(index["assets"], &Map.merge(&1, extra)))
      )

      assert {:ok, %Store{entries: entries, errors: errors}} = StaticAssets.load_store(dir)
      assert Map.keys(entries) == [@cdn <> "/f1/a.png"]

      assert Enum.sort(Enum.map(errors, & &1.reason)) ==
               ["SHA-256 mismatch", "invalid entry", "invalid file name"]
    end

    @tag :tmp_dir
    test "an entry whose recorded url is not a string is an error, not a crash", %{
      tmp_dir: dir
    } do
      serve(%{"a1b2c3d4e5f6.cdn.bubble.io/f1/a.png" => {"image/png", @png}})
      {:ok, _} = StaticAssets.fetch(frontend([@cdn <> "/f1/a.png"]), dir)
      index = dir |> Path.join("index.json") |> File.read!() |> Jason.decode!()

      for bad <- [123, %{"a" => 1}, ["x"], true] do
        broken = put_in(index, ["assets", @cdn <> "/f1/a.png", "url"], bad)
        File.write!(Path.join(dir, "index.json"), Jason.encode!(broken))

        assert {:ok, %Store{entries: entries, errors: [%{reason: "invalid url"}]}} =
                 StaticAssets.load_store(dir)

        assert entries == %{}
      end
    end

    @tag :tmp_dir
    test "an absent store is empty; a broken index is an error", %{tmp_dir: dir} do
      assert {:ok, %Store{entries: entries}} = StaticAssets.load_store(Path.join(dir, "none"))
      assert entries == %{}
      File.write!(Path.join(dir, "index.json"), "{")
      assert {:error, %BubbleEx.Error{}} = StaticAssets.load_store(dir)
    end
  end

  defp routed(conn, "evil.example/x.png"),
    do:
      conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, @png)

  defp routed(conn, "a1b2c3d4e5f6.cdn.bubble.io/f1/moved.png") do
    conn
    |> Plug.Conn.put_resp_header("location", "https://s3.amazonaws.com/appforest_uf/f1/moved.png")
    |> Plug.Conn.send_resp(302, "")
  end

  defp routed(conn, "s3.amazonaws.com/appforest_uf/f1/moved.png"),
    do:
      conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, @png)

  defp routed(conn, "a1b2c3d4e5f6.cdn.bubble.io/f2/out.png"),
    do: redirect(conn, "https://evil.example/x.png")

  defp routed(conn, "a1b2c3d4e5f6.cdn.bubble.io/f3/meta.png"),
    do: redirect(conn, "http://169.254.169.254/latest/meta-data")

  defp routed(conn, "a1b2c3d4e5f6.cdn.bubble.io/f4/loop.png"),
    do: redirect(conn, @cdn <> "/f4/loop2.png")

  defp routed(conn, "a1b2c3d4e5f6.cdn.bubble.io/f4/loop2.png"),
    do: redirect(conn, @cdn <> "/f4/loop.png")

  defp routed(conn, _key), do: Plug.Conn.send_resp(conn, 404, "")

  defp redirect(conn, location),
    do: conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.send_resp(302, "")
end
