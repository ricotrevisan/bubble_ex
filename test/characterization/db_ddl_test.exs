defmodule BubbleEx.Characterization.DbDdlTest do
  # The generated DDL must load. SQLite DDL for every golden fixture, in both
  # namings, is executed in an in-memory database (python3's sqlite3 module,
  # present on CI runners and dev machines). PostgreSQL DDL is executed in a
  # fresh database per fixture when BUBBLE_EX_DDL_PG names a server (a URL
  # without a database, e.g. postgres://postgres:postgres@localhost:5432);
  # CI runs it in the ash-compile-check job, next to its PostgreSQL service.
  # Both foreign-key modes load; by default (foreign_keys: :none) a row
  # holding dangling references, as real Bubble data does, inserts too:
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

  @dangling_fixture "test/support/samples/synthetic_app.json"
  @dangling_columns ~s[("_id", "onboarding answer", "status", "Created By")]
  @dangling_values "('r1', 'deleted-answer', 'deleted-status', 'deleted-user');"

  defp ddl(fixture, format, naming, foreign_keys) do
    {:ok, db} = fixture |> File.read!() |> Jason.decode!() |> Reader.parse()
    {:ok, result} = Encoder.render(format, db, naming: naming, foreign_keys: foreign_keys)
    result.content
  end

  # Every reference of the synthetic Survey Response points at nothing.
  defp dangling_sqlite(foreign_keys) do
    ddl(@dangling_fixture, :sqlite, :proper, foreign_keys) <>
      "\nPRAGMA foreign_keys = ON;\n" <>
      ~s[INSERT INTO "custom__Survey Response" #{@dangling_columns} VALUES #{@dangling_values}\n]
  end

  defp dangling_postgres(foreign_keys) do
    ddl(@dangling_fixture, :postgres, :proper, foreign_keys) <>
      ~s[\nINSERT INTO "custom"."Survey Response" #{@dangling_columns} VALUES #{@dangling_values}\n]
  end

  test "the SQLite check rejects invalid DDL" do
    assert {output, 1} = Ddl.sqlite(~s[CREATE TABLE t ("a" TEXT, "A" TEXT);])
    assert output =~ "duplicate column name"
  end

  for fixture <- @fixtures, naming <- [:proper, :id], foreign_keys <- [:none, :enforced] do
    @fixture fixture
    @naming naming
    @foreign_keys foreign_keys
    test "SQLite loads #{Path.basename(fixture)} (#{naming}, foreign_keys: #{foreign_keys})" do
      assert {"", 0} = Ddl.sqlite(ddl(@fixture, :sqlite, @naming, @foreign_keys))
    end
  end

  test "SQLite accepts a row with dangling references by default, even with the pragma on" do
    assert {"", 0} = Ddl.sqlite(dangling_sqlite(:none))
  end

  test "SQLite with foreign_keys: :enforced rejects a row with dangling references" do
    assert {output, 1} = Ddl.sqlite(dangling_sqlite(:enforced))
    assert output =~ "FOREIGN KEY constraint failed"
  end

  describe "PostgreSQL" do
    @describetag :ddl_postgres

    for fixture <- @fixtures, naming <- [:proper, :id], foreign_keys <- [:none, :enforced] do
      @fixture fixture
      @naming naming
      @foreign_keys foreign_keys
      test "loads #{Path.basename(fixture)} (#{naming}, foreign_keys: #{foreign_keys})" do
        assert {_, 0} = Ddl.postgres(pg_url(), ddl(@fixture, :postgres, @naming, @foreign_keys))
      end
    end

    test "accepts a row with dangling references by default" do
      assert {_, 0} = Ddl.postgres(pg_url(), dangling_postgres(:none))
    end

    test "with foreign_keys: :enforced, rejects a row with dangling references" do
      assert {output, code} = Ddl.postgres(pg_url(), dangling_postgres(:enforced))
      assert code != 0
      assert output =~ "violates foreign key constraint"
    end
  end

  defp pg_url, do: System.get_env("BUBBLE_EX_DDL_PG") || flunk("set BUBBLE_EX_DDL_PG")
end
