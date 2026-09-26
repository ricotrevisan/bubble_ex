defmodule BubbleEx.Target.Ash.DecisionsCut2Test do
  # BubbleEx.Target.Ash applying owner decisions, cut 2 (WTF-405, WTF-352
  # §4.2): derive_count, text_to_reference, derive_reverse_relationship and
  # add_indexes (hints applied by default), over the synthetic cut-2 export
  # (test/support/samples/synthetic_decisions_cut2_export.json, invented
  # data) taken through Findings -> Decision -> resolve -> applicable
  # (BubbleEx.Test.DecidedFixture). The per-set source goldens are checked
  # by BubbleEx.Target.Ash.DecisionsTest; the combined cut-2 Project and its
  # privacy: :unverified source here.
  #
  # Regenerate the goldens after an intended change with
  #
  #     BUBBLE_EX_UPDATE_GOLDEN=1 mix test test/bubble_ex/target/ash/decisions_cut2_test.exs
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Decision, Finding}
  alias BubbleEx.Decision.Applied
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.{Aggregate, Calculation, Index, Project, Relationship, Source}
  alias BubbleEx.Test.DecidedFixture

  @golden "test/support/target/ash/golden/decisions"
  @sha String.duplicate("a", 64)
  @now ~U[2026-09-26 00:00:00Z]

  defp check_golden(path, actual) do
    if System.get_env("BUBBLE_EX_UPDATE_GOLDEN"), do: File.write!(path, actual)
    assert File.exists?(path), "missing golden #{path}; set BUBBLE_EX_UPDATE_GOLDEN=1"
    expected = File.read!(path)

    assert actual == expected or
             (String.ends_with?(path, ".ex.txt") and
                Version.compare(System.version(), "1.19.0") != :lt and
                reformat(actual) == reformat(expected))
  end

  defp reformat(source), do: source |> Code.format_string!() |> IO.iodata_to_binary()

  defp project!(set, opts \\ []) do
    {:ok, project} = DecidedFixture.project(set, opts)
    project
  end

  defp resource(project, type), do: Enum.find(project.resources, &(&1.source.type == type))

  defp attribute(project, type, field),
    do: Enum.find(resource(project, type).attributes, &(&1.source[:field] == field))

  defp derived(project, type, field) do
    r = resource(project, type)

    Enum.find(r.calculations ++ r.aggregates, &(&1.source[:field] == field)) ||
      Enum.find(r.relationships, &(&1.source[:field] == field and &1.kind == :has_many))
  end

  defp map(model, applied, opts \\ []),
    do: Ash.map(model, applied, Keyword.put_new(opts, :decisions_sha256, @sha))

  defp message({:error, %BubbleEx.Error{kind: :invalid_input, message: message}}), do: message

  defp model, do: DecidedFixture.build(:indexes).model

  # The applicable entries of `choices` (`{kind, subject, choice, params}`)
  # over the cut-2 export, with the hints rejected unless listed.
  defp applicable(choices) do
    %{model: model, index: index, findings: findings} = DecidedFixture.build(:indexes)

    records =
      for {kind, subject, choice, params} <- choices do
        finding = Enum.find(findings, &(&1.kind == kind and &1.subject == subject))
        assert finding, "no #{kind} finding on #{inspect(subject)}"
        {:ok, decision} = Decision.for_finding(finding, choice, params)
        decision
      end

    decided = MapSet.new(records, & &1.basis.finding_id)

    hints =
      for f <- findings, f.kind == :search_index, not MapSet.member?(decided, f.id) do
        {:ok, reject} = Decision.for_finding(f, :reject)
        reject
      end

    {:ok, resolved} = Decision.resolve(records ++ hints, findings, index: index, now: @now)
    {model, Decision.applicable(resolved, findings), findings}
  end

  # A hand-built applied finding, consistent with itself (IDs and hashes).
  defp applied_finding(kind, subject, proposal) do
    id = Finding.id(kind, subject)
    hashes = %{proposal_sha256: @sha, basis_sha256: String.duplicate("b", 64)}

    struct!(
      Applied,
      Map.merge(hashes, %{
        key: "finding:" <> id,
        kind: :finding,
        decision_id: "dec_x",
        finding_id: id,
        transform: proposal.transform,
        subject: subject,
        proposal: proposal,
        basis: hashes
      })
    )
  end

  defp rename(subject, slot, name) do
    {:ok, decision} =
      Decision.new(
        kind: :rename,
        target: "ash",
        subject: subject,
        choice: :accept,
        params: %{slot: slot, name: name}
      )

    %Applied{
      key: decision.key,
      kind: :rename,
      transform: :rename,
      subject: subject,
      target: "ash",
      params: decision.params
    }
  end

  describe "goldens" do
    test "cut2 matches its golden Project" do
      json =
        project!(:cut2)
        |> Project.to_map()
        |> CanonicalJson.ordered()
        |> Jason.encode!(pretty: true)

      check_golden(Path.join(@golden, "cut2.project.json"), json <> "\n")
    end

    test "cut2 renders its golden source (privacy: :unverified)" do
      {:ok, source} = :cut2 |> project!(privacy: :unverified) |> Source.render()
      check_golden(Path.join(@golden, "cut2.unverified.ex.txt"), source)
    end
  end

  describe "derive_count" do
    test "a count of a stored list is the list's length, with the locked name" do
      {:ok, faithful} = Ash.map(model())
      project = project!(:count)

      for {type, field} <- [
            {"board", "card_count_number"},
            {"board", "watcher_count_number"},
            {"card", "board_card_count_number"},
            {"card", "board_watcher_count_number"}
          ] do
        refute attribute(project, type, field)

        assert %Calculation{kind: :derived, type: :integer, public?: true} =
                 calc = derived(project, type, field)

        assert calc.name == attribute(faithful, type, field).name
      end

      assert derived(project, "board", "watcher_count_number").expr.expr ==
               {:call, "length", [{:op, "||", {:ref, [], "watchers"}, {:value, []}}]}

      assert derived(project, "card", "board_watcher_count_number").expr.expr ==
               {:call, "length", [{:op, "||", {:ref, ["board"], "watchers"}, {:value, []}}]}

      {:ok, source} = Source.render(project)
      assert source =~ "expr(length(board.watchers || []))"
      assert Project.summary(project)["applied"] == %{"derive_count" => 4}
    end

    test "a count of a list derived as a has_many is an aggregate over it" do
      project = project!(:cut2)

      assert %Aggregate{kind: :count, path: ["cards"], public?: true, authorize?: false} =
               derived(project, "board", "card_count_number")

      assert %Aggregate{path: ["board", "cards"]} =
               derived(project, "card", "board_card_count_number")

      # a list still stored keeps its length calculation
      assert %Calculation{} = derived(project, "board", "watcher_count_number")
      assert Project.summary(project)["derived_aggregates"] == 2

      {:ok, source} = Source.render(project)
      assert source =~ "count :card_count, [:cards]"
      assert source =~ "count :board_card_count, [:board, :cards]"
    end

    test "with privacy: :unverified a count reads through private twins and has a field policy" do
      project = project!(:cut2, privacy: :unverified)
      board = resource(project, "board")
      card = resource(project, "card")

      assert %Aggregate{path: ["cards_for_privacy"]} =
               derived(project, "board", "card_count_number")

      # the ungated `board` relationship gets a twin too: public
      # relationships are unsortable, a derived count must sort
      assert %Aggregate{path: ["board_for_privacy", "cards_for_privacy"]} =
               derived(project, "card", "board_card_count_number")

      assert Enum.any?(card.privacy_relationships, &(&1.name == "board_for_privacy"))
      assert Enum.find(card.relationships, &(&1.name == "board")).gate == nil

      assert derived(project, "card", "board_watcher_count_number").expr.expr ==
               {:call, "length",
                [{:op, "||", {:ref, ["board_for_privacy"], "watchers"}, {:value, []}}]}

      assert Enum.any?(board.field_policies, &("card_count" in &1.fields))
      assert Enum.any?(board.field_policies, &("watcher_count" in &1.fields))
      for action <- board.extra_actions, do: refute("card_count" in action.accept)
    end

    test "is a derived field: a derived_from_related source cannot be a count" do
      {model, applied, _} =
        applicable([
          {:denormalized_field, %{type: "board", field: "card_count_number"}, :accept, %{}}
        ])

      derive =
        applied_finding(:denormalized_field, %{type: "card", field: "points_number"}, %{
          transform: :derive_from_related,
          field: "field:card/points_number",
          derivation: %{
            via: ["field:card/board_custom_board"],
            source_field: "field:board/card_count_number"
          }
        })

      assert map(model, applied ++ [derive]) |> message() =~ "source is derived too"
    end

    test "one transform per field: a count is not also refined" do
      subject = %{type: "board", field: "card_count_number"}

      {model, applied, _} =
        applicable([
          {:denormalized_field, subject, :accept, %{}},
          {:number_type, subject, :accept, %{}}
        ])

      assert map(model, applied) |> message() =~ "two decisions transform one field"
    end

    test "a stale count (not a list, not a number) is an error" do
      subject = %{type: "board", field: "card_count_number"}

      not_list =
        applied_finding(:denormalized_field, subject, %{
          transform: :derive_count,
          field: "field:board/card_count_number",
          derivation: %{via: [], source_field: "field:board/name_text"}
        })

      assert map(model(), [not_list]) |> message() =~ "not a list"

      not_number =
        applied_finding(:denormalized_field, %{type: "board", field: "name_text"}, %{
          transform: :derive_count,
          field: "field:board/name_text",
          derivation: %{via: [], source_field: "field:board/watchers_list_user"}
        })

      assert map(model(), [not_number]) |> message() =~ "needs a number field"
    end
  end

  describe "text_to_reference" do
    test "one ID becomes a belongs_to (no foreign key); the attribute keeps its name" do
      {:ok, faithful} = Ash.map(model())
      project = project!(:text_ref)
      before = attribute(faithful, "card", "assignee_id_text")
      after_ = attribute(project, "card", "assignee_id_text")

      assert after_.name == before.name
      assert after_.type == :string and after_.column == nil
      assert after_.references == %{target: "user", cardinality: :one}

      rel =
        Enum.find(
          resource(project, "card").relationships,
          &(&1.source.field == "assignee_id_text")
        )

      assert %Relationship{
               kind: :belongs_to,
               name: "assignee",
               source_attribute: "assignee_id",
               destination: "User",
               db_reference: :ignore
             } = rel

      assert get_in(project.names, ["resources", "card", "relationships", "assignee_id_text"]) ==
               "assignee"

      {:ok, source} = Source.render(project)
      assert source =~ "reference :assignee, ignore?: true"
    end

    test "a list of IDs keeps its array, marked as references" do
      project = project!(:text_ref)
      list = attribute(project, "card", "blocker_ids_list_text")
      assert list.type == {:array, :string}
      assert list.references == %{target: "card", cardinality: :many}

      refute Enum.any?(
               resource(project, "card").relationships,
               &(&1.source.field == "blocker_ids_list_text")
             )
    end

    test "its relationship can be renamed; a missing target type is an error" do
      {model, applied, _} =
        applicable([{:id_in_text, %{type: "card", field: "assignee_id_text"}, :accept, %{}}])

      renamed = rename(%{type: "card", field: "assignee_id_text"}, "relationship", "owner")
      {:ok, project} = map(model, applied ++ [renamed])
      assert Enum.any?(resource(project, "card").relationships, &(&1.name == "owner"))

      untyped =
        applied_finding(:id_in_text, %{type: "card", field: "status_text"}, %{
          transform: :text_to_reference,
          field: "field:card/status_text",
          target_type: nil,
          cardinality: :one
        })

      assert map(model, [untyped]) |> message() =~ "modify target_type"

      not_text =
        applied_finding(:id_in_text, %{type: "card", field: "points_number"}, %{
          transform: :text_to_reference,
          field: "field:card/points_number",
          target_type: "data_type:user",
          cardinality: :one
        })

      assert map(model, [not_text]) |> message() =~ "needs a text field"
    end
  end

  describe "derive_reverse_relationship" do
    test "the list becomes a has_many from the other side's reference" do
      {:ok, faithful} = Ash.map(model())
      project = project!(:reverse)
      refute attribute(project, "board", "cards_list_custom_card")

      assert %Relationship{
               kind: :has_many,
               name: name,
               destination: "Card",
               source_attribute: "id",
               destination_attribute: "board_id"
             } = derived(project, "board", "cards_list_custom_card")

      assert name == attribute(faithful, "board", "cards_list_custom_card").name

      {:ok, source} = Source.render(project)
      assert source =~ "has_many :cards, MyApp.Card do"
      refute source =~ "reference :cards"
      assert Project.summary(project)["relationships"]["has_many"] == 1
    end

    test "the applied record lists the reads to rewrite" do
      project = project!(:reverse)
      [record] = Enum.filter(project.applied, &(&1.transform == :derive_reverse_relationship))

      assert record.rewrite_reads == [
               "action:aCountCards",
               "action:aCreateCard",
               "element:eCardCount",
               "element:eHolding",
               "privacy_rule:board/busy_"
             ]

      assert Enum.all?(project.applied -- [record], &(&1.rewrite_reads == []))
    end

    test "with privacy: :unverified it is gated like the list, and rules test it with exists" do
      project = project!(:reverse, privacy: :unverified)
      board = resource(project, "board")
      cards = Enum.find(board.relationships, &(&1.name == "cards"))

      # the list was visible to the Busy and Watcher rules only
      assert cards.gate == {:visible_if, ["privacy_rule_busy", "privacy_rule_watcher"]}
      assert Map.has_key?(board.privacy.relationship_checks, "cards")
      refute Enum.any?(board.field_policies, &("cards" in &1.fields))

      assert %Relationship{kind: :has_many, public?: false, gate: nil} =
               Enum.find(board.privacy_relationships, &(&1.name == "cards_for_privacy"))

      busy = Enum.find(board.calculations, &(&1.name == "privacy_rule_busy"))

      assert busy.expr.expr ==
               {:call, "exists", [{:ref, [], "cards_for_privacy"}, {:value, true}]}

      refute Enum.any?(project.diagnostics, &(&1.code == :ash_expr_unmapped_reference))
    end

    test "a stale proposal (the reference does not point back) is an error" do
      bad =
        applied_finding(
          :redundant_reverse_list,
          %{type: "board", field: "cards_list_custom_card"},
          %{
            transform: :derive_reverse_relationship,
            drop_field: "field:board/cards_list_custom_card",
            relationship: %{
              source_type: "data_type:card",
              via: "field:card/assignee_id_text",
              cardinality: :many
            }
          }
        )

      assert map(model(), [bad]) |> message() =~ "points back"
    end

    test "the list cannot be renamed as an attribute" do
      {model, applied, _} =
        applicable([
          {:redundant_reverse_list, %{type: "board", field: "cards_list_custom_card"}, :accept,
           %{}}
        ])

      renamed = rename(%{type: "board", field: "cards_list_custom_card"}, "attribute", "items")
      assert map(model, applied ++ [renamed]) |> message() =~ "has_many"
    end
  end

  describe "add_indexes" do
    test "access patterns map to btree, GIN, trigram and full-text indexes" do
      project = project!(:indexes)
      card = resource(project, "card")

      assert [
               %Index{method: :btree, columns: ["points"], using: nil},
               %Index{method: :btree, columns: ["status", "title"]},
               %Index{method: :gin, columns: ["tags"], using: "gin"},
               %Index{method: :full_text, columns: ["title"], using: "gin"} = fts,
               %Index{method: :trigram, columns: ["title"], fields: [~s("title" gin_trgm_ops)]}
             ] = card.indexes

      assert fts.expression == ~s[to_tsvector('simple'::regconfig, coalesce("title", ''))]
      assert project.extensions == ["pg_trgm"]

      assert Enum.all?(project.resources, fn r ->
               Enum.all?(r.indexes, &(byte_size(&1.name) <= 63))
             end)

      assert Project.summary(project)["indexes"] == %{
               "btree" => 3,
               "full_text" => 1,
               "gin" => 2,
               "trigram" => 1
             }

      {:ok, source} = Source.render(project)
      assert source =~ ~s(index [:status, :title], name: "card_status_title_index")
      assert source =~ ~s(def installed_extensions, do: ["pg_trgm"])
    end

    test "geographic access and derived fields stay deferred with a warning" do
      project = project!(:cut2)

      # the board's hint: a range on the derived count, membership in the
      # derived list, a geographic search
      [deferred] = project.deferred
      assert deferred.subject == %{type: "board"} and deferred.indexes == [0, 1, 2]
      refute Enum.any?(project.applied, &(&1.key == deferred.key))
      assert resource(project, "board").indexes == []

      [warning] = for d <- project.diagnostics, d.code == :ash_decision_deferred, do: d
      assert warning.severity == :warning
      assert Enum.map(warning.details.indexes, & &1.index) == [0, 1, 2]
      reasons = Enum.map(warning.details.indexes, & &1.reason)
      assert Enum.count(reasons, &(&1 =~ "derived by a decision")) == 2
      assert Enum.any?(reasons, &(&1 =~ "PostGIS"))

      # with nothing derived, the board's range and membership indexes apply
      board = resource(project!(:indexes), "board")
      assert Enum.map(board.indexes, & &1.method) == [:btree, :gin]
    end

    test "modify drop leaves indexes out; an index on a missing field is stale" do
      {model, applied, _} =
        applicable([{:search_index, %{type: "card"}, :modify, %{"drop" => [0, 4]}}])

      {:ok, project} = map(model, applied)

      assert Enum.map(resource(project, "card").indexes, & &1.method) == [
               :btree,
               :gin,
               :full_text
             ]

      assert project.extensions == []

      stale =
        applied_finding(:search_index, %{type: "card"}, %{
          transform: :add_indexes,
          type: "data_type:card",
          indexes: [%{columns: [%{field: "field:board/name_text", access: :equality}]}]
        })

      assert map(model, [stale]) |> message() =~ "stale"
    end
  end

  describe "the whole cut" do
    test "every cut-2 transform applies together, deterministically and stably" do
      %{model: model, applied: applied, decisions_sha256: sha} = DecidedFixture.build(:cut2)
      project = project!(:cut2)

      assert Project.summary(project)["applied"] == %{
               "add_indexes" => 1,
               "derive_count" => 4,
               "derive_reverse_relationship" => 1,
               "text_to_reference" => 2
             }

      assert Enum.count(applied, & &1.automatic) == 2
      assert Project.to_json(project!(:cut2)) == Project.to_json(project)

      names = project.names |> Jason.encode!() |> Jason.decode!()
      {:ok, again} = Ash.map(model, applied, names: names, decisions_sha256: sha)
      assert Project.to_json(again) == Project.to_json(project)

      for privacy <- [:omit, :unverified] do
        {:ok, project} = DecidedFixture.project(:cut2, privacy: privacy)
        assert {:ok, _} = Source.render(project)
      end
    end
  end
end
