defmodule BubbleEx.Editor.PluginSchemaTest do
  use ExUnit.Case, async: true
  alias BubbleEx.Editor.PluginSchema

  defp raw do
    Jason.decode!(File.read!("test/support/editor/discovered_plugin_contracts.json"))["popover"]
  end

  test "discovers arbitrary plugin identities without a product inventory" do
    for group <- ["123x456_current", "987x654"] do
      assert {:ok, schema} = PluginSchema.normalize(group, "current", raw())
      assert schema.nodes[group <> "-AEA"].name == "Modern Popover"
      assert schema.nodes[group <> "-AEB"].role == :actions
      assert schema.nodes[group <> "-AEB"].owner == group <> "-AEA"
      assert schema.nodes[group <> "-AEG"].role == :workflows
    end
  end

  test "hash pins declarative contract and version, but excludes executable source" do
    assert {:ok, first} = PluginSchema.normalize("123x456", "1", raw())

    assert {:ok, same} =
             PluginSchema.normalize("123x456", "1", Map.put(raw(), "headers", "secret"))

    assert first.hash == same.hash
    refute inspect(same) =~ "secret"
    assert {:ok, changed} = PluginSchema.normalize("123x456", "2", raw())
    refute first.hash == changed.hash
    changed_raw = put_in(raw(), ["plugin_elements", "AEA", "fields", "AFU", "value"], "number")
    assert {:ok, changed} = PluginSchema.normalize("123x456", "1", changed_raw)
    refute first.hash == changed.hash
  end

  test "mobile contracts do not authorize web element edits" do
    raw = put_in(raw(), ["plugin_elements", "AEA", "platform_type"], "mobile")
    assert {:ok, %{nodes: nodes}} = PluginSchema.normalize("123x456", "1", raw)
    assert nodes == %{}
  end

  test "schema transport rejects redirects and malformed bodies without disclosing contents" do
    {:ok, target} = BubbleEx.Editor.Target.new("demo", "child", "secret-cookie")

    for {status, body} <- [{302, "secret-cookie"}, {200, "secret-cookie"}] do
      get = fn _url, _headers, _opts ->
        {:ok,
         %BubbleEx.HTTP.Response{
           status_code: status,
           body: body,
           headers: [],
           request_url: "https://bubble.io"
         }}
      end

      assert {:error, error} = BubbleEx.Editor.Client.plugin(target, "123x456", "1", get_fun: get)
      refute inspect(error) =~ "secret-cookie"
    end
  end

  test "enforces discovered field types and enum options, rejecting unsupported editors" do
    fields = raw()["plugin_elements"]["AEA"]["fields"]
    assert :ok = PluginSchema.validate_value(fields["AFU"], "label")
    assert :ok = PluginSchema.validate_value(fields["AFJ"], 8)
    assert :ok = PluginSchema.validate_value(fields["AFG"], false)
    assert :ok = PluginSchema.validate_value(fields["AFF"], "Anchored")

    for {key, value} <- [
          {"AFU", 8},
          {"AFJ", "8"},
          {"AFG", "false"},
          {"AFF", "unknown"},
          {"AFV", "label"}
        ] do
      assert {:error, %BubbleEx.Error{kind: :invalid_input}} =
               PluginSchema.validate_value(fields[key], value)
    end
  end

  test "exposes Tiptap string identifiers and states without assuming three-letter codes" do
    raw =
      Jason.decode!(File.read!("test/support/editor/discovered_plugin_contracts.json"))["tiptap"]

    assert {:ok, schema} = PluginSchema.normalize("123x456_current", "current", raw)
    assert schema.nodes["123x456_current-toc_element"].fields["accessible_label"]
    assert schema.nodes["123x456_current-heading_clicked"].role == :workflows
  end
end
