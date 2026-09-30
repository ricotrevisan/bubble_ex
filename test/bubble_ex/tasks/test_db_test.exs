defmodule BubbleEx.Tasks.TestDbTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error
  alias BubbleEx.Tasks.TestDb

  @moduletag :tmp_dir

  defp refused(url, opts \\ []) do
    assert {:error, %Error{kind: :invalid_input, message: m}} = TestDb.parse(url, opts)
    refute m =~ "secret"
    m
  end

  test "accepts an explicit port and a test database" do
    for url <- [
          "ecto://postgres:secret@127.0.0.1:55432/my_app_test",
          "postgres://u:secret@127.0.0.2:6543/wtf_scratch",
          "postgresql://u@localhost:15432/app_test?ssl=false",
          "ecto://u:secret@[::1]:15432/app_test?ssl=true"
        ],
        do: assert(TestDb.parse(url) == {:ok, {:url, url}})
  end

  test "refuses port 5432 unless allowed" do
    url = "ecto://postgres:secret@localhost:5432/my_app_test"
    assert refused(url) =~ "port 5432"
    assert refused(url) =~ "WTF_TASK_ALLOW_5432=1"
    assert TestDb.parse(url, allow_5432: true) == {:ok, {:url, url}}
  end

  test "refuses an implicit port, a missing host and other schemes" do
    assert refused("ecto://postgres:secret@localhost/my_app_test") =~ "port explicitly"
    assert refused("ecto://:55432/my_app_test") =~ "host"
    assert refused("mysql://u:secret@localhost:3306/my_app_test") =~ "ecto:// or postgres://"
    assert refused("my_app_test") =~ "ecto:// or postgres://"
  end

  test "refuses query parameters that bypass the host and port, and fragments" do
    base = "ecto://postgres:secret@127.0.0.1:55432/my_app_test"

    for query <- [
          "socket=/var/run/postgresql/.s.PGSQL.5432",
          "socket_dir=/var/run/postgresql",
          "port=5432",
          "hostname=db.example.com",
          "timeout=abc",
          "ssl=yes",
          "ssl=true&socket_dir=/var/run/postgresql",
          "ssl=true&ssl=false",
          ""
        ] do
      assert refused("#{base}?#{query}") =~ "no query parameter but ssl=true or ssl=false"
    end

    assert refused(base <> "#frag") =~ "no #fragment"
  end

  test "refuses a host that is not loopback unless allowed" do
    url = "ecto://postgres:secret@db.example.com:55432/my_app_test"
    assert refused(url) =~ "loopback host"
    assert refused(url) =~ "WTF_TASK_ALLOW_REMOTE_TEST_DB=1"
    assert refused("ecto://postgres:secret@10.0.0.5:55432/my_app_test") =~ "loopback host"
    assert TestDb.parse(url, allow_remote: true) == {:ok, {:url, url}}
  end

  test "refuses a database that is not a test or wtf_ database" do
    for db <- ["my_app", "my_app_dev", "", "a/b_test", "test_app", "my%2Fapp_test"] do
      assert refused("ecto://postgres:secret@127.0.0.1:55432/#{db}") =~ "ending in _test"
    end

    assert refused("ecto://postgres:secret@127.0.0.1:55432") =~ "ending in _test"
  end

  test "the URL reaches mix test as TEST_DATABASE_URL; DATABASE_URL never does" do
    # nil removes the variable from the subprocess's environment.
    assert TestDb.env(:project) == [{"MIX_ENV", "test"}, {"DATABASE_URL", nil}]

    assert TestDb.env({:url, "ecto://h:1/a_test"}) ==
             [
               {"MIX_ENV", "test"},
               {"DATABASE_URL", nil},
               {"TEST_DATABASE_URL", "ecto://h:1/a_test"}
             ]
  end

  test "a URL needs a config/test.exs that reads TEST_DATABASE_URL", %{tmp_dir: root} do
    url = {:url, "ecto://h:55432/a_test"}
    assert TestDb.usable(root, :project) == :ok
    assert {:error, %Error{message: m}} = TestDb.usable(root, url)
    assert m =~ "does not read TEST_DATABASE_URL"

    File.mkdir_p!(Path.join(root, "config"))
    path = Path.join(root, "config/test.exs")

    # DATABASE_URL is not the test database's variable.
    File.write!(path, ~s|if url = System.get_env("DATABASE_URL"), do: :ok\n|)
    assert {:error, _} = TestDb.usable(root, url)

    File.write!(path, ~s|if url = System.get_env("TEST_DATABASE_URL"), do: :ok\n|)
    assert TestDb.usable(root, url) == :ok
  end

  describe "usable/2 reads the project's config" do
    setup %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "config"))

      File.write!(Path.join(root, "config/test.exs"), """
      import Config
      config :app, App.Repo, url: System.get_env("TEST_DATABASE_URL")
      """)

      %{url: {:url, "ecto://h:55432/a_test"}}
    end

    defp runtime(root, source), do: File.write!(Path.join(root, "config/runtime.exs"), source)

    test "a prod-only runtime.exs is fine", %{tmp_dir: root, url: url} do
      runtime(root, """
      import Config

      if config_env() == :prod do
        config :app, App.Repo, url: System.get_env("DATABASE_URL")
      end
      """)

      assert TestDb.usable(root, url) == :ok
    end

    test "runtime.exs reading DATABASE_URL outside prod is refused", %{tmp_dir: root, url: url} do
      runtime(root, """
      import Config
      database_url = System.get_env("DATABASE_URL")
      if config_env() == :prod, do: config(:app, App.Repo, url: database_url)
      """)

      assert {:error, %Error{message: m}} = TestDb.usable(root, url)
      assert m =~ "config/runtime.exs reads DATABASE_URL"

      # The else branch of a prod-only block runs in test.
      runtime(root, """
      import Config

      if config_env() == :prod do
        :ok
      else
        config :app, App.Repo, url: System.get_env("DATABASE_URL")
      end
      """)

      assert {:error, _} = TestDb.usable(root, url)
    end

    test "runtime.exs setting a Repo's connection outside prod is refused", %{
      tmp_dir: root,
      url: url
    } do
      runtime(root, """
      import Config
      config :app, App.Repo, hostname: System.get_env("DB_HOST", "localhost")
      """)

      assert {:error, %Error{message: m}} = TestDb.usable(root, url)
      assert m =~ "sets a Repo's connection"

      # Other Repo settings are fine.
      runtime(root, "import Config\nconfig :app, App.Repo, pool_size: 5\n")
      assert TestDb.usable(root, url) == :ok
    end

    test "a Repo socket or socket_dir is refused", %{tmp_dir: root, url: url} do
      File.write!(Path.join(root, "config/config.exs"), """
      import Config
      config :app, App.Repo, socket_dir: "/var/run/postgresql"
      """)

      assert {:error, %Error{message: m}} = TestDb.usable(root, url)
      assert m =~ "config/config.exs sets a Repo's socket or socket_dir"
    end
  end
end
