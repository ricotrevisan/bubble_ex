defmodule BubbleEx.WorkflowsTest do
  use ExUnit.Case, async: true
  alias BubbleEx.{Error, Workflows}

  defp app(workflows) do
    %{
      "pages" => %{
        "home" => %{
          "workflows" => workflows,
          "elements" => %{"button" => %{"id" => "button-id", "name" => "Save"}}
        }
      },
      "element_definitions" => %{},
      "mobile_views" => %{},
      "api" => %{},
      "user_types" => %{"task" => %{"display" => "Task"}}
    }
  end

  test "accounts for page, reusable and backend workflows, including unknown types" do
    payload = File.read!("test/support/samples/synthetic_export.json") |> Jason.decode!()
    assert {:ok, i} = Workflows.inventory(payload)
    assert i.coverage.workflow_entries == 4
    assert i.coverage.action_entries == 7
    assert Enum.any?(i.diagnostics, &(&1.code == "unsupported_type"))
    assert Enum.any?(i.diagnostics, &(&1.code == "malformed_owner"))
    assert Enum.all?(i.workflows, &(at_pointer(payload, &1.path) == &1.raw))

    assert Enum.all?(
             Enum.flat_map(i.workflows, & &1.actions),
             &(at_pointer(payload, &1.path) == &1.raw)
           )
  end

  test "keeps numeric order, conditions, data/element/previous-step references and unknown expressions" do
    condition = %{"type" => "FutureExpression", "private" => nil, "next" => [false, 0]}

    workflow = %{
      "id" => "wf",
      "type" => "ButtonClicked",
      "properties" => %{"element_id" => "button-id", "condition" => condition},
      "actions" => %{
        "10" => %{
          "type" => "APIReturnData",
          "properties" => %{"result" => %{"action_id" => "created"}}
        },
        "2" => %{
          "id" => "created",
          "type" => "NewThing",
          "properties" => %{"type_to_create" => "custom.task", "condition" => false}
        },
        "0" => %{"type" => "ShowElement", "properties" => %{"element_id" => "button-id"}}
      }
    }

    assert {:ok, i} = Workflows.inventory(app(%{"save" => workflow}))
    assert [w] = i.workflows
    assert w.ordering == "numeric_keys"
    assert Enum.map(w.actions, & &1.source_key) == ["0", "2", "10"]
    assert [%{raw: ^condition, status: "unresolved"}] = w.event.conditions
    assert [%{status: "resolved"}] = w.event.references
    assert [%{kind: "data_type", status: "resolved"}] = Enum.at(w.actions, 1).references
    assert [%{kind: "action", status: "resolved"}] = Enum.at(w.actions, 2).references
    assert [%{raw: false, status: "fully_supported"}] = Enum.at(w.actions, 1).conditions
    assert w.raw == workflow
  end

  test "compact workflow and condition keys are supported without mistaking width for workflows" do
    w = %{
      "%x" => "ButtonClicked",
      "%p" => %{"%ei" => "missing", "%c" => false},
      "actions" => [%{"%x" => "NewThing", "%p" => %{"%tt" => "custom.absent"}}]
    }

    payload = %{"%p3" => %{"p" => %{"%p" => %{"%w" => 320}, "%wf" => %{"w" => w}}}}
    assert {:ok, i} = Workflows.inventory(payload)
    assert [w] = i.workflows
    assert w.event.type == "ButtonClicked"
    assert [%{raw: false}] = w.event.conditions
    assert w.ordering == "array_order"
    assert [%{status: "unavailable"}] = w.event.references
    refute Enum.any?(i.scopes, &String.ends_with?(&1.path, "/%w"))
  end

  test "unavailable definitions are not reported as no workflows" do
    assert {:ok, %{availability: "unavailable", workflows: []}} = Workflows.inventory(%{})
    assert {:ok, %{availability: "empty", workflows: []}} = Workflows.inventory(app(%{}))

    assert {:ok, %{availability: "unavailable"}} =
             Workflows.inventory(%{"pages" => %{"index" => %{"name" => "index"}}})

    assert {:ok, %{availability: "partial"}} =
             Workflows.inventory(%{
               "workflows" => %{"w" => %{"type" => "CustomEvent", "actions" => %{}}}
             })
  end

  test "malformed owners, collections, nodes, properties and actions remain visible" do
    for malformed <- [nil, false, 12, "unavailable"] do
      assert {:ok, i} = Workflows.inventory(app(malformed))
      assert i.availability == "partial"
      assert Enum.any?(i.scopes, &(&1.status == "malformed" and &1.raw == malformed))
    end

    assert {:ok, i} =
             Workflows.inventory(
               app(%{
                 "broken" => false,
                 "odd" => %{"type" => [], "properties" => 7, "actions" => "bad"}
               })
             )

    assert i.coverage.workflow_entries == 2
    assert Enum.any?(i.diagnostics, &(&1.code == "malformed_node"))
    assert Enum.any?(i.diagnostics, &(&1.code == "malformed_actions"))
    assert Enum.any?(i.diagnostics, &(&1.code == "malformed_properties"))
  end

  test "malformed action entries and unknown ordering are never dropped or assigned invented order" do
    for actions <- [%{"z" => false, "first" => 1}, %{"01" => %{}, "1" => nil}, %{"-1" => %{}}] do
      assert {:ok, i} =
               Workflows.inventory(
                 app(%{"w" => %{"type" => "CustomEvent", "actions" => actions}})
               )

      assert [w] = i.workflows
      assert w.ordering == "unresolved"
      assert length(w.actions) == map_size(actions)
      assert Enum.any?(i.diagnostics, &(&1.code == "unresolved_order"))
    end
  end

  test "duplicate reference identities are ambiguous and references cannot cross element scopes" do
    payload =
      app(%{
        "w" => %{
          "type" => "ButtonClicked",
          "properties" => %{"element_id" => "button-id"},
          "actions" => %{}
        }
      })

    duplicate = put_in(payload, ["pages", "home", "elements", "second"], %{"id" => "button-id"})
    assert {:ok, %{workflows: [w]}} = Workflows.inventory(duplicate)
    assert [%{status: "ambiguous", candidates: [_, _]}] = w.event.references

    other_page =
      put_in(payload, ["pages", "home", "elements"], %{})
      |> put_in(["pages", "other"], %{"elements" => %{"button-id" => %{}}, "workflows" => %{}})

    assert {:ok, %{workflows: [w]}} = Workflows.inventory(other_page)
    assert [%{status: "unavailable"}] = w.event.references
  end

  test "JSON pointers escape source keys and machine output preserves null, false and unknown values" do
    raw = %{
      "type" => "PluginMystery",
      "condition" => nil,
      "opaque" => [nil, false, 0],
      "actions" => []
    }

    payload = app(%{"a/b~c" => raw})
    assert {:ok, artifacts} = Workflows.render(payload)
    decoded = Jason.decode!(artifacts.json)
    assert [w] = decoded["workflows"]
    assert w["path"] == "/pages/home/workflows/a~1b~0c"
    assert w["raw"] == raw
    assert at_pointer(payload, w["path"]) == raw
    assert artifacts.markdown =~ "Unsupported construct"
    assert {:ok, ^artifacts} = Workflows.render(payload)
  end

  test "Markdown cannot break out of retained source fences" do
    assert {:ok, %{markdown: md}} =
             Workflows.render(
               app(%{
                 "<script>[click](https://example.com)" => %{
                   "type" => "Mystery",
                   "payload" => "```\n<script>bad</script>",
                   "actions" => %{}
                 }
               })
             )

    assert md =~ "````json"
    assert md =~ "&lt;script&gt;"
    refute md =~ "### /pages/home/workflows/<script>"
  end

  test "public entry points reject non-JSON terms with typed errors" do
    for value <- [
          nil,
          [],
          false,
          "json",
          %{:atom => 1},
          %{"nested" => self()},
          %{"invalid" => <<255>>},
          %{"struct" => %Error{}}
        ] do
      assert {:error, %Error{kind: :invalid_input}} = Workflows.inventory(value)
      assert {:error, %Error{kind: :invalid_input}} = Workflows.render(value)
    end
  end

  @tag :tmp_dir
  test "exports both reports and refuses to overwrite existing evidence", %{tmp_dir: dir} do
    out = Path.join(dir, "inventory")
    assert {:ok, _} = Workflows.export(app(%{}), out)
    assert Jason.decode!(File.read!(Path.join(out, "inventory.json")))["availability"] == "empty"
    assert File.read!(Path.join(out, "WORKFLOWS.md")) =~ "Nothing was executed"
    assert {:error, %Error{kind: :invalid_input}} = Workflows.export(app(%{}), out)
    assert {:error, %Error{}} = Workflows.export(app(%{}), Path.join(out, "inventory.json"))
  end

  test "collection length metadata is retained separately and never counted as a workflow" do
    payload =
      app(%{"length" => 0, "w" => %{"type" => "CustomEvent", "actions" => %{"length" => 0}}})
      |> put_in(["pages", "length"], 0)

    assert {:ok, i} = Workflows.inventory(payload)
    assert i.coverage.workflow_entries == 1
    assert i.coverage.action_entries == 0
    assert i.coverage.malformed_scopes == 0
    assert length(i.collection_metadata) == 2
    assert [w] = i.workflows
    assert [%{raw: 0, path: "/pages/home/workflows/w/actions/length"}] = w.action_metadata
    assert {:ok, %{markdown: md}} = Workflows.render(payload)
    assert md =~ "Collection metadata"
  end

  test "navigation element_id resolves a page, while reusable self references remain scoped" do
    payload =
      app(%{
        "go" => %{
          "type" => "PageLoaded",
          "actions" => [%{"type" => "ChangePage", "properties" => %{"element_id" => "target"}}]
        }
      })
      |> put_in(["pages", "target"], %{"name" => "Target", "workflows" => %{}})

    assert {:ok, %{workflows: [w]}} = Workflows.inventory(payload)
    assert [%{kind: "page", status: "resolved"}] = hd(w.actions).references
  end

  test "missing actions, alias collisions and unfamiliar workflow locations are explicit" do
    payload = %{
      "future_container" => %{
        "workflows" => %{"w" => %{"type" => "CustomEvent", "%x" => "FutureEvent"}}
      }
    }

    assert {:ok, %{workflows: [w], diagnostics: diagnostics}} = Workflows.inventory(payload)
    assert w.ordering == "unavailable"
    assert Enum.any?(diagnostics, &(&1.code == "alias_collision"))
    assert w.raw["%x"] == "FutureEvent"
  end

  test "improper lists are rejected as non-JSON rather than raising" do
    assert {:error, %Error{kind: :invalid_input}} = Workflows.inventory(%{"workflows" => [1 | 2]})
  end

  test "unfamiliar and historical action-bearing definitions are reported separately" do
    candidate = %{"type" => "FutureEvent", "actions" => [%{"type" => "FutureAction"}]}
    payload = app(%{}) |> Map.put("future_workflow_shape", candidate)
    assert {:ok, i} = Workflows.inventory(payload)
    assert i.workflows == []
    assert i.availability == "partial"
    assert [%{raw: ^candidate}] = i.unclassified_definitions
    assert i.coverage.unclassified_candidates == 1
    assert i.coverage.workflow_entries == 0
    assert Enum.any?(i.diagnostics, &(&1.code == "unclassified_definition"))
  end

  test "explicit null properties are malformed and malformed-owner pointers locate retained values" do
    payload =
      app(%{"w" => %{"type" => "PageLoaded", "properties" => nil, "actions" => []}})
      |> put_in(["pages", "bad"], false)

    assert {:ok, i} = Workflows.inventory(payload)

    assert Enum.any?(
             i.diagnostics,
             &(&1.code == "malformed_properties" and
                 &1.path == "/pages/home/workflows/w/properties")
           )

    scope = Enum.find(i.scopes, &(&1.status == "malformed"))
    assert scope.path == "/pages/bad"
    assert at_pointer(payload, scope.path) == scope.raw
  end

  defp at_pointer(payload, pointer) do
    pointer
    |> String.split("/")
    |> tl()
    |> Enum.reduce(payload, fn escaped, value ->
      key = escaped |> String.replace("~1", "/") |> String.replace("~0", "~")
      if is_list(value), do: Enum.at(value, String.to_integer(key)), else: Map.fetch!(value, key)
    end)
  end
end
