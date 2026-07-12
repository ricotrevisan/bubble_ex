defmodule BubbleEx.Db.Encoder.PlanTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Db.Encoder.Plan

  test "orders dependencies, classifies mutual cycle edges, and disambiguates names" do
    a = "api.apiconnector2.one.call.Node"
    b = "api.apiconnector2.two.call.Node"

    node = fn id, target ->
      %{
        id: id,
        resolution: :resolved,
        fields: [
          %{
            id: "next",
            path: ["next"],
            type: %{type: :external, target: target, cardinality: :one}
          }
        ]
      }
    end

    plan = Plan.build(%{external_types: [node.(b, a), node.(a, b)]})
    assert plan.names[a] == "Node_#{a}"
    assert plan.names[b] == "Node_#{b}"
    assert Enum.sort(plan.order) == Enum.sort([a, b])
    assert MapSet.size(plan.cycle_edges) == 1
    assert Plan.cycle_edge?(plan, a, "next") or Plan.cycle_edge?(plan, b, "next")

    reordered = Plan.build(%{external_types: [node.(a, b), node.(b, a)]})
    assert reordered == plan
  end

  test "disambiguates normalized external member collisions deterministically" do
    id = "api.apiconnector2.one.call.Shape"

    fields = [
      %{
        id: "a",
        caption: "Foo Bar",
        path: ["a"],
        type: %{type: :scalar, scalar: :text, cardinality: :one}
      },
      %{
        id: "b",
        caption: "foo_bar",
        path: ["b"],
        type: %{type: :scalar, scalar: :text, cardinality: :one}
      }
    ]

    plan =
      Plan.build(%{
        external_types: [%{id: id, resolution: :resolved, fields: Enum.reverse(fields)}]
      })

    assert Plan.field_name(plan, id, hd(fields)) == "Foo Bar_a"

    assert Plan.field_name(plan, id, List.last(fields)) == "foo_bar_b"
  end

  test "honors naming mode and excludes empty contracts from typed nodes" do
    id = "api.apiconnector2.one.call.RawShape"

    node = %{
      id: id,
      caption: "Display Shape",
      resolution: :resolved,
      fields: [
        %{
          id: "raw_field",
          caption: "Display Field",
          path: ["x"],
          type: %{type: :scalar, scalar: :text, cardinality: :one}
        }
      ]
    }

    proper = Plan.build(%{external_types: [node]}, naming: :proper)
    raw = Plan.build(%{external_types: [node]}, naming: :id)
    assert Plan.name(proper, id) == "DisplayShape"
    assert Plan.name(raw, id) == "RawShape"
    assert Plan.field_name(proper, id, hd(node.fields)) == "Display Field"
    assert Plan.field_name(raw, id, hd(node.fields)) == "raw_field"

    empty = %{id: id, caption: "Empty", resolution: :resolved_empty, fields: []}
    refute Plan.resolved?(Plan.build(%{external_types: [empty]}), id)
  end
end
