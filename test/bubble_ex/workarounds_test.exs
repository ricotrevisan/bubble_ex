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
               "eNet" => {:js_bridge, :low},
               "eHover" => {:unknown, :low},
               "eDead" => {:unused, :high},
               "eState" => {:value_holder, :high},
               "eGrow" => {:unknown, :low}
             }
    end

    test "a JS bridge's scripts decide: page-only is a hook, the rest a brief for a developer" do
      entries = catalog()

      assert %{option: :hook, js: %{verdict: :page_only, brief: nil}} = entries["eJs"]
      assert [%{element: "eJs", kind: :publisher}] = entries["eJs"].js.scripts
      assert %{option: :hook, js: %{verdict: :page_only}} = entries["eScript"]

      net = entries["eNet"]
      assert %{class: :js_bridge, confidence: :low, option: :keep} = net
      refute :hook in net.options
      assert net.reason =~ "a developer has to port"
      assert %{verdict: :owner, brief: brief} = net.js
      assert "it makes a network request (fetch)" in brief.why
      assert brief.shape =~ "Make the request on the server"
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

      # An unclear one suggests keeping the markup, and offers every lowering
      # but skipping.
      assert [:keep, :page_state, :plugin_event, :css_gap, :hook] = entries["eGrow"].options
      # An unused one is skipped, or kept.
      assert %{option: :skip, options: [:skip, :keep], unused_inside: nil} = entries["eDead"]
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

  describe "unused elements" do
    defp hidden(id, order, extra \\ %{}) do
      Map.merge(
        %{
          "id" => id,
          "type" => "Group",
          "properties" => %{
            "order" => order,
            "is_visible" => false,
            "width" => 200,
            "height" => 50
          }
        },
        extra
      )
    end

    defp with_elements(fun), do: update_in(app(), ["pages", "index", "elements"], fun)

    defp entries(app) do
      {:ok, index} = Index.build(app)
      app |> Workarounds.catalog(index) |> Map.new(&{&1.element, &1})
    end

    defp applied(app, decide) do
      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)
      {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)
      decisions = decide.(findings)
      {:ok, resolved} = Decision.resolve(decisions, findings, index: index, now: @now)
      Decision.applicable(resolved, findings)
    end

    defp keep(id) do
      fn findings ->
        f = Enum.find(findings, &(&1.subject == %{element: id}))
        {:ok, d} = Decision.for_finding(f, :modify, %{"option" => "keep"})
        [d]
      end
    end

    defp nest do
      with_elements(fn els ->
        Map.put(
          els,
          "eOuter",
          hidden("eOuter", 40, %{
            "elements" => %{
              "eInner" => hidden("eInner", 1, %{"elements" => %{"eLeaf" => text("eLeaf", 1)}})
            }
          })
        )
      end)
    end

    defp text(id, order),
      do: %{
        "id" => id,
        "type" => "Text",
        "properties" => %{"order" => order, "text" => "hidden", "width" => 100, "height" => 20}
      }

    test "a never-visible element nothing reads, sets, shows or triggers is unused" do
      e = entries(app())["eDead"]

      assert %{class: :unused, confidence: :high, readers: [], setters: [], events: []} = e
      assert e.reason =~ "nothing reads, sets, shows or triggers it"

      # A fetched payload's ID index and editor history name it: no use.
      app =
        app()
        |> Map.put("_index", %{"id_to_path" => %{"eDead" => "%p3.pHome.%el.eDead"}})
        |> Map.put("merge_changes", [%{"id" => "eDead"}])

      assert entries(app)["eDead"].class == :unused
    end

    test "any use keeps an element out of the class" do
      app =
        with_elements(fn els ->
          els
          # its HTML ID attribute: the app's code may find it
          |> Map.put("eId", hidden("eId", 41) |> put_in(["properties", "html_id"], "panel"))
          # a plugin element names it outside the index's references
          |> Map.put("eNamed", hidden("eNamed", 42))
          |> Map.put("eRef", %{
            "id" => "eRef",
            "type" => "Text",
            "properties" => %{"order" => 43, "text" => "x", "target" => "eNamed"}
          })
          # its contents trigger a workflow
          |> Map.put(
            "eClick",
            hidden("eClick", 44, %{"elements" => %{"eClickBtn" => text("eClickBtn", 1)}})
          )
          # a reusable element instance: its workflows run inside it
          |> Map.put("eInst", %{
            "id" => "eInst",
            "type" => "CustomElement",
            "properties" => %{
              "order" => 45,
              "is_visible" => false,
              "width" => 200,
              "height" => 50
            }
          })
          # …or holds one
          |> Map.put(
            "eInstIn",
            hidden("eInstIn", 47, %{
              "elements" => %{
                "eInst2" => %{
                  "id" => "eInst2",
                  "type" => "CustomElement",
                  "properties" => %{"order" => 1, "width" => 200, "height" => 50}
                }
              }
            })
          )
          # a script
          |> Map.put("eHtml", %{
            "id" => "eHtml",
            "type" => "HTML",
            "properties" => %{
              "order" => 46,
              "is_visible" => false,
              "html" => "<script>go()</script>"
            }
          })
        end)
        |> put_in(["pages", "index", "workflows", "w2"], %{
          "id" => "wClick",
          "type" => "ButtonClicked",
          "properties" => %{"element_id" => "eClickBtn"},
          "actions" => %{}
        })

      entries = entries(app)

      for id <- ~w(eId eNamed eClick eInst eInstIn eHtml),
          do: refute(entries[id].class == :unused, "#{id} is not unused")

      # Holding a value nobody reads, hidden: unused; set by a step: not.
      assert entries["eDead"].class == :unused
      assert entries["eState"].class == :value_holder
    end

    test "a nest of unused elements is skipped, or kept, as a whole" do
      app = nest()
      entries = entries(app)

      assert %{class: :unused, held: ["element:eInner"], unused_inside: nil} = entries["eOuter"]
      assert %{class: :unused, unused_inside: "element:eOuter"} = entries["eInner"]

      skipped = Workarounds.skipped(applied(app, fn _ -> [] end))
      assert "eOuter" in skipped and "eInner" in skipped and "eDead" in skipped

      for id <- ~w(eOuter eInner) do
        skipped = Workarounds.skipped(applied(app, keep(id)))
        refute "eOuter" in skipped
        refute "eInner" in skipped
        assert "eDead" in skipped
      end
    end

    test "a value holder lowers to page state with the unused elements it holds" do
      app =
        with_elements(fn els ->
          els
          |> Map.put("eVals", %{
            "id" => "eVals",
            "type" => "Group",
            "properties" => %{
              "order" => 50,
              "single_width" => true,
              "single_height" => true,
              "width" => 10,
              "height" => 10,
              "data_source" => %{"type" => "CurrentUser"}
            },
            "elements" => %{"eHid" => hidden("eHid", 1)}
          })
          |> Map.put("eValsText", %{
            "id" => "eValsText",
            "type" => "Text",
            "properties" => %{
              "order" => 51,
              "text" => %{
                "type" => "TextExpression",
                "entries" => %{
                  "0" => %{
                    "type" => "GetElement",
                    "properties" => %{"element_id" => "eVals"},
                    "next" => %{"type" => "Message", "name" => "get_group_data"}
                  }
                }
              }
            }
          })
        end)

      entries = entries(app)
      assert %{class: :value_holder, confidence: :high} = entries["eVals"]
      assert entries["eHid"].class == :unused

      assert "eVals" in Workarounds.page_state(applied(app, fn _ -> [] end))

      # The owner keeps what it holds: the holder keeps its markup too.
      kept = applied(app, keep("eHid"))
      refute "eVals" in Workarounds.page_state(kept)
      refute "eHid" in Workarounds.skipped(kept)
    end

    test "a tiny wrapper of unused elements only is a spacer" do
      app =
        with_elements(fn els ->
          Map.put(els, "eWrap", %{
            "id" => "eWrap",
            "type" => "Group",
            "properties" => %{
              "order" => 52,
              "single_width" => true,
              "single_height" => true,
              "width" => 10,
              "height" => 10
            },
            "elements" => %{"eGone" => hidden("eGone", 1)}
          })
        end)

      entries = entries(app)
      assert entries["eGone"].class == :unused
      assert %{class: :spacer, confidence: :high} = entries["eWrap"]
      assert entries["eWrap"].reason =~ "only wraps 1 unused element (eGone)"
    end

    test "the finding names its unused holder; a reject keeps it too" do
      app = nest()
      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)
      {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)
      inner = Enum.find(findings, &(&1.subject == %{element: "eInner"}))

      assert %{class: :unused, option: :skip, options: [:skip, :keep], inside: "element:eOuter"} =
               inner.proposal

      assert inner.message =~ "not generated unless the owner keeps it"
      # Other classes' proposals do not name a holder.
      refute Map.has_key?(
               Enum.find(findings, &(&1.subject == %{element: "eGap"})).proposal,
               :inside
             )

      # Only an unused element may be skipped.
      gap = Enum.find(findings, &(&1.subject == %{element: "eGap"}))

      assert {:error, %Error{kind: :invalid_input}} =
               Decision.for_finding(gap, :modify, %{"option" => "skip"})

      reject = fn fs ->
        {:ok, d} =
          Decision.for_finding(Enum.find(fs, &(&1.subject == %{element: "eOuter"})), :reject)

        [d]
      end

      skipped = Workarounds.skipped(applied(app, reject))
      refute "eOuter" in skipped
      refute "eInner" in skipped
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
      assert length(findings) == 12
    end

    test "sure findings apply by default; the rest are the owner's questions" do
      %{index: index, findings: findings} = findings()
      {:ok, resolved} = Decision.resolve([], findings, index: index, now: @now)
      applied = Decision.applicable(resolved, findings)

      assert applied |> Enum.map(& &1.subject.element) |> Enum.sort() ==
               ~w(eDead eGap eJs eList eScript eState eTip eVars)

      assert Enum.all?(applied, & &1.automatic)

      asked =
        for id <- resolved.undecided,
            f = Enum.find(findings, &(&1.id == id)),
            do: f.subject.element

      assert Enum.sort(asked) == ~w(eGrow eHolder eHover eNet)
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

      # Page state is for groups only so far.
      tip = Enum.find(findings, &(&1.subject == %{element: "eTip"}))

      assert {:error, %Error{kind: :invalid_input}} =
               Decision.for_finding(tip, :modify, %{"option" => "page_state"})

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
               Enum.map(~w(eGrow eHolder eHover eNet), &("decision:workaround/" <> &1))

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

      acceptance =
        Enum.find(plan.tasks, &(&1.kind == :acceptance and &1.subjects == ["page:pHome"]))

      [%{args: %{elements: accepted}}] =
        Enum.filter(acceptance.criteria, &(&1.check == :traceability))

      refute "element:eList" in accepted
      assert "element:eVars" in accepted

      # A skipped unused element and its contents are not generated either.
      refute "element:eDead" in elements
      refute "element:eDeadText" in elements
      refute "element:eDead" in accepted
    end

    test "findings: must be findings" do
      %{index: index, model: model} = findings()

      assert {:error, %Error{kind: :invalid_input}} =
               Plan.build(model, index, nil, [], findings: [:x])
    end
  end
end
