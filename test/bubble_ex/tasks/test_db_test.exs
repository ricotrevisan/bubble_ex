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
          "postgres://u:secret@db.local:6543/wtf_scratch",
          "postgresql://u@localhost:15432/app_test?ssl=false"
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

  test "refuses a database that is not a test or wtf_ database" do
    for db <- ["my_app", "my_app_dev", "", "a/b_test", "test_app"] do
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
end
