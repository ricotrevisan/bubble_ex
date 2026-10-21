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

  defp el(i, id, opts \\ []) do
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

      assert %{
               category: :known,
               known_class: "other",
               reasons: ["owner (other): stricter privacy" | _]
             } =
               find(report, "bGroup", :only_bubble)

      assert %{category: :export_drift, known_class: nil} = find(report, "bExtra", :only_ours)
    end

    test "a known entry covers only its kinds, and unmatched entries are listed", %{index: index} do
      {:ok, known} =
        RenderDiff.parse_known(%{
          "$comment" => "skipped",
          "bCell" => %{
            "reason" => "the rows are counted on the server",
            "class" => "server_data",
            "kinds" => ["count_differs"]
          },
          "bLabel" => %{"reason" => "not a text difference", "kinds" => ["only_ours"]},
          "bGone" => %{"reason" => "on another page", "class" => "privacy"}
        })

      report = RenderDiff.diff(bubble(), ours(), index, known: known)

      assert %{category: :known, known_class: "server_data"} =
               cell = find(report, "bCell", :count_differs)

      assert "owner (server_data): the rows are counted on the server" in cell.reasons
      assert cell in report.known
      # bLabel's entry covers only_ours, not its text difference.
      assert find(report, "bLabel", :text_differs) in report.unexplained
      # bGone is not on this page: its entry is for another one.
      assert report.known_unused == ["bLabel"]

      text = RenderDiff.summary(report, 5)
      assert text =~ "Known: owner-listed (1)"
      assert text =~ "count_differs bCell Text \"Cell\" [known/server_data]"
      assert text =~ "Owner-listed but no difference here (fixed or stale): bLabel"
    end

    test "an entry on an element folded into an ancestor's difference is named, not stale",
         %{index: index} do
      report = RenderDiff.diff(bubble(), ours(), index, known: %{"bInner" => %{reason: "inside"}})

      assert %{category: :unexplained, nested: 1} = find(report, "bGroup", :only_bubble)
      assert report.known_unused == []
      assert report.known_folded == %{"bInner" => "bGroup"}

      assert RenderDiff.summary(report, 5) =~
               "folded into another difference (list that one): bInner in bGroup"
    end

    test "diff/4 takes partial entries and refuses what it cannot read", %{index: index} do
      report = RenderDiff.diff(bubble(), ours(), index, known: %{"bGroup" => %{reason: "r"}})
      assert %{category: :known, known_class: "other"} = find(report, "bGroup", :only_bubble)

      assert_raise ArgumentError, ~r/parse_known/, fn ->
        RenderDiff.diff(bubble(), ours(), index, known: %{"bGroup" => %{"reason" => "r"}})
      end
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

    test "an element under two parents folds into one root without crashing", %{index: index} do
      # bCardText sits once inside the hidden bGroup and once under the page.
      bubble =
        capture("bubble", [
          el(0, "bPage"),
          el(1, "bGroup", parent: 0),
          el(2, "bCardText", parent: 1, text: "A"),
          el(3, "bTitle", parent: 0),
          el(4, "bCardText", parent: 3, text: "B"),
          el(5, "bInner", parent: 4, text: "C")
        ])

      ours = capture("bubble_ex", [el(0, "bPage"), el(3, "bTitle", parent: 0)])
      report = RenderDiff.diff(bubble, ours, index)
      ids = Enum.map(report.unexplained, &{&1.id, &1.kind})
      assert {"bGroup", :only_bubble} in ids
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "a parent cycle does not hang", %{index: index} do
      bubble =
        capture("bubble", [el(0, "bGroup", parent: 1), el(1, "bInner", parent: 0, text: "x")])

      task = Task.async(fn -> RenderDiff.diff(bubble, capture("bubble_ex", []), index) end)
      assert %{unexplained: [_ | _]} = Task.await(task, 2000)
    end

    test "malformed entries and boxes are skipped", %{index: index} do
      bubble = %{"elements" => [nil, 3, el(0, "bTitle", box: [nil, 0, 1, 1], text: "t")]}
      ours = %{"elements" => [el(0, "bTitle", box: [0, 0, 1, 1], text: "t")]}
      assert %{matched: %{bubble_elements: 1}} = RenderDiff.diff(bubble, ours, index)
    end

    test "an ancestor's note is a reason, not an explanation", %{index: index} do
      report =
        RenderDiff.diff(bubble(), ours(), index,
          notes: %{"bPage" => ["text: dynamic value not compiled"]}
        )

      extra = find(report, "bExtra", :only_ours)
      assert extra.category == :unexplained
      assert "ours (ancestor bPage): text: dynamic value not compiled" in extra.reasons
    end

    test "an element only in the export the app was generated from is drift", %{index: index} do
      generated = Map.put(index, "bGone", %{type: "Text", name: "Gone", owner: "page:demo"})
      ours = capture("bubble_ex", [el(0, "bGone", text: "old")])
      report = RenderDiff.diff(capture("bubble", []), ours, index, generated_from: generated)

      assert %{category: :export_drift, reasons: ["not in the export" | rest]} =
               find(report, "bGone", :only_ours)

      assert "only in the export the app was generated from" in rest
    end

    test "variants are not counted as instances, and a count difference is not also a text one",
         %{index: index} do
      bubble =
        capture("bubble", [
          el(0, "bCell", text: "Row 1"),
          el(1, "bCell_group_item_a_0", text: "a"),
          el(2, "bTitle", text: "x"),
          el(3, "bTitle", text: "y")
        ])

      ours = capture("bubble_ex", [el(0, "bCell", text: "Row 1"), el(1, "bTitle", text: "x")])
      report = RenderDiff.diff(bubble, ours, index)
      refute find(report, "bCell", :count_differs)
      refute find(report, "bCell", :text_differs)
      assert find(report, "bTitle", :count_differs)
      refute find(report, "bTitle", :text_differs)
    end

    test "box offsets compare only from the same parent", %{index: index} do
      bubble =
        capture("bubble", [
          el(0, "bPage", box: [0, 0, 10, 10]),
          el(1, "bBox", parent: 0, box: [500, 500, 10, 10])
        ])

      ours =
        capture("bubble_ex", [
          el(0, "bGroup", box: [0, 0, 10, 10]),
          el(1, "bBox", parent: 0, box: [0, 0, 10, 10])
        ])

      refute find(RenderDiff.diff(bubble, ours, index), "bBox", :box_off)
    end

    test "the summary can leave texts out", %{report: report} do
      refute RenderDiff.summary(report, 5, text: false) =~ "text="
      assert RenderDiff.summary(report, 5) =~ "text="
    end

    test "the summary lists both groups", %{report: report} do
      text = RenderDiff.summary(report, 5)
      assert text =~ "Unexplained (candidate bugs)"
      assert text =~ "Known: owner-listed (0)"
      assert text =~ "Known: export drift (0)"
      assert text =~ "Known: marked as not migrated in ours (1)"
      refute text =~ "no difference here"
      assert text =~ "only_bubble bGroup Group"
    end
  end

  describe "parse_known/1" do
    test "takes reasons and entries, with a default class and all kinds" do
      assert {:ok,
              %{
                "bA" => %{reason: "r", class: "other", kinds: :all},
                "bB" => %{reason: "s", class: "drift", kinds: [:only_bubble, :box_off]}
              }} =
               RenderDiff.parse_known(%{
                 "bA" => "r",
                 "bB" => %{
                   "reason" => "s",
                   "class" => "drift",
                   "kinds" => ["only_bubble", "box_off"]
                 }
               })
    end

    test "refuses what it cannot read, naming the entry" do
      for {bad, message} <- [
            {[], ~r/JSON object/},
            {%{"bA" => 1}, ~r/^bA: every value/},
            {%{"bA" => %{"class" => "privacy"}}, ~r/^bA: every value/},
            {%{"bA" => %{"reason" => "r", "class" => "bug"}}, ~r/^bA: class must be one of/},
            {%{"bA" => %{"reason" => "r", "kinds" => ["moved"]}}, ~r/^bA: kinds must be/},
            {%{"bA" => %{"reason" => "r", "kinds" => []}}, ~r/^bA: kinds must be/},
            {%{"bA" => %{"reason" => "r", "why" => "x"}}, ~r/^bA: unknown keys/}
          ] do
        assert {:error, why} = RenderDiff.parse_known(bad)
        assert why =~ message
      end
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

    test "a TODO at the end of a line does not take the next line; marker literals are unescaped" do
      source = """
      x = 1 # TODO(bubble:bB)
      secret = conn.assigns.token
      <p data-bubble-id="bC" title={Bubble.dev_marker("Say \\"hi\\" \\x7B")}></p>
      """

      refute Enum.any?(RenderDiff.notes_in(source), &(elem(&1, 0) == "bB"))
      assert {"bC", ~s(Say "hi" {)} in RenderDiff.notes_in(source)
      refute Enum.any?(RenderDiff.notes_in(source), fn {_, n} -> n =~ "secret" end)
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

      known = Path.join(dir, "known.json")

      File.write!(
        known,
        Jason.encode!(%{"bExtra" => %{"reason" => "a capture gap", "class" => "capture_gap"}})
      )

      printed =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Bubble.RenderDiff.run([
            b,
            o,
            "--export",
            export,
            "--known",
            known,
            "--out",
            out
          ])
        end)

      assert printed =~ "[known/capture_gap]"
      assert File.stat!(out).mode |> Bitwise.band(0o777) == 0o600
      report = out |> File.read!() |> Jason.decode!()
      assert report["counts"]["only_bubble"] >= 2
      assert Enum.any?(report["unexplained"], &(&1["id"] == "bGroup"))

      assert [%{"known_class" => "capture_gap"}] =
               Enum.filter(report["known"], &(&1["id"] == "bExtra"))

      assert report["known_unused"] == []
    end

    @tag :tmp_dir
    test "refuses a malformed --known and bad options", %{tmp_dir: dir} do
      export = Path.join(dir, "app.bubble")
      File.write!(export, Jason.encode!(app()))
      b = Path.join(dir, "b.json")
      File.write!(b, Jason.encode!(bubble()))
      known = Path.join(dir, "known.json")
      File.write!(known, Jason.encode!(%{"bGroup" => 1}))

      assert_raise Mix.Error, ~r/--known/, fn ->
        Mix.Tasks.Bubble.RenderDiff.run([b, b, "--export", export, "--known", known])
      end

      assert_raise Mix.Error, ~r/invalid options/, fn ->
        Mix.Tasks.Bubble.RenderDiff.run([b, b, "--export", export, "--bogus"])
      end

      assert_raise Mix.Error, ~r/--top/, fn ->
        Mix.Tasks.Bubble.RenderDiff.run([b, b, "--export", export, "--top", "0"])
      end
    end
  end
end
