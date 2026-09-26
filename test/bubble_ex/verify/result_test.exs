defmodule BubbleEx.Verify.ResultTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Error}
  alias BubbleEx.Decision.Resolved
  alias BubbleEx.Verify.{Check, Recording, Result, Scenario, Seed, Staleness}

  @dir "test/support/verify"
  @ran_at ~U[2026-10-02 09:15:00Z]
  @now ~U[2026-10-02 10:00:00Z]
  @sha String.duplicate("a", 64)
  @diff [
    %{op: "field_visible", record: "task_w1", field: "notes_text", expected: false, actual: true}
  ]
  @owner %{kind: :owner, id: "user:1", via: :form}
  @agent %{kind: :agent, id: "agent:1", via: :chat}

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

  defp quarantine(extra \\ %{}),
    do: waiver(:agent, Map.merge(%{since: @ran_at, expires_at: ~U[2026-10-03 00:00:00Z]}, extra))

  defp resolved(entries), do: %Resolved{entries: entries}
  defp entry(d, state \\ :active), do: %{decision: d, state: state, reasons: []}

  defp evaluate(r, entries, opts \\ []),
    do: Result.evaluate(r, resolved(entries), [now: @now] ++ opts)

  defp parity(author, opts \\ []) do
    scenario_sha = golden("result.waived.json").scenario.sha256

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
        basis: Keyword.get(opts, :basis, %{scenario_sha256: scenario_sha}),
        author: author,
        rationale: "Bubble's behaviour is a leak we do not reproduce."
      })

    d
  end

  defp waived_with(%Decision{key: key}),
    do: golden("result.waived.json") |> Map.put(:decision, parity_ref(key))

  defp finding_decision(opts \\ []) do
    %Decision{
      key: finding_ref().key,
      kind: :finding,
      revision: 1,
      subject: Keyword.get(opts, :subject, %{type: "custom.task"}),
      choice: Keyword.get(opts, :choice, :accept),
      author: Keyword.get(opts, :author, @owner),
      basis: %{
        finding_id: "privacy_access_list:9f2c1b7d0e4a5c63",
        proposal_sha256: Keyword.get(opts, :proposal_sha256, @sha),
        basis_sha256: @sha
      }
    }
  end

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
      rejected("acceptance", [waiver: waiver(:reviewer)], "no waiver")
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

        rejected(check, [status: :waived, diff: @diff, waiver: waiver(:reviewer)], "cannot be")
        rejected(check, [status: :waived, diff: @diff, decision: parity_ref()], "cannot be")
        rejected(check, [status: :quarantined, diff: @diff, waiver: quarantine()], "cannot be")
      end
    end

    test "privacy, data and auth differences are waived only by a parity exception" do
      for check <- ["privacy_read", "privacy_spot_check", "row_hashes", "files", "auth_users"] do
        assert %Result{status: :waived} =
                 ok(check, status: :waived, diff: @diff, decision: parity_ref())

        for actor <- [:agent, :reviewer] do
          rejected(
            check,
            [status: :waived, diff: @diff, waiver: waiver(actor)],
            "parity exception"
          )
        end

        rejected(check, [status: :waived, diff: @diff], "parity exception")

        rejected(
          check,
          [status: :quarantined, diff: @diff, waiver: quarantine()],
          "parity exception"
        )
      end
    end

    test "a parity exception is the waiver; a finding decision never waives" do
      rejected(
        "dom_text",
        [status: :waived, diff: @diff, decision: parity_ref(), waiver: waiver(:reviewer)],
        "is the waiver"
      )

      rejected(
        "dom_text",
        [status: :waived, diff: @diff, decision: finding_ref()],
        "decided_difference"
      )
    end

    test "behaviour: reviewers waive, agents only quarantine" do
      assert %Result{} = ok("dom_text", status: :waived, diff: @diff, waiver: waiver(:reviewer))
      assert %Result{} = ok("api_workflow", status: :waived, diff: @diff, decision: parity_ref())

      rejected(
        "dom_text",
        [status: :waived, diff: @diff, waiver: waiver(:agent)],
        "agent may not waive"
      )

      week = quarantine(%{expires_at: DateTime.add(@ran_at, 7 * 86_400, :second)})

      assert %Result{status: :quarantined} =
               ok("workflow_side_effects", status: :quarantined, diff: @diff, waiver: week)
    end

    test "a quarantine expires after ran_at, within 7 days of the first quarantine" do
      too_long = quarantine(%{expires_at: DateTime.add(@ran_at, 7 * 86_400 + 1, :second)})
      rejected("dom_text", [status: :quarantined, diff: @diff, waiver: too_long], "7 days")

      past = quarantine(%{expires_at: @ran_at})
      rejected("dom_text", [status: :quarantined, diff: @diff, waiver: past], "7 days")

      rejected(
        "dom_text",
        [status: :quarantined, diff: @diff, waiver: quarantine(%{expires_at: nil})],
        "expires_at"
      )

      rejected("dom_text", [status: :quarantined, diff: @diff], "needs a waiver")

      rejected(
        "acceptance",
        [status: :quarantined, diff: @diff, waiver: quarantine()],
        "cannot be"
      )
    end

    test "probe M3: renewing a quarantine never extends it past 7 days from the first" do
      renewal =
        quarantine(%{
          since: ~U[2026-09-28 09:15:00Z],
          expires_at: DateTime.add(@ran_at, 6 * 86_400, :second)
        })

      rejected(
        "dom_text",
        [status: :quarantined, diff: @diff, waiver: renewal],
        "first quarantine"
      )

      rejected(
        "dom_text",
        [status: :quarantined, diff: @diff, waiver: quarantine(%{since: nil})],
        "since"
      )

      future_since = quarantine(%{since: DateTime.add(@ran_at, 60, :second)})
      rejected("dom_text", [status: :quarantined, diff: @diff, waiver: future_since], "since")

      rejected(
        "dom_text",
        [status: :waived, diff: @diff, waiver: waiver(:reviewer, %{since: @ran_at})],
        "only a quarantine"
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
        [status: :waived, diff: @diff, waiver: waiver(:reviewer)],
        "cannot be"
      )

      rejected(
        "traceability.rendered",
        [status: :waived, diff: @diff, decision: parity_ref()],
        "cannot be"
      )
    end

    test "a reviewer's visual waiver needs an attestation with its hash" do
      rejected(
        "visual_parity",
        [status: :waived, diff: @diff, waiver: waiver(:reviewer)],
        "attestation"
      )

      unhashed = [
        %{kind: :attestation, ref: ".wtf/verification/attestations/v.json", sha256: nil}
      ]

      rejected(
        "visual_parity",
        [status: :waived, diff: @diff, waiver: waiver(:reviewer), evidence: unhashed],
        "attestation"
      )

      evidence = [
        %{kind: :attestation, ref: ".wtf/verification/attestations/v.json", sha256: @sha}
      ]

      assert %Result{} =
               ok("visual_parity",
                 status: :waived,
                 diff: @diff,
                 waiver: waiver(:reviewer),
                 evidence: evidence
               )
    end

    test "probe H3: a self-declared owner waiver is refused; waiver actors need an ID" do
      for check <- ["dom_text", "visual_parity", "acceptance", "privacy_read"] do
        rejected(
          check,
          [status: :waived, diff: @diff, waiver: waiver(:owner)],
          "parity exception"
        )
      end

      raw =
        put_in(raw("result.quarantined.json"), ["waiver", "actor"], %{"kind" => "agent"})

      assert {:error, %Error{message: m}} = Result.from_map(raw)
      assert m =~ "missing"
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

    test "probe H4: a Bubble oracle is a replay branch in every spelling" do
      for branch <- [
            nil,
            "live",
            "test",
            "Live",
            " live",
            "live ",
            "TEST",
            "version-live",
            "version-test",
            "Version-Test",
            "feature",
            "wtfreplay/../live",
            "WTFREPLAY"
          ] do
        rejected(
          "privacy_read",
          [oracle: %{kind: :bubble, sha256: @sha, branch: branch}],
          "branch"
        )
      end

      assert %Result{} =
               ok("privacy_read", oracle: %{kind: :bubble, sha256: @sha, branch: "wtfreplay-2"})

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

  describe "evaluate/3" do
    test "probe H1: a decoded waived or decided result never counts without its decision" do
      for name <- ["result.waived.json", "result.decided_difference.json"] do
        result = golden(name)

        assert {:error, %Error{message: m}} = evaluate(result, [])
        assert m =~ "does not exist"
        refute Result.passing?(result, resolved([]), now: @now)
        refute Result.bubble_verified?(result, resolved([]), now: @now)
      end
    end

    test "it needs now and refuses results from the future" do
      result = golden("result.pass.json")
      assert {:error, %Error{message: m}} = Result.evaluate(result, resolved([]), [])
      assert m =~ "now"

      assert {:error, %Error{message: m}} =
               Result.evaluate(result, resolved([]), now: DateTime.add(@ran_at, -301, :second))

      assert m =~ "future"

      assert {:ok, _} =
               Result.evaluate(result, resolved([]), now: DateTime.add(@ran_at, -60, :second))
    end

    test "passing follows the status table" do
      assert {:ok, %{passing: true}} = evaluate(golden("result.pass.json"), [])
      assert {:ok, %{passing: false}} = evaluate(golden("result.quarantined.json"), [])
      assert {:ok, %{passing: false}} = evaluate(golden("result.stale.json"), [])

      assert {:ok, %{passing: false}} =
               evaluate(ok("privacy_read", status: :skipped, reason: "x"), [])

      assert {:ok, %{passing: true}} = evaluate(ok("dom_text", status: :skipped, reason: "x"), [])
      assert {:ok, %{passing: false}} = evaluate(ok("lint", status: :fail), [])

      d = parity(@owner)
      assert {:ok, %{passing: true}} = evaluate(waived_with(d), [entry(d)])

      decided = golden("result.decided_difference.json")
      assert {:ok, %{passing: true}} = evaluate(decided, [entry(finding_decision())])
    end

    test "probe H3: a reviewer's waiver counts only for a trusted reviewer" do
      result = ok("dom_text", status: :waived, diff: @diff, waiver: waiver(:reviewer))

      assert {:ok, %{passing: false}} = evaluate(result, [])
      assert {:ok, %{passing: false}} = evaluate(result, [], reviewers: ["reviewer:2"])
      assert {:ok, %{passing: true}} = evaluate(result, [], reviewers: ["reviewer:1"])
    end

    test "probe M2: a model oracle never counts as Bubble-verified, at any level" do
      model = ok("privacy_read", oracle: %{kind: :model, sha256: @sha, branch: nil})
      assert {:ok, %{passing: true, bubble_verified: false}} = evaluate(model, [])

      spot = ok("privacy_spot_check", oracle: %{kind: :model, sha256: @sha, branch: nil})
      assert {:ok, %{passing: true, bubble_verified: false}} = evaluate(spot, [])

      spot = ok("privacy_spot_check", [])
      assert {:ok, %{bubble_verified: false}} = evaluate(spot, [])

      export = ok("row_hashes", oracle: %{kind: :export, sha256: @sha, branch: nil})
      assert {:ok, %{bubble_verified: true}} = evaluate(export, [])

      assert {:ok, %{bubble_verified: true}} = evaluate(ok("lint", []), [])
    end

    test "probe M4: a Bubble oracle is trusted only with its matching recording" do
      {:ok, bubble} = raw("recording.bubble.json") |> Recording.from_map()
      {:ok, model} = raw("recording.model.json") |> Recording.from_map()
      result = golden("result.pass.json")

      assert {:ok, %{bubble_verified: false}} = evaluate(result, [])
      assert {:ok, %{bubble_verified: true}} = evaluate(result, [], recording: bubble)

      assert {:error, %Error{message: m}} = evaluate(result, [], recording: model)
      assert m =~ "another recording"

      relabelled = %{
        result
        | oracle: %{result.oracle | kind: :model, branch: nil, sha256: Recording.sha256(model)}
      }

      assert :ok = Result.check_recording(relabelled, model)

      lying = %{relabelled | oracle: %{relabelled.oracle | kind: :bubble, branch: "wtfreplay"}}
      assert {:error, %Error{message: m}} = Result.check_recording(lying, model)
      assert m =~ "kind"
    end
  end

  describe "link_decision/3" do
    test "an owner's active parity exception excuses the result" do
      d = parity(@owner)
      result = waived_with(d)
      assert {:ok, ^result} = Result.link_decision(result, resolved([entry(d)]))
    end

    test "an agent's parity exception never excuses a difference" do
      for author <- [@agent, %{kind: :wtf_staff, id: "s", via: :cli}, nil] do
        d = parity(author)

        assert {:error, %Error{kind: :invalid_input, message: message}} =
                 Result.link_decision(waived_with(d), resolved([entry(d)]))

        assert message =~ "owner"
      end
    end

    test "the exception's scope and subject must cover the result" do
      d = parity(@owner, scope: "privacy_read.custom.task.w1_member")

      assert {:error, %Error{message: m}} =
               Result.link_decision(waived_with(d), resolved([entry(d)]))

      assert m =~ "scope"

      d = parity(@owner, subject: %{type: "custom.workspace"})

      assert {:error, %Error{message: m}} =
               Result.link_decision(waived_with(d), resolved([entry(d)]))

      assert m =~ "subject"
    end

    test "a parity exception on a scenario pins the scenario hash" do
      d = parity(@owner, basis: %{})

      assert {:error, %Error{message: m}} =
               Result.link_decision(waived_with(d), resolved([entry(d)]))

      assert m =~ "scenario_sha256"

      d = parity(@owner, basis: %{scenario_sha256: String.duplicate("0", 64)})

      assert {:ok, %Result{status: :stale, stale_reasons: [:decision_changed]}} =
               Result.link_decision(waived_with(d), resolved([entry(d)]))
    end

    test "an expired or withdrawn exception turns the result stale" do
      d = parity(@owner)

      assert {:ok, %Result{status: :stale, stale_reasons: [:decision_expired]}} =
               Result.link_decision(waived_with(d), resolved([entry(d, :expired)]))

      {:ok, withdrawn} = Decision.withdraw(d, author: @owner)

      assert {:ok, %Result{status: :stale, stale_reasons: [:decision_withdrawn]}} =
               Result.link_decision(
                 waived_with(d),
                 resolved([entry(d, :superseded), entry(withdrawn, :withdrawn)])
               )
    end

    test "a missing decision is an error" do
      d = parity(@owner)
      assert {:error, %Error{message: m}} = Result.link_decision(waived_with(d), resolved([]))
      assert m =~ "does not exist"
    end

    test "a finding decision holds while its proposal hash matches" do
      result = golden("result.decided_difference.json")
      assert {:ok, ^result} = Result.link_decision(result, resolved([entry(finding_decision())]))

      changed = finding_decision(proposal_sha256: String.duplicate("c", 64))

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
               Result.link_decision(result, resolved([entry(finding_decision(choice: :reject))]))

      assert m =~ "accepted or modified"
    end

    test "probe H2: an agent's or an unrelated finding decision explains no privacy difference" do
      result = golden("result.decided_difference.json")

      assert {:error, %Error{message: m}} =
               Result.link_decision(result, resolved([entry(finding_decision(author: @agent))]))

      assert m =~ "owner"

      unrelated = finding_decision(subject: %{type: "custom.invoice", field: "total_number"})

      assert {:error, %Error{message: m}} =
               Result.link_decision(result, resolved([entry(unrelated)]))

      assert m =~ "another subject"
    end

    test "probe H2: behaviour checks accept an agent's finding decision only when relevant" do
      result =
        ok("dom_text",
          status: :decided_difference,
          diff: @diff,
          decision: finding_ref(),
          subjects: %{type: "custom.task"}
        )

      assert {:ok, %Result{status: :decided_difference}} =
               Result.link_decision(result, resolved([entry(finding_decision(author: @agent))]))

      unrelated = finding_decision(author: @agent, subject: %{type: "custom.invoice"})

      assert {:error, %Error{}} = Result.link_decision(result, resolved([entry(unrelated)]))
    end

    test "a finding listed in the result's scenario covers is relevant" do
      {:ok, scenario} = raw("scenario.privacy_read.json") |> Scenario.from_map()
      finding_id = "privacy_access_list:9f2c1b7d0e4a5c63"
      scenario = %{scenario | covers: %{scenario.covers | findings: [finding_id]}}

      result =
        golden("result.decided_difference.json")
        |> Map.put(:scenario, %{
          golden("result.decided_difference.json").scenario
          | sha256: Scenario.sha256(scenario)
        })

      other_subject = finding_decision(subject: %{type: "custom.workspace"})
      entries = resolved([entry(other_subject)])

      assert {:error, _} = Result.link_decision(result, entries)
      assert {:ok, ^result} = Result.link_decision(result, entries, scenario: scenario)

      stale_scenario = %{scenario | persona: "w1_member"}
      assert {:error, _} = Result.link_decision(result, entries, scenario: stale_scenario)
      assert {:error, _} = Result.link_decision(result, entries, scenario: scenario, findings: [])
    end

    test "a result without a decision is unchanged" do
      result = golden("result.pass.json")
      assert {:ok, ^result} = Result.link_decision(result, resolved([]))
    end
  end

  describe "mark_stale/2" do
    test "keeps the evidence, accumulates reasons and leaves errors alone" do
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

    test "probe H5: a new mask makes the result and its recording stale", %{
      result: result,
      current: current
    } do
      mask = %BubbleEx.Verify.Mask{
        op: "o2",
        kind: :values,
        pointer: "/notes_text",
        reason: :random
      }

      masked = %{current.scenario | masks: [mask | current.scenario.masks]}

      assert :scenario_changed in Staleness.result(result, %{current | scenario: masked})
      assert :scenario_changed in Staleness.recording(current.recording, masked, current.seed)
    end

    test "unknown current hashes are not compared", %{result: result} do
      assert Staleness.result(result, %{}) == []
    end
  end
end
