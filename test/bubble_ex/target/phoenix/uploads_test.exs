defmodule BubbleEx.Target.Phoenix.UploadsTest do
  # Safe serving of migrated files in the generated app (WTF-415). The
  # generated <Web>.Uploads is plain Elixir: it is compiled here and run
  # against the hostile-file fixture (test/support/target/phoenix/
  # hostile_uploads). The generated app's own UploadsTest (run by
  # scripts/phoenix_compile_check.sh) checks the served responses.
  use ExUnit.Case, async: false

  alias BubbleEx.Target.Phoenix

  @fixture "test/support/target/phoenix/hostile_uploads"
  @uploads_app "test/support/target/phoenix/uploads_app.json"
  @public_url "https://files.example.test"

  # Files whose name or bytes are active content: never inline.
  @hostile ~w(evil.html evil.svg evil.xml evil.js evil.xhtml html_named.png utf16_bom.html)
  @images %{
    "pixel.png" => "image/png",
    "pixel.jpg" => "image/jpeg",
    "pixel.gif" => "image/gif",
    "pixel.webp" => "image/webp",
    # A GIF header before HTML is a GIF to a browser told so with nosniff.
    "gif_polyglot.html" => "image/gif"
  }

  setup_all do
    {:ok, files} = Phoenix.render(project(), module: "UploadsCheck")
    [{module, _}] = Code.compile_string(files["lib/uploads_check_web/uploads.ex"])
    on_exit(fn -> :code.purge(module) && :code.delete(module) end)
    %{uploads: module, files: files}
  end

  defp project do
    app = @uploads_app |> File.read!() |> Jason.decode!()
    {:ok, model} = BubbleEx.Model.build(app)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    project
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # The bytes the controller reads to decide the type.
  defp head(name) do
    bytes = File.read!(Path.join(@fixture, name))
    binary_part(bytes, 0, min(byte_size(bytes), 16))
  end

  test "the fixture covers every hostile and image file" do
    assert Enum.sort(@hostile ++ Map.keys(@images) ++ ["doc.pdf"]) ==
             @fixture |> File.ls!() |> Enum.sort()
  end

  test "hostile files are attachments of an inert type; only raster images are inline", %{
    uploads: uploads
  } do
    assert uploads.head_size() == 16

    for name <- @hostile do
      assert uploads.content_type(head(name)) == {:attachment, "application/octet-stream"}, name

      headers = Map.new(uploads.headers(uploads.content_type(head(name)), name, :public))
      assert headers["content-disposition"] == ~s(attachment; filename="#{name}")
      assert headers["x-content-type-options"] == "nosniff"
      assert headers["content-security-policy"] == "sandbox; default-src 'none'"
    end

    for {name, type} <- @images do
      assert uploads.content_type(head(name)) == {:inline, type}, name
    end

    # An inline image is saved with its real type's extension.
    disposition = fn name, type ->
      {:inline, type}
      |> uploads.headers(name, :public)
      |> Map.new()
      |> Map.fetch!("content-disposition")
    end

    assert disposition.("gif_polyglot.html", "image/gif") ==
             ~s(inline; filename="gif_polyglot.html.gif")

    assert disposition.("pixel.JPG", "image/jpeg") == ~s(inline; filename="pixel.JPG")
    assert disposition.("pixel.png", "image/png") == ~s(inline; filename="pixel.png")

    assert uploads.content_type(head("doc.pdf")) == {:attachment, "application/pdf"}
    assert uploads.content_type("") == {:attachment, "application/octet-stream"}
  end

  test "links are made for stored references only", %{uploads: uploads} do
    sha = String.duplicate("ab", 32)
    config = [public_url: @public_url]

    assert uploads.url("#{@public_url}/#{sha}/cv.pdf", config) == "/uploads/#{sha}/cv.pdf"
    assert uploads.url("#{@public_url}/#{sha}/cv.pdf", []) == "/uploads/#{sha}/cv.pdf"

    for reference <- [
          "https://evil.example/#{sha}/cv.pdf",
          "//s3.amazonaws.com/appforest_uf/f1/evil.html",
          "javascript:alert(1)",
          "#{@public_url}/#{String.upcase(sha)}/cv.pdf",
          "#{@public_url}/#{sha}/../cv.pdf",
          "#{@public_url}/#{sha}/.htaccess",
          "#{@public_url}/#{sha}/a b.pdf",
          "private/#{sha}/cv.pdf",
          "/#{sha}/cv.pdf",
          ""
        ] do
      assert uploads.url(reference, config) == nil, reference
    end

    assert uploads.url(nil, config) == nil
    assert uploads.url(42, config) == nil

    # Private files get a link only once the owner opts in.
    assert uploads.url("private/#{sha}/cv.pdf", private: :signed_in) ==
             "/uploads/private/#{sha}/cv.pdf"

    assert uploads.url("#{@public_url}/#{sha}/cv.pdf",
             public_url: @public_url,
             uploads_host: "https://usercontent.example.test/"
           ) == "https://usercontent.example.test/uploads/#{sha}/cv.pdf"
  end

  test "uploads_host must be https:// and a host, else nothing public is linked", %{
    uploads: uploads
  } do
    sha = String.duplicate("ab", 32)
    reference = "#{@public_url}/#{sha}/cv.pdf"

    for host <- [
          "https://u.example.test",
          "https://u.example.test/",
          "https://u.example.test:8443"
        ] do
      assert uploads.validate!(uploads_host: host) == :ok

      assert uploads.url(reference, uploads_host: host) =~
               ~r"^https://u\.example\.test(:8443)?/uploads/"

      assert uploads.uploads_host(uploads_host: host) == "u.example.test"
    end

    for host <- [
          "u.example.test",
          "http://u.example.test",
          "https://",
          "https://u.test/x",
          "https://a@u.test",
          42
        ] do
      assert_raise ArgumentError, fn -> uploads.validate!(uploads_host: host) end
      assert uploads.url(reference, uploads_host: host) == nil
      assert uploads.uploads_host(uploads_host: host) == :invalid
      assert uploads.on_uploads_host(sha, "cv.pdf", uploads_host: host) == nil
    end

    assert uploads.on_uploads_host("../x", "cv.pdf", uploads_host: "https://u.test") == nil
  end

  def boom(_actor, _file), do: raise("boom")

  test "a failing or missing authorization function denies", %{uploads: uploads} do
    sha = String.duplicate("ab", 32)

    ExUnit.CaptureLog.capture_log(fn ->
      for private <- [{__MODULE__, :boom}, {__MODULE__, :missing}, {NoSuchModule, :allow}] do
        refute uploads.authorized?(%{id: "u1"}, sha, "cv.pdf", private: private)
      end
    end)
  end

  test "private files are off unless the owner opts in", %{uploads: uploads} do
    sha = String.duplicate("ab", 32)

    for config <- [[], [private: false], [private: true], [private: "yes"]] do
      refute uploads.private?(config)
      refute uploads.authorized?(%{id: "u1"}, sha, "cv.pdf", config)
    end

    refute uploads.authorized?(nil, sha, "cv.pdf", private: :signed_in)
    assert uploads.authorized?(%{id: "u1"}, sha, "cv.pdf", private: :signed_in)
  end

  @tag :tmp_dir
  test "only regular files at content addresses are served", %{uploads: uploads, tmp_dir: root} do
    bytes = File.read!(Path.join(@fixture, "evil.html"))
    sha = sha(bytes)
    dir = Path.join([root, "public", sha])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "evil.html"), bytes)
    File.write!(Path.join(root, "secret.txt"), "secret")
    File.ln_s!(Path.join(root, "secret.txt"), Path.join(dir, "link.txt"))
    File.ln_s!(dir, Path.join([root, "public", String.duplicate("0", 64)]))
    config = [root: root]

    assert {:ok, path, size} = uploads.file(:public, sha, "evil.html", config)
    assert path == Path.join(dir, "evil.html") and size == byte_size(bytes)

    for {sha, name} <- [
          {sha, "link.txt"},
          {String.duplicate("0", 64), "evil.html"},
          {sha, "../../secret.txt"},
          {sha, ".."},
          {"../public/" <> sha, "evil.html"},
          {String.upcase(sha), "evil.html"},
          {sha, "missing.html"}
        ] do
      assert uploads.file(:public, sha, name, config) == :error, "#{sha}/#{name}"
    end

    assert uploads.file(:private, sha, "evil.html", config) == :error
    assert uploads.file(:public, sha, "evil.html", []) == :error
  end

  test "single byte ranges", %{uploads: uploads} do
    assert uploads.range(nil, 10) == :full
    assert uploads.range("bytes=0-3", 10) == {:partial, 0, 4}
    assert uploads.range("bytes=5-", 10) == {:partial, 5, 5}
    assert uploads.range("bytes=-3", 10) == {:partial, 7, 3}
    assert uploads.range("bytes=-30", 10) == {:partial, 0, 10}
    assert uploads.range("bytes=8-100", 10) == {:partial, 8, 2}
    assert uploads.range("bytes=10-", 10) == :unsatisfiable
    assert uploads.range("bytes=-0", 10) == :unsatisfiable
    assert uploads.range("bytes=5-2", 10) == :full
    assert uploads.range("bytes=0-1,4-5", 10) == :full
    assert uploads.range("items=0-1", 10) == :full
    assert uploads.range("bytes=99999999999999999999999-", 10) == :full
  end

  test "the files, routes and test are generated", %{files: files} do
    manifest = Jason.decode!(files[".wtf/generated.json"])

    for path <-
          ~w(lib/uploads_check_web/uploads.ex lib/uploads_check_web/controllers/uploads_controller.ex
             test/uploads_check_web/uploads_test.exs lib/uploads_check_web/bubble_routes.ex),
        do: assert(Map.has_key?(manifest["generated"], path), path)

    routes = files["lib/uploads_check_web/bubble_routes.ex"]
    assert routes =~ ~s(get "/:sha/:name", UploadsController, :public)
    assert routes =~ ~s(get "/private/:sha/:name", UploadsController, :private)
    # The session is read by the controller, only for enabled private files.
    refute routes =~ "load_from_session"
    assert files["lib/uploads_check_web/endpoint.ex"] =~ "plug UploadsCheckWeb.UploadsHostGuard"
    assert files["config/runtime.exs"] =~ "UPLOADS_HOST must be https://"
    assert files["config/runtime.exs"] =~ "private: false"
    assert files["README.md"] =~ "**Private files are off**"
  end

  test "pages link file and image fields through the upload route" do
    app = @uploads_app |> File.read!() |> Jason.decode!()
    {:ok, model} = BubbleEx.Model.build(app)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    shown =
      for {id, %{file?: true}} <- expressions,
          do: id |> String.split("/") |> List.last()

    # An image field, a file field, a dynamic text that is only an image
    # field, and "https:" followed by one (the scheme is dropped: the link
    # is the app's route). Not a text around a file.
    assert Enum.sort(shown) == ["bIH :: src", "bIM :: src", "bIT :: src", "bLK :: destination"]

    for %{source: source} <- Map.values(expressions) do
      assert source =~ "ShopWeb.Uploads.url(get_in(current_user"
    end

    {:ok, files} =
      Phoenix.render(project, module: "Shop", frontend: frontend, expressions: expressions)

    template = files["lib/shop_web/live/profile_live.html.heex"]
    assert template =~ ~r/<img\s+data-bubble-id="bIM"[^>]*\s+src=\{src_bim\(@current_user\)\}/
    assert template =~ ~r/<img\s+data-bubble-id="bIT"[^>]*\s+src=\{src_bit\(@current_user\)\}/

    assert template =~
             ~r/<a\s+data-bubble-id="bLK"[^>]*\s+href=\{destination_blk\(@current_user\)\}/

    assert template =~ ~r/<img\s+data-bubble-id="bIH"[^>]*\s+src=\{src_bih\(@current_user\)\}/

    live = files["lib/shop_web/live/profile_live.ex"]

    # File links stay nil when empty (no attribute), never "" or "https:".
    for helper <- ~w(src_bih src_bim src_bit destination_blk) do
      assert live =~
               ~r/defp #{helper}\(current_user\) do\n    ShopWeb\.Uploads\.url\(get_in\(current_user, \[Access\.key\(:(avatar|resume)\)\]\)\)\n  end/
    end

    refute live =~ ~s("https:")
    assert live =~ "ShopWeb.Uploads.url(get_in(current_user, [Access.key(:avatar)]))"
    assert live =~ "ShopWeb.Uploads.url(get_in(current_user, [Access.key(:resume)]))"
  end
end
