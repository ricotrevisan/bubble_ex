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
    assert States.from_definitions(@definitions) == %{
             "1600000000000x100-AAA" => %{
               "AAB" => %{"value" => "boolean", "is_list" => false},
               "AAC" => %{"value" => "number", "is_list" => true},
               "AAD" => %{"value" => "custom_data_AAF", "is_list" => false},
               "AAE" => %{"value" => "date_range", "is_list" => false}
             }
           }

    assert States.from_definitions(nil) == %{}
  end

  test "an element's states by accessor, its type fields read from its properties" do
    states = States.from_definitions(@definitions)

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
