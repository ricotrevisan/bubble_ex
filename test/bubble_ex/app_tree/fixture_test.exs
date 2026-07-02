defmodule BubbleEx.AppTree.FixtureTest do
  use ExUnit.Case, async: true

  test "synthetic_export fixture decodes and covers the shapes AppTree needs" do
    app = BubbleEx.SampleHelper.load_json_sample("synthetic_export")

    assert app["_id"] == "synthexport"
    # page map key deliberately differs from the inner "id" field, as in real exports
    assert app["pages"]["pgA"]["id"] == "pgroot"
    assert app["pages"]["pgA"]["name"] == "index"
    # malformed component entry is present
    assert app["element_definitions"]["weird"] == 42
    # export-shaped user_types (readable keys, not %d/%f3)
    assert app["user_types"]["task"]["fields"]["title_text"]["value"] == "text"
    assert app["option_sets"]["status"]["values"]["v1"]["db_value"] == "open"
  end
end
