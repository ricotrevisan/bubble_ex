defmodule BubbleEx.AppTree.WriterTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree.Writer

  @entries [
    {"a/b.json", {:json, %{"x" => 1}}},
    {"README.md", {:text, "# hi\n"}}
  ]

  @tag :tmp_dir
  test "writes nested entries and returns the count", %{tmp_dir: tmp} do
    out = Path.join(tmp, "out")
    assert {:ok, 2} = Writer.write(out, @entries, [])
    assert File.read!(Path.join(out, "README.md")) == "# hi\n"
    assert Path.join(out, "a/b.json") |> File.read!() |> Jason.decode!() == %{"x" => 1}
  end

  @tag :tmp_dir
  test "refuses a non-empty target without force", %{tmp_dir: tmp} do
    out = Path.join(tmp, "out")
    File.mkdir_p!(out)
    File.write!(Path.join(out, "existing.txt"), "x")

    assert {:error, %BubbleEx.Error{kind: :invalid_input}} = Writer.write(out, @entries, [])
    assert {:ok, 2} = Writer.write(out, @entries, force: true)
  end

  @tag :tmp_dir
  test "surfaces disk write failures (via AppTree.generate) as :invalid_input", %{tmp_dir: tmp} do
    # Skip if running as root (File.chmod has no effect for root)
    root? = System.cmd("id", ["-u"]) == {"0\n", 0}
    if root?, do: :skip

    # Create a synthetic export and attempt to write to a location where
    # mkdir_p will fail (a file already exists where the dir would be)
    hostile = %{
      "_id" => "test",
      "pages" => %{"p1" => %{"id" => "p1", "name" => "test", "elements" => %{}}},
      "element_definitions" => %{},
      "api" => %{},
      "user_types" => %{},
      "option_sets" => %{},
      "styles" => %{},
      "settings" => %{}
    }

    path = Path.join(tmp, "test.json")
    File.write!(path, Jason.encode!(hostile))

    # Create a file where the output directory should be
    out = Path.join(tmp, "out_blocked")
    File.write!(out, "blocking_file")

    # AppTree.generate should return {:error, :invalid_input}, not :parse_failed
    result = BubbleEx.AppTree.generate(path, out)
    assert {:error, %BubbleEx.Error{kind: :invalid_input}} = result
  end
end
