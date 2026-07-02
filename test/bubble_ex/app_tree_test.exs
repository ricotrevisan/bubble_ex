defmodule BubbleEx.AppTreeTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree
  alias BubbleEx.AppTree.Splitter

  @fixture "test/support/samples/synthetic_export.json"

  describe "generate/3" do
    @tag :tmp_dir
    test "writes the full two-layer tree", %{tmp_dir: tmp} do
      out = Path.join(tmp, "tree")

      assert {:ok, %{files: files, coverage: coverage, out_dir: ^out}} =
               AppTree.generate(@fixture, out)

      assert files > 15

      # Layer 1
      assert File.exists?(Path.join(out, "pages/index/page.json"))
      assert File.exists?(Path.join(out, "pages/index/workflows/reset-form--wfReset.json"))
      assert File.exists?(Path.join(out, "components/left-nav--cmpNav/component.json"))
      assert File.exists?(Path.join(out, "components/weird.json"))
      assert File.exists?(Path.join(out, "api/update-avatar--apiAvatar.json"))
      assert File.exists?(Path.join(out, "meta/uid_counter.json"))

      # Layer 2
      assert File.exists?(Path.join(out, "pages/index/OUTLINE.md"))
      assert File.exists?(Path.join(out, "pages/index/WORKFLOWS.md"))
      assert File.exists?(Path.join(out, "components/left-nav--cmpNav/OUTLINE.md"))
      assert File.exists?(Path.join(out, "api/API.md"))
      assert File.exists?(Path.join(out, "data/schema.dbml"))
      assert File.exists?(Path.join(out, "styles/STYLES.md"))
      assert File.exists?(Path.join(out, "settings/SETTINGS.md"))
      assert File.exists?(Path.join(out, "README.md"))
      assert File.exists?(Path.join(out, "AGENTS.md"))
      assert File.exists?(Path.join(out, "MANIFEST.json"))

      # honest coverage: fixture has plugin + unknown actions (unrendered);
      # all four fixture expressions render fully (amended during execution —
      # PageData text parts are :ok, not :partial)
      assert coverage.actions == %{total: 7, rendered: 5}
      assert coverage.expressions == %{total: 4, rendered: 4}

      # schema.dbml went through the export-shape adapter
      assert File.read!(Path.join(out, "data/schema.dbml")) =~ "Task"
    end

    @tag :tmp_dir
    test "round-trips from disk: Layer-1 files + manifest rebuild the original export", %{
      tmp_dir: tmp
    } do
      out = Path.join(tmp, "tree")
      {:ok, _} = AppTree.generate(@fixture, out)

      manifest = out |> Path.join("MANIFEST.json") |> File.read!() |> Jason.decode!()

      entries =
        out
        |> Path.join("**/*.json")
        |> Path.wildcard()
        |> Enum.map(&{Path.relative_to(&1, out), {:json, &1 |> File.read!() |> Jason.decode!()}})

      original = @fixture |> File.read!() |> Jason.decode!()
      assert {:ok, ^original} = Splitter.reassemble(entries, manifest)
    end

    @tag :tmp_dir
    test "surfaces missing file and bad JSON as BubbleEx.Error", %{tmp_dir: tmp} do
      assert {:error, %BubbleEx.Error{kind: :not_found}} =
               AppTree.generate(Path.join(tmp, "nope.json"), Path.join(tmp, "o1"))

      bad = Path.join(tmp, "bad.json")
      File.write!(bad, "{not json")

      assert {:error, %BubbleEx.Error{kind: :parse_failed}} =
               AppTree.generate(bad, Path.join(tmp, "o2"))
    end

    @tag :tmp_dir
    test "refuses a non-empty out_dir without force", %{tmp_dir: tmp} do
      out = Path.join(tmp, "occupied")
      File.mkdir_p!(out)
      File.write!(Path.join(out, "x"), "x")

      assert {:error, %BubbleEx.Error{kind: :invalid_input}} = AppTree.generate(@fixture, out)
      assert {:ok, _} = AppTree.generate(@fixture, out, force: true)
    end

    @tag :tmp_dir
    test "a hostile export never raises: generate/3 succeeds and Layer 1 round-trips", %{
      tmp_dir: tmp
    } do
      hostile = %{
        "_id" => "hostile",
        "pages" => %{
          "pgOk" => %{"id" => "p1", "name" => "ok", "elements" => 5, "workflows" => nil},
          "pgNonMapWf" => %{"id" => "p2", "name" => "nonmap", "elements" => 5, "workflows" => 5},
          "bad" => 7
        },
        "element_definitions" => %{"weird" => 42},
        "api" => %{"bad" => 5},
        "user_types" => %{"bad" => 5, "ghost" => %{"display" => "Ghost"}},
        "option_sets" => %{"bad" => []},
        "styles" => nil,
        "settings" => 12
      }

      path = Path.join(tmp, "hostile.json")
      File.write!(path, Jason.encode!(hostile))
      out = Path.join(tmp, "tree")

      assert {:ok, %{files: files}} = AppTree.generate(path, out)
      assert files > 0

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(hostile, %{})
      assert {:ok, ^hostile} = Splitter.reassemble(entries, manifest)
    end
  end
end
