defmodule BubbleEx.Test.DecidedFixture do
  @moduledoc false

  # Owner decision sets over two synthetic exports (invented data), taken
  # through the whole pipeline: Findings.analyze -> Decision records ->
  # resolve/3 -> applicable/2 -> Target.Ash.map/3. Used by the Target.Ash
  # decision goldens (WTF-401, WTF-405, WTF-406), the diagnostic sweep and
  # scripts/ash_compile_check/render.exs.
  #
  # Cut 1 (`refine`, `derive`, `rename`, `combined`, over
  # test/support/samples/synthetic_findings_export.json) rejects the two
  # `search_index` hints, so its goldens show cut 1 alone. Cut 2 (over
  # test/support/samples/synthetic_decisions_cut2_export.json): `count`,
  # `text_ref` and `reverse` accept one transform's findings and reject
  # the hints; `indexes` decides nothing, so the hints apply by default;
  # `cut2` accepts every cut-2 finding and leaves the hints to apply.
  # Cut 3 (over the cut-1 export, hints rejected): `join` normalizes
  # Project's Tasks (a join of its own, order kept) and the two mirrored
  # lists Project's Viewers and User's Favorites (one shared join: Viewers
  # with `keep_order: false`, Favorites naming it `favorite_project`);
  # `membership` makes Workspace's Members a membership join (its rules
  # test it) shared with User's Workspaces; `cut3` is both.

  alias BubbleEx.{Decision, Findings, Index, Model}
  alias BubbleEx.Target.Ash

  @app "test/support/samples/synthetic_findings_export.json"
  @cut2_app "test/support/samples/synthetic_decisions_cut2_export.json"
  @now ~U[2026-09-26 00:00:00Z]

  @cut1 ~w(refine derive rename combined)a
  @cut2 ~w(count text_ref reverse indexes cut2)a
  @cut3 ~w(join membership cut3)a
  @sets @cut1 ++ @cut2 ++ @cut3

  @doc "The decision sets."
  def sets, do: @sets

  @doc "The cut-2 decision sets."
  def cut2_sets, do: @cut2

  @doc "The cut-3 decision sets."
  def cut3_sets, do: @cut3

  @doc "The app JSON (of a decision set: the cut-2 sets have their own app)."
  def app(set \\ :refine)
  def app(set) when set in @cut2, do: @cut2_app |> File.read!() |> Jason.decode!()

  # Cut 3: the cut-1 export with a Workspace rule testing the current
  # user's Workspaces (a list the sets normalize): "Listed", Current User's
  # Workspaces contains This Workspace, view all and search, and
  # auto-binding the Members (which the sets normalize: no longer
  # auto-bindable).
  def app(set) when set in @cut3 do
    rule = %{
      "display" => "Listed",
      "condition" => %{
        "type" => "CurrentUser",
        "next" => %{
          "name" => "workspaces_list_custom_workspace",
          "type" => "Message",
          "next" => %{
            "name" => "contains",
            "type" => "Message",
            "args" => %{"type" => "InjectedValue"}
          }
        }
      },
      "permissions" => %{
        "view_all" => true,
        "search_for" => true,
        "auto_binding" => true,
        "binding_fields" => ["members_list_user"]
      }
    }

    put_in(app(:refine), ["user_types", "workspace", "privacy_role", "listed_"], rule)
  end

  def app(_set), do: @app |> File.read!() |> Jason.decode!()

  @doc """
  `%{model, index, findings, records, applied, decisions_sha256}` for a
  decision set.
  """
  def build(set) when set in @sets or set == :locked do
    app = app(set)
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

  @cut2_transforms [:derive_count, :text_to_reference, :derive_reverse_relationship]

  @doc """
  An owner accepting every cut-2 finding of `findings` (derive_count,
  text_to_reference with a target type, derive_reverse_relationship) not
  decided in `records`, on top of `records` with the hint decisions
  dropped (the hints apply by default). Returns `{records, applied,
  decisions_sha256}`. For real-app checks (the private export); nothing
  here is committed.
  """
  def accept_cut2(findings, records, index),
    do: accept(findings, records, index, @cut2_transforms)

  @cut3_transforms @cut2_transforms ++ [:normalize_list_to_join, :membership_policy]

  @doc """
  `accept_cut2/3` with every cut-3 finding accepted too (WTF-406): lists of
  things normalized to joins (shared by mirrored lists) and membership
  joins. For real-app checks; nothing here is committed.
  """
  def accept_cut3(findings, records, index),
    do: accept(findings, records, index, @cut3_transforms)

  defp accept(findings, records, index, transforms) do
    hints = for f <- findings, f.category == :hint, into: MapSet.new(), do: f.id
    kept = Enum.reject(records, &MapSet.member?(hints, &1.basis.finding_id))
    decided = MapSet.new(kept, & &1.basis.finding_id)

    accepts =
      for f <- findings,
          f.proposal[:transform] in transforms,
          not MapSet.member?(decided, f.id),
          f.proposal[:transform] != :text_to_reference or f.proposal.target_type != nil do
        {:ok, decision} = Decision.for_finding(f, :accept)
        decision
      end

    records = kept ++ accepts
    {:ok, resolved} = Decision.resolve(records, findings, index: index, now: @now)
    {records, Decision.applicable(resolved, findings), Decision.decisions_sha256(records)}
  end

  defp records(set, findings) do
    hints =
      if set in [:indexes, :cut2],
        do: [],
        else: for(f <- findings, f.kind == :search_index, do: finding!(f, :reject))

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

  defp decided(:count, findings) do
    for {type, field} <- [
          {"board", "card_count_number"},
          {"board", "watcher_count_number"},
          {"card", "board_card_count_number"},
          {"card", "board_watcher_count_number"}
        ],
        do: findings |> find(:denormalized_field, type, field) |> finding!(:accept)
  end

  defp decided(:text_ref, findings) do
    [
      # written from Current User's unique id
      findings |> find(:id_in_text, "card", "assignee_id_text") |> finding!(:accept),
      # a list of texts compared with cards' unique ids
      findings |> find(:id_in_text, "card", "blocker_ids_list_text") |> finding!(:accept)
    ]
  end

  defp decided(:reverse, findings) do
    [
      findings
      |> find(:redundant_reverse_list, "board", "cards_list_custom_card")
      |> finding!(:accept)
    ]
  end

  defp decided(:indexes, _findings), do: []

  defp decided(:join, findings) do
    [
      findings
      |> find(:list_relationship, "project", "tasks_list_custom_task")
      |> finding!(:accept),
      findings
      |> find(:list_relationship, "project", "viewers_list_user")
      |> finding!(:modify, %{"keep_order" => false}),
      findings
      |> find(:list_relationship, "user", "favorites_list_custom_project")
      |> finding!(:modify, %{"join_name" => "favorite_project"})
    ]
  end

  defp decided(:membership, findings) do
    [
      findings
      |> find(:privacy_access_list, "workspace", "members_list_user")
      |> finding!(:accept),
      findings
      |> find(:list_relationship, "user", "workspaces_list_custom_workspace")
      |> finding!(:accept)
    ]
  end

  defp decided(:cut3, findings), do: decided(:join, findings) ++ decided(:membership, findings)

  defp decided(:cut2, findings),
    do: decided(:count, findings) ++ decided(:text_ref, findings) ++ decided(:reverse, findings)

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
