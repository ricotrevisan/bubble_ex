defmodule BubbleEx.Characterization.DbGoldenTest do
  # Golden output of every `BubbleEx.Db.Encoder` format for the synthetic
  # fixtures (all data invented): `Reader.parse/1`, then `Encoder.render/3`
  # with default options. Each golden holds the rendered content and the
  # result's diagnostics (code and path), so any change in what an encoder
  # emits shows up as a reviewable diff.
  #
  # Regenerate after an intended change with
  #
  #     BUBBLE_EX_UPDATE_GOLDEN=1 mix test test/characterization/db_golden_test.exs
  #
  # and explain the diff in the PR.
  use ExUnit.Case, async: true

  alias BubbleEx.Db.{Encoder, Reader}

  @golden "test/support/db/golden"
  @formats ~w(dbml postgres sqlite tsql ecto zod xano convex)a

  @fixtures Enum.sort(
              Path.wildcard("test/support/model/*.json") ++
                ~w(test/support/samples/synthetic_app.json test/support/samples/synthetic_export.json)
            )

  defp render(app, format) do
    {:ok, db} = Reader.parse(app)
    {:ok, result} = Encoder.render(format, db)
    diagnostics = Enum.map_join(result.diagnostics, "", &"#{&1.code} #{&1.path}\n")
    result.content <> "--- diagnostics ---\n" <> diagnostics
  end

  for fixture <- @fixtures, format <- @formats do
    @fixture fixture
    @format format
    name = Path.basename(fixture, ".json")
    @path Path.join(@golden, "#{name}.#{format}.txt")

    test "#{name} renders its #{format} golden" do
      actual = @fixture |> File.read!() |> Jason.decode!() |> render(@format)

      if System.get_env("BUBBLE_EX_UPDATE_GOLDEN") do
        File.mkdir_p!(@golden)
        File.write!(@path, actual)
      end

      assert File.exists?(@path), "missing golden #{@path}; set BUBBLE_EX_UPDATE_GOLDEN=1"
      assert actual == File.read!(@path)
    end
  end

  test "every golden has a fixture and format" do
    expected =
      for fixture <- @fixtures,
          format <- @formats,
          do: "#{Path.basename(fixture, ".json")}.#{format}.txt"

    assert @golden |> File.ls!() |> Enum.sort() == Enum.sort(expected)
  end
end
