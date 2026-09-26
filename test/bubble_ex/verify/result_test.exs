defmodule BubbleEx.Verify.ResultTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Error}
  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Verify.{Check, Recording, Result, Scenario, Seed, Staleness}

  @dir "test/support/verify"
  @ran_at ~U[2026-10-02 09:15:00Z]
  @sha String.duplicate("a", 64)
  @diff [
    %{op: "field_visible", record: "task_w1", field: "notes_text", expected: false, actual: true}
  ]

  defp raw(name), do: @dir |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp golden(name) do
    {:ok, result} = name |> raw() |> Result.from_map()
    result
  end

  defp scenario_ref(id \\ "s1"),
    do: %{id: id, sha256: @sha, source_sha256: @sha, seed_sha256: @sha}

  # A minimal valid result of `check` with `attrs` merged in.
  defp attrs(check, attrs) do
    {:ok, {level, _}} = Check.fetch(check)

    behavioural =
      if level in [:l2, :l3],
        do: %{
          scenario: scenario_ref(),
          oracle: %{kind: :bubble, sha256: @sha, branch: "wtfreplay"}
        },
        else: %{}

    %{id: "r1", check: check, status: :pass, actor: "ci", ran_at: @ran_at}
    |> Map.merge(behavioural)
    |> Map.merge(Map.new(attrs))
  end

  defp build(check, attrs), do: Result.new(attrs(check, attrs))

  defp ok(check, attrs) do
    assert {:ok, result} = build(check, attrs)
    result
  end

  defp rejected(check, attrs, pattern) do
    assert {:error, %Error{kind: :invalid_input, message: message}} = build(check, attrs)
    assert message =~ pattern
  end

  defp finding_ref,
    do: %{
      key: "finding:privacy_access_list:9f2c1b7d0e4a5c63",
      kind: :finding,
      proposal_sha256: @sha
    }

  defp parity_ref(key \\ "parity_exception:0123456789abcdef"),
    do: %{key: key, kind: :parity_exception, proposal_sha256: nil}

  defp waiver(kind, extra \\ %{}),
    do:
      Map.merge(
        %{actor: %{kind: kind, id: "#{kind}:1"}, reason: "Known difference.", expires_at: nil},
        extra
      )

  describe "level and class come from the check" do
    test "they are filled in and a mismatch is rejected" do
      result = ok("privacy_read", [])
      assert {result.level, result.class} == {:l2, :privacy}

      raw = Map.put(raw("result.pass.json"), "class", "behavior")
      assert {:error, %Error{message: message}} = Result.from_map(raw)
      assert message =~ "class does not match"

      raw = Map.put(raw("result.pass.json"), "level", "L0")

      assert {:error, %Error{message: "result level does not match its check"}} =
               Result.from_map(raw)
    end

    test "an unknown check is rejected" do
      assert {:error, %Error{kind: :invalid_input}} =
               Result.new(%{attrs("lint", []) | check: "vibes"})
    end
  end

  describe "status rules" do
    test "pass has no diff, decision or waiver" do
      rejected("lint", [diff: @diff], "no diff")
      rejected("lint", [decision: finding_ref()], "no decision")
      rejected("acceptance", [waiver: waiver(:owner)], "no waiver")
    end

    test "fail may carry a diff but no acceptance" do
      assert %Result{status: :fail} = ok("lint", status: :fail, diff: @diff)
      rejected("row_counts", [status: :fail, diff: @diff, decision: parity_ref()], "no decision")
    end

    test "decided_difference cites a finding decision with its proposal hash" do
      assert %Result{} =
               ok("privacy_read",
                 status: :decided_difference,
                 diff: @diff,
                 decision: finding_ref()
               )

      rejected("privacy_read", [status: :decided_difference, diff: @diff], "finding decision")

      rejected(
        "privacy_read",
        [status: :decided_difference, diff: @diff, decision: parity_ref()],
        "finding decision"
      )

      rejected(
        "privacy_read",
        [status: :decided_difference, decision: finding_ref()],
        "needs the diff"
      )

      raw = put_in(raw("result.decided_difference.json"), ["decision", "proposal_sha256"], nil)
      assert {:error, %Error{message: message}} = Result.from_map(raw)
      assert message =~ "proposal_sha256"
    end

    test "structural and gate checks accept no difference at all" do
      for check <- ["lint", "policy_coverage", "cutover_gate"] do
        rejected(
          check,
          [status: :decided_difference, diff: @diff, decision: finding_ref()],
          "cannot be"
        )

        rejected(check, [status: :waived, diff: @diff, waiver: waiver(:owner)], "cannot be")
        rejected(check, [status: :waived, diff: @diff, decision: parity_ref()], "cannot be")
        rejected(check, [status: :quarantined, diff: @diff, waiver: waiver(:agent)], "cannot be")
      end
    end

    test "privacy, data and auth differences are waived only by a parity exception" do
      for check <- ["privacy_read", "privacy_spot_check", "row_hashes", "files", "auth_users"] do
        assert %Result{status: :waived} =
                 ok(check, status: :waived, diff: @diff, decision: parity_ref())

        for actor <- [:agent, :reviewer, :owner] do
          rejected(
            check,
            [status: :waived, diff: @diff, waiver: waiver(actor)],
            "parity exception"
          )
        end

        rejected(check, [status: :waived, diff: @diff], "parity exception")

        rejected(
          check,
          [
            status: :quarantined,
            diff: @diff,
            waiver: waiver(:agent, %{expires_at: ~U[2026-10-03 00:00:00Z]})
          ],
          "parity exception"
        )
      end
    end

    test "a parity exception is the waiver; a finding decision never waives" do
      rejected(
        "privacy_read",
        [status: :waived, diff: @diff, decision: parity_ref(), waiver: waiver(:owner)],
        "is the waiver"
      )

      rejected(
        "dom_text",
        [status: :waived, diff: @diff, decision: finding_ref()],
        "decided_difference"
      )
    end

    test "behaviour: reviewers and owners waive, agents only quarantine" do
      assert %Result{} = ok("dom_text", status: :waived, diff: @diff, waiver: waiver(:reviewer))
      assert %Result{} = ok("journey", status: :waived, diff: @diff, waiver: waiver(:owner))
      assert %Result{} = ok("api_workflow", status: :waived, diff: @diff, decision: parity_ref())

      rejected(
        "dom_text",
        [status: :waived, diff: @diff, waiver: waiver(:agent)],
        "agent may not waive"
      )

      week = waiver(:agent, %{expires_at: DateTime.add(@ran_at, 7 * 86_400, :second)})

      assert %Result{status: :quarantined} =
               ok("workflow_side_effects", status: :quarantined, diff: @diff, waiver: week)
    end

    test "a quarantine expires after ran_at and within 7 days" do
      too_long = waiver(:agent, %{expires_at: DateTime.add(@ran_at, 7 * 86_400 + 1, :second)})
      rejected("dom_text", [status: :quarantined, diff: @diff, waiver: too_long], "7 days")

      past = waiver(:agent, %{expires_at: @ran_at})
      rejected("dom_text", [status: :quarantined, diff: @diff, waiver: past], "7 days")

      rejected(
        "dom_text",
        [status: :quarantined, diff: @diff, waiver: waiver(:agent)],
        "expires_at"
      )

      rejected("dom_text", [status: :quarantined, diff: @diff], "needs a waiver")

      rejected(
        "acceptance",
        [
          status: :quarantined,
          diff: @diff,
          waiver: waiver(:agent, %{expires_at: ~U[2026-10-03 00:00:00Z]})
        ],
        "cannot be"
      )
    end

    test "attested criteria may be waived by an agent; traceability only by a finding decision" do
      assert %Result{} = ok("acceptance", status: :waived, diff: @diff, waiver: waiver(:agent))

      assert %Result{} =
               ok("traceability.rendered",
                 status: :decided_difference,
                 diff: @diff,
                 decision: finding_ref()
               )

      rejected(
        "traceability.rendered",
        [status: :waived, diff: @diff, waiver: waiver(:owner)],
        "cannot be"
      )

      rejected(
        "traceability.rendered",
        [status: :waived, diff: @diff, decision: parity_ref()],
        "cannot be"
      )
    end

    test "a reviewer's visual waiver needs an attestation" do
      rejected(
        "visual_parity",
        [status: :waived, diff: @diff, waiver: waiver(:reviewer)],
        "attestation"
      )

      evidence = [
        %{kind: :attestation, ref: ".wtf/verification/attestations/visual.json", sha256: nil}
      ]

      assert %Result{} =
               ok("visual_parity",
                 status: :waived,
                 diff: @diff,
                 waiver: waiver(:reviewer),
                 evidence: evidence
               )

      assert %Result{} = ok("visual_parity", status: :waived, diff: @diff, waiver: waiver(:owner))
    end

    test "stale needs reasons; only stale has them" do
      assert %Result{} = ok("lint", status: :stale, stale_reasons: [:source_changed])
      rejected("lint", [status: :stale], "stale_reasons")
      rejected("lint", [stale_reasons: [:source_changed]], "only stale")

      raw = Map.put(raw("result.stale.json"), "stale_reasons", ["vibes"])
      assert {:error, %Error{kind: :invalid_input}} = Result.from_map(raw)
    end

    test "skipped and error need a reason" do
      rejected("privacy_read", [status: :skipped], "reason")
      assert %Result{} = ok("privacy_read", status: :skipped, reason: "replay-unsafe: external")
      assert %Result{} = ok("compiles", status: :error, reason: "harness crashed")
    end

    test "L2 and L3 results need their scenario and oracle" do
      rejected("privacy_read", [scenario: nil], "scenario and oracle")
      rejected("journey", [oracle: nil], "scenario and oracle")

      assert %Result{} =
               ok("privacy_read", status: :error, reason: "boom", scenario: nil, oracle: nil)
    end

    test "a Bubble oracle is never live" do
      rejected(
        "privacy_read",
        [oracle: %{kind: :bubble, sha256: @sha, branch: "live"}],
        "never live"
      )

      rejected(
        "privacy_read",
        [oracle: %{kind: :model, sha256: @sha, branch: "wtfreplay"}],
        "no branch"
      )
    end

    test "evidence refs stay inside the repository and carry no URLs" do
      for ref <- [
            "/home/me/rec.json",
            "../secret.json",
            "a/../../b",
            "https://x.example/r?token=1",
            "C:\\rec.json",
            "~/r"
          ] do
        rejected("lint", [evidence: [%{kind: :log, ref: ref, sha256: nil}]], "evidence ref")
      end

      assert %Result{} =
               ok("lint",
                 evidence: [%{kind: :artifact, ref: "artifact:ci-123/lint.txt", sha256: nil}]
               )
    end

    test "diff entries use the typed ops" do
      rejected("lint", [status: :fail, diff: [%{op: "vibes"}]], "unknown diff op")

      rejected(
        "lint",
        [status: :fail, diff: [%{op: "lint", note: "x"}]],
        "unknown diff entry members"
      )
    end
  end

  describe "reading results" do
    test "passing?/1 follows the status table" do
      assert Result.passing?(golden("result.pass.json"))
      assert Result.passing?(golden("result.decided_difference.json"))
      assert Result.passing?(golden("result.waived.json"))
      refute Result.passing?(golden("result.quarantined.json"))
      refute Result.passing?(golden("result.stale.json"))
      refute Result.passing?(ok("privacy_read", status: :skipped, reason: "unsafe"))
      assert Result.passing?(ok("dom_text", status: :skipped, reason: "unsafe"))
      refute Result.passing?(ok("lint", status: :fail))
    end

    test "an L2 result on the model oracle is never Bubble-verified" do
      bubble = ok("privacy_read", [])
      model = ok("privacy_read", oracle: %{kind: :model, sha256: @sha, branch: nil})

      assert Result.bubble_verified?(bubble)
      assert Result.passing?(model)
      refute Result.bubble_verified?(model)
      assert Result.bubble_verified?(ok("lint", []))
    end

    test "mark_stale/2 keeps the evidence, accumulates reasons and leaves errors alone" do
      result = golden("result.decided_difference.json")
      stale = Result.mark_stale(result, [:source_changed])

      assert stale.status == :stale
      assert stale.decision == result.decision
      assert {:ok, ^stale} = stale |> Result.to_json() |> Result.from_json()

      assert Result.mark_stale(stale, [:decisions_changed]).stale_reasons == [
               :decisions_changed,
               :source_changed
             ]

      assert Result.mark_stale(result, []) == result

      error = ok("lint", status: :error, reason: "boom")
      assert Result.mark_stale(error, [:source_changed]) == error
      assert_raise ArgumentError, fn -> Result.mark_stale(result, [:vibes]) end
    end
  end

  describe "staleness" do
    setup do
      {:ok, seed} = raw("seed.json") |> Seed.from_map()
      {:ok, scenario} = raw("scenario.privacy_read.json") |> Scenario.from_map()
      {:ok, recording} = raw("recording.bubble.json") |> Recording.from_map()
      result = golden("result.pass.json")

      current = %{
        scenario: scenario,
        seed: seed,
        recording: recording,
        source_sha256: result.basis.source_sha256,
        decisions_sha256: result.basis.decisions_sha256
      }

      %{result: result, current: current}
    end

    test "a result is current against what it pinned", %{result: result, current: current} do
      assert Staleness.result(result, current) == []
      assert Staleness.refresh(result, current) == result
    end

    test "a changed decision set or source makes it stale", %{result: result, current: current} do
      current = %{current | decisions_sha256: String.duplicate("0", 64)}
      assert Staleness.result(result, current) == [:decisions_changed]

      assert %Result{status: :stale, stale_reasons: [:decisions_changed]} =
               Staleness.refresh(result, current)

      assert Staleness.result(result, %{source_sha256: String.duplicate("0", 64)}) == [
               :source_changed
             ]
    end

    test "a re-recorded or changed scenario makes it stale", %{result: result, current: current} do
      recording = %{current.recording | runs: 3}
      assert Staleness.result(result, %{current | recording: recording}) == [:recording_changed]

      scenario = %{current.scenario | persona: "w1_member"}
      assert :scenario_changed in Staleness.result(result, %{current | scenario: scenario})

      seed = %{current.seed | records: tl(current.seed.records)}
      assert :seed_changed in Staleness.result(result, %{current | seed: seed})

      incomplete = %{current.recording | complete: false}
      assert :recording_incomplete in Staleness.result(result, %{current | recording: incomplete})
    end

    test "unknown current hashes are not compared", %{result: result} do
      assert Staleness.result(result, %{}) == []
    end
  end

  describe "link_decision/2" do
    defp parity(author, opts \\ []) do
      {:ok, d} =
        Decision.new(%{
          kind: :parity_exception,
          subject: Keyword.get(opts, :subject, %{type: "custom.task"}),
          choice: Keyword.get(opts, :choice, :accept),
          params: %{
            scope: Keyword.get(opts, :scope, "privacy_read.custom.task.w2_member"),
            bubble_behavior: "Bubble shows the notes field to members of other workspaces.",
            chosen_behavior: "Notes stay private to the workspace."
          },
          author: author,
          rationale: "Bubble's behaviour is a leak we do not reproduce."
        })

      d
    end

    defp resolved(entries), do: %Resolved{entries: entries}
    defp entry(d, state \\ :active), do: %{decision: d, state: state, reasons: []}

    defp waived_with(%Decision{key: key}) do
      golden("result.waived.json") |> Map.put(:decision, parity_ref(key))
    end

    defp finding_decision(choice \\ :accept) do
      %Decision{
        key: finding_ref().key,
        kind: :finding,
        revision: 1,
        subject: %{type: "custom.task"},
        choice: choice,
        basis: %{
          finding_id: "privacy_access_list:9f2c1b7d0e4a5c63",
          proposal_sha256: @sha,
          basis_sha256: @sha
        }
      }
    end

    test "an owner's active parity exception excuses the result" do
      d = parity(%{kind: :owner, id: "user:1", via: :form})
      result = waived_with(d)
      assert {:ok, ^result} = Result.link_decision(result, resolved([entry(d)]))
    end

    test "an agent's parity exception never excuses a privacy difference" do
      for author <- [
            %{kind: :agent, id: "agent:1", via: :chat},
            %{kind: :wtf_staff, id: "s", via: :cli},
            nil
          ] do
        d = parity(author)

        assert {:error, %Error{kind: :invalid_input, message: message}} =
                 Result.link_decision(waived_with(d), resolved([entry(d)]))

        assert message =~ "owner"
      end
    end

    test "the exception's scope and subject must cover the result" do
      owner = %{kind: :owner, id: "user:1", via: :form}

      d = parity(owner, scope: "privacy_read.custom.task.w1_member")

      assert {:error, %Error{message: m}} =
               Result.link_decision(waived_with(d), resolved([entry(d)]))

      assert m =~ "scope"

      d = parity(owner, subject: %{type: "custom.workspace"})

      assert {:error, %Error{message: m}} =
               Result.link_decision(waived_with(d), resolved([entry(d)]))

      assert m =~ "subject"
    end

    test "an expired or withdrawn exception turns the result stale" do
      d = parity(%{kind: :owner, id: "user:1", via: :form})

      assert {:ok, %Result{status: :stale, stale_reasons: [:decision_expired]}} =
               Result.link_decision(waived_with(d), resolved([entry(d, :expired)]))

      {:ok, withdrawn} = Decision.withdraw(d, author: %{kind: :owner, id: "user:1", via: :form})

      assert {:ok, %Result{status: :stale, stale_reasons: [:decision_withdrawn]}} =
               Result.link_decision(
                 waived_with(d),
                 resolved([entry(d, :superseded), entry(withdrawn, :withdrawn)])
               )
    end

    test "a missing decision is an error" do
      d = parity(%{kind: :owner, id: "user:1", via: :form})
      assert {:error, %Error{message: m}} = Result.link_decision(waived_with(d), resolved([]))
      assert m =~ "does not exist"
    end

    test "a finding decision holds while its proposal hash matches" do
      result = golden("result.decided_difference.json")
      assert {:ok, ^result} = Result.link_decision(result, resolved([entry(finding_decision())]))

      changed = %{
        finding_decision()
        | basis: %{finding_decision().basis | proposal_sha256: String.duplicate("c", 64)}
      }

      assert {:ok, %Result{status: :stale, stale_reasons: [:decision_changed]}} =
               Result.link_decision(result, resolved([entry(changed)]))

      assert {:ok, %Result{status: :stale, stale_reasons: [:decision_stale]}} =
               Result.link_decision(result, resolved([entry(finding_decision(), :stale)]))

      assert {:ok, %Result{status: :stale, stale_reasons: [:decision_orphaned]}} =
               Result.link_decision(result, resolved([entry(finding_decision(), :orphaned)]))
    end

    test "a rejected finding explains nothing" do
      result = golden("result.decided_difference.json")

      assert {:error, %Error{message: m}} =
               Result.link_decision(result, resolved([entry(finding_decision(:reject))]))

      assert m =~ "accepted or modified"
    end

    test "a result without a decision is unchanged" do
      result = golden("result.pass.json")
      assert {:ok, ^result} = Result.link_decision(result, resolved([]))
    end
  end
end
