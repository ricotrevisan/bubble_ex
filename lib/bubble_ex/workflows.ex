defmodule BubbleEx.Workflows do
  @moduledoc """
  Static, lossless workflow inventory of supplied JSON app data. Never performs
  network requests or executes expressions or workflows. Missing definitions are
  unavailable, not evidence of an app with no workflows. See `inventory/1`.
  """

  alias BubbleEx.AppTree.Writer
  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Workflows.{Node, Report, Source}

  @doc """
  Inventory every entry in workflow collections (`workflows`, `%wf`) and
  the root backend `api` collection, including malformed entries. Source paths
  are RFC 6901 JSON pointers into the supplied payload. `raw` values are retained
  exactly. Availability and interpretation are separate: a present workflow may
  contain unsupported semantics. The inventory claims coverage of supplied data
  only, never the complete server-side app.
  """
  @spec inventory(term()) :: {:ok, map()} | {:error, Error.t()}
  def inventory(payload) when is_map(payload) and not is_struct(payload) do
    if json?(payload) do
      build(payload)
    else
      {:error, Error.new(:invalid_input, "expected JSON data with string map keys")}
    end
  end

  def inventory(_), do: {:error, Error.new(:invalid_input, "expected an app JSON object")}

  defp build(payload) do
    collections = Source.collections(payload)
    index = Node.index(payload)
    scopes = Enum.map(collections, &scope/1)

    {candidates, known} = Enum.split_with(collections, &Map.get(&1, :single, false))
    workflows = Enum.flat_map(known, &workflow_entries(&1, index))
    candidates = Enum.flat_map(candidates, &workflow_entries(&1, index))

    diagnostics =
      Enum.flat_map(scopes, & &1.diagnostics) ++
        Enum.flat_map(workflows ++ candidates, & &1.diagnostics)

    {:ok,
     %{
       explanation_coverage: explanation_coverage(workflows),
       schema_version: 2,
       explanation_vocabulary_version: 1,
       scope: "supplied_data_only",
       execution: "never",
       source_sha256: hash(payload),
       availability: availability(scopes, workflows),
       scopes: scopes,
       workflows: workflows,
       unclassified_definitions: candidates,
       collection_metadata:
         Source.owner_metadata(payload) ++
           Enum.flat_map(collections, &Source.metadata(&1.value, &1.path)),
       diagnostics: diagnostics,
       coverage: %{
         workflow_entries: length(workflows),
         unclassified_candidates: length(candidates),
         candidate_action_entries: Enum.sum(Enum.map(candidates, &length(&1.actions))),
         malformed_workflow_entries:
           Enum.count(workflows, &(&1.event.interpretation == "malformed")),
         action_entries: Enum.sum(Enum.map(workflows, &length(&1.actions))),
         unavailable_scopes: Enum.count(scopes, &(&1.status == "unavailable")),
         malformed_scopes: Enum.count(scopes, &(&1.status == "malformed")),
         diagnostics: length(diagnostics)
       }
     }}
  end

  defp explanation_coverage(workflows) do
    nodes = Enum.flat_map(workflows, &[&1.event | &1.actions])

    %{
      nodes: Enum.frequencies_by(nodes, & &1.description.status),
      conditions: nodes |> Enum.flat_map(& &1.conditions) |> Enum.frequencies_by(& &1.status),
      data_actions:
        nodes
        |> Enum.filter(&(&1.type in ["NewThing", "ChangeThing"]))
        |> Enum.frequencies_by(& &1.description.status)
    }
  end

  defp workflow_entries(%{single: true} = collection, index) do
    [
      Node.workflow(collection.value, collection.path, index)
      |> Map.put(:discovery, "unclassified_candidate")
    ]
  end

  defp workflow_entries(%{present: true} = collection, index) do
    Enum.map(Source.entries(collection.value), fn {key, value} ->
      Node.workflow(value, collection.path ++ [key], index)
      |> Map.put(:discovery, "collection_entry")
    end)
  end

  defp workflow_entries(_, _), do: []

  defp scope(%{single: true} = c) do
    %{
      path: Source.pointer(c.path),
      status: "unclassified",
      count: 1,
      diagnostics: [
        Source.diagnostic(
          "unclassified_definition",
          c.path,
          "Action-bearing definition outside known workflow collections retained as a candidate; its role is not inferred."
        )
      ]
    }
  end

  defp scope(%{malformed: true} = c) do
    %{
      path: Source.pointer(c.path),
      status: "malformed",
      count: nil,
      raw: c.value,
      diagnostics: [
        Source.diagnostic(
          "malformed_owner",
          c.path,
          "Expected an owner object/map; source retained and workflow availability is unknown."
        )
      ]
    }
  end

  defp scope(%{present: false} = c) do
    %{
      path: Source.pointer(c.path),
      status: "unavailable",
      count: nil,
      diagnostics: [
        Source.diagnostic(
          "unavailable_data",
          c.path,
          "Workflow data was not supplied for this scope."
        )
      ]
    }
  end

  defp scope(%{value: value} = c) when is_map(value) or is_list(value) do
    %{
      path: Source.pointer(c.path),
      status: if(Source.entries(value) == [], do: "empty", else: "present"),
      count: length(Source.entries(value)),
      diagnostics: []
    }
  end

  defp scope(c) do
    %{
      path: Source.pointer(c.path),
      status: "malformed",
      count: nil,
      raw: c.value,
      diagnostics: [
        Source.diagnostic(
          "malformed_collection",
          c.path,
          "Expected a workflow map or list; value retained."
        )
      ]
    }
  end

  defp availability(scopes, workflows) do
    cond do
      Enum.any?(scopes, &(&1.status in ["malformed", "unclassified"])) -> "partial"
      Enum.any?(scopes, &(&1.status == "unavailable")) and workflows != [] -> "partial"
      Enum.any?(scopes, &(&1.status == "unavailable")) -> "unavailable"
      workflows == [] -> "empty"
      true -> "present"
    end
  end

  @doc "Returns the JSON and Markdown artifacts without writing them. Input is supplied app data."
  @spec render(term()) ::
          {:ok, %{json: String.t(), markdown: String.t(), inventory: map()}} | {:error, Error.t()}
  def render(payload) do
    with {:ok, inventory} <- inventory(payload) do
      {:ok,
       %{
         json: Jason.encode!(CanonicalJson.ordered(inventory), pretty: true) <> "\n",
         markdown: Report.render(inventory),
         inventory: inventory
       }}
    end
  end

  @doc "Writes inventory.json and WORKFLOWS.md to an empty directory. Reports retain private source values."
  @spec export(term(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def export(payload, out_dir) when is_binary(out_dir) do
    with {:ok, artifacts} <- render(payload),
         {:ok, _} <-
           Writer.write(out_dir, [
             {"inventory.json", {:text, artifacts.json}},
             {"WORKFLOWS.md", {:text, artifacts.markdown}}
           ]) do
      {:ok, %{out_dir: out_dir, coverage: artifacts.inventory.coverage}}
    end
  rescue
    _ ->
      {:error,
       Error.new(:invalid_input, "could not write workflow inventory", %{out_dir: out_dir})}
  end

  def export(_, _), do: {:error, Error.new(:invalid_input, "expected an output directory path")}

  defp json?(map) when is_map(map) and not is_struct(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and String.valid?(k) and json?(v) end)

  defp json?([]), do: true
  defp json?([head | tail]), do: json?(head) and json_list?(tail)
  defp json?(v) when is_binary(v), do: String.valid?(v)
  defp json?(v), do: is_number(v) or v in [true, false, nil]

  defp json_list?([]), do: true
  defp json_list?([head | tail]), do: json?(head) and json_list?(tail)
  defp json_list?(_), do: false

  # Unlike the frontend serializer, preserve explicit null values.
  defp hash(payload), do: CanonicalJson.sha256(payload)
end
