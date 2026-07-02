defmodule BubbleEx.AppTree.NamesTest do
  use ExUnit.Case, async: true

  alias BubbleEx.AppTree.Names

  describe "slug/1" do
    test "downcases, strips emoji, folds accents, collapses separators" do
      assert Names.slug("🏠 Left Nav") == "left-nav"
      assert Names.slug("BTN: Submit Ent") == "btn-submit-ent"
      assert Names.slug("Café  Menu") == "cafe-menu"
      assert Names.slug("PU: Contact Form") == "pu-contact-form"
    end

    test "returns empty string for nil or unsluggable input" do
      assert Names.slug(nil) == ""
      assert Names.slug("🐞") == ""
      assert Names.slug("") == ""
    end
  end

  describe "entry_name/2" do
    test "joins slug and id with --" do
      assert Names.entry_name("🏠 Left Nav", "cmpNav") == "left-nav--cmpNav"
    end

    test "falls back to bare id when slug is empty" do
      assert Names.entry_name(nil, "weird") == "weird"
      assert Names.entry_name("🐞", "bTdbg") == "bTdbg"
    end
  end

  describe "element_name/1" do
    test "prefers properties.original_name, then name, then default_name" do
      assert Names.element_name(%{
               "properties" => %{"original_name" => "grp-main"},
               "name" => "x"
             }) == "grp-main"

      assert Names.element_name(%{"name" => "🏠 Left Nav"}) == "🏠 Left Nav"
      assert Names.element_name(%{"default_name" => "Text A"}) == "Text A"
      assert Names.element_name(%{"properties" => %{}}) == nil
      assert Names.element_name(42) == nil
    end
  end

  describe "element_names/1" do
    test "indexes every element id across pages and components" do
      app = BubbleEx.SampleHelper.load_json_sample("synthetic_export")
      names = Names.element_names(app)

      assert names["elGrp"] == "grp-main"
      assert names["elBtn"] == "BTN: Go"
      assert names["elTxt"] == "Text A"
      assert names["elNavTxt"] == "Text N"
    end
  end

  describe "workflow_file_name/3" do
    setup do
      {:ok, names: %{"elBtn" => "BTN: Go"}}
    end

    test "uses event_name when present", %{names: names} do
      wf = %{"type" => "CustomEvent", "properties" => %{"event_name" => "Reset Form"}}
      assert Names.workflow_file_name("wfReset", wf, names) == "reset-form--wfReset"
    end

    test "uses wf_name for backend workflows", %{names: names} do
      wf = %{"type" => "APIEvent", "properties" => %{"wf_name" => "update-avatar"}}
      assert Names.workflow_file_name("apiAvatar", wf, names) == "update-avatar--apiAvatar"
    end

    test "falls back to event type + target element name", %{names: names} do
      wf = %{"type" => "ButtonClicked", "properties" => %{"element_id" => "elBtn"}}
      assert Names.workflow_file_name("wfClick", wf, names) == "button-clicked-btn-go--wfClick"
    end

    test "falls back to bare key when nothing is nameable" do
      assert Names.workflow_file_name("wfX", %{"properties" => %{}}, %{}) == "wfX"
    end
  end
end
