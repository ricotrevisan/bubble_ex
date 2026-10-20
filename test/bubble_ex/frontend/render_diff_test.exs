defmodule BubbleEx.Frontend.RenderDiffTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Frontend.RenderDiff

  # A synthetic app: a page with a header text, a group hidden by default
  # (shown for logged-in users) holding a text, a repeating group's cell
  # text, a group that differs in size, and a reusable's text.
  defp user_logged_in do
    %{
      "type" => "CurrentUser",
      "is_slidable" => false,
      "next" => %{"type" => "Message", "name" => "is_logged_in"}
    }
  end

  defp app do
    %{
      "pages" => %{
        "AAA" => %{
          "id" => "bPage",
          "name" => "demo",
          "type" => "Page",
          "elements" => %{
            "k1" => %{"id" => "bTitle", "type" => "Text", "name" => "Title"},
            "k2" => %{
              "id" => "bGroup",
              "type" => "Group",
              "name" => "Members only",
              "properties" => %{"is_visible" => false},
              "states" => %{
                "0" => %{"condition" => user_logged_in(), "properties" => %{"is_visible" => true}}
              },
              "elements" => %{
                "k3" => %{"id" => "bInner", "type" => "Text", "name" => "Inner"}
              }
            },
            "k4" => %{"id" => "bCell", "type" => "Text", "name" => "Cell"},
            "k5" => %{"id" => "bBox", "type" => "Group", "name" => "Box"},
            "k6" => %{
              "id" => "bLabel",
              "type" => "Text",
              "name" => "Label",
              "states" => %{
                "0" => %{"condition" => user_logged_in(), "properties" => %{"text" => "Hi"}}
              }
            },
            "k7" => %{"id" => "bExtra", "type" => "Group", "name" => "Extra"},
            "k8" => %{"id" => "bMarked", "type" => "Text", "name" => "Marked"}
          }
        }
      },
      "element_definitions" => %{
        "bReuse" => %{
          "id" => "bReuse",
          "name" => "Card",
          "type" => "CustomDefinition",
          "elements" => %{"r1" => %{"id" => "bCardText", "type" => "Text", "name" => "Card text"}}
        }
      }
    }
  end

  defp el(i, id, opts) do
    %{
      "i" => i,
      "id" => id,
      "type" => nil,
      "parent" => Keyword.get(opts, :parent),
      "visible" => Keyword.get(opts, :visible, true),
      "box" => Keyword.get(opts, :box, [0, i * 20, 100, 20]),
      "text" => Keyword.get(opts, :text, ""),
      "imgs" => [],
      "marker" => Keyword.get(opts, :marker)
    }
  end

  defp capture(source, elements),
    do: %{"source" => source, "path" => "/demo", "width" => 1280, "elements" => elements}

  defp bubble do
    capture("bubble", [
      el(0, "bPage", box: [0, 0, 1280, 900]),
      el(1, "bTitle", parent: 0, text: "Welcome"),
      el(2, "bGroup", parent: 0, box: [0, 40, 400, 200]),
      el(3, "bInner", parent: 2, text: "Secret plans"),
      el(4, "bCell", parent: 0, text: "Row 1"),
      el(5, "bCell", parent: 0, text: "Row 2"),
      el(6, "bBox", parent: 0, box: [0, 300, 200, 100]),
      el(7, "bLabel", parent: 0, text: "Hi"),
      el(8, "bMarked", parent: 0, text: "Plugin text"),
      el(9, "bUnknown_group_item_x", parent: 0, visible: false),
      el(10, "bCardText", parent: 0, text: "Card")
    ])
  end

  defp ours do
    capture("bubble_ex", [
      el(0, "bPage", box: [0, 0, 1280, 900]),
      el(1, "bTitle", parent: 0, text: "Welcome"),
      el(2, "bGroup", parent: 0, visible: false, marker: %{"visible" => "false"}),
      el(3, "bInner", parent: 2, visible: false, text: "Secret plans"),
      el(4, "bCell", parent: 0, text: "Row 1"),
      el(6, "bBox", parent: 0, box: [0, 300, 200, 300]),
      el(7, "bLabel", parent: 0, text: ""),
      el(8, "bMarked",
        parent: 0,
        visible: false,
        marker: %{"title" => "Plugin element (not migrated)"}
      ),
      el(9, "bExtra", parent: 0, text: "Only here"),
      el(10, "bCardText", parent: 0, text: "Card")
    ])
  end

  describe "index/2" do
    test "indexes page and reusable elements with their conditions" do
      index = RenderDiff.index(app())

      assert %{type: "Group", owner: "page:demo", parent: "bPage", hidden_by_default: true} =
               index["bGroup"]

      assert [%{visible: true, when: when_text}] = index["bGroup"].visibility_conditions
      assert is_binary(when_text)
      assert index["bInner"].parent == "bGroup"
      assert [%{sets: ["text"]}] = index["bLabel"].other_conditions
      assert index["bCardText"].owner == "reusable:Card"
    end
  end

  describe "diff/4" do
    setup do
      index = RenderDiff.index(app())
      %{index: index, report: RenderDiff.diff(bubble(), ours(), index)}
    end

    defp find(report, id, kind),
      do: Enum.find(report.known ++ report.unexplained, &(&1.id == id and &1.kind == kind))

    test "a group hidden in ours is one difference that folds its subtree", %{report: report} do
      group = find(report, "bGroup", :only_bubble)
      assert group.nested == 1
      assert group.chars == String.length("Secret plans")
      assert group.category == :unexplained
      assert "hidden by default" in group.reasons
      assert Enum.any?(group.reasons, &String.starts_with?(&1, "shown when"))
      assert "ours: data-bubble-visible=false" in group.reasons
      refute find(report, "bInner", :only_bubble)
    end

    test "repeated elements compare their visible instances", %{report: report} do
      cell = find(report, "bCell", :count_differs)
      assert cell.bubble.visible == 2
      assert cell.ours.visible == 1
    end

    test "text and box differences", %{report: report} do
      label = find(report, "bLabel", :text_differs)
      assert label.bubble.text == "Hi"
      assert label.ours.text == ""
      assert Enum.any?(label.reasons, &String.starts_with?(&1, "sets text when"))

      box = find(report, "bBox", :box_off)
      assert box.off == 200
      refute find(report, "bTitle", :box_off)
      refute find(report, "bCardText", :text_differs)
    end

    test "marked elements are known, the rest unexplained", %{report: report} do
      marked = find(report, "bMarked", :only_bubble)
      assert marked.category == :marked
      assert "ours: Plugin element (not migrated)" in marked.reasons
      assert marked in report.known

      extra = find(report, "bExtra", :only_ours)
      assert extra in report.unexplained
    end

    test "owner-listed and drift categories", %{index: index} do
      generated = Map.delete(index, "bExtra")

      report =
        RenderDiff.diff(bubble(), ours(), index,
          generated_from: generated,
          known: %{"bGroup" => "stricter privacy"}
        )

      assert %{category: :known, reasons: ["owner: stricter privacy" | _]} =
               find(report, "bGroup", :only_bubble)

      assert %{category: :export_drift} = find(report, "bExtra", :only_ours)
    end

    test "ranks by visible content and counts the matches", %{report: report} do
      assert report.matched.bubble_with_id == 11
      assert report.matched.not_in_export == 1
      assert report.visible_chars.bubble > report.visible_chars.ours

      chars = Enum.map(report.unexplained, & &1.chars)
      assert chars == Enum.sort(chars, :desc)
    end

    test "Bubble's suffixed child IDs count as their element", %{index: index} do
      bubble = capture("bubble", [el(0, "bCell_group_item_x_0", text: "Row")])
      report = RenderDiff.diff(bubble, capture("bubble_ex", []), index)
      assert %{id: "bCell", kind: :only_bubble} = hd(report.unexplained)
    end

    test "the summary lists both groups", %{report: report} do
      text = RenderDiff.summary(report, 5)
      assert text =~ "Unexplained (candidate bugs)"
      assert text =~ "Known (drift, owner-listed, marked)"
      assert text =~ "only_bubble bGroup Group"
    end
  end

  describe "notes_in/1" do
    test "reads TODO comments and dev-marker texts per element" do
      source = """
      <p data-bubble-id="bA" title={Bubble.dev_marker("Text not migrated: reads data that is not loaded")}>
        <%!-- TODO(bubble:bA) text: dynamic value not compiled --%>
      </p>
      """

      notes = source |> RenderDiff.notes_in() |> Enum.sort()

      assert notes == [
               {"bA", "Text not migrated: reads data that is not loaded"},
               {"bA", "text: dynamic value not compiled"}
             ]
    end
  end

  describe "mix bubble.render_diff" do
    @tag :tmp_dir
    test "writes the report for a .bubble JSON export", %{tmp_dir: dir} do
      export = Path.join(dir, "app.bubble")
      File.write!(export, Jason.encode!(app()))
      b = Path.join(dir, "bubble.json")
      o = Path.join(dir, "ours.json")
      out = Path.join(dir, "report.json")
      File.write!(b, Jason.encode!(bubble()))
      File.write!(o, Jason.encode!(ours()))

      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Bubble.RenderDiff.run([b, o, "--export", export, "--out", out])
      end)

      report = out |> File.read!() |> Jason.decode!()
      assert report["counts"]["only_bubble"] >= 2
      assert Enum.any?(report["unexplained"], &(&1["id"] == "bGroup"))
    end
  end
end
