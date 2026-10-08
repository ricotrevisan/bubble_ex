defmodule BubbleEx.Frontend.Export.FloatingCssTest do
  # Where a Floating Group is pinned and how wide it is (WTF-516): the
  # horizontal reference names the viewport edges, the group's own width
  # (fixed, fit or fill; an instance's over its reusable's) its width. Only
  # a group that fills its width spans the viewport between both edges.
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend
  alias BubbleEx.Frontend.Export.Css
  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Target.Phoenix.Tailwind

  # A page holding a side panel: a Floating Group reusable (row layout, no
  # floating references and no width flag of its own) placed by an
  # instance that sets its width, and a main column beside it.
  defp side_panel_app(instance_props, definition_props \\ %{}) do
    %{
      "_id" => "side-panel",
      "pages" => %{
        "dashboard" => %{
          "id" => "page",
          "type" => "Page",
          "name" => "dashboard",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "panel" => %{
              "id" => "panel-instance",
              "type" => "CustomElement",
              "properties" =>
                Map.merge(
                  %{"custom_id" => "panel-root", "order" => 1, "zindex" => 8},
                  instance_props
                )
            },
            "main" => %{
              "id" => "main",
              "type" => "Group",
              "properties" => %{
                "container_layout" => "column",
                "margin_left" => 248,
                "order" => 2
              }
            }
          }
        }
      },
      "element_definitions" => %{
        "panel" => %{
          "id" => "panel-root",
          "type" => "CustomDefinition",
          "name" => "Side panel",
          "properties" =>
            Map.merge(
              %{
                "element_type" => "FloatingGroup",
                "container_layout" => "row",
                "default_width" => 248,
                "width" => 200,
                "height" => 200,
                "min_height_px" => 600
              },
              definition_props
            ),
          "elements" => %{
            "label" => %{"id" => "label", "type" => "Text", "properties" => %{"%3" => "Panel"}}
          }
        }
      }
    }
  end

  defp instance_root(app) do
    {:ok, frontend} = Frontend.normalize(app)
    [page] = frontend.pages
    instance = Enum.find(page.children, &(&1.kind == :reusable_instance))
    definition = Enum.find(frontend.reusables, &(&1.source.bubble_id == "panel-root"))
    Css.lower_root(definition, instance).declarations |> Map.new()
  end

  defp floating(props) do
    app = %{
      "_id" => "floating",
      "pages" => %{
        "index" => %{
          "id" => "page",
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "bar" => %{
              "id" => "bar",
              "type" => "FloatingGroup",
              "properties" => Map.merge(%{"container_layout" => "row"}, props)
            }
          }
        }
      }
    }

    {:ok, frontend} = Frontend.normalize(app)
    [page] = frontend.pages
    [%Node{kind: :floating_group} = bar] = page.children
    page |> Css.lower() |> Enum.find(&(&1.node == bar)) |> Map.fetch!(:declarations) |> Map.new()
  end

  @fit %{"fit_width" => true, "single_width" => false}
  @fill %{"fit_width" => false, "single_width" => false}
  @fixed %{"fit_width" => false, "single_width" => true, "width" => 240}

  describe "a Floating Group reusable placed by an instance" do
    test "fit width with no references: at the left edge, as wide as its content" do
      css = instance_root(side_panel_app(Map.merge(@fit, %{"min_width_css" => "248px"})))

      assert css["position"] == "fixed"
      assert css["top"] == "0"
      assert css["left"] == "0"
      refute Map.has_key?(css, "right")
      assert css["width"] == "fit-content"
      assert css["min-width"] == "248px"
      assert css["z-index"] == 8

      {classes, []} = Tailwind.utilities(Enum.to_list(css))
      assert "fixed" in classes and "left-[0]" in classes and "w-[fit-content]" in classes
      refute "right-[0]" in classes
    end

    test "a fixed width on the left edge keeps its width" do
      props = Map.merge(@fixed, %{"floating_reference_horizontal_resp" => "left"})
      css = instance_root(side_panel_app(props))

      assert css["left"] == "0"
      refute Map.has_key?(css, "right")
      assert css["width"] == "240px"
    end

    test "the instance's width wins over the reusable's" do
      css = instance_root(side_panel_app(@fill, @fit))
      assert css["left"] == "0" and css["right"] == "0"
      refute css["width"] == "fit-content"

      css = instance_root(side_panel_app(@fit, @fill))
      refute Map.has_key?(css, "right")
      assert css["width"] == "fit-content"
    end

    test "the instance's horizontal reference wins over the reusable's" do
      css =
        instance_root(
          side_panel_app(
            Map.put(@fit, "floating_reference_horizontal_resp", "right"),
            %{"floating_reference_horizontal_resp" => "left"}
          )
        )

      assert css["right"] == "0"
      refute Map.has_key?(css, "left")
      assert css["width"] == "fit-content"
    end
  end

  describe "a Floating Group's horizontal reference" do
    test "left and right pin one edge at the group's own width" do
      css = floating(Map.put(@fit, "floating_reference_horizontal_resp", "left"))
      assert {css["left"], css["right"], css["width"]} == {"0", nil, "fit-content"}

      css = floating(Map.put(@fixed, "floating_reference_horizontal_resp", "right"))
      assert {css["left"], css["right"], css["width"]} == {nil, "0", "240px"}
    end

    test "both stretches between the edges only when the group fills its width" do
      css = floating(Map.put(@fill, "floating_reference_horizontal_resp", "both"))
      assert {css["left"], css["right"]} == {"0", "0"}
      refute css["width"] in ["fit-content", "240px"]

      css = floating(Map.put(@fit, "floating_reference_horizontal_resp", "both"))
      assert {css["left"], css["right"], css["width"]} == {"0", nil, "fit-content"}

      css = floating(Map.put(@fixed, "floating_reference_horizontal_resp", "both"))
      assert {css["left"], css["right"], css["width"]} == {"0", nil, "240px"}
    end

    test "no reference reads as both" do
      assert {floating(@fill)["left"], floating(@fill)["right"]} == {"0", "0"}
      assert {floating(@fit)["left"], floating(@fit)["right"]} == {"0", nil}
    end

    test "center centers the group at its own width" do
      css = floating(Map.put(@fit, "floating_reference_horizontal_resp", "center"))

      assert {css["left"], css["right"]} == {"0", "0"}
      assert {css["margin-left"], css["margin-right"]} == {"auto", "auto"}
      assert css["width"] == "fit-content"
    end
  end
end
