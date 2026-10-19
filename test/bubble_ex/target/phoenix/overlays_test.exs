defmodule BubbleEx.Target.Phoenix.OverlaysTest do
  # WTF-559: which Popups and Group Focuses render their contents only
  # while open (BubbleEx.Target.Phoenix.Overlays), on synthetic trees.
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec
  alias BubbleEx.Target.Phoenix.Overlays

  @popup %{"boundary" => "overlay", "overlay" => "popup", "initial" => "hidden"}
  @cells %{"boundary" => "container", "repeats" => true}

  defp node(id, kind, children \\ [], extra \\ []) do
    struct!(
      Node,
      [
        exporter_id: id,
        kind: kind,
        map_key: id,
        source: %{bubble_id: id},
        children: children
      ] ++ extra
    )
  end

  defp popup(id, children), do: node(id, :popup, children, runtime: @popup)
  defp instance(id, of), do: node(id, :reusable_instance, [], definition_ref: of)

  defp hide(element), do: %{op: :hide, args: %{target: %{path: [], element: element}}}

  defp surface(kind, steps \\ [], inputs \\ %{}),
    do: %{kind: kind, workflows: [%{steps: steps}], states: [], inputs: inputs}

  defp lazy(flows, pages, reusables) do
    surfaces = Enum.map(pages ++ reusables, &{&1.map_key, &1, &1.map_key})

    Overlays.lazy(flows, surfaces, reusables,
      bid: & &1.map_key,
      scoped: MapSet.new(reusables, & &1.map_key),
      surface_id: & &1.map_key
    )
  end

  test "a popup in a repeating group's cell renders as before; one outside it does not" do
    page =
      node("p", :page, [
        popup("pOut", [node("t1", :text)]),
        node("rg", :placeholder, [popup("pCell", [node("t2", :text)])], runtime: @cells)
      ])

    flows = %Spec{surfaces: %{"p" => surface(:page)}}
    assert lazy(flows, [page], [])["p"] == MapSet.new(["pOut"])
  end

  test "a nested reusable element that shows or hides its own elements keeps the popup as before" do
    # p > popup > instance of A > instance of B; B hides its own text.
    b = node("B", :reusable_definition, [node("bText", :text)])
    a = node("A", :reusable_definition, [instance("aB", "B")])
    page = node("p", :page, [popup("pop", [instance("pA", "A")])])

    plain = %Spec{
      surfaces: %{"p" => surface(:page), "A" => surface(:reusable), "B" => surface(:reusable)}
    }

    assert lazy(plain, [page], [a, b])["p"] == MapSet.new(["pop"])

    hiding = put_in(plain.surfaces["B"], surface(:reusable, [hide("bText")]))
    assert lazy(hiding, [page], [a, b])["p"] == MapSet.new()

    # A cycle (A renders itself) keeps nothing more.
    cyclic = node("A", :reusable_definition, [instance("aA", "A")])
    assert lazy(plain, [page], [cyclic, b])["p"] == MapSet.new(["pop"])
  end

  test "only tracked text inputs keep a popup lazy" do
    page = fn control -> node("p", :page, [popup("pop", [node("c", control)])]) end
    tracked = %Spec{surfaces: %{"p" => surface(:page, [], %{"c" => :text})}}
    untracked = %Spec{surfaces: %{"p" => surface(:page)}}

    assert lazy(tracked, [page.(:input)], [])["p"] == MapSet.new(["pop"])
    assert lazy(tracked, [page.(:multiline_input)], [])["p"] == MapSet.new(["pop"])
    assert lazy(untracked, [page.(:input)], [])["p"] == MapSet.new()

    # The page renders a checkbox's and a dropdown's first value: tracked
    # or not, they keep the popup as before.
    for control <- [:checkbox, :dropdown, :radio_buttons] do
      assert lazy(tracked, [page.(control)], [])["p"] == MapSet.new(), inspect(control)
    end
  end
end
