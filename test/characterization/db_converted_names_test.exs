defmodule BubbleEx.Characterization.DbConvertedNamesTest do
  # Every encoder that converts names (Ecto, Convex, Xano, Zod) declares each
  # name once per scope for every schema golden fixture, in both namings
  # (WTF-391); `BubbleEx.Test.NameCheck` lists what it checks. The Ecto
  # output also parses as Elixir here; `scripts/ash_compile_check.sh` (CI's
  # ash-compile-check job) compiles it against Ecto.
  use ExUnit.Case, async: true

  alias BubbleEx.Db.{Encoder, Reader}
  alias BubbleEx.Test.NameCheck

  @fixtures Enum.sort(
              Path.wildcard("test/support/model/*.json") ++
                Path.wildcard("test/support/db/fixtures/*.json") ++
                ~w(test/support/samples/synthetic_app.json test/support/samples/synthetic_export.json)
            )

  for fixture <- @fixtures, format <- ~w(ecto convex xano zod)a, naming <- [:proper, :id] do
    @fixture fixture
    @format format
    @naming naming

    test "#{Path.basename(fixture, ".json")} #{format} (#{naming}) repeats no name" do
      {:ok, db} = @fixture |> File.read!() |> Jason.decode!() |> Reader.parse()
      {:ok, result} = Encoder.render(@format, db, naming: @naming)
      assert NameCheck.duplicates(@format, result.content) == []
    end
  end
end
