defmodule BubbleEx.WorkaroundsTest do
  # Workaround elements (WTF-586): tiny and never-visible elements, what
  # sets and reads them, their class and the owner's say on it, on the
  # invented app of BubbleEx.Test.WorkaroundsFixture.
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Error, Finding, Findings, Index, Model, Plan, Workarounds}
  import BubbleEx.Test.WorkaroundsFixture, only: [app: 0]

  @tooltip "1658529043551x529931311906553860"
  @now ~U[2026-10-21 00:00:00Z]

  defp catalog do
    app = app()
    {:ok, index} = Index.build(app)
    app |> Workarounds.catalog(index) |> Map.new(&{&1.element, &1})
  end

  defp findings do
    app = app()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)

    %{
      app: app,
      model: model,
      index: index,
      findings: Enum.filter(findings, &(&1.kind == :workaround_element))
    }
  end

  describe "catalog/2" do
    test "classifies each tiny or never-visible element" do
      classes = Map.new(catalog(), fn {id, e} -> {id, {e.class, e.confidence}} end)

      assert classes == %{
               "eVars" => {:value_holder, :high},
               "eList" => {:value_holder, :high},
               "eHolder" => {:value_holder, :medium},
               "eGap" => {:spacer, :high},
               "eTip" => {:keep_alive, :high},
               "eJs" => {:js_bridge, :high},
               "eScript" => {:js_bridge, :high},
               "eHover" => {:unknown, :low},
               "eDead" => {:unknown, :low},
               "eState" => {:value_holder, :high},
               "eGrow" => {:unknown, :low}
             }
    end

    test "an element a step or a conditional shows is not a candidate" do
      entries = catalog()
      refute Map.has_key?(entries, "eShown")
      refute Map.has_key?(entries, "eCond")
      refute Map.has_key?(entries, "eDeadText")
    end

    test "records who sets and who reads an element, and what" do
      entries = catalog()

      assert %{
               signals: [:never_visible],
               setters: [
                 %{action: "action:aSet", workflow: "workflow:wGo", type: "SetCustomState"}
               ],
               readers: [%{from: "element:eStateText", reads: ["custom.count_"], inside: false}],
               custom_states: ["count_"],
               option: :page_state,
               options: [:page_state, :plugin_event, :css_gap, :hook, :keep]
             } = entries["eState"]

      # An unclear one suggests keeping the markup, and offers every lowering.
      assert [:keep, :page_state, :plugin_event, :css_gap, :hook] = entries["eDead"].options
      assert entries["eVars"].held == ["element:eList"]
      refute entries["eVars"].contents.used

      assert %{signals: [:tiny], tiny: :fixed, inside: "element:eVars", data_source: true} =
               entries["eList"]

      assert [%{from: "element:eCount", reads: ["get_list_data"]}] = entries["eList"].readers
      assert entries["eVars"].reason =~ "only wraps 1 value_holder element (eList)"
      assert entries["eHolder"].reason =~ "it has contents that may show"
      assert entries["eHover"].reason =~ "is_hovered"
      assert entries["eGrow"].tiny == :min_only
      assert entries["eGrow"].reason =~ "min_width_css"
      assert entries["eTip"].plugins == ["plugin:" <> @tooltip]
      assert entries["eScript"].script
    end

    test "a holder whose contents something outside uses is not sure" do
      app =
        update_in(app(), ["pages", "index", "elements"], fn els ->
          els
          |> put_in(["eVars", "elements", "eInput"], %{
            "id" => "eInput",
            "type" => "Input",
            "properties" => %{"order" => 2, "width" => 100, "height" => 20}
          })
          |> Map.put("eInputText", %{
            "id" => "eInputText",
            "type" => "Text",
            "properties" => %{
              "order" => 30,
              "text" => %{
                "type" => "TextExpression",
                "entries" => %{
                  "0" => %{
                    "type" => "GetElement",
                    "properties" => %{"element_id" => "eInput"},
                    "next" => %{"type" => "Message", "name" => "value"}
                  }
                }
              }
            }
          })
        end)

      {:ok, index} = Index.build(app)
      entries = app |> Workarounds.catalog(index) |> Map.new(&{&1.element, &1})

      assert entries["eVars"].contents.used
      # No longer a pure wrapper: it holds an input read from outside.
      refute entries["eVars"].class == :value_holder and entries["eVars"].confidence == :high
    end

    test "page_state/1 lowers a holder only with every candidate it holds" do
      %{index: index, findings: findings} = findings()
      list = Enum.find(findings, &(&1.subject == %{element: "eList"}))
      {:ok, resolved} = Decision.resolve([], findings, index: index, now: @now)
      assert "eVars" in Workarounds.page_state(Decision.applicable(resolved, findings))

      {:ok, keep} = Decision.for_finding(list, :modify, %{"option" => "keep"})
      {:ok, resolved} = Decision.resolve([keep], findings, index: index, now: @now)
      lowered = Workarounds.page_state(Decision.applicable(resolved, findings))
      refute "eVars" in lowered
      refute "eList" in lowered
      assert "eState" in lowered
    end

    test "a fixed axis in a Fixed container is tiny only at a tiny canvas size" do
      app =
        put_in(app(), ["pages", "index", "properties", "container_layout"], "fixed")

      {:ok, index} = Index.build(app)
      ids = app |> Workarounds.catalog(index) |> MapSet.new(& &1.element)

      refute "eGap" in ids
      # eList sits in eVars, a Column: still 0x0.
      assert "eList" in ids
    end
  end

  describe ":workaround_element findings and decisions" do
    test "one :default finding per element, keyed by its ID" do
      %{findings: findings} = findings()
      f = Enum.find(findings, &(&1.subject == %{element: "eHolder"}))

      assert %Finding{
               category: :default,
               confidence: :medium,
               proposal: %{
                 transform: :lower_workaround,
                 element: "element:eHolder",
                 class: :value_holder,
                 option: :page_state,
                 type: "Group",
                 holds: []
               }
             } = f

      assert f.id == Finding.id(:workaround_element, %{element: "eHolder"})

      assert f.evidence.readers == [
               %{from: "element:eEmail", reads: ["get_group_data"], inside: false}
             ]

      assert "page:pHome" in f.affects.readers.pages
      assert length(findings) == 11
    end

    test "sure findings apply by default; the rest are the owner's questions" do
      %{index: index, findings: findings} = findings()
      {:ok, resolved} = Decision.resolve([], findings, index: index, now: @now)
      applied = Decision.applicable(resolved, findings)

      assert applied |> Enum.map(& &1.subject.element) |> Enum.sort() ==
               ~w(eGap eJs eList eScript eState eTip eVars)

      assert Enum.all?(applied, & &1.automatic)

      asked =
        for id <- resolved.undecided,
            f = Enum.find(findings, &(&1.id == id)),
            do: f.subject.element

      assert Enum.sort(asked) == ~w(eDead eGrow eHolder eHover)
    end

    test "the owner answers a question or overrides a default, keyed to the element" do
      %{index: index, findings: findings} = findings()
      holder = Enum.find(findings, &(&1.subject == %{element: "eHolder"}))
      gap = Enum.find(findings, &(&1.subject == %{element: "eGap"}))

      {:ok, answer} = Decision.for_finding(holder, :modify, %{"option" => "page_state"})
      {:ok, keep} = Decision.for_finding(gap, :modify, %{"option" => "keep"})

      assert %{"subject" => %{"element" => "eHolder"}, "params" => %{"option" => "page_state"}} =
               Decision.to_map(answer)

      assert {:ok, ^answer} = answer |> Decision.to_json() |> Decision.from_json()

      {:ok, resolved} = Decision.resolve([answer, keep], findings, index: index, now: @now)
      applied = Map.new(Decision.applicable(resolved, findings), &{&1.subject.element, &1})

      assert %{automatic: false, proposal: %{option: :page_state}} = applied["eHolder"]
      assert %{automatic: false, proposal: %{option: :keep}} = applied["eGap"]
      refute holder.id in resolved.undecided

      # Only lowerings, never a plugin option.
      assert {:error, %Error{kind: :invalid_input}} =
               Decision.for_finding(holder, :modify, %{"option" => "rebuild"})
    end

    test "a rejected default applies nothing: the markup stays" do
      %{index: index, findings: findings} = findings()
      gap = Enum.find(findings, &(&1.subject == %{element: "eGap"}))
      {:ok, reject} = Decision.for_finding(gap, :reject)
      {:ok, resolved} = Decision.resolve([reject], findings, index: index, now: @now)

      refute Enum.any?(
               Decision.applicable(resolved, findings),
               &(&1.subject == %{element: "eGap"})
             )
    end
  end

  describe "the plan" do
    test "each question is an open owner decision task that blocks nothing" do
      %{index: index, model: model, findings: findings} = findings()
      {:ok, resolved} = Decision.resolve([], findings, index: index, now: @now)
      applied = Decision.applicable(resolved, findings)

      {:ok, plan} = Plan.build(model, index, nil, applied, resolved: resolved, findings: findings)

      questions = Enum.filter(plan.tasks, &String.starts_with?(&1.id, "decision:workaround/"))

      assert questions |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.map(~w(eDead eGrow eHolder eHover), &("decision:workaround/" <> &1))

      assert Enum.all?(
               questions,
               &(&1.kind == :decision and &1.actor == :owner and &1.status == :open)
             )

      holder = Enum.find(questions, &(&1.id == "decision:workaround/eHolder"))
      assert holder.subjects == ["element:eHolder"]

      key = "finding:" <> Finding.id(:workaround_element, %{element: "eHolder"})
      assert [%{check: :decision_recorded, args: %{key: ^key}}] = holder.criteria

      refute Enum.any?(plan.tasks, fn t ->
               Enum.any?(t.depends_on, &String.starts_with?(&1.task, "decision:workaround/"))
             end)

      # Answered, it is no question any more.
      f = Enum.find(findings, &(&1.subject == %{element: "eHolder"}))
      {:ok, answer} = Decision.for_finding(f, :modify, %{"option" => "keep"})
      {:ok, resolved} = Decision.resolve([answer], findings, index: index, now: @now)
      applied = Decision.applicable(resolved, findings)
      {:ok, plan} = Plan.build(model, index, nil, applied, resolved: resolved, findings: findings)
      refute Enum.any?(plan.tasks, &(&1.id == "decision:workaround/eHolder"))
    end

    test "the contents of a lowered holder are not traced, nor asked about" do
      %{index: index, model: model, findings: findings} = findings()
      {:ok, resolved} = Decision.resolve([], findings, index: index, now: @now)
      applied = Decision.applicable(resolved, findings)
      {:ok, plan} = Plan.build(model, index, nil, applied, resolved: resolved, findings: findings)

      page = Enum.find(plan.tasks, &(&1.kind == :surface and &1.subjects == ["page:pHome"]))
      [%{args: %{elements: elements}}] = Enum.filter(page.criteria, &(&1.check == :traceability))

      assert "element:eVars" in elements
      refute "element:eList" in elements
      assert "element:eInside" in elements
    end

    test "findings: must be findings" do
      %{index: index, model: model} = findings()

      assert {:error, %Error{kind: :invalid_input}} =
               Plan.build(model, index, nil, [], findings: [:x])
    end
  end
end
