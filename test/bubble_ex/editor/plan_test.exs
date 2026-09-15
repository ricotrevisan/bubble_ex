defmodule BubbleEx.Editor.PlanTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Editor.{Plan, Snapshot}

  @fixture_path "test/support/editor/scoped_demo_fixture.json"

  test "checks an exact supported leaf against target, revision, and value" do
    path = ["%p3", "page", "%el", "text", "%nm"]
    assert {:ok, plan} = Plan.new(plan([operation("set", path, "Before", "After")]))
    snapshot = snapshot(41, [{path, "Before"}])

    assert :ok = Plan.check(plan, snapshot)

    assert {:error, %BubbleEx.Error{context: %{reason: :stale_revision}}} =
             Plan.check(plan, %{snapshot | last_change: 42})

    assert {:error, %BubbleEx.Error{context: %{reason: :stale_value}}} =
             Plan.check(plan, snapshot(41, [{path, "Somebody else"}]))
  end

  test "rejects unsupported roots, properties and node types" do
    assert {:error, %BubbleEx.Error{context: %{reason: :unsupported_edit}}} =
             Plan.new(plan([operation("set", ["api", "workflow"], nil, true)]))

    assert {:error, %BubbleEx.Error{context: %{reason: :unsupported_edit}}} =
             Plan.new(
               plan([operation("set", ["%p3", "page", "%p", "private_unknown"], nil, true)])
             )

    bad = %{"%x" => "RepeatingGroup", "id" => "unknown"}

    assert {:error, %BubbleEx.Error{context: %{reason: :unsupported_edit}}} =
             Plan.new(plan([operation("put", ["%p3", "page"], nil, bad)]))

    unknown_expression = %{"%x" => "SearchForThings", "%p" => %{}}

    assert {:error, %BubbleEx.Error{context: %{reason: :unsupported_node}}} =
             Plan.new(
               plan([
                 operation(
                   "set",
                   ["%p3", "page", "%el", "text", "%p", "%3"],
                   "Before",
                   unknown_expression
                 )
               ])
             )
  end

  test "accepts the bounded demo fixture and generates indexes for every owned id" do
    fixture = File.read!(@fixture_path) |> Jason.decode!()
    plugin = fixture["plugin_group"]

    source =
      plan(
        [
          operation("put", ["%ed", fixture["reusable_key"]], nil, fixture["reusable"]),
          operation("put", ["%p3", fixture["page_key"]], nil, fixture["page"])
        ],
        [plugin]
      )

    assert {:ok, checked} = Plan.new(source)
    index_paths = checked.operations |> Enum.filter(& &1.internal) |> Enum.map(& &1.path)

    assert ["_index", "id_to_path", "wtf271plugin001"] in index_paths
    assert ["_index", "id_to_path", "wtf271workflow1"] in index_paths
    assert ["_index", "id_to_path", "wtf271instance02"] in index_paths
    assert ["_index", "issues_sub", "wtf271reuse001"] in index_paths

    inverse = Plan.inverse(checked, 99)
    assert Enum.map(inverse["operations"], & &1["op"]) == ["remove", "remove"]
    assert {:ok, _inverse_plan} = Plan.new(inverse)
  end

  test "guards pre-existing references and resolves IDs created in the same plan" do
    existing = %{
      "%x" => "CustomElement",
      "id" => "instance-id",
      "%p" => %{"%ci" => "existing-reusable-id"}
    }

    source =
      plan([operation("put", ["%p3", "page"], nil, page_with(existing))])
      |> Map.put("references", %{"existing-reusable-id" => "%ed.existing_reusable"})

    assert {:ok, checked} = Plan.new(source)

    assert Enum.any?(checked.operations, fn operation ->
             operation.op == :guard and
               operation.path == ["_index", "id_to_path", "existing-reusable-id"] and
               operation.expected == "%ed.existing_reusable"
           end)

    refute Enum.any?(Plan.changes(checked, "session"), fn change ->
             change["path_array"] == ["_index", "id_to_path", "existing-reusable-id"]
           end)

    assert Plan.inverse(checked, 42)["references"] == %{
             "existing-reusable-id" => "%ed.existing_reusable"
           }

    assert {:error, %BubbleEx.Error{message: message}} =
             Plan.new(plan([operation("put", ["%p3", "page"], nil, page_with(existing))]))

    assert message =~ "unresolved"

    fixture = File.read!(@fixture_path) |> Jason.decode!()

    assert {:ok, _checked} =
             Plan.new(
               plan(
                 [
                   operation("put", ["%ed", fixture["reusable_key"]], nil, fixture["reusable"]),
                   operation("put", ["%p3", fixture["page_key"]], nil, fixture["page"])
                 ],
                 [fixture["plugin_group"]]
               )
             )
  end

  test "a removal retains external reference guards for its inverse put" do
    child = %{
      "%x" => "CustomElement",
      "id" => "instance-id",
      "%p" => %{"%ci" => "existing-reusable-id"}
    }

    remove =
      operation("remove", ["%p3", "page", "%el", "child"], child, nil)
      |> Map.merge(%{"owner_id" => "page-id", "owner_issue_ids" => ["instance-id"]})

    source =
      plan([remove])
      |> Map.put("references", %{"existing-reusable-id" => "%ed.existing_reusable"})

    assert {:ok, checked} = Plan.new(source)
    assert {:ok, inverse} = checked |> Plan.inverse(42) |> Plan.new()

    assert Enum.any?(inverse.operations, fn operation ->
             operation.op == :guard and
               operation.path == ["_index", "id_to_path", "existing-reusable-id"]
           end)
  end

  test "rejects duplicate created IDs" do
    duplicate = %{"%x" => "Text", "id" => "same-id", "%p" => %{"%3" => "Hi"}}

    page = %{
      "%x" => "Page",
      "id" => "page-id",
      "%el" => %{"one" => duplicate, "two" => duplicate}
    }

    assert {:error, %BubbleEx.Error{context: %{reason: :duplicate_id}}} =
             Plan.new(plan([operation("put", ["%p3", "page"], nil, page)]))
  end

  test "a property update compiles to one leaf-only SetData change" do
    path = ["%p3", "page", "%el", "text", "%p", "%3"]
    assert {:ok, checked} = Plan.new(plan([operation("set", path, "old", "new")]))
    assert [change] = Plan.changes(checked, "sanitized-session")

    assert change["path_array"] == path
    assert change["body"] == "new"
    assert change["intent"]["name"] == "SetData"
    assert change["version_control_api_version"] == 5
    assert change["session_id"] == "sanitized-session"
  end

  test "an allowlisted installed-plugin property is guarded by the exact node type" do
    plugin_group = "1787127143284x497506916809310200_current"
    plugin_type = plugin_group <> "-AEA"
    path = ["%ed", "reusable", "%el", "plugin", "%p", "AFU"]

    operation =
      operation("set", path, "Before", "After")
      |> Map.put("plugin_type", plugin_type)

    assert {:ok, checked} = Plan.new(plan([operation], [plugin_group]), plugin_schemas())

    assert Enum.any?(checked.operations, fn item ->
             item.op == :guard and
               item.path == ["%ed", "reusable", "%el", "plugin", "%x"] and
               item.expected == plugin_type
           end)

    assert [change] = Plan.changes(checked, "session")
    assert change["path_array"] == path

    assert [inverse] = Plan.inverse(checked, 42)["operations"]
    assert inverse["plugin_type"] == plugin_type

    unsupported =
      operation("set", List.replace_at(path, -1, "ZZZ"), nil, true)
      |> Map.put("plugin_type", plugin_type)

    assert {:error, %BubbleEx.Error{context: %{reason: :unsupported_edit}}} =
             Plan.new(plan([unsupported], [plugin_group]), plugin_schemas())
  end

  test "plugin node suffixes and workflow action roles are bounded" do
    plugin_group = "1787127143284x497506916809310200_current"

    unknown_plugin = %{"%x" => plugin_group <> "-ZZZ", "id" => "plugin-id"}

    assert {:error, %BubbleEx.Error{context: %{reason: :unsupported_edit}}} =
             Plan.new(
               plan(
                 [operation("put", ["%p3", "page", "%el", "plugin"], nil, unknown_plugin)],
                 [plugin_group]
               ),
               plugin_schemas()
             )

    workflow = %{
      "%x" => "ButtonClicked",
      "id" => "workflow-id",
      "actions" => %{"0" => %{"%x" => "Text", "id" => "not-an-action"}}
    }

    assert {:error, %BubbleEx.Error{message: message}} =
             Plan.new(
               plan([
                 operation("put", ["%p3", "page", "%wf", "clicked"], nil, workflow)
               ])
             )

    assert message =~ "unsupported workflow action"
  end

  test "same-owner move updates the node and every owned id path, and cross-owner moves fail" do
    from = ["%p3", "page", "%el", "old_group"]
    to = ["%p3", "page", "%el", "new_parent", "%el", "moved_group"]

    node = %{
      "%x" => "Group",
      "id" => "group-id",
      "%el" => %{"text" => %{"%x" => "Text", "id" => "text-id", "%p" => %{"%3" => "Hi"}}}
    }

    source =
      plan([
        %{"op" => "move", "from" => from, "to" => to, "expected" => node}
      ])

    assert {:ok, checked} = Plan.new(source)
    assert Enum.at(checked.operations, 0).path == to
    assert Enum.at(checked.operations, 1).path == from

    assert Enum.any?(checked.operations, fn operation ->
             operation.path == ["_index", "id_to_path", "text-id"] and
               operation.expected == "%p3.page.%el.old_group.%el.text" and
               operation.value == "%p3.page.%el.new_parent.%el.moved_group.%el.text"
           end)

    inverse = Plan.inverse(checked, 42)
    assert [%{"op" => "move", "from" => ^to, "to" => ^from}] = inverse["operations"]
    assert {:ok, _} = Plan.new(inverse)

    cross_owner =
      plan([
        %{
          "op" => "move",
          "from" => from,
          "to" => ["%ed", "reusable", "%el", "moved"],
          "expected" => node
        }
      ])

    assert {:error, %BubbleEx.Error{context: %{reason: :cross_owner_move}}} =
             Plan.new(cross_owner)
  end

  test "nested create and remove guard and update the owner's shared issue index" do
    path = ["%p3", "page", "%el", "new_group"]

    node = %{
      "%x" => "Group",
      "id" => "group-id",
      "%el" => %{"text" => %{"%x" => "Text", "id" => "text-id", "%p" => %{"%3" => "Hi"}}}
    }

    put =
      operation("put", path, nil, node)
      |> Map.merge(%{"owner_id" => "page-id", "owner_issue_ids" => ["existing-id"]})

    assert {:ok, checked} = Plan.new(plan([put]))

    assert Enum.any?(checked.operations, fn operation ->
             operation.path == ["_index", "issues_sub", "page-id"] and
               operation.expected == ~s(["existing-id"]) and
               operation.value == ~s(["existing-id","group-id","text-id"])
           end)

    inverse = Plan.inverse(checked, 42)

    assert [
             %{
               "op" => "remove",
               "owner_id" => "page-id",
               "owner_issue_ids" => ["existing-id", "group-id", "text-id"]
             }
           ] = inverse["operations"]

    assert {:ok, inverse_checked} = Plan.new(inverse)

    assert Enum.any?(inverse_checked.operations, fn operation ->
             operation.path == ["_index", "issues_sub", "page-id"] and
               operation.expected == ~s(["existing-id","group-id","text-id"]) and
               operation.value == ~s(["existing-id"])
           end)
  end

  test "nested create and remove refuse to guess owner issue indexes" do
    node = %{"%x" => "Text", "id" => "text-id", "%p" => %{"%3" => "Hi"}}
    path = ["%p3", "page", "%el", "text"]

    assert {:error, %BubbleEx.Error{message: message}} =
             Plan.new(plan([operation("put", path, nil, node)]))

    assert message =~ "owner_id"

    without_ids =
      operation("remove", path, node, nil)
      |> Map.put("owner_id", "page-id")

    assert {:error, %BubbleEx.Error{message: message}} = Plan.new(plan([without_ids]))
    assert message =~ "owner_issue_ids"
  end

  defp plan(operations, plugin_types \\ []) do
    %{
      "appname" => "tiptap-plugin",
      "version" => "43jvs",
      "base_last_change" => 41,
      "plugin_types" => plugin_types,
      "operations" => operations
    }
  end

  defp operation("remove", path, expected, _value),
    do: %{"op" => "remove", "path" => path, "expected" => expected}

  defp operation(op, path, expected, value),
    do: %{"op" => op, "path" => path, "expected" => expected, "value" => value}

  defp page_with(child) do
    %{"%x" => "Page", "id" => "page-id", "%el" => %{"child" => child}}
  end

  defp plugin_schemas do
    raw = File.read!("test/support/editor/discovered_plugin_contracts.json") |> Jason.decode!()
    group = "1787127143284x497506916809310200_current"
    {:ok, schema} = BubbleEx.Editor.PluginSchema.normalize(group, "current", raw["popover"])
    %{group => schema}
  end

  defp snapshot(revision, values) do
    entries =
      Map.new(values, fn {path, value} -> {Snapshot.key(path), %{path: path, value: value}} end)

    %Snapshot{appname: "tiptap-plugin", version: "43jvs", last_change: revision, entries: entries}
  end
end
