defmodule BubbleEx.AppTree.Render.ReadmeTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree.{Render.Readme, Splitter}

  setup do
    app = BubbleEx.SampleHelper.load_json_sample("synthetic_export")
    {:ok, %{manifest: manifest}} = Splitter.split(app, %{"file" => "x.json", "sha256" => "abc"})
    coverage = %{actions: %{total: 7, rendered: 5}, expressions: %{total: 4, rendered: 3}}
    {:ok, entries: Readme.render(app, manifest, coverage), manifest: manifest}
  end

  test "produces README.md, AGENTS.md and MANIFEST.json", %{entries: entries} do
    assert Enum.map(entries, &elem(&1, 0)) |> Enum.sort() == [
             "AGENTS.md",
             "MANIFEST.json",
             "README.md"
           ]
  end

  test "README reports counts and honest coverage", %{entries: entries} do
    {_, {:text, iodata}} = Enum.find(entries, fn {p, _} -> p == "README.md" end)
    text = IO.iodata_to_binary(iodata)

    assert text =~ "# synthexport — AppTree export"
    assert text =~ "- Pages: 1"
    assert text =~ "- Components: 2"
    assert text =~ "- Backend workflows: 1"
    assert text =~ "- Data types: 2"
    assert text =~ "- Option sets: 1"
    assert text =~ "Actions rendered semantically: 5/7"
    assert text =~ "Expressions rendered: 3/4"
  end

  test "AGENTS.md carries the concept map and navigation rules", %{entries: entries} do
    {_, {:text, iodata}} = Enum.find(entries, fn {p, _} -> p == "AGENTS.md" end)
    text = IO.iodata_to_binary(iodata)

    assert text =~ "| pages | routes / views |"
    assert text =~ "MANIFEST.json"
    assert text =~ "ground truth"
  end

  test "MANIFEST.json entry is the manifest plus coverage", %{
    entries: entries,
    manifest: manifest
  } do
    {_, {:json, m}} = Enum.find(entries, fn {p, _} -> p == "MANIFEST.json" end)
    assert m["ids"] == manifest["ids"]

    assert m["coverage"] == %{
             "actions" => %{"total" => 7, "rendered" => 5},
             "expressions" => %{"total" => 4, "rendered" => 3}
           }
  end

  test "schema: true (default) marks the schema as present", %{entries: entries} do
    {_, {:json, m}} = Enum.find(entries, fn {p, _} -> p == "MANIFEST.json" end)
    assert m["schema_dbml"] == true
  end

  describe "schema: false" do
    setup %{manifest: manifest} do
      app = BubbleEx.SampleHelper.load_json_sample("synthetic_export")
      coverage = %{actions: %{total: 0, rendered: 0}, expressions: %{total: 0, rendered: 0}}
      {:ok, entries: Readme.render(app, manifest, coverage, schema: false)}
    end

    test "MANIFEST.json records the schema as absent", %{entries: entries} do
      {_, {:json, m}} = Enum.find(entries, fn {p, _} -> p == "MANIFEST.json" end)
      assert m["schema_dbml"] == false
    end

    test "AGENTS.md omits the data/schema.dbml pointer", %{entries: entries} do
      {_, {:text, iodata}} = Enum.find(entries, fn {p, _} -> p == "AGENTS.md" end)
      text = IO.iodata_to_binary(iodata)
      refute text =~ "data/schema.dbml"
    end
  end
end
