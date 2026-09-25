defmodule BubbleEx.Characterization.DbDdlTest do
  # The generated DDL must load. SQLite DDL for every golden fixture, in both
  # namings, is executed in an in-memory database (python3's sqlite3 module,
  # present on CI runners and dev machines). PostgreSQL DDL is executed in a
  # fresh database per fixture when BUBBLE_EX_DDL_PG names a server (a URL
  # without a database, e.g. postgres://postgres:postgres@localhost:5432);
  # CI runs it in the ash-compile-check job, next to its PostgreSQL service:
  #
  #     BUBBLE_EX_DDL_PG=postgres://… mix test --only ddl_postgres
  use ExUnit.Case, async: true

  alias BubbleEx.Db.{Encoder, Reader}
  alias BubbleEx.Test.Ddl

  @fixtures Enum.sort(
              Path.wildcard("test/support/model/*.json") ++
                Path.wildcard("test/support/db/fixtures/*.json") ++
                ~w(test/support/samples/synthetic_app.json test/support/samples/synthetic_export.json)
            )

  defp ddl(fixture, format, naming) do
    {:ok, db} = fixture |> File.read!() |> Jason.decode!() |> Reader.parse()
    {:ok, result} = Encoder.render(format, db, naming: naming)
    result.content
  end

  test "the SQLite check rejects invalid DDL" do
    assert {output, 1} = Ddl.sqlite(~s[CREATE TABLE t ("a" TEXT, "A" TEXT);])
    assert output =~ "duplicate column name"
  end

  for fixture <- @fixtures, naming <- [:proper, :id] do
    @fixture fixture
    @naming naming
    test "SQLite loads #{Path.basename(fixture)} (#{naming})" do
      assert {"", 0} = Ddl.sqlite(ddl(@fixture, :sqlite, @naming))
    end
  end

  describe "PostgreSQL" do
    @describetag :ddl_postgres

    for fixture <- @fixtures, naming <- [:proper, :id] do
      @fixture fixture
      @naming naming
      test "loads #{Path.basename(fixture)} (#{naming})" do
        url = System.get_env("BUBBLE_EX_DDL_PG") || flunk("set BUBBLE_EX_DDL_PG")
        assert {_, 0} = Ddl.postgres(url, ddl(@fixture, :postgres, @naming))
      end
    end
  end
end
