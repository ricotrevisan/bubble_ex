defmodule BubbleEx.Load.DataApiTest do
  # The exporter against an in-memory Data API (Req.Test plug): no request
  # leaves the VM, and the token is a made-up one.
  use ExUnit.Case, async: true

  alias BubbleEx.Load.{DataApi, Export}
  alias BubbleEx.Test.LoadFakeDataApi, as: Fake
  alias BubbleEx.Test.LoadFixture, as: F

  @moduletag :tmp_dir

  defp rows do
    rows = F.field_types_rows()
    # The Data API has no row without an _id; add a user with extra
    # authentication members the export must not keep.
    task = Enum.filter(rows["task"], & &1["_id"])

    user =
      Map.put(hd(rows["user"]), "authentication", %{
        "email" => %{"email" => "ada@example.test", "email_confirmed" => true, "extra" => "x"},
        "facebook" => %{"id" => "fb-secret-id", "token" => "oauth-token"}
      })

    %{"project" => rows["project"], "task" => task, "user" => [user | tl(rows["user"])]}
  end

  defp files do
    %{
      F.cdn_url() => %{body: "PNG bytes of a cover", content_type: "image/png"},
      F.private_url() => %{
        body: "%PDF private contract",
        content_type: "application/pdf",
        private: true
      },
      F.missing_url() => 404
    }
  end

  defp start(opts \\ []) do
    fake = Fake.start(Keyword.merge([rows: rows(), files: files()], opts))
    {fake, [plug: Fake.plug(fake)]}
  end

  defp export(dir, http, opts \\ []) do
    DataApi.export(
      F.model(:field_types),
      dir,
      [
        app_url: "https://" <> Fake.host(),
        version: "test",
        token: Fake.token(),
        http: http,
        page_size: 1,
        sleep: fn _ -> :ok end,
        now: ~U[2026-09-26 00:00:00Z]
      ] ++ opts
    )
  end

  test "exports every type, paging, with GET requests only", %{tmp_dir: dir} do
    {fake, http} = start()
    assert {:ok, export} = export(dir, http)

    assert Export.complete?(export)

    assert Enum.map(Export.types(export), &{&1["type"], &1["rows"]}) == [
             {"project", 1},
             {"task", 2},
             {"user", 3}
           ]

    assert export |> Export.rows("task") |> Enum.map(& &1["_id"]) == [F.task1(), F.task2()]

    assert export.manifest["source"] == %{
             "kind" => "data_api",
             "base_url" => "https://acme.bubbleapps.io/version-test"
           }

    log = Fake.log(fake)
    assert Enum.all?(log, &(&1.method == "GET"))
    # page_size 1: one page per row, plus the empty tail of none
    assert Enum.count(log, &String.contains?(&1.path, "/obj/task")) == 2
    assert Enum.all?(log, &(&1.query["sort_field"] in [nil, "Created Date"]))
  end

  test "the token goes only to the app's host, and is stored nowhere", %{tmp_dir: dir} do
    {fake, http} = start()
    assert {:ok, _export} = export(dir, http)

    for entry <- Fake.log(fake), entry.auth != nil do
      assert entry.host == Fake.host()
    end

    cdn = Enum.find(Fake.log(fake), &String.ends_with?(&1.host, ".cdn.bubble.io"))
    assert cdn.auth == nil

    for file <- Path.wildcard(Path.join(dir, "**/*")), File.regular?(file) do
      data = File.read!(file)
      data = if String.ends_with?(file, ".gz"), do: :zlib.gunzip(data), else: data
      refute data =~ Fake.token(), "#{file} holds the token"
      refute data =~ "oauth-token"
      refute data =~ "fb-secret-id"
    end
  end

  test "keeps only the email and its status from authentication", %{tmp_dir: dir} do
    {_fake, http} = start()
    {:ok, export} = export(dir, http)
    ada = export |> Export.rows("user") |> Enum.find(&(&1["_id"] == F.ada()))

    assert ada["authentication"] == %{
             "email" => %{"email" => "ada@example.test", "email_confirmed" => true},
             "facebook" => %{}
           }
  end

  test "fetches Bubble files with checksums; private ones with the token; failures recorded",
       %{tmp_dir: dir} do
    {_fake, http} = start()
    {:ok, export} = export(dir, http)
    by_url = Map.new(Export.files(export), &{&1["url"], &1})

    cover = by_url[F.cdn_url()]
    assert cover["status"] == "ok" and cover["visibility"] == "public"
    assert File.read!(Export.blob_path(export, cover["sha256"])) == "PNG bytes of a cover"
    assert cover["sha256"] == Export.sha256_hex("PNG bytes of a cover")

    assert by_url[F.private_url()]["visibility"] == "private"
    assert by_url[F.private_url()]["status"] == "ok"

    assert by_url[F.missing_url()] == %{
             "url" => F.missing_url(),
             "status" => "failed",
             "error" => "http_404"
           }

    # A URL outside Bubble's storage is not fetched.
    refute Map.has_key?(by_url, F.external_url())
    assert export.manifest["files"]["failed"] == 1

    %File.Stat{mode: mode} = File.stat!(dir)
    assert Bitwise.band(mode, 0o777) == 0o700
  end

  test "a length mismatch fails the file", %{tmp_dir: dir} do
    files = Map.put(files(), F.cdn_url(), %{body: "short", content_length: 99})
    {_fake, http} = start(files: files)
    {:ok, export} = export(dir, http)
    entry = Enum.find(Export.files(export), &(&1["url"] == F.cdn_url()))
    assert entry["error"] == "length_mismatch"
  end

  test "resumes after an interruption with the same rows", %{tmp_dir: dir} do
    {_fake, http} = start()
    interrupted = Path.join(dir, "interrupted")
    assert {:error, error} = export(interrupted, http, max_calls: 3)
    assert error.context.reason == :budget_exhausted
    assert File.exists?(Path.join(interrupted, "state.json"))
    refute File.exists?(Path.join(interrupted, "manifest.json"))

    # A partial download a killed export left behind is swept.
    File.write!(Path.join([interrupted, "files", ".fetch-42"]), "partial private bytes")
    assert {:ok, resumed} = export(interrupted, http)
    assert Path.wildcard(Path.join(interrupted, "files/.fetch-*"), match_dot: true) == []
    {_fake, http} = start()
    {:ok, straight} = export(Path.join(dir, "straight"), http)

    for type <- ["project", "task", "user"] do
      assert Enum.to_list(Export.rows(resumed, type)) == Enum.to_list(Export.rows(straight, type))
    end

    assert Export.types(resumed) == Export.types(straight)
    refute File.exists?(Path.join(interrupted, "state.json"))
  end

  test "retries 429 and 5xx; a type the Data API does not expose fails", %{tmp_dir: dir} do
    rows = Map.delete(rows(), "project")

    {fake, http} =
      start(
        rows: rows,
        script: [{"/version-test/api/1.1/obj/task", 429}, {"/version-test/api/1.1/obj/user", 503}]
      )

    {:ok, export} = export(dir, http)
    refute Export.complete?(export)
    assert Export.type(export, "project")["error"] == "not_found"
    assert Export.type(export, "task")["rows"] == 2
    assert Export.type(export, "user")["rows"] == 3
    assert Enum.count(Fake.log(fake), &(&1.path =~ "/obj/task")) == 3
  end

  test "a wrong token stops the export", %{tmp_dir: dir} do
    {_fake, http} = start(token: "another-token-0000")
    assert {:error, %{kind: :unauthorized} = error} = export(dir, http)
    refute inspect(error) =~ Fake.token()
  end

  test "validates the app URL, version and token", %{tmp_dir: dir} do
    {_fake, http} = start()
    model = F.model(:field_types)
    base = [version: "test", token: Fake.token(), http: http]

    for url <- [
          "http://acme.bubbleapps.io",
          "https://acme.bubbleapps.io/version-test",
          "https://u:p@acme.bubbleapps.io",
          nil
        ] do
      assert {:error, %{kind: :invalid_input}} =
               DataApi.export(model, dir, Keyword.put(base, :app_url, url))
    end

    assert {:error, %{kind: :invalid_input}} =
             DataApi.export(
               model,
               dir,
               Keyword.merge(base, app_url: "https://acme.bubbleapps.io", version: "../x")
             )

    assert {:error, %{kind: :invalid_input, message: message}} =
             DataApi.export(model, dir,
               app_url: "https://acme.bubbleapps.io",
               version: "live",
               token_env: "BUBBLE_EX_TEST_NO_SUCH_TOKEN_VAR"
             )

    assert message =~ "BUBBLE_EX_TEST_NO_SUCH_TOKEN_VAR"
  end

  test "reads the token from the environment", %{tmp_dir: dir} do
    {_fake, http} = start()
    var = "BUBBLE_EX_TEST_TOKEN_#{System.unique_integer([:positive])}"
    System.put_env(var, Fake.token())
    on_exit(fn -> System.delete_env(var) end)

    assert {:ok, _} =
             DataApi.export(F.model(:field_types), dir,
               app_url: "https://" <> Fake.host(),
               version: "test",
               token_env: var,
               http: http,
               files: false
             )
  end

  test "a page without `remaining` fails the type instead of completing it", %{tmp_dir: dir} do
    # A handler answering one row and no `remaining`.
    plug = fn conn ->
      body = Jason.encode!(%{"response" => %{"results" => [%{"_id" => F.project1()}]}})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end

    {:ok, export} = export(dir, [plug: plug], types: ["project"], files: false)
    assert Export.type(export, "project")["error"] == "no_remaining"
  end

  test "resumes only an export of the same app and version", %{tmp_dir: dir} do
    {_fake, http} = start()
    assert {:error, _} = export(dir, http, max_calls: 2)

    assert {:error, %{message: message}} =
             DataApi.export(F.model(:field_types), dir,
               app_url: "https://other.bubbleapps.io",
               version: "test",
               token: Fake.token(),
               http: http
             )

    assert message =~ "another app"
  end

  test "streams large files to disk under a configurable cap", %{tmp_dir: dir} do
    big = :binary.copy("0123456789abcdef", 200_000)

    {_fake, http} =
      start(files: Map.put(files(), F.cdn_url(), %{body: big, content_type: "image/png"}))

    {:ok, export} = export(Path.join(dir, "a"), http)
    cover = Enum.find(Export.files(export), &(&1["url"] == F.cdn_url()))
    assert cover["bytes"] == byte_size(big) and cover["sha256"] == Export.sha256_hex(big)
    assert File.read!(Export.blob_path(export, cover["sha256"])) == big
    assert Path.wildcard(Path.join(export.dir, "files/.fetch-*")) == []

    {_fake, http} =
      start(files: Map.put(files(), F.cdn_url(), %{body: big, content_type: "image/png"}))

    {:ok, capped} = export(Path.join(dir, "b"), http, max_file_bytes: 1_000)

    assert Enum.find(Export.files(capped), &(&1["url"] == F.cdn_url()))["error"] ==
             "body_too_large"
  end

  test "a file that takes too long fails alone", %{tmp_dir: dir} do
    {fake, _http} = start()

    slow = fn conn ->
      if String.ends_with?(conn.host, ".cdn.bubble.io"), do: Process.sleep(:infinity)
      Fake.plug(fake).(conn)
    end

    {:ok, export} = export(dir, [plug: slow], file_timeout: 300)
    assert Enum.find(Export.files(export), &(&1["url"] == F.cdn_url()))["error"] == "timeout"
    assert Enum.find(Export.files(export), &(&1["url"] == F.private_url()))["status"] == "ok"
  end

  test "the token never prints" do
    secret = BubbleEx.Load.Secret.new("fake-admin-token-0123456789")
    assert inspect(secret) == "#Secret<redacted>"
    assert inspect(%{token: secret}) =~ "redacted"
    refute inspect(%{token: secret}) =~ "fake-admin"
  end

  describe "Bubble file URLs" do
    alias BubbleEx.Load.Files

    test "only Bubble's storage hosts, and the app's own for private files" do
      assert Files.bubble?("//meta-q.cdn.bubble.io/f1x2/a.png")
      assert Files.bubble?("https://s3.amazonaws.com/appforest_uf/f1x2/a.png")
      assert Files.bubble?("https://dd7tel2830j4w.cloudfront.net/f1700000000000x5/a.png")

      assert Files.bubble?("https://acme.bubbleapps.io/fileupload/f1x2/a.pdf", [
               "acme.bubbleapps.io"
             ])

      refute Files.bubble?("https://evil.example/appforest_uf/f1x2/a.png")
      refute Files.bubble?("https://evil.example/fileupload/f1x2/a.pdf", ["acme.bubbleapps.io"])
      refute Files.bubble?("https://acme.bubbleapps.io/fileupload/f1x2/a.pdf")
      refute Files.bubble?("https://s3.amazonaws.com/other-bucket/a.png")
      refute Files.bubble?("https://dd7tel2830j4w.cloudfront.net/other/a.png")
      refute Files.bubble?("http://meta-q.cdn.bubble.io/f1x2/a.png")
      refute Files.bubble?("https://u:p@meta-q.cdn.bubble.io/f1x2/a.png")
    end

    test "names are sanitized, and again when read from an export" do
      assert Files.file_name("https://x.cdn.bubble.io/f1x2/..%2F..%2Fetc%2Fpasswd") ==
               "_.._etc_passwd"

      assert Files.safe_name("../../x") == "_.._x"
      assert Files.safe_name(nil) == "file"
      assert Files.file_name("https://x.cdn.bubble.io/f1x2/%E0%A4%A") =~ "A"
    end
  end
end
