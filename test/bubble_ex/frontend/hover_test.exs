defmodule BubbleEx.Frontend.HoverTest do
  # "is hovered" conditionals moved to the node's hover rules (WTF-590),
  # on synthetic apps (all invented).
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.{Conditions, Hover}

  @fixture "test/support/target/phoenix/hover.json"

  defp hovered(element \\ nil, next \\ nil) do
    message = %{"type" => "Message", "name" => "is_hovered"}
    message = if next, do: Map.put(message, "next", next), else: message

    if element,
      do: %{"type" => "GetElement", "properties" => %{"element_id" => element}, "next" => message},
      else: %{"type" => "ThisElement", "next" => message}
  end

  defp nodes(root), do: [root | Enum.flat_map(root.children, &nodes/1)]

  defp node(frontend, id) do
    frontend.pages
    |> Enum.flat_map(&nodes/1)
    |> Enum.find(&(&1.source.bubble_id == id))
  end

  defp normalize(app) do
    {:ok, frontend} = BubbleEx.Frontend.normalize(app)
    frontend
  end

  defp states(node) do
    case node.bindings["condition"] do
      %{payload: payload} -> Conditions.keyed(payload)
      nil -> []
    end
  end

  defp page(elements) do
    %{
      "_id" => "hover-unit",
      "pages" => %{
        "index" => %{
          "id" => "bHome",
          "name" => "index",
          "type" => "Page",
          "elements" => Map.new(elements, &{&1["id"], &1})
        }
      }
    }
  end

  defp el(id, type, order, opts \\ []) do
    props = Map.merge(%{"order" => order, "width" => 100, "height" => 20}, opts[:props] || %{})

    %{"id" => id, "type" => type, "properties" => props}
    |> then(&if opts[:states], do: Map.put(&1, "states", opts[:states]), else: &1)
    |> then(
      &if opts[:children],
        do: Map.put(&1, "elements", Map.new(opts[:children], fn c -> {c["id"], c} end)),
        else: &1
    )
  end

  describe "targets/1" do
    test "this element, another element and an or of them" do
      assert Hover.targets(hovered()) == [:self]
      assert Hover.targets(hovered("bA")) == ["bA"]

      either = hovered("bA", %{"type" => "Message", "name" => "or_", "args" => hovered("bB")})
      assert Hover.targets(either) == ["bA", "bB"]
    end

    test "anything else read alongside is not a hover condition" do
      both =
        hovered(nil, %{
          "type" => "Message",
          "name" => "and_",
          "args" => %{
            "type" => "CurrentUser",
            "next" => %{"type" => "Message", "name" => "logged_in"}
          }
        })

      assert Hover.targets(both) == nil

      assert Hover.targets(%{
               "type" => "CurrentUser",
               "next" => %{"type" => "Message", "name" => "logged_in"}
             }) == nil

      assert Hover.targets(nil) == nil
    end
  end

  describe "the fixture" do
    setup do
      %{frontend: @fixture |> File.read!() |> Jason.decode!() |> normalize()}
    end

    test "own, ancestor, sibling and descendant hovers move to rules", %{frontend: f} do
      assert [
               %{
                 "on" => [%{"element" => "self"}],
                 "paint" => %{"font_color" => "rgba(200, 0, 0, 1)"},
                 "visible" => nil
               }
             ] =
               node(f, "bCardTitle").hover

      assert [
               %{
                 "on" => [%{"element" => "bCard", "relation" => "ancestor"}],
                 "paint" => %{},
                 "visible" => true
               }
             ] =
               node(f, "bCardTools").hover

      assert [
               %{
                 "on" => [
                   %{"element" => "bCardTitle", "relation" => "within", "within" => "bCard"}
                 ],
                 "paint" => %{"background" => "rgba(0, 0, 200, 1)"}
               }
             ] = node(f, "bCardDot").hover

      assert [%{"on" => [%{"element" => "bRowIcon", "relation" => "descendant"}]}] =
               node(f, "bRow").hover

      assert [%{"on" => [%{"element" => "bZero", "relation" => "ancestor"}], "visible" => true}] =
               node(f, "bZeroShown").hover

      # Their conditionals are gone: nothing is left for the server.
      for id <- ~w(bCardTitle bCardTools bCardDot bRow bZeroShown),
          do: assert(node(f, id).bindings["condition"] == nil, id)
    end

    test "a hover with another condition, or before a later visibility state, stays", %{
      frontend: f
    } do
      assert node(f, "bComboVis").hover == []
      assert [{"0", _}] = states(node(f, "bComboVis"))

      assert node(f, "bOrder").hover == []
      assert [{"0", _}, {"1", _}] = states(node(f, "bOrder"))
    end
  end

  test "a state's properties a stylesheet does not set stay, with its condition" do
    props = %{"bgcolor" => "#ff0000", "underline" => true, "padding_top" => 4}

    app =
      page([
        el("bT", "Text", 1, states: %{"0" => %{"condition" => hovered(), "properties" => props}})
      ])

    t = app |> normalize() |> node("bT")

    assert [%{"paint" => %{"background" => "#ff0000", "text-decoration-line" => "underline"}}] =
             t.hover

    assert [{"0", %{properties: %{"padding_top" => 4}}}] = states(t)
  end

  test "a later hover state wins: the rules keep Bubble's order" do
    app =
      page([
        el("bG", "Group", 1,
          children: [el("bA", "Text", 1), el("bB", "Text", 2)],
          states: %{
            "0" => %{"condition" => hovered("bA"), "properties" => %{"bgcolor" => "#111111"}},
            "1" => %{"condition" => hovered("bB"), "properties" => %{"bgcolor" => "#222222"}}
          }
        )
      ])

    assert [%{"state" => "0"}, %{"state" => "1"}] =
             app |> normalize() |> node("bG") |> Map.get(:hover)
  end

  test "an element read in a repeating group's cell, or outside the page's tree, is not told apart" do
    cell = el("bCellText", "Text", 1)

    app =
      page([
        el("bList", "RepeatingGroup", 1,
          props: %{"data_source" => nil},
          children: [cell]
        ),
        el("bOut", "Text", 2,
          states: %{
            "0" => %{
              "condition" => hovered("bCellText"),
              "properties" => %{"bgcolor" => "#333333"}
            }
          }
        ),
        el("bLost", "Text", 3,
          states: %{
            "0" => %{
              "condition" => hovered("bNowhere"),
              "properties" => %{"bgcolor" => "#444444"}
            }
          }
        ),
        el("bPageRead", "Text", 4,
          states: %{
            "0" => %{"condition" => hovered("bHome"), "properties" => %{"bgcolor" => "#555555"}}
          }
        )
      ])

    f = normalize(app)

    for id <- ~w(bOut bLost bPageRead) do
      assert node(f, id).hover == [], id
      assert [{"0", _}] = states(node(f, id))
    end
  end
end
