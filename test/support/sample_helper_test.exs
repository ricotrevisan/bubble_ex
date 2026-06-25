defmodule BubbleEx.SampleHelperTest do
  use ExUnit.Case
  alias BubbleEx.SampleHelper

  describe "load_json_sample/1" do
    test "loads synthetic_app.json" do
      content = SampleHelper.load_json_sample("synthetic_app")
      assert is_map(content)
      assert content["_id"] == "synthapp"
    end
  end

  describe "available_json_samples/0" do
    test "returns list of available JSON samples" do
      samples = SampleHelper.available_json_samples()
      assert is_list(samples)
      assert "synthetic_app" in samples
    end
  end

  describe "available_samples/0" do
    test "returns list of all available samples" do
      samples = SampleHelper.available_samples()
      assert is_list(samples)
      assert "synthetic_app.json" in samples
    end
  end
end
