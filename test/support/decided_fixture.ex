defmodule BubbleEx.Test.DecidedFixture do
  @moduledoc false

  # Owner decision sets over the synthetic findings export
  # (test/support/samples/synthetic_findings_export.json, invented data),
  # taken through the whole pipeline: Findings.analyze -> Decision records
  # -> resolve/3 -> applicable/2 -> Target.Ash.map/3. Used by the Target.Ash
  # decision goldens (WTF-401), the diagnostic sweep and
  # scripts/ash_compile_check/render.exs.
  #
  # Every set rejects the two `search_index` hints: hints apply by default,
  # and Target.Ash does not apply `add_indexes` before cut 2.

  alias BubbleEx.{Decision, Findings, Index, Model}
  alias BubbleEx.Target.Ash

  @app "test/support/samples/synthetic_findings_export.json"
  @now ~U[2026-09-26 00:00:00Z]

  @sets ~w(refine derive rename combined)a

  @doc "The decision sets."
  def sets, do: @sets

  @doc "The app JSON."
  def app, do: @app |> File.read!() |> Jason.decode!()

  @doc """
  `%{model, index, findings, records, applied, decisions_sha256}` for a
  decision set.
  """
  def build(set) when set in @sets or set == :locked do
    app = app()
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {:ok, %{findings: findings}} = Findings.analyze(app, model: model, index: index)

    records = records(set, findings)
    {:ok, resolved} = Decision.resolve(records, findings, index: index, now: @now)
    applied = Decision.applicable(resolved, findings)

    %{
      model: model,
      index: index,
      findings: findings,
      records: records,
      applied: applied,
      decisions_sha256: Decision.decisions_sha256(records)
    }
  end

  @doc "The mapped Project of a decision set (`opts` go to `Target.Ash.map/3`)."
  def project(set, opts \\ []) do
    %{model: model, applied: applied, decisions_sha256: sha} = build(set)
    Ash.map(model, applied, Keyword.put(opts, :decisions_sha256, sha))
  end

  @doc """
  The `:combined` decisions without the table rename, mapped after the
  name lock: `names:` is the source-faithful mapping's name map, so the
  renamed attributes keep their columns (`source:`) and the renamed module
  keeps its table.
  """
  def locked_project(opts \\ []) do
    %{model: model, applied: applied, decisions_sha256: sha} = build(:locked)
    {:ok, faithful} = Ash.map(model)
    Ash.map(model, applied, Keyword.merge(opts, names: faithful.names, decisions_sha256: sha))
  end

  defp records(set, findings) do
    hints = for f <- findings, f.kind == :search_index, do: finding!(f, :reject)
    Enum.sort_by(hints ++ decided(set, findings), & &1.key)
  end

  defp decided(:refine, findings) do
    [
      # every write is integral: an integer
      findings |> find(:number_type, "project", "task_count_number") |> finding!(:accept),
      # points may be fractional after all: a decimal
      findings
      |> find(:number_type, "task", "points_number")
      |> finding!(:modify, %{"to" => "decimal"})
    ]
  end

  defp decided(:derive, findings) do
    [
      # "Sort: Workspace Name" copies its Workspace's Name
      findings
      |> find(:denormalized_field, "project", "sort_workspace_name_text")
      |> finding!(:accept),
      # "Workspace created" copies its Workspace's Created Date (a built-in field)
      findings
      |> find(:denormalized_field, "project", "workspace_created_date")
      |> finding!(:accept)
    ]
  end

  defp decided(:rename, _findings) do
    [
      rename!(%{type: "project"}, "module", "Initiative"),
      rename!(%{type: "task"}, "table", "todo_item"),
      rename!(%{type: "project", field: "title_text"}, "attribute", "headline"),
      rename!(%{type: "project", field: "workspace_custom_workspace"}, "relationship", "team")
    ]
  end

  defp decided(:combined, findings) do
    decided(:refine, findings) ++
      decided(:derive, findings) ++
      decided(:rename, findings) ++
      [rename!(%{type: "project", field: "sort_workspace_name_text"}, "calculation", "team_name")]
  end

  defp decided(:locked, findings) do
    Enum.reject(decided(:combined, findings), &(&1.kind == :rename and &1.params.slot == :table))
  end

  defp find(findings, kind, type, field) do
    Enum.find(findings, &(&1.kind == kind and &1.subject == %{type: type, field: field})) ||
      raise "no #{kind} finding on #{type}.#{field}"
  end

  defp finding!(finding, choice, params \\ %{}) do
    {:ok, decision} =
      Decision.for_finding(finding, choice, params,
        id: "dec_" <> binary_part(finding.id, byte_size(finding.id) - 8, 8),
        author: %{"kind" => "owner", "id" => "user:fixture", "via" => "form"}
      )

    decision
  end

  defp rename!(subject, slot, name) do
    {:ok, decision} =
      Decision.new(
        kind: :rename,
        target: "ash",
        subject: subject,
        choice: :accept,
        params: %{slot: slot, name: name},
        id: "dec_rename_" <> name
      )

    decision
  end
end
