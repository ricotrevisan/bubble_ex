defmodule BubbleEx.Target.Ash.BoundaryTest do
  # WTF-342 boundary check: renderers only print. `mix xref` must show no
  # path (compile, export or runtime; transitive) from a renderer to the
  # Model, the Reader or the mapper that reads them.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @renderers [
    "lib/bubble_ex/target/ash/source.ex",
    # The Phoenix target (WTF-369) prints a Project too.
    "lib/bubble_ex/target/phoenix.ex",
    "lib/bubble_ex/target/phoenix/manifest.ex",
    "lib/bubble_ex/target/phoenix/templates.ex"
  ]

  defp forbidden do
    [
      ~r{^lib/bubble_ex/model\.ex$},
      ~r{^lib/bubble_ex/model/},
      ~r{^lib/bubble_ex/db/reader(\.ex$|/)},
      ~r{^lib/bubble_ex/target/ash\.ex$}
    ]
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

  for file <- @renderers do
    @file_path file
    test "#{file} depends on neither the Model nor the Reader" do
      deps = dependencies(@file_path)

      if @file_path != "lib/bubble_ex/target/phoenix/templates.ex",
        do: assert("lib/bubble_ex/target/ash/project.ex" in deps, inspect(deps))

      for dep <- deps, pattern <- forbidden() do
        refute Regex.match?(pattern, dep), "#{@file_path} depends on #{dep}"
      end
    end
  end

  test "the check sees a real dependency on the Model" do
    assert "lib/bubble_ex/model.ex" in dependencies("lib/bubble_ex/target/ash.ex")
  end
end
