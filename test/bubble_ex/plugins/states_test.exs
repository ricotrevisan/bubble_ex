defmodule BubbleEx.Plugins.StatesTest do
  # The types of plugin element states, from Buildprint's copy of the
  # plugins' definitions (synthetic definitions, all invented).
  use ExUnit.Case, async: true

  alias BubbleEx.Plugins.States

  @definitions %{
    "1600000000000x100" => %{
      "plugin_id" => "1600000000000x100",
      "human" => "Timer",
      "html_header" => %{"snippet" => "<script>secret()</script>"},
      "plugin_elements" => %{
        "AAA" => %{
          "display" => "Timer",
          "fields" => %{"AAF" => %{"editor" => "custom_type", "caption" => "Type"}},
          "states" => %{
            "AAB" => %{
              "caption" => "Running",
              "doc" => "d",
              "name" => "running",
              "value" => "boolean"
            },
            "AAC" => %{"caption" => "Laps", "value" => "number", "is_list" => true},
            "AAD" => %{"caption" => "Picked", "value" => "custom_data_AAF"},
            "AAE" => %{"caption" => "Span", "value" => "date_range"},
            "AAG" => %{"caption" => "Broken"}
          }
        },
        "ABA" => %{"display" => "No states"}
      },
      "plugin_actions" => %{"ACA" => %{"code" => %{"fn" => "run()"}}}
    },
    "bad" => "not a map"
  }

  test "the projection keeps declared types only" do
    # AAG (no type) is dropped and counted.
    assert States.from_definitions(@definitions) ==
             {%{
                "1600000000000x100-AAA" => %{
                  "AAB" => %{"value" => "boolean", "is_list" => false},
                  "AAC" => %{"value" => "number", "is_list" => true},
                  "AAD" => %{"value" => "custom_data_AAF", "is_list" => false},
                  "AAE" => %{"value" => "date_range", "is_list" => false}
                }
              }, 1}

    assert States.from_definitions(nil) == {%{}, 0}
  end

  test "a state whose code or type is not a known form is dropped and counted" do
    long = String.duplicate("A", 40)

    definitions = %{
      "1600000000000x200" => %{
        "plugin_elements" => %{
          "AAA" => %{
            "states" => %{
              "AAB" => %{"value" => "number"},
              "AAC" => %{"value" => "<script>"},
              "AAD" => %{"value" => "custom_data_" <> long},
              "AAE" => %{"value" => String.duplicate("x", 300)},
              "AAF" => %{"value" => 7},
              "bad code" => %{"value" => "text"},
              long => %{"value" => "text"},
              "AAG" => %{"value" => "option.status"},
              "AAH" => "not a map"
            }
          },
          "not a code!" => %{"states" => %{"AAB" => %{"value" => "text"}}}
        }
      },
      "bad id!" => %{
        "plugin_elements" => %{"AAA" => %{"states" => %{"AAB" => %{"value" => "text"}}}}
      }
    }

    assert States.from_definitions(definitions) ==
             {%{
                "1600000000000x200-AAA" => %{
                  "AAB" => %{"value" => "number", "is_list" => false},
                  "AAG" => %{"value" => "option.status", "is_list" => false}
                }
              }, 8}
  end

  test "a malformed projection never crashes the tree" do
    app = %{
      "pages" => %{
        "p" => %{
          "id" => "bP",
          "elements" => %{"bX" => %{"id" => "bX", "type" => "1600000000000x100-AAA"}}
        }
      }
    }

    for broken <- [
          %{"1600000000000x100-AAA" => %{"AAB" => "boolean", 3 => %{}, "AAC" => nil}},
          %{"1600000000000x100-AAA" => %{"AAB" => %{"value" => 3}}},
          %{"1600000000000x100-AAA" => "nonsense"},
          %{"1600000000000x100-AAA" => [1, 2]}
        ] do
      tree = app |> Map.put(States.key(), broken) |> BubbleEx.Expression.Tree.build()
      assert BubbleEx.Expression.Tree.node(tree, "bX").plugin_states == %{}
    end

    tree = app |> Map.put(States.key(), "nonsense") |> BubbleEx.Expression.Tree.build()
    assert BubbleEx.Expression.Tree.node(tree, "bX").plugin_states == %{}
  end

  test "an element's states by accessor, its type fields read from its properties" do
    {states, _dropped} = States.from_definitions(@definitions)

    assert States.element(states, "1600000000000x100-AAA", %{"AAF" => "custom.task"}) == %{
             "get_AAB" => "boolean",
             "get_AAC" => "list.number",
             "get_AAD" => "custom.task"
           }

    # A versioned type is the same plugin's; a type field left empty (or
    # not a type) leaves that state untyped.
    assert States.element(states, "1600000000000x100_test-AAA", %{}) == %{
             "get_AAB" => "boolean",
             "get_AAC" => "list.number"
           }

    assert States.element(states, "1600000000000x100-AAA", %{"AAF" => "nonsense"}) ==
             %{"get_AAB" => "boolean", "get_AAC" => "list.number"}

    assert States.element(states, "Group", %{}) == %{}
    assert States.element(states, nil, %{}) == %{}
  end

  test "an app holds the projection under its key, only when there is one" do
    app = %{"pages" => %{}}
    assert States.put(app, %{}) == app
    assert States.get(app) == %{}

    with_states = States.put(app, %{"x-AAA" => %{}})
    assert States.get(with_states) == %{"x-AAA" => %{}}
    assert States.delete(with_states) == app
  end
end
