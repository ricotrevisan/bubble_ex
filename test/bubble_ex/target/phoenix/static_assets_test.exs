defmodule BubbleEx.Target.Phoenix.StaticAssetsTest do
  # WTF-447: the generated pages never point at Bubble's storage. The
  # fixture page (test/support/target/phoenix/static_assets.json) has
  # images on Bubble's CDN and S3 bucket (protocol-relative, http and
  # https, an SVG, one never downloaded), on other hosts (look-alikes
  # included), hostile sources, a data URL, responsive variants, a
  # reusable whose instances pass their image, and an icon; its committed
  # store (static_assets.store/) is what mix bubble.fetch_assets wrote
  # against a fake server. scripts/phoenix_compile_check.sh compiles and
  # mounts it as `phoenix_static_assets`.
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.StaticAssets
  alias BubbleEx.Target.Phoenix

  @fixture "test/support/target/phoenix/static_assets.json"
  @store "test/support/target/phoenix/static_assets.store"
  @png_sha "c414cd0e204de974f73753c7e28d7638e7b3691bb8b1a2bab6b25bb7fed7ce77"
  @gif_sha "ef1955ae757c8b966c83248350331bd3a30f658ced11f387f8ebf05ab3368629"

  defp render(opts \\ [], edit \\ & &1) do
    app = @fixture |> File.read!() |> edit.() |> Jason.decode!()
    {:ok, model} = BubbleEx.Model.build(app)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    {:ok, expressions} =
      BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend,
        runtime: "Shop.Bubble.Runtime",
        namespace: "Shop"
      )

    opts = [module: "Shop", frontend: frontend, expressions: expressions] ++ opts
    {:ok, files} = Phoenix.render(project, opts)
    # Offline and deterministic.
    {:ok, ^files} = Phoenix.render(project, opts)
    {:ok, report} = Phoenix.frontend_report(project, opts)
    {files, report}
  end

  defp store do
    {:ok, store} = StaticAssets.load_store(@store)
    assert store.errors == []
    store
  end

  defp pages(files) do
    for {path, content} <- files,
        path =~ ~r{^lib/shop_web/(live|components/reusables)/.*\.(heex|ex)$},
        into: "",
        do: content
  end

  defp img(markup, id) do
    [tag] = Regex.run(~r/<img\s+data-bubble-id="#{id}"[^>]*>/s, markup)
    tag
  end

  defp by_url(manifest), do: Map.new(manifest["assets"], &{{&1["kind"], &1["url"]}, &1})

  # No page or component references Bubble's storage (the generated
  # uploads test holds hostile Bubble URLs on purpose).
  defp refute_bubble_urls(files) do
    markup = pages(files)
    refute markup =~ ~r{//[a-z0-9-]+\.cdn\.bubble\.io/}i
    refute markup =~ ~r{s3\.amazonaws\.com/appforest_uf|appforest_uf\.s3}i
  end

  test "with the store: Bubble's images are the app's own, other hosts stay linked" do
    {files, report} = render(asset_store: store())
    refute_bubble_urls(files)
    markup = pages(files)

    png = "/images/bubble/#{@png_sha}.png"
    # Protocol-relative, http:// and https:// references to one file.
    for id <- ~w(bCdn bHttp bResp), do: assert(img(markup, id) =~ ~s(src="#{png}"), id)
    assert img(markup, "bS3") =~ ~s(src="/images/bubble/#{@gif_sha}.gif")
    assert img(markup, "bSvg") =~ ~r|src="/images/bubble/[0-9a-f]{64}\.svg"|
    assert markup =~ ~r/<source\s+media="\(width &lt;= 600px\)"\s+srcset="#{Regex.escape(png)}"/

    # Never downloaded: no source, never the Bubble URL, and marked.
    refute img(markup, "bMiss") =~ "src="
    assert markup =~ "TODO(bubble:bMiss) image on Bubble's storage not downloaded"

    # Other hosts, look-alikes of Bubble's included, stay linked to their
    # URL as in Bubble (WTF-465): lazy, without a Referer, and not marked.
    assert img(markup, "bExt") =~ ~s(src="https://images.example.org/hero.jpg")
    assert img(markup, "bLook") =~ ~s(src="https://a1b2c3d4e5f6.cdn.bubble.io.evil.example/)
    assert img(markup, "bBucket") =~ ~s(src="https://evil.example/appforest_uf/)

    for id <- ~w(bExt bLook bBucket) do
      assert img(markup, id) =~ ~s(loading="lazy"), id
      assert img(markup, id) =~ ~s(referrerpolicy="no-referrer"), id
    end

    refute markup =~ "outside host"
    refute markup =~ ~r/TODO\(bubble:(bExt|bLook|bBucket)\)/

    # A local image with a responsive variant on another host: its <img>
    # governs the variant's request too.
    assert img(markup, "bResp") =~ ~s(src="#{png}")
    assert img(markup, "bResp") =~ ~s(loading="lazy")
    assert img(markup, "bResp") =~ ~s(referrerpolicy="no-referrer")

    # Local, inline and dropped images are neither lazy nor linked.
    for id <- ~w(bCdn bS3 bSvg bMiss bData bJs) do
      refute img(markup, id) =~ "referrerpolicy", id
      refute img(markup, id) =~ "loading=", id
    end

    assert markup =~
             ~S|<source media="(width &lt; 400px)" srcset="https://images.example.org/small.png"|

    # Hostile sources are dropped, never echoed.
    for id <- ~w(bJs bQuote bUser bToken), do: refute(img(markup, id) =~ "src=", id)
    refute markup =~ "javascript:"
    refute markup =~ "onerror"
    refute markup =~ "secret"
    refute markup =~ "abc123"
    assert img(markup, "bData") =~ ~s(src="data:image/png;base64,iVBORw0KGgo=")

    # A reusable's instances pass their image through the same rules.
    assert markup =~ ~s|src_bphoto={\n      to_string(\n        "#{png}"\n      )\n    }|
    assert markup =~ ~S|src_bphoto={to_string("https://images.example.org/two.png")}|
    assert files["lib/shop_web/components/reusables/card.html.heex"] =~ "src={@src_bphoto}"

    # The icon's symbol is inlined from the stored library, sanitized.
    assert markup =~ ~s(<symbol id="bubble-icon-bIcon" viewBox="0 0 32 32">)

    # The images the app serves, generated and hash-checked.
    served =
      for {path, bytes} <- files,
          String.starts_with?(path, "priv/bubble_images/"),
          do: {path, bytes}

    assert Enum.map(served, &elem(&1, 0)) |> Enum.sort() ==
             Enum.sort([
               "priv/bubble_images/#{@png_sha}.png",
               "priv/bubble_images/#{@gif_sha}.gif",
               hd(for {p, _} <- served, String.ends_with?(p, ".svg"), do: p)
             ])

    for {path, bytes} <- served do
      assert path =~ Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      refute bytes =~ "script"
    end

    generated = Jason.decode!(files[".wtf/generated.json"])["generated"]
    for {path, _} <- served, do: assert(Map.has_key?(generated, path), path)
    assert Map.has_key?(generated, ".wtf/assets.json")

    # The manifest.
    manifest = Jason.decode!(files[".wtf/assets.json"])
    assets = by_url(manifest)

    assert %{
             "status" => "local",
             "sha256" => @png_sha,
             "content_type" => "image/png",
             "size" => 70,
             "src" => ^png,
             "path" => "priv/bubble_images/" <> _,
             "elements" => ["bCdn", "bHttp", "bPhoto", "bResp"]
           } = assets[{"image", "https://a1b2c3d4e5f6.cdn.bubble.io/f1700000000000x100/logo.png"}]

    assert %{"status" => "local", "content_type" => "image/gif", "size" => 42} =
             assets[
               {"image", "https://s3.amazonaws.com/appforest_uf/f1600000000000x300/footer.png"}
             ]

    assert %{"status" => "pending"} =
             assets[
               {"image", "https://a1b2c3d4e5f6.cdn.bubble.io/f1700000000002x400/missing.png"}
             ]

    assert %{
             "status" => "external",
             "handling" => "linked",
             "host" => "images.example.org",
             "note" => "on another host: linked to its original URL, as in Bubble",
             "elements" => ["bExt"]
           } = assets[{"image", "https://images.example.org/hero.jpg"}]

    refute Map.has_key?(assets[{"image", "https://images.example.org/hero.jpg"}], "reason")
    assert manifest["about"] =~ "external: on another host, linked to its original URL"

    assert %{"status" => "local", "inlined" => true} =
             assets[
               {"icon", "https://app.example.test/static/icon_libraries/fontawesome-4.7.0.svg"}
             ]

    # Credentials never reach the manifest.
    refute files[".wtf/assets.json"] =~ "secret"
    refute files[".wtf/assets.json"] =~ "abc123"

    assert manifest["counts"] == %{
             "local" => 5,
             "pending" => 1,
             "external" => 5,
             "data" => 1,
             "invalid" => 4
           }

    assert report["assets_local"] == 5 and report["assets_external"] == 5
  end

  test "an http:// image on another host is linked over HTTPS, an instance's too" do
    {files, report} =
      render([asset_store: store()], fn json ->
        json
        |> String.replace(
          "https://images.example.org/hero.jpg",
          "http://images.example.org/hero.jpg"
        )
        |> String.replace(
          "https://images.example.org/two.png",
          "http://images.example.org/two.png"
        )
      end)

    markup = pages(files)
    assert img(markup, "bExt") =~ ~s(src="https://images.example.org/hero.jpg")
    refute markup =~ "http://images.example.org"
    assert markup =~ ~S|src_bphoto={to_string("https://images.example.org/two.png")}|

    # The reusable's image: an instance passes a linked one.
    [card] =
      Regex.run(
        ~r/<img\s[^>]*src=\{@src_bphoto\}[^>]*>/s,
        files["lib/shop_web/components/reusables/card.html.heex"]
      )

    assert card =~ ~s(referrerpolicy="no-referrer")
    assert card =~ ~s(loading="lazy")

    manifest = Jason.decode!(files[".wtf/assets.json"])

    assert %{"status" => "external"} =
             by_url(manifest)[{"image", "https://images.example.org/hero.jpg"}]

    assert report["assets_external"] == 5
  end

  test "an image on a loopback or private host stays linked, with a note" do
    {files, _report} =
      render(
        [],
        &String.replace(&1, "https://images.example.org/hero.jpg", "https://10.0.0.7/hero.jpg")
      )

    assert img(pages(files), "bExt") =~ ~s(src="https://10.0.0.7/hero.jpg")
    assets = files[".wtf/assets.json"] |> Jason.decode!() |> by_url()

    assert %{"status" => "external", "handling" => "linked", "note" => note} =
             assets[{"image", "https://10.0.0.7/hero.jpg"}]

    assert note =~ "loopback or private address"

    refute assets[{"image", "https://images.example.org/two.png"}]["note"] =~ "private"
  end

  test "an http:// image on a port other than 80 is dropped and marked" do
    {files, _report} =
      render(
        [],
        &String.replace(
          &1,
          "https://images.example.org/hero.jpg",
          "http://images.example.org:8080/hero.jpg"
        )
      )

    markup = pages(files)
    refute img(markup, "bExt") =~ "src="

    assert markup =~
             "TODO(bubble:bExt) image source dropped: an http:// URL on a port other than 80"
  end

  test "the pages' policy allows images from any HTTPS host" do
    {files, _report} = render()
    router = files["lib/shop_web/router.ex"]
    assert router =~ "plug :put_secure_browser_headers"

    [policy] =
      Regex.run(~r/"content-security-policy" =>\s*"([^"]+)"/, router, capture: :all_but_first)

    assert policy =~ "base-uri 'self'"
    assert policy =~ "frame-ancestors 'self'"
    assert policy =~ "img-src 'self' data: blob: https:;"
    refute policy =~ "http:"
    refute policy =~ "example"
  end

  test "without the store: no Bubble URL either, every Bubble image pending" do
    {files, report} = render()
    refute_bubble_urls(files)
    markup = pages(files)

    for id <- ~w(bCdn bHttp bS3 bSvg bMiss bResp), do: refute(img(markup, id) =~ "src=", id)
    assert img(markup, "bExt") =~ ~s(src="https://images.example.org/hero.jpg")
    refute Enum.any?(Map.keys(files), &String.starts_with?(&1, "priv/bubble_images/"))
    # The instance passing a Bubble image passes nothing.
    refute markup =~ ~r/data-bubble-id="bOne"[^>]*src_bphoto/s

    manifest = Jason.decode!(files[".wtf/assets.json"])
    assert manifest["counts"]["local"] == 0
    assert manifest["counts"]["pending"] == 6
    assert report["assets_pending"] == 6
  end

  test "the endpoint serves the images with nosniff and a sandbox policy" do
    {files, _report} = render()
    endpoint = files["lib/shop_web/endpoint.ex"]
    assert endpoint =~ ~s(at: "/images/bubble")
    assert endpoint =~ ~s(from: {:shop, "priv/bubble_images"})
    assert endpoint =~ ~s("x-content-type-options" => "nosniff")

    assert endpoint =~
             ~s("content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; sandbox")

    # Outside priv/static, which the main static plug serves (`images`
    # included, gzip in production): no other spelling of the path, and
    # no .gz without its raw file, reaches an image without the policy
    # (WTF-455). Behavior: the generated BubbleImagesTest
    # (scripts/phoenix_compile_check.sh).
    refute endpoint =~ "priv/static/images"
    assert files["test/shop_web/bubble_images_test.exs"] =~ "/images/bubbl%65"
  end

  # Existing projects (WTF-455): the owned endpoint may still serve the
  # images from priv/static/images/bubble, and copies left there are
  # served without the policy. check_manifest/3 says so.
  @tag :tmp_dir
  test "check_manifest lists images the endpoint does not serve, and leftovers", %{
    tmp_dir: root
  } do
    {files, _report} = render(asset_store: store())
    json = files[".wtf/generated.json"]
    endpoint = "lib/shop_web/endpoint.ex"
    images = Enum.sort(for {p, _} <- files, String.starts_with?(p, "priv/bubble_images/"), do: p)

    assert Jason.decode!(json)["images"] == %{
             "endpoint" => endpoint,
             "from" => "priv/bubble_images",
             "files" => images
           }

    assert length(images) == 3
    assert {:ok, %{clean?: true, images_unserved: []}} = Phoenix.check_manifest(json, files)

    # An endpoint scaffolded before WTF-455, or with the plug commented out.
    old = String.replace(files[endpoint], "priv/bubble_images", "priv/static/images/bubble")

    commented =
      String.replace(
        files[endpoint],
        ~s(from: {:shop, "priv/bubble_images"},),
        ~s(# from: {:shop, "priv/bubble_images"},)
      )

    assert commented =~ ~s(# from: {:shop, "priv/bubble_images"},)

    for edited <- [old, commented] do
      assert {:ok, %{clean?: true, images_unserved: ^images}} =
               Phoenix.check_manifest(json, Map.put(files, endpoint, edited))
    end

    # A copy left under priv/static/images/bubble, served by the main plug.
    left = "priv/static/images/bubble/#{@png_sha}.png"

    assert {:ok, %{images_unserved: [^left]}} =
             Phoenix.check_manifest(json, Map.put(files, left, "png"))

    # The same from the project's directory, nested and dot files included.
    for {path, content} <- files, do: write(root, path, content)
    nested = "priv/static/images/bubble/sub/.hidden.svg"
    for path <- [left, nested], do: write(root, path, "x")
    assert {:ok, %{images_unserved: [^left, ^nested]}} = Phoenix.check_manifest(json, root)

    # Leftovers are listed even when the render has no images.
    {plain, _report} = render()
    refute Map.has_key?(Jason.decode!(plain[".wtf/generated.json"]), "images")

    assert {:ok, %{images_unserved: [^left]}} =
             Phoenix.check_manifest(plain[".wtf/generated.json"], Map.put(plain, left, "png"))
  end

  defp write(root, path, content) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)
  end

  # The exporter's `assets:` (the fidelity cases' path) are served only as
  # verified: raw bytes are never written as they came (review of #169).
  test "the exporter's assets are written only checked, typed and sanitized" do
    app = @fixture |> File.read!() |> Jason.decode!()
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    ids = Map.new(StaticAssets.references(frontend), &{hd(&1.elements), hd(&1.ids)})
    png = File.read!(Path.join(@store, "#{@png_sha}.png"))

    assets = %{
      ids["bExt"] => %{path: "assets/hero.jpg", bytes: png},
      ids["bLook"] => %{
        path: "assets/logo.png",
        bytes:
          ~S|<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><path d="M0 0"/></svg>|
      },
      ids["bBucket"] => %{path: "assets/evil.png", bytes: "<html><script>alert(1)</script>"}
    }

    {files, _report} = render(assets: assets)
    markup = pages(files)
    served = for {p, b} <- files, String.starts_with?(p, "priv/bubble_images/"), do: {p, b}

    assert {"priv/bubble_images/#{@png_sha}.png", png} in served
    assert img(markup, "bExt") =~ ~s(src="/images/bubble/#{@png_sha}.png")

    [{svg_path, svg}] = for {p, b} <- served, String.ends_with?(p, ".svg"), do: {p, b}
    refute svg =~ "onload"
    assert svg_path =~ Base.encode16(:crypto.hash(:sha256, svg), case: :lower)
    assert img(markup, "bLook") =~ ~s(src="/images/bubble/#{Path.basename(svg_path)}")

    # Not an image: never written, rendered without a source.
    assert length(served) == 2
    refute Enum.any?(served, fn {_p, b} -> b =~ "<html" end)
    refute img(markup, "bBucket") =~ "src="
  end

  test "asset_store: must be a loaded store" do
    app = @fixture |> File.read!() |> Jason.decode!()
    {:ok, model} = BubbleEx.Model.build(app)
    {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :omit)
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)

    assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
             Phoenix.render(project, frontend: frontend, asset_store: @store)
  end
end
