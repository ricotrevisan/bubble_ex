defmodule BubbleEx.Test.WorkaroundsFixture do
  @moduledoc false

  # An invented app for the workaround elements (WTF-586): one page in a
  # Column, with a floating "variables" group holding a list, a 0x0 group
  # holding the current user (with a text inside), an empty 0x0 spacer, a
  # 0x0 tooltip plugin element, a 1x1 Toolbox element, a script, a hover
  # target, a hidden group nothing shows, a hidden group a step shows, a
  # hidden group a conditional shows, a hidden group holding a custom state
  # a button sets, and a 1x1 element a conditional grows.

  @tooltip "1658529043551x529931311906553860"
  @toolbox "1488796042609x768734193128308700"

  # Fixed on both axes with no min size: 0x0 in a Column, whatever the
  # canvas size.
  defp tiny(props),
    do:
      Map.merge(
        %{"single_width" => true, "single_height" => true, "width" => 320, "height" => 250},
        props
      )

  defp read(element, name, next \\ nil) do
    step = %{"type" => "Message", "name" => name}
    step = if next, do: Map.put(step, "next", %{"type" => "Message", "name" => next}), else: step

    %{
      "type" => "TextExpression",
      "entries" => %{
        "0" => %{
          "type" => "GetElement",
          "properties" => %{"element_id" => element},
          "next" => step
        }
      }
    }
  end

  defp text(id, order, text_value),
    do: %{
      "id" => id,
      "type" => "Text",
      "properties" => %{"order" => order, "text" => text_value, "width" => 200, "height" => 20}
    }

  def app do
    elements = %{
      "eVars" => %{
        "id" => "eVars",
        "type" => "FloatingGroup",
        "properties" => tiny(%{"container_layout" => "column", "order" => 1}),
        "elements" => %{
          "eList" => %{
            "id" => "eList",
            "type" => "RepeatingGroup",
            "properties" => tiny(%{"order" => 1, "data_source" => %{"type" => "CurrentUser"}})
          }
        }
      },
      "eCount" => text("eCount", 2, read("eList", "get_list_data", "count")),
      "eHolder" => %{
        "id" => "eHolder",
        "type" => "Group",
        "properties" =>
          tiny(%{
            "order" => 3,
            "container_layout" => "column",
            "group_type" => "user",
            "data_source" => %{"type" => "CurrentUser"}
          }),
        "elements" => %{"eInside" => text("eInside", 1, "inside the holder")}
      },
      "eEmail" => text("eEmail", 4, read("eHolder", "get_group_data", "email")),
      "eGap" => %{"id" => "eGap", "type" => "Group", "properties" => tiny(%{"order" => 5})},
      "eTip" => %{
        "id" => "eTip",
        "type" => @tooltip <> "-AAV",
        # A plugin element keeps its canvas size: this one's is 0x0.
        "properties" => tiny(%{"order" => 6, "width" => 0, "height" => 0})
      },
      "eJs" => %{
        "id" => "eJs",
        "type" => @toolbox <> "-AAP",
        "properties" => tiny(%{"order" => 7, "width" => 1, "height" => 1})
      },
      "eScript" => %{
        "id" => "eScript",
        "type" => "HTML",
        "properties" => tiny(%{"order" => 8, "html" => "<script>window.x = 1</script>"})
      },
      "eHover" => %{"id" => "eHover", "type" => "Group", "properties" => tiny(%{"order" => 9})},
      "eHoverText" => text("eHoverText", 10, read("eHover", "is_hovered")),
      "eDead" => %{
        "id" => "eDead",
        "type" => "Group",
        "properties" => %{"order" => 11, "is_visible" => false, "width" => 200, "height" => 50},
        "elements" => %{"eDeadText" => text("eDeadText", 1, "never seen")}
      },
      "eShown" => %{
        "id" => "eShown",
        "type" => "Group",
        "properties" => %{"order" => 12, "is_visible" => false, "width" => 200, "height" => 50}
      },
      "eCond" => %{
        "id" => "eCond",
        "type" => "Group",
        "properties" => %{"order" => 13, "is_visible" => false, "width" => 200, "height" => 50},
        "states" => %{
          "0" => %{
            "condition" => %{"type" => "CurrentUser", "next" => %{"name" => "is_logged_in"}},
            "properties" => %{"is_visible" => true}
          }
        }
      },
      "eState" => %{
        "id" => "eState",
        "type" => "Group",
        "properties" => %{"order" => 14, "is_visible" => false, "width" => 200, "height" => 50},
        "custom_states" => %{"count_" => %{"display" => "count", "value" => "number"}}
      },
      "eStateText" => text("eStateText", 15, read("eState", "custom.count_")),
      "eGrow" => %{
        "id" => "eGrow",
        "type" => "Group",
        "properties" => %{
          "order" => 16,
          "min_width_css" => "1px",
          "min_height_css" => "1px",
          "width" => 200,
          "height" => 50
        },
        "states" => %{
          "0" => %{
            "condition" => %{"type" => "CurrentUser", "next" => %{"name" => "is_logged_in"}},
            "properties" => %{"min_width_css" => "200px"}
          }
        }
      },
      "eBtn" => %{
        "id" => "eBtn",
        "type" => "Button",
        "properties" => %{"order" => 17, "text" => "Go", "width" => 100, "height" => 40}
      }
    }

    %{
      "user_types" => %{
        "user" => %{
          "display" => "User",
          "fields" => %{"email" => %{"display" => "email", "value" => "text"}}
        }
      },
      "pages" => %{
        "index" => %{
          "id" => "pHome",
          "name" => "index",
          "type" => "Page",
          "properties" => %{"container_layout" => "column"},
          "elements" => elements,
          "workflows" => %{
            "w1" => %{
              "id" => "wGo",
              "type" => "ButtonClicked",
              "properties" => %{"element_id" => "eBtn"},
              "actions" => %{
                "0" => %{
                  "id" => "aShow",
                  "type" => "ShowElement",
                  "properties" => %{"element_id" => "eShown"}
                },
                "1" => %{
                  "id" => "aSet",
                  "type" => "SetCustomState",
                  "properties" => %{
                    "element_id" => "eState",
                    "custom_state" => "count_",
                    "value" => 1
                  }
                }
              }
            }
          }
        }
      }
    }
  end
end
