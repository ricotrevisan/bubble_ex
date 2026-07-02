defmodule BubbleEx.AppTree.SplitterTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree.Splitter

  @source %{"file" => "synthetic_export.json", "sha256" => "abc123"}

  setup do
    app = BubbleEx.SampleHelper.load_json_sample("synthetic_export")
    {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, @source)
    {:ok, app: app, entries: entries, manifest: manifest, paths: Enum.map(entries, &elem(&1, 0))}
  end

  test "produces the spec'd paths", %{paths: paths} do
    assert "pages/index/page.json" in paths
    assert "pages/index/workflows/reset-form--wfReset.json" in paths
    assert "pages/index/workflows/button-clicked-btn-go--wfClick.json" in paths
    assert "components/left-nav--cmpNav/component.json" in paths
    assert "components/left-nav--cmpNav/workflows/nav-reset--wfNav.json" in paths
    # malformed entry preserved as a raw file, not a folder
    assert "components/weird.json" in paths
    assert "api/update-avatar--apiAvatar.json" in paths
    assert "data/types/task--task.json" in paths
    assert "data/option-sets/status--status.json" in paths
    assert "styles/styles.json" in paths
    assert "settings/settings.json" in paths
    # unclaimed top-level keys land in meta/ verbatim
    assert "meta/_id.json" in paths
    assert "meta/app_version.json" in paths
    assert "meta/uid_counter.json" in paths
  end

  test "page.json content is the page without its workflows key", %{entries: entries} do
    {_, {:json, page}} = Enum.find(entries, fn {p, _} -> p == "pages/index/page.json" end)
    refute Map.has_key?(page, "workflows")
    assert page["name"] == "index"
    assert page["id"] == "pgroot"
  end

  test "manifest ids cover pages, workflows, components, api, data", %{manifest: m} do
    assert m["version"] == 1
    assert m["source"] == @source
    assert m["ids"]["page:pgA"]["kind"] == "page"
    assert m["ids"]["page:pgA"]["key"] == "pgA"
    assert m["ids"]["page:pgA"]["path"] == "pages/index/page.json"
    assert m["ids"]["page:pgA"]["workflows_present"] == true
    assert m["ids"]["workflow:wfReset"]["kind"] == "workflow"
    assert m["ids"]["workflow:wfReset"]["parent"] == "pgA"
    assert m["ids"]["component_raw:weird"]["kind"] == "component_raw"
    assert m["ids"]["api_workflow:apiAvatar"]["kind"] == "api_workflow"
    assert m["ids"]["user_type:task"]["kind"] == "user_type"
    assert m["ids"]["option_set:status"]["kind"] == "option_set"
  end

  test "round-trip: reassemble(split(app)) deep-equals the original", %{
    app: app,
    entries: entries,
    manifest: manifest
  } do
    assert {:ok, rebuilt} = Splitter.reassemble(entries, manifest)
    assert rebuilt == app
  end

  describe "lossless edge cases" do
    test "an empty workflows map round-trips to an empty map" do
      app = %{
        "pages" => %{
          "pgE" => %{"id" => "x", "name" => "empty", "workflows" => %{}, "elements" => %{}}
        }
      }

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      assert manifest["ids"]["page:pgE"]["workflows_present"] == true
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "a container without a workflows key gets none added back" do
      app = %{"pages" => %{"pgN" => %{"id" => "y", "name" => "bare"}}}

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      assert manifest["ids"]["page:pgN"]["workflows_present"] == false
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "a non-map workflows value is left inside the container JSON and round-trips" do
      app = %{
        "pages" => %{
          "pgNil" => %{"id" => "y2", "name" => "nilwf", "workflows" => nil}
        }
      }

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      {_, {:json, page}} = Enum.find(entries, fn {p, _} -> p == "pages/nilwf/page.json" end)
      assert page["workflows"] == nil
      assert manifest["ids"]["page:pgNil"]["workflows_present"] == false
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "absent styles and settings produce no files and do not reappear" do
      app = %{"uid_counter" => 1}

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      paths = Enum.map(entries, &elem(&1, 0))
      refute "styles/styles.json" in paths
      refute "settings/settings.json" in paths
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "a malformed page entry is preserved as a raw file with kind page_raw" do
      app = %{"pages" => %{"bad" => 7}}

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      assert {"pages/bad.json", {:json, 7}} in entries
      assert manifest["ids"]["page_raw:bad"]["kind"] == "page_raw"
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "empty sections survive the round-trip" do
      app = %{"pages" => %{}, "option_sets" => %{}, "uid_counter" => 1}

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "a non-map workflow entry is preserved raw and round-trips" do
      app = %{
        "pages" => %{
          "pgW" => %{
            "id" => "z",
            "name" => "raw-wf",
            "workflows" => %{
              "wfOk" => %{
                "id" => "w",
                "type" => "CustomEvent",
                "properties" => %{"event_name" => "E"},
                "actions" => %{}
              },
              "wfBad" => 5
            }
          }
        }
      }

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      assert {"pages/raw-wf/workflows/wfBad.json", {:json, 5}} in entries
      assert manifest["ids"]["workflow_raw:wfBad"]["kind"] == "workflow_raw"
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "a non-map api entry is preserved raw with kind api_workflow_raw" do
      app = %{"api" => %{"bad" => 5}}

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      assert {"api/bad.json", {:json, 5}} in entries
      assert manifest["ids"]["api_workflow_raw:bad"]["kind"] == "api_workflow_raw"
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "non-map user_type and option_set entries get _raw kinds and round-trip" do
      app = %{"user_types" => %{"bad" => 5}, "option_sets" => %{"bad" => []}}

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      assert manifest["ids"]["user_type_raw:bad"]["kind"] == "user_type_raw"
      assert manifest["ids"]["option_set_raw:bad"]["kind"] == "option_set_raw"
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "a non-map whole section is preserved verbatim under meta/ and round-trips" do
      app = %{"api" => nil, "pages" => 42}

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      assert {"meta/api.json", {:json, nil}} in entries
      assert {"meta/pages.json", {:json, 42}} in entries
      refute "api" in manifest["sections"]
      refute "pages" in manifest["sections"]
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end
  end

  describe "manifest id key collisions across kinds" do
    test "a user_type and an option_set sharing a raw key round-trip without collision" do
      app = %{
        "user_types" => %{"status" => %{"display" => "Status T", "fields" => %{}}},
        "option_sets" => %{"status" => %{"display" => "Status O", "values" => %{}}}
      }

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      assert manifest["ids"]["user_type:status"]["kind"] == "user_type"
      assert manifest["ids"]["user_type:status"]["key"] == "status"
      assert manifest["ids"]["option_set:status"]["kind"] == "option_set"
      assert manifest["ids"]["option_set:status"]["key"] == "status"
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end
  end

  describe "page slug collisions" do
    test "two pages with colliding slugs get key-suffixed dirs and round-trip" do
      app = %{
        "pages" => %{
          "p1" => %{"id" => "x1", "name" => "about_us"},
          "p2" => %{"id" => "x2", "name" => "about-us"}
        }
      }

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      paths = Enum.map(entries, &elem(&1, 0))

      assert "pages/about-us--p1/page.json" in paths
      assert "pages/about-us--p2/page.json" in paths
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end

    test "an emoji-only page name slugs to the bare key" do
      app = %{"pages" => %{"pgBug" => %{"id" => "z", "name" => "🐞"}}}

      {:ok, %{entries: entries, manifest: manifest}} = Splitter.split(app, %{})
      paths = Enum.map(entries, &elem(&1, 0))

      assert "pages/pgBug/page.json" in paths
      assert {:ok, ^app} = Splitter.reassemble(entries, manifest)
    end
  end
end
