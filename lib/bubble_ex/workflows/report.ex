defmodule BubbleEx.Workflows.Report do
  @moduledoc false

  @spec render(map()) :: String.t()
  def render(inventory) do
    """
    # Workflow inventory

    Static inspection of supplied data only. Nothing was executed. Labels describe
    intent, not complete Bubble runtime semantics. Raw source values may be private.

    Availability: **#{inventory.availability}**. Workflow entries: **#{inventory.coverage.workflow_entries}**.
    Action entries: **#{inventory.coverage.action_entries}**. Diagnostics: **#{inventory.coverage.diagnostics}**.
    Source SHA-256 (canonical JSON): `#{inventory.source_sha256}`.

    Explanation coverage (supplied definitions only): #{escape(inspect(inventory.explanation_coverage))}.

    ## Supplied scopes

    #{Enum.map_join(inventory.scopes, "\n", fn s -> "- #{escape(s.path)}: #{s.status} (#{inspect(s.count)} entries)" end)}

    ## Workflows

    #{Enum.map_join(inventory.workflows, "\n", &workflow/1)}

    ## Unclassified definitions

    Typed action-bearing source records outside workflow collections. These may be
    history or unfamiliar layouts; they are not counted as active workflows.

    #{Enum.map_join(inventory.unclassified_definitions, "\n", &workflow/1)}

    ## Collection metadata

    These source members are metadata, not workflow/action definitions:

    #{Enum.map_join(inventory.collection_metadata ++ Enum.flat_map(inventory.workflows, & &1.action_metadata), "\n", fn m -> "- #{escape(m.path)}: #{inspect(m.raw)}" end)}

    ## Diagnostics

    #{Enum.map_join(inventory.diagnostics, "\n", fn d -> "- **#{d.code}** at #{escape(d.path)}: #{escape(d.message)}" end)}
    """
  end

  defp workflow(w) do
    """
    ### #{escape(w.path)}

    #{escape(w.event.explanation)} — type #{escape(inspect(w.event.type))}.
    Discovery: #{w.discovery}. Interpretation: #{w.event.interpretation}. Action ordering: **#{w.ordering}**.

    #{description(w.event, "Event")}
    #{references(w.event.references)}
    #{Enum.map_join(w.actions, "\n", fn a -> "- Source key #{escape(inspect(a.source_key))}: #{escape(a.explanation)} (#{escape(inspect(a.type))})\n" <> description(a, "Action") <> references(a.references) end)}

    Retained source (all properties, unknown constructs and conditions):

    #{code(w.raw)}
    """
  end

  defp description(node, scope) do
    d = node.description
    flags = Enum.map_join(Map.get(d, :flags, []), "; ", & &1.text)

    "#{scope} explanation: **#{d.status}**. #{escape(flags)}\n" <>
      conditions(node.conditions, scope) <>
      explanation_sources(d) <>
      Enum.map_join(Map.get(d, :uninterpreted, []), "\n", &escape(&1.text)) <> "\n"
  end

  defp explanation_sources(description) do
    description
    |> source_evidence()
    |> Enum.uniq()
    |> Enum.map_join("\n", fn {source, target} ->
      "Explanation source #{escape(source)} → definition #{escape(target)}."
    end)
    |> Kernel.<>("\n")
  end

  defp source_evidence(node) do
    own = Enum.map(Map.get(node, :evidence, []), &{node.path, &1.path})
    own ++ Enum.flat_map(Map.get(node, :children, []), &source_evidence/1)
  end

  defp conditions(items, scope),
    do:
      Enum.map_join(items, "\n", fn c ->
        "#{scope} only when at #{escape(c.path)}: #{escape(c.text)} (#{c.status}).\n"
      end)

  defp references(items) do
    Enum.map_join(items, "\n", fn r ->
      targets =
        Enum.map_join(r.candidates, ", ", fn c ->
          escape(c.path) <> " (" <> escape(inspect(c.name)) <> ")"
        end)

      "Reference #{escape(r.path)} → #{escape(inspect(r.value))}: #{r.status} #{targets}.\n"
    end)
  end

  defp code(raw) do
    json = Jason.encode!(raw, pretty: true)

    longest =
      Regex.scan(~r/`+/, json)
      |> Enum.map(fn [s] -> String.length(s) end)
      |> Enum.max(fn -> 0 end)

    fence = String.duplicate("`", max(3, longest + 1))
    fence <> "json\n" <> json <> "\n" <> fence <> "\n"
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~r/([\\`*_{}\[\]()#+.!|~-])/, "\\\\\\1")
    |> String.replace("\n", " ")
  end
end
