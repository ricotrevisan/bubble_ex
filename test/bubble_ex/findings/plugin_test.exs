defmodule BubbleEx.Findings.PluginTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Error, Finding, Findings, Index}
  alias BubbleEx.Plugins.{Catalog, Inventory}

  # An invented app. Toolbox (a public marketplace plugin the catalog
  # knows) runs JavaScript on the home page, whose value a text reads; an
  # invented chart plugin draws on it; another invented plugin is installed
  # and unused; a development version of a fourth is used but not
  # installed. `select2` is one of Bubble's own plugins.
  @toolbox "1488796042609x768734193128308700"
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
            "e4" => %{"id" => "eSelect", "type" => "select2-MultiDropdown"}
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
                          "type" => "GetElement",
                          "properties" => %{"element_id" => "eJ2B"},
                          "next" => %{"type" => "Message", "name" => "value"}
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
               {@dev, false, nil, nil}
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
      assert [%{from: "action:aGo", kind: :reads_element}] = toolbox.state_reads
      assert toolbox.surfaces == ["page:pHome"]
      assert toolbox.workflows == ["workflow:wJ2B"]

      assert toolbox.counts == %{
               elements: 1,
               actions: 1,
               events: 1,
               state_reads: 1,
               surfaces: 1,
               workflows: 1
             }

      assert %{members: [%{role: :element, code: "AAC", count: 2}], workflows: []} =
               Enum.find(inventory, &(&1.bubble_id == @chart))

      assert %{references: [], surfaces: []} =
               unused = Enum.find(inventory, &(&1.bubble_id == @unused))

      refute Inventory.used?(unused)
    end
  end

  describe ":plugin findings" do
    test "a known plugin is replaced natively", %{findings: fs} do
      f = finding(fs, @toolbox)

      assert f.category == :decision
      assert f.confidence == :medium
      assert f.path == "/settings/client_safe/plugins/" <> @toolbox

      assert f.proposal == %{
               transform: :replace_plugin,
               plugin: "plugin:" <> @toolbox,
               option: :replace_native,
               options: [:drop, :replace_native, :rebuild],
               equivalent: :hand_written_code
             }

      assert f.evidence.symbols ==
               Enum.sort(["plugin:" <> @toolbox, "element:eJ2B", "action:aRun", "workflow:wJ2B"])

      assert Enum.map(f.evidence.references, &{&1.from, &1.kind}) == [
               {"action:aGo", :reads_element},
               {"action:aRun", :uses_plugin},
               {"element:eJ2B", :uses_plugin},
               {"workflow:wJ2B", :uses_plugin}
             ]

      assert f.affects.readers.pages == ["page:pHome"]
      assert f.affects.readers.workflows == ["workflow:wJ2B"]
      assert f.message =~ "Toolbox"
    end

    test "an unknown plugin is rebuilt; an unused one dropped", %{findings: fs} do
      assert %{option: :rebuild, options: [:drop, :rebuild], equivalent: nil} =
               finding(fs, @chart).proposal

      assert finding(fs, @chart).confidence == :medium

      unused = finding(fs, @unused)
      assert %{option: :drop, options: [:drop]} = unused.proposal
      assert unused.confidence == :high
      assert unused.evidence.references == []
    end

    test "a used plugin that is not installed is low confidence", %{findings: fs} do
      f = finding(fs, @dev)
      assert %{option: :rebuild, options: [:drop, :rebuild]} = f.proposal
      assert f.confidence == :low
      assert f.evidence.installed == false
      assert f.path == ""
    end

    test "one per plugin; Bubble's own plugins are not plugins", %{findings: fs} do
      assert fs |> Enum.map(& &1.subject.plugin) |> Enum.sort() ==
               Enum.sort([@toolbox, @chart, @unused, @dev])

      assert Enum.all?(fs, &(&1.id == Finding.id(:plugin, &1.subject)))
    end

    test "the basis is the plugin's installed version; the proposal is its uses", ctx do
      f = finding(ctx.findings, @chart)

      upgraded = put_in(app(), ["settings", "client_safe", "plugins", @chart], "3.1.0")
      g = upgraded |> analyze() |> finding(@chart)
      assert g.id == f.id
      assert g.proposal_sha256 == f.proposal_sha256
      assert g.basis_sha256 != f.basis_sha256

      fewer = update_in(app(), ["pages", "pg", "elements"], &Map.delete(&1, "e3"))
      h = fewer |> analyze() |> finding(@chart)
      assert h.id == f.id
      assert h.proposal_sha256 != f.proposal_sha256
      assert h.basis_sha256 == f.basis_sha256
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
      {:ok, drop} = Decision.for_finding(f, :modify, %{"option" => "drop"})

      {:ok, resolved} =
        Decision.resolve([accept], ctx.findings, index: ctx.index, now: ~U[2026-09-26 00:00:00Z])

      assert [%{transform: :replace_plugin, proposal: %{option: :replace_native}}] =
               Decision.applicable(resolved, ctx.findings)

      {:ok, resolved} =
        Decision.resolve([drop], ctx.findings, index: ctx.index, now: ~U[2026-09-26 00:00:00Z])

      assert [%{params: %{option: :drop}, proposal: %{option: :drop}}] =
               Decision.applicable(resolved, ctx.findings)

      assert {:ok, ^drop} = drop |> Decision.to_json() |> Decision.from_json()
    end

    test "only offered options; never a reject", ctx do
      unused = finding(ctx.findings, @unused)

      assert {:error, %Error{kind: :invalid_input}} =
               Decision.for_finding(unused, :modify, %{"option" => "rebuild"})

      assert {:error, %Error{kind: :invalid_input}} =
               Decision.for_finding(unused, :modify, %{"option" => "keep"})

      assert {:error, %Error{kind: :invalid_input}} =
               Decision.for_finding(unused, :modify, %{"equivalent" => "chart"})

      assert {:error, %Error{kind: :invalid_input, message: message}} =
               Decision.for_finding(unused, :reject)

      assert message =~ "cannot be rejected"
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
