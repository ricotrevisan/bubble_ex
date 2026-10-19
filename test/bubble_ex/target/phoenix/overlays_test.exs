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

  # --- elements hidden by their conditions (option c) ---------------------------

  @visible %{
    "0" => %{"condition" => %{"type" => "CurrentUser"}, "properties" => %{"is_visible" => true}}
  }

  defp conditional(id, children),
    do:
      node(id, :group, children,
        bindings: %{"condition" => %{kind: :condition, payload: @visible}}
      )

  defp step(op, element, extra \\ %{}),
    do: Map.merge(%{op: op, element: element, args: %{}, residue: []}, extra)

  defp hidden_contents(flows, pages, reusables, opts \\ []) do
    surfaces = Enum.map(pages ++ reusables, &{&1.map_key, &1, &1.map_key})

    Overlays.hidden_contents(
      flows,
      surfaces,
      reusables,
      [bid: & &1.map_key, surface_id: & &1.map_key] ++ opts
    )
  end

  test "a group hidden by its conditions renders its contents only while visible, unless a step shows it" do
    page = node("p", :page, [conditional("g", [node("t", :text)])])
    plain = %Spec{surfaces: %{"p" => surface(:page)}}
    assert hidden_contents(plain, [page], [])["p"] == MapSet.new(["g"])

    # Without workflows, nothing is proven.
    assert hidden_contents(nil, [page], []) == %{"p" => MapSet.new()}

    # A show, hide or toggle of it, or a step this target does not lower
    # (an animation, a plugin's action), in any surface's workflows.
    for s <- [
          hide("g"),
          step(:toggle, "g"),
          step(:animate, "g"),
          step(nil, "g", %{type: "plugin-action"}),
          step(:show, "t"),
          step(:focus, "t"),
          step(:reset_group, "t"),
          step(nil, "t")
        ] do
      flows = put_in(plain.surfaces["other"], surface(:page, [s]))
      assert hidden_contents(flows, [page], [])["p"] == MapSet.new(), inspect(s)
    end

    # Server-side steps naming what is inside keep it: the page renders
    # what they set.
    for op <- [:display_data, :display_list, :set_state, :call_reusable, :navigate] do
      flows = put_in(plain.surfaces["p"], surface(:page, [step(op, "t")]))
      assert hidden_contents(flows, [page], [])["p"] == MapSet.new(["g"]), inspect(op)
    end

    # ... unless it has residue (not lowered).
    unlowered = step(:set_state, "t", %{residue: [%{reason: :uncompiled_expression}]})
    flows = put_in(plain.surfaces["p"], surface(:page, [unlowered]))
    assert hidden_contents(flows, [page], [])["p"] == MapSet.new()
  end

  test "a step on an ancestor does not matter; an overlay, a cell and a leaf are not candidates" do
    page =
      node("p", :page, [
        node("outer", :group, [conditional("g", [node("t", :text)])]),
        node("rg", :placeholder, [conditional("gCell", [node("t2", :text)])], runtime: @cells),
        conditional("leaf", [])
      ])

    flows = %Spec{surfaces: %{"p" => surface(:page, [hide("outer"), step(nil, "outer")])}}
    assert hidden_contents(flows, [page], [])["p"] == MapSet.new(["g"])
  end

  test "no control, and no plugin element with states, inside" do
    page = fn child -> node("p", :page, [conditional("g", [child])]) end
    flows = %Spec{surfaces: %{"p" => surface(:page, [], %{"c" => :text})}}

    # Even a tracked text input: a reconnect may hide and show it.
    for kind <- [:input, :multiline_input, :checkbox, :dropdown, :slider] do
      assert hidden_contents(flows, [page.(node("c", kind))], [])["p"] == MapSet.new(),
             inspect(kind)
    end

    plugin = node("pl", :placeholder, [], attributes: %{"data-placeholder-kind" => "1x1-AAC"})
    states = %{"__bubble_ex_plugin_states__" => %{"1x1-AAC" => %{"AAD" => %{"value" => "text"}}}}
    none = %{"__bubble_ex_plugin_states__" => %{"1x1-AAE" => %{"AAD" => %{"value" => "text"}}}}

    assert hidden_contents(flows, [page.(plugin)], [], payload: states)["p"] == MapSet.new()
    assert hidden_contents(flows, [page.(plugin)], [], payload: none)["p"] == MapSet.new(["g"])
    # An app that does not say what its plugins hold: any plugin element.
    assert hidden_contents(flows, [page.(plugin)], [], payload: %{})["p"] == MapSet.new()
  end

  test "nothing outside reads what only the browser has of an element inside; an element inside may" do
    page = node("p", :page, [conditional("g", [node("in", :group, [node("t", :text)])])])
    state = %{element: "in", state: "custom.open_", default: nil}

    flows = %Spec{
      surfaces: %{"p" => %{surface(:page) | states: [state]}},
      elements: %{"in" => %{surface: "p", instance_of: nil, root?: false}}
    }

    reads = fn readers -> [reads: %{"in" => MapSet.new(readers)}] end

    # Inside, anything of it.
    assert hidden_contents(flows, [page], [], reads.([{"t", "is_visible"}]))["p"] ==
             MapSet.new(["g"])

    # What only the browser has, or what depends on its being rendered.
    for state <- [
          "is_visible",
          "isnt_visible",
          "is_hovered",
          "get_width",
          "page_number",
          "get_AAC",
          nil
        ],
        reader <- [:workflow, "elsewhere", "g"] do
      assert hidden_contents(flows, [page], [], reads.([{reader, state}]))["p"] == MapSet.new(),
             inspect({reader, state})
    end

    # What the server keeps whether it is rendered or not: its thing or
    # list (page data), a custom state.
    for state <- ["get_group_data", "get_list_data", "custom.open_"],
        reader <- [:workflow, "elsewhere", "g"] do
      assert hidden_contents(flows, [page], [], reads.([{reader, state}]))["p"] ==
               MapSet.new(["g"]),
             inspect({reader, state})
    end

    # A custom state the page does not keep is not the server's.
    assert hidden_contents(flows, [page], [], reads.([{:workflow, "custom.other_"}]))["p"] ==
             MapSet.new()

    # One browser-only read among server-kept ones blocks it.
    mixed = reads.([{:workflow, "get_group_data"}, {"elsewhere", "is_visible"}])
    assert hidden_contents(flows, [page], [], mixed)["p"] == MapSet.new()
  end

  test "an input's value read from outside: only a tracked input's is kept by the server" do
    # A reusable element's input, behind an instance.
    card = node("C", :reusable_definition, [node("cIn", :input)])
    page = node("p", :page, [conditional("g", [instance("pC", "C")])])
    read = [reads: %{"cIn" => MapSet.new([{:workflow, "get_data"}])}]

    tracked = %Spec{
      surfaces: %{"p" => surface(:page), "C" => surface(:reusable, [], %{"cIn" => :text})}
    }

    untracked = %Spec{surfaces: %{"p" => surface(:page), "C" => surface(:reusable)}}

    reasons = fn flows ->
      surfaces = Enum.map([page, card], &{&1.map_key, &1, &1.map_key})

      Overlays.hidden_contents_reasons(
        flows,
        surfaces,
        [card],
        [bid: & &1.map_key, surface_id: & &1.map_key] ++ read
      )[{"p", "g"}]
    end

    # Either way the input itself keeps it (no control at all), but only
    # the untracked one's value is a read of what the browser has.
    assert {:keep, "a control (input)"} = reasons.(tracked)

    assert {:keep, "an expression outside it reads what only the browser has of cIn"} =
             reasons.(untracked)
  end

  test "a reusable element inside that shows or hides its own elements keeps it" do
    card = node("C", :reusable_definition, [node("cText", :text)])
    page = node("p", :page, [conditional("g", [instance("pC", "C")])])
    plain = %Spec{surfaces: %{"p" => surface(:page), "C" => surface(:reusable)}}

    assert hidden_contents(plain, [page], [card])["p"] == MapSet.new(["g"])

    hiding = put_in(plain.surfaces["C"], surface(:reusable, [hide("cText")]))
    assert hidden_contents(hiding, [page], [card])["p"] == MapSet.new()

    # A group of the reusable element: its own workflows decide, and an
    # expression reading inside it through its instance is outside it.
    inner = node("C", :reusable_definition, [conditional("cg", [node("cT", :text)])])
    assert hidden_contents(plain, [page], [inner])["C"] == MapSet.new(["cg"])

    read = [reads: %{"cT" => MapSet.new([{:workflow, "is_visible"}])}]
    assert hidden_contents(plain, [page], [inner], read)["C"] == MapSet.new()
  end

  test "element_reads/1: every GetElement of the app, by reader" do
    get = fn id -> %{"type" => "GetElement", "properties" => %{"element_id" => id}} end

    app = %{
      "pages" => %{
        "p" => %{
          "id" => "p",
          "elements" => %{
            "a" => %{
              "id" => "a",
              "properties" => %{
                "text" => %{
                  "entries" => %{
                    "0" =>
                      Map.put(get.("x"), "next", %{"type" => "Message", "name" => "is_visible"})
                  }
                }
              },
              "elements" => %{
                "b" => %{"id" => "b", "states" => %{"0" => %{"condition" => get.("y")}}}
              }
            }
          },
          "workflows" => %{"w" => %{"actions" => %{"0" => %{"properties" => get.("z")}}}}
        }
      },
      "element_definitions" => %{
        "C" => %{
          "id" => "C",
          "elements" => %{
            "c" => %{
              "id" => "c",
              "%p" => %{
                "v" => %{
                  "%x" => "GetElement",
                  "%p" => %{"%ei" => "x"},
                  "%n" => %{"%x" => "Message", "%nm" => "get_group_data"}
                }
              }
            }
          }
        }
      }
    }

    frontend = %BubbleEx.Frontend.Normalized{
      source: %BubbleEx.Frontend.Normalized.Source{payload: app},
      pages: [],
      reusables: []
    }

    assert Overlays.element_reads(frontend) == %{
             "x" => MapSet.new([{"a", "is_visible"}, {"c", "get_group_data"}]),
             "y" => MapSet.new([{"b", nil}]),
             "z" => MapSet.new([{:workflow, nil}])
           }
  end

  test "a Group Focus placed next to an element inside keeps it" do
    focus =
      node("gf", :group_focus, [node("ft", :text)],
        runtime: %{
          "boundary" => "overlay",
          "overlay" => "group_focus",
          "initial" => "hidden",
          "placement" => %{"placement" => "element", "reference" => %{"bubble_id" => "anchor"}}
        }
      )

    page = fn anchor ->
      node("p", :page, [conditional("g", [node(anchor, :text), node("other", :text)]), focus])
    end

    frontend = fn page ->
      %BubbleEx.Frontend.Normalized{
        source: %BubbleEx.Frontend.Normalized.Source{payload: nil},
        pages: [page],
        reusables: []
      }
    end

    flows = %Spec{surfaces: %{"p" => surface(:page)}}

    for {anchor, expected} <- [{"anchor", MapSet.new()}, {"elsewhere", MapSet.new(["g"])}] do
      reads = Overlays.element_reads(frontend.(page.(anchor)))
      assert hidden_contents(flows, [page.(anchor)], [], reads: reads)["p"] == expected
    end

    assert Overlays.element_reads(frontend.(page.("anchor")))["anchor"] ==
             MapSet.new([{:workflow, nil}])
  end

  test "element_reads/1: a mobile view's expressions read too" do
    get = %{
      "type" => "GetElement",
      "properties" => %{"element_id" => "x"},
      "next" => %{"type" => "Message", "name" => "is_visible"}
    }

    app = %{
      "mobile_views" => %{
        "m" => %{
          "id" => "m",
          "elements" => %{"a" => %{"id" => "a", "properties" => %{"v" => get}}},
          "workflows" => %{"w" => %{"actions" => %{"0" => %{"properties" => get}}}}
        }
      }
    }

    frontend = %BubbleEx.Frontend.Normalized{
      source: %BubbleEx.Frontend.Normalized.Source{payload: app},
      pages: [],
      reusables: []
    }

    assert Overlays.element_reads(frontend) == %{
             "x" => MapSet.new([{"a", "is_visible"}, {:workflow, "is_visible"}])
           }
  end

  test "only the elements whose conditionals compiled are candidates" do
    page =
      node("p", :page, [
        conditional("g", [node("t", :text)]),
        conditional("h", [node("u", :text)])
      ])

    flows = %Spec{surfaces: %{"p" => surface(:page)}}
    compiled = fn "p", %Node{map_key: key} -> key == "g" end

    assert hidden_contents(flows, [page], [], compiled: compiled)["p"] == MapSet.new(["g"])

    surfaces = [{"p", page, "p"}]

    reasons =
      Overlays.hidden_contents_reasons(flows, surfaces, [],
        bid: & &1.map_key,
        surface_id: & &1.map_key,
        compiled: compiled
      )

    assert Map.keys(reasons) == [{"p", "g"}]
  end
end
