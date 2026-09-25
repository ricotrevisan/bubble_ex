defmodule BubbleEx.Db.OneInterpretationTest do
  # WTF-365: `BubbleEx.Model` is the one interpretation of data types, fields,
  # option sets and API Connector types. `BubbleEx.Db` (the Reader and every
  # encoder) only projects and renders it, and the Model never depends on
  # `BubbleEx.Db`, so there is no cycle and no second parser.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @db_sources Path.wildcard("lib/bubble_ex/db/**/*.ex")

  # Members of the app JSON that only a parser of data types, fields, option
  # sets or API Connector settings reads.
  @source_keys ~w(%f3 %v %d %del default_val sort_factor attributes values user_types option_sets apiconnector2 client_safe)

  # JSON pointers the encoder builds for diagnostics on hand-built db maps
  # (a projected column always has its own `source_path`).
  @allowed [
    {"lib/bubble_ex/db/encoder.ex", "option_sets"},
    {"lib/bubble_ex/db/encoder.ex", "user_types"}
  ]

  test "no BubbleEx.Db module reads Bubble's source keys" do
    offenders =
      for file <- @db_sources,
          source = File.read!(file),
          key <- @source_keys,
          String.contains?(source, ~s("#{key}")),
          {file, key} not in @allowed,
          do: {file, key}

    assert offenders == []
  end

  test "no BubbleEx.Db module pattern-matches a Bubble type descriptor" do
    descriptor = ~r/\(\s*"(?:list|custom|option|api|user)\.?[^"]*"\s*<>\s*[a-z_]/

    offenders = for file <- @db_sources, Regex.match?(descriptor, File.read!(file)), do: file
    assert offenders == []
  end

  test "the Reader reads through the Model" do
    assert "lib/bubble_ex/model.ex" in dependencies("lib/bubble_ex/db/reader.ex")
  end

  test "the Model does not depend on BubbleEx.Db" do
    for file <- ["lib/bubble_ex/model.ex" | Path.wildcard("lib/bubble_ex/model/**/*.ex")],
        dep <- dependencies(file) do
      refute String.starts_with?(dep, "lib/bubble_ex/db/"), "#{file} depends on #{dep}"
    end
  end

  defp dependencies(file) do
    output =
      capture_io(fn ->
        Mix.Task.rerun("xref", ["graph", "--source", file, "--format", "plain", "--no-compile"])
      end)

    ~r{lib/\S+\.ex}
    |> Regex.scan(output)
    |> List.flatten()
    |> Enum.uniq()
  end
end
