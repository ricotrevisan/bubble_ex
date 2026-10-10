defmodule BubbleEx.AppDefinitionTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{AppDefinition, Diagnostic, Error, Frontend, Model}
  alias BubbleEx.Frontend.EditorGeometry

  @moduletag :tmp_dir

  test "loads JSON objects regardless of extension, preserving editor geometry and model", %{
    tmp_dir: dir
  } do
    raw = %{
      "_id" => "local-app",
      "user_types" => %{
        "task" => %{
          "display" => "Task",
          "fields" => %{"title_text" => %{"display" => "Title", "value" => "text"}}
        }
      },
      "settings" => %{"private" => "unscanned-secret"}
    }

    for extension <- ["bubble", "json", "unknown"] do
      path = Path.join(dir, "app.#{extension}")
      File.write!(path, Jason.encode!(raw))

      assert {:ok, %AppDefinition{} = definition} = AppDefinition.load(path)
      assert definition.app == EditorGeometry.mark(raw)
      assert EditorGeometry.editor?(definition.app)
      assert {:ok, definition.app} == Frontend.read_bubble_export(path)
      assert {:ok, definition.model} == Model.build(definition.app)
      assert Model.matches?(definition.model, definition.app)
      assert definition.source == %{kind: :bubble_export, geometry: :editor, metadata: %{}}
      assert definition.app["settings"]["private"] == "unscanned-secret"
      refute inspect(definition.source) =~ dir
    end
  end

  test "returns normalized model diagnostics without dropping malformed model members", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "malformed-model.bubble")
    File.write!(path, Jason.encode!(%{"user_types" => %{"bad-secret-id" => 42}}))

    assert {:ok, definition} = AppDefinition.load(path)
    assert definition.diagnostics != []
    assert definition.diagnostics == Diagnostic.normalize(definition.model.diagnostics)
    assert definition.app["user_types"]["bad-secret-id"] == 42
  end

  test "rejects invalid paths and unsupported directories without exposing paths", %{tmp_dir: dir} do
    split = Path.join(dir, "legacy-split")
    File.mkdir_p!(Path.join(split, "data_types/t"))
    File.write!(Path.join(split, "data_types/t/type.json"), "{}")

    for path <- [nil, 42, [], "", Path.join(dir, "missing"), dir, split, <<0>>] do
      assert {:error, %Error{kind: :invalid_input} = error} = AppDefinition.load(path)
      refute inspect(error) =~ dir
    end
  end

  test "delegates malformed JSON and non-object errors without echoing contents", %{tmp_dir: dir} do
    for {name, body} <- [
          {"broken", "{unscanned-secret"},
          {"array", "[]"},
          {"null", "null"},
          {"number", "42"},
          {"string", ~s("unscanned-secret")}
        ] do
      path = Path.join(dir, name)
      File.write!(path, body)
      assert {:error, %Error{kind: :parse_failed} = error} = AppDefinition.load(path)
      assert {:error, error} == Frontend.read_bubble_export(path)
      refute inspect(error) =~ "unscanned-secret"
      refute inspect(error) =~ dir
    end
  end

  test "validates options even for files and rejects malformed or unknown options", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "app.json")
    File.write!(path, "{}")

    for opts <- [
          nil,
          %{},
          :bad,
          ["bad"],
          [{"max_index_bytes", 1}],
          [{:max_index_bytes}],
          [max_index_bytes: 0],
          [max_index_bytes: -1],
          [max_index_bytes: 1.5],
          [max_index_bytes: "1"],
          [max_index_bytes: nil],
          [max_index_bytes: 1, max_index_bytes: 0],
          [unknown: "unscanned-secret"],
          [max_index_bytes: 1, unknown: true]
        ] do
      assert {:error, %Error{kind: :invalid_input} = error} = AppDefinition.load(path, opts)
      refute inspect(error) =~ "unscanned-secret"
      refute inspect(error) =~ dir
    end

    assert {:ok, _} = AppDefinition.load(path, max_index_bytes: 1)
  end
end
