defmodule BubbleEx.Findings.PluginTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Error, Finding, Findings, Index}
  alias BubbleEx.Plugins.{Catalog, Inventory}

  # An invented app. Toolbox (a public marketplace plugin the catalog
  # knows, by code-level features) runs JavaScript on the home page, whose
  # value a later step reads; Heroicons (catalog, a standard component)
  # draws two icons, and a text reads one's state; an invented chart plugin
  # draws on the page and names one of its data types; another invented
  # plugin is installed and unused; a development version of a fourth is
  # installed (under its `_current` key) and used; a fifth is used but not
  # installed. `select2` is one of Bubble's own plugins.
  @toolbox "1488796042609x768734193128308700"
  @icons "1618916043803x877032991371296800"
  @devinst "1600000000000x400"
  @chart "1600000000000x200"
  @unused "1600000000000x100"
  @dev "1600000000000x300"

  defp app(overrides \\ %{}) do
    %{
      "settings" => %{
        "client_safe" => %{
          "plugins" => %{
            @toolbox => "2.1.4",
            @chart => "3.0.0",
            @unused => "1.0.0",
            @icons => "4.0.2",
            (@devinst <> "_current") => "0.1.0",
            "select2" => true
          }
        }
      },
      "pages" => %{
        "pg" => %{
          "id" => "pHome",
          "type" => "Page",
          "elements" => %{
            "e1" => %{"id" => "eJ2B", "type" => @toolbox <> "-AAP"},
            "e2" => %{"id" => "eChart", "type" => @chart <> "-AAC"},
            "e3" => %{"id" => "eChart2", "type" => @chart <> "-AAC"},
            "e4" => %{"id" => "eSelect", "type" => "select2-MultiDropdown"},
            "e5" => %{"id" => "eIcon1", "type" => @icons <> "-ABj"},
            "e6" => %{"id" => "eIcon2", "type" => @icons <> "-ABj"},
            "e7" => %{"id" => "eDev", "type" => @devinst <> "_current-AAC"},
            "e8" => %{
              "id" => "eChartData",
              "type" => "RepeatingGroup",
              "properties" => %{"data_type" => "api." <> @chart <> ".plugin_api.AAe"}
            },
            "e9" => %{
              "id" => "eIconText",
              "type" => "Text",
              "properties" => %{
                "text" => %{
                  "type" => "TextExpression",
                  "entries" => %{
                    "0" => %{
                      "type" => "GetElement",
                      "properties" => %{"element_id" => "eIcon1"},
                      "next" => %{"type" => "Message", "name" => "isvisible"}
                    }
                  }
                }
              }
            }
          },
          "workflows" => %{
            "w1" => %{
              "id" => "wJ2B",
              "type" => @toolbox <> "-AAX",
              "properties" => %{"element_id" => "eJ2B"},
              "actions" => %{
                "0" => %{"id" => "aRun", "type" => @toolbox <> "-AAg", "properties" => %{}},
                "1" => %{
                  "id" => "aGo",
                  "type" => "ChangePage",
                  "properties" => %{
                    "parameters" => %{
                      "0" => %{
                        "key" => "q",
                        "value" => %{
                          "type" => "PreviousStep",
                          "properties" => %{"action_id" => "aRun"},
                          "next" => %{"type" => "Message", "name" => "output1"}
                        }
                      }
                    }
                  }
                }
              }
            },
            "w2" => %{
              "id" => "wBtn",
              "type" => "ButtonClicked",
              "properties" => %{"element_id" => "eChart"},
              "actions" => %{"0" => %{"id" => "aDev", "type" => @dev <> "_current-AAD"}}
            }
          }
        }
      }
    }
    |> Map.merge(overrides)
  end

  setup_all do
    app = app()
    {:ok, index} = Index.build(app)
    {:ok, result} = Findings.analyze(app, index: index)
    %{app: app, index: index, findings: Enum.filter(result.findings, &(&1.kind == :plugin))}
  end

  defp finding(findings, plugin), do: Enum.find(findings, &(&1.subject == %{plugin: plugin}))

  describe "inventory" do
    test "every installed or used marketplace plugin, with its uses", %{index: index} do
      inventory = Inventory.build(index)

      assert Enum.map(inventory, &{&1.bubble_id, &1.installed, &1.version, &1.name}) == [
               {@toolbox, true, "2.1.4", "Toolbox"},
               {@unused, true, "1.0.0", nil},
               {@chart, true, "3.0.0", nil},
               {@dev, false, nil, nil},
               {@devinst, true, "0.1.0", nil},
               {@icons, true, "4.0.2", "Heroicons"}
             ]

      toolbox = Enum.find(inventory, &(&1.bubble_id == @toolbox))

      assert toolbox.members == [
               %{role: :element, code: "AAP", count: 1},
               %{role: :action, code: "AAg", count: 1},
               %{role: :event, code: "AAX", count: 1}
             ]

      assert toolbox.elements == ["element:eJ2B"]
      assert toolbox.actions == ["action:aRun"]
      assert toolbox.events == ["workflow:wJ2B"]
      assert [%{from: "action:aGo", kind: :reads_step, to: "action:aRun"}] = toolbox.step_reads
      assert toolbox.surfaces == ["page:pHome"]
      assert toolbox.workflows == ["workflow:wJ2B"]

      assert toolbox.counts == %{
               elements: 1,
               actions: 1,
               events: 1,
               data_types: 0,
               state_reads: 0,
               step_reads: 1,
               surfaces: 1,
               workflows: 1
             }

      icons = Enum.find(inventory, &(&1.bubble_id == @icons))
      assert [%{from: "element:eIconText", kind: :reads_element}] = icons.state_reads

      assert icons.features == [
               %{role: :element, code: "ABj"},
               %{role: :state, code: "ABj"}
             ]

      assert %{
               members: [
                 %{role: :element, code: "AAC", count: 2},
                 %{role: :data_type, code: "AAe", count: 1}
               ],
               data_types: ["element:eChartData"],
               workflows: []
             } = Enum.find(inventory, &(&1.bubble_id == @chart))

      assert %{references: [], surfaces: []} =
               unused = Enum.find(inventory, &(&1.bubble_id == @unused))

      refute Inventory.used?(unused)
    end
  end

  describe ":plugin findings" do
    test "a plugin whose features all have a standard component is replaced natively", ctx do
      f = finding(ctx.findings, @icons)

      assert f.category == :decision
      assert f.confidence == :medium
      assert f.path == "/settings/client_safe/plugins/" <> @icons

      assert f.proposal == %{
               transform: :replace_plugin,
               plugin: "plugin:" <> @icons,
               option: :replace_native,
               options: [:drop, :replace_native, :rebuild],
               features: [
                 %{role: :element, code: "ABj", equivalent: :icon_set},
                 %{role: :state, code: "ABj", equivalent: :icon_set}
               ]
             }

      # Uses are evidence facts, not what the decision is about.
      assert f.evidence.symbols == ["plugin:" <> @icons]
      assert f.evidence.references == []
      assert f.evidence.uses.elements == ["element:eIcon1", "element:eIcon2"]
      assert f.affects.readers.pages == ["page:pHome"]
      assert f.message =~ "Heroicons"
    end

    test "code-level equivalents are low confidence", %{findings: fs} do
      f = finding(fs, @toolbox)
      assert %{option: :replace_native, options: [:drop, :replace_native, :rebuild]} = f.proposal
      assert Enum.all?(f.proposal.features, &(&1.equivalent == :hand_written_code))
      assert f.confidence == :low
      assert f.evidence.rewire == ["workflow:wJ2B"]
      assert f.evidence.event_only == []
      assert "workflow:wJ2B" in f.affects.readers.workflows
    end

    test "an unknown plugin or feature is rebuilt; an unused one dropped", %{findings: fs} do
      chart = finding(fs, @chart)
      assert %{option: :rebuild, options: [:drop, :rebuild]} = chart.proposal
      assert chart.confidence == :medium
      assert %{role: :data_type, code: "AAe", equivalent: nil} in chart.proposal.features

      unused = finding(fs, @unused)
      assert %{option: :drop, options: [:drop], features: []} = unused.proposal
      assert unused.confidence == :high
    end

    test "a used plugin that is not installed is low confidence", %{findings: fs} do
      f = finding(fs, @dev)
      assert %{option: :rebuild, options: [:drop, :rebuild]} = f.proposal
      assert f.confidence == :low
      assert f.evidence.installed == false
      assert f.path == ""

      # Installed under a development key: the same plugin.
      assert finding(fs, @devinst).evidence.installed
    end

    test "one per plugin; Bubble's own plugins are not plugins", %{findings: fs} do
      assert fs |> Enum.map(& &1.subject.plugin) |> Enum.sort() ==
               Enum.sort([@toolbox, @chart, @unused, @dev, @devinst, @icons])

      assert Enum.all?(fs, &(&1.id == Finding.id(:plugin, &1.subject)))
    end

    test "the basis is the installed version; the proposal is the set of features used", ctx do
      f = finding(ctx.findings, @icons)

      upgraded = put_in(app(), ["settings", "client_safe", "plugins", @icons], "4.1.0")
      g = upgraded |> analyze() |> finding(@icons)
      assert g.id == f.id
      assert g.proposal_sha256 == f.proposal_sha256
      assert g.basis_sha256 != f.basis_sha256

      # One icon less: the same features, so the same proposal.
      fewer = update_in(app(), ["pages", "pg", "elements"], &Map.delete(&1, "e6"))
      h = fewer |> analyze() |> finding(@icons)
      assert h.proposal_sha256 == f.proposal_sha256
      assert h.basis_sha256 == f.basis_sha256
      assert h.evidence.counts.elements == 1

      # A new feature (another icon type) changes it.
      more =
        put_in(app(), ["pages", "pg", "elements", "e10"], %{
          "id" => "eIcon3",
          "type" => @icons <> "-AAC"
        })

      assert (more |> analyze() |> finding(@icons)).proposal_sha256 != f.proposal_sha256
    end

    test "is deterministic", ctx do
      assert Enum.map(analyze(ctx.app), &Finding.to_map/1) ==
               Enum.map(ctx.findings, &Finding.to_map/1)
    end
  end

  describe "decisions" do
    test "accept takes the suggestion; modify picks another offered option", ctx do
      f = finding(ctx.findings, @toolbox)
      {:ok, accept} = Decision.for_finding(f, :accept)

      {:ok, drop} =
        Decision.for_finding(f, :modify, %{
          "option" => "drop",
          "delete_workflows" => ["workflow:wJ2B"]
        })

      {:ok, resolved} =
        Decision.resolve([accept], ctx.findings, index: ctx.index, now: ~U[2026-09-26 00:00:00Z])

      assert [%{transform: :replace_plugin, proposal: %{option: :replace_native}}] =
               Decision.applicable(resolved, ctx.findings)

      {:ok, resolved} =
        Decision.resolve([drop], ctx.findings, index: ctx.index, now: ~U[2026-09-26 00:00:00Z])

      assert [%{proposal: %{option: :drop, delete_workflows: ["workflow:wJ2B"]}}] =
               Decision.applicable(resolved, ctx.findings)

      assert {:ok, ^drop} = drop |> Decision.to_json() |> Decision.from_json()
    end

    test "only offered options and rewire workflows; never a reject or acknowledge", ctx do
      unused = finding(ctx.findings, @unused)
      toolbox = finding(ctx.findings, @toolbox)

      for {f, params} <- [
            {unused, %{"option" => "rebuild"}},
            {unused, %{"option" => "keep"}},
            {unused, %{"equivalent" => "chart"}},
            {toolbox, %{"delete_workflows" => ["workflow:wJ2B"]}},
            {toolbox, %{"option" => "drop", "delete_workflows" => ["workflow:wBtn"]}},
            {toolbox, %{"option" => "drop", "delete_workflows" => ["wJ2B"]}}
          ],
          do:
            assert(
              {:error, %Error{kind: :invalid_input}} = Decision.for_finding(f, :modify, params),
              inspect(params)
            )

      assert {:error, %Error{kind: :invalid_input, message: message}} =
               Decision.for_finding(unused, :reject)

      assert message =~ "cannot be rejected"

      {:ok, accept} = Decision.for_finding(unused, :accept)

      assert {:error, %Error{kind: :invalid_input}} =
               Decision.acknowledge(accept, finding: unused)
    end

    test "every equivalent the catalog names is documented" do
      for e <- Catalog.equivalents(),
          do: assert(Code.fetch_docs(Catalog) |> inspect() =~ "`:#{e}`", inspect(e))
    end
  end

  defp analyze(app) do
    {:ok, result} = Findings.analyze(app, kinds: [:plugin])
    result.findings
  end
end
