defmodule BubbleEx.Verify.FormatsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error
  alias BubbleEx.Verify.{Mask, Observation, Recording, Scenario, Seed, Staleness}

  @dir "test/support/verify"

  defp raw(name), do: @dir |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp invalid(result, pattern \\ nil) do
    assert {:error, %Error{kind: :invalid_input, message: message}} = result
    if pattern, do: assert(message =~ pattern)
    message
  end

  defp seed, do: raw("seed.json") |> Seed.from_map() |> elem(1)
  defp scenario, do: raw("scenario.privacy_read.json") |> Scenario.from_map() |> elem(1)
  defp recording, do: raw("recording.bubble.json") |> Recording.from_map() |> elem(1)

  defp put_record(raw, key, fun) do
    Map.update!(raw, "records", &Enum.map(&1, fn r -> update_if(r, key, fun) end))
  end

  defp update_if(%{"key" => key} = record, key, fun), do: fun.(record)
  defp update_if(record, _key, _fun), do: record

  describe "seed" do
    test "records are sorted by key on decode" do
      shuffled = Map.update!(raw("seed.json"), "records", &Enum.reverse/1)
      {:ok, seed} = Seed.from_map(shuffled)
      assert Enum.map(seed.records, & &1.key) == Enum.sort(Enum.map(seed.records, & &1.key))
      assert Seed.to_json(seed) == Seed.to_json(seed())
    end

    test "duplicate record keys are rejected" do
      raw = raw("seed.json")
      dup = Map.update!(raw, "records", &[hd(&1) | &1])
      invalid(Seed.from_map(dup), "duplicate")
    end

    test "references must name seed records" do
      raw =
        put_record(raw("seed.json"), "task_w2", fn r ->
          put_in(r, ["fields", "Created By"], %{"ref" => "user_ghost"})
        end)

      invalid(Seed.from_map(raw), "unknown records")
    end

    test "personas name user records of the seed" do
      raw = put_in(raw("seed.json"), ["personas", "w1_member", "user"], "task_w1")
      invalid(Seed.from_map(raw), "persona users")

      raw = put_in(raw("seed.json"), ["personas", "Bad Persona"], %{"user" => nil})
      invalid(Seed.from_map(raw), "persona IDs")
    end

    test "emails must use a reserved domain (synthetic data only)" do
      for email <- ["jane@acme.com", "Contact: bob@gmail.com today"] do
        raw =
          put_record(raw("seed.json"), "user_w1", fn r ->
            put_in(r, ["fields", "email"], %{"text" => email})
          end)

        invalid(Seed.from_map(raw), "reserved domain")
      end

      for email <- ["a@replay.wtf.invalid", "b@example.com", "c@sub.example.org", "d@x.test"] do
        raw =
          put_record(raw("seed.json"), "user_w1", fn r ->
            put_in(r, ["fields", "email"], %{"text" => email})
          end)

        assert {:ok, _} = Seed.from_map(raw)
      end

      leak =
        put_record(raw("seed.json"), "task_w2", fn r ->
          put_in(r, ["fields", "payload_json"], %{"json" => %{"to" => "real@company.io"}})
        end)

      invalid(Seed.from_map(leak), "reserved domain")
    end

    test "file and image URLs must be on a reserved domain" do
      for url <- [
            "https://s3.amazonaws.com/appforest_uf/f1/secret.pdf",
            "//cdn.bubble.io/x.png",
            "not a url"
          ] do
        raw =
          put_record(raw("seed.json"), "task_w1", fn r ->
            put_in(r, ["fields", "attachment_file"], %{"file" => url})
          end)

        invalid(Seed.from_map(raw), "URLs")
      end
    end

    test "phone numbers must be fictional 555-01xx numbers" do
      for text <- ["Call +1 (415) 867-5309", "tel 020 7946 0123 4", "0612345678"] do
        raw =
          put_record(raw("seed.json"), "task_w2", fn r ->
            put_in(r, ["fields", "title_text"], %{"text" => text})
          end)

        invalid(Seed.from_map(raw), "phone")
      end

      for text <- ["Call +1 (415) 555-0123", "555-0199", "Ship 3 of 12", "v2.10.3"] do
        raw =
          put_record(raw("seed.json"), "task_w2", fn r ->
            put_in(r, ["fields", "title_text"], %{"text" => text})
          end)

        assert {:ok, _} = Seed.from_map(raw)
      end
    end

    test "invalid values are rejected with the seed" do
      raw =
        put_record(raw("seed.json"), "task_w2", fn r ->
          put_in(r, ["fields", "title_text"], "Ship")
        end)

      invalid(Seed.from_map(raw))
    end
  end

  describe "scenario" do
    test "the kind limits the ops" do
      raw =
        Map.update!(raw("scenario.privacy_read.json"), "ops", fn ops ->
          ops ++
            [%{"id" => "o3", "op" => "trigger", "workflow" => "bTHcK", "observe" => ["db_diff"]}]
        end)

      invalid(Scenario.from_map(raw), "cannot run")
    end

    test "an op observes only what it can" do
      raw =
        update_in(raw("scenario.privacy_read.json"), ["ops"], fn [search | rest] ->
          [Map.put(search, "observe", ["db_diff"]) | rest]
        end)

      invalid(Scenario.from_map(raw), "cannot observe")
    end

    test "ops need their members and have unique ids" do
      raw =
        update_in(raw("scenario.privacy_read.json"), ["ops"], fn [search, get] ->
          [search, Map.delete(get, "record")]
        end)

      invalid(Scenario.from_map(raw), "missing")

      raw =
        update_in(raw("scenario.privacy_read.json"), ["ops"], fn [search, get] ->
          [search, Map.put(get, "id", "o1")]
        end)

      invalid(Scenario.from_map(raw), "duplicate")

      invalid(
        Scenario.from_map(Map.put(raw("scenario.privacy_read.json"), "ops", [])),
        "at least one"
      )
    end

    test "unknown checks and non-Bubble-ID subjects are rejected" do
      invalid(
        Scenario.from_map(Map.put(raw("scenario.privacy_read.json"), "check", "vibes")),
        "unknown check"
      )

      invalid(
        Scenario.from_map(
          Map.put(raw("scenario.privacy_read.json"), "subjects", %{"resource" => "Task"})
        ),
        "subject"
      )
    end

    test "masks must name an op and a kind it observes" do
      mask = %{
        "op" => "o9",
        "kind" => "record_set",
        "pointer" => "/records",
        "reason" => "random"
      }

      invalid(
        Scenario.from_map(Map.put(raw("scenario.privacy_read.json"), "masks", [mask])),
        "unknown op"
      )

      mask = %{"op" => "o1", "kind" => "values", "pointer" => "/x", "reason" => "random"}

      invalid(
        Scenario.from_map(Map.put(raw("scenario.privacy_read.json"), "masks", [mask])),
        "does not make"
      )

      mask = %{
        "op" => "o2",
        "kind" => "values",
        "pointer" => "/x",
        "reason" => "random",
        "tolerance_ms" => 10
      }

      invalid(
        Scenario.from_map(Map.put(raw("scenario.privacy_read.json"), "masks", [mask])),
        "tolerance"
      )
    end

    test "hashing is canonical for numbers and verbatim for text" do
      api = raw("scenario.api_workflow.json")

      hash = fn points, task_title ->
        raw =
          api
          |> put_in(["ops", Access.at(0), "params", "points"], points)
          |> put_in(["ops", Access.at(0), "params", "title"], task_title)

        {:ok, sc} = Scenario.from_map(raw)
        {Scenario.sha256(sc), Scenario.to_json(sc)}
      end

      nfc = %{"text" => "caf\u00e9"}
      nfd = %{"text" => "cafe\u0301"}

      {h1, j1} = hash.(%{"number" => 0}, nfc)
      {h2, j2} = hash.(%{"number" => -0.0}, nfc)
      {h3, _} = hash.(%{"number" => 0.0}, nfc)
      assert h1 == h2 and h2 == h3
      assert j1 == j2

      {h5, _} = hash.(%{"number" => 5}, nfc)
      {h6, _} = hash.(%{"number" => 5.0}, nfc)
      assert h5 == h6

      {h_nfd, j_nfd} = hash.(%{"number" => 0}, nfd)
      refute h_nfd == h1
      assert j_nfd =~ "cafe\u0301"
      assert {:ok, sc} = Scenario.from_json(j_nfd)
      assert Scenario.sha256(sc) == h_nfd
    end

    test "sha256 covers every member, masks included" do
      s = scenario()
      base = Scenario.sha256(s)

      refute Scenario.sha256(%{s | masks: []}) == base
      refute Scenario.sha256(%{s | subjects: %{}}) == base
      refute Scenario.sha256(%{s | persona: "w1_member"}) == base
      refute Scenario.sha256(%{s | ops: tl(s.ops)}) == base
    end

    test "probe H5: a mask never covers a whole op or a whole observation" do
      for mask <- [
            %{"op" => "o2", "reason" => "random", "pointer" => "/x"},
            %{"op" => "o2", "kind" => nil, "reason" => "random", "pointer" => "/x"},
            %{"op" => "o2", "kind" => "values", "reason" => "random"},
            %{"op" => "o2", "kind" => "values", "reason" => "random", "pointer" => ""},
            %{"op" => "o2", "kind" => "values", "reason" => "random", "pointer" => "/"},
            %{"op" => "o2", "kind" => "vibes", "reason" => "random", "pointer" => "/x"}
          ] do
        invalid(Mask.from_map(mask))
      end
    end

    test "probe H5: privacy scenarios never mask their verdict" do
      for {kind, pointer} <- [
            {"visible", "/x"},
            {"visible_fields", "/0"},
            {"record_set", "/records"},
            {"values", "/*"},
            {"values", "/a/b"}
          ] do
        op = if kind == "record_set", do: "o1", else: "o2"
        mask = %{"op" => op, "kind" => kind, "pointer" => pointer, "reason" => "differential"}

        invalid(
          Scenario.from_map(Map.put(raw("scenario.privacy_read.json"), "masks", [mask])),
          "may not mask"
        )
      end

      rec = recording()
      verdict = %Mask{op: "o2", kind: :visible_fields, pointer: "/0", reason: :differential}
      invalid(Recording.check_scenario(%{rec | masks: [verdict]}, scenario()), "may not mask")

      stray = %Mask{op: "o1", kind: :values, pointer: "/x", reason: :differential}
      invalid(Recording.check_scenario(%{rec | masks: [stray]}, scenario()), "does not have")
    end

    test "check_seed catches unknown personas, records and a changed seed" do
      seed = seed()
      s = scenario()

      invalid(Scenario.check_seed(%{s | persona: "ghost"}, seed), "personas")

      [search, get] = s.ops

      invalid(
        Scenario.check_seed(%{s | ops: [search, %{get | record: "task_ghost"}]}, seed),
        "records"
      )

      changed = %{seed | records: tl(seed.records)}
      invalid(Scenario.check_seed(s, changed), "changed")
      invalid(Scenario.check_seed(s, %{seed | id: "other"}), "another seed")
    end
  end

  describe "recording" do
    test "a Bubble recording never comes from live or test" do
      for branch <- [
            "live",
            "test",
            "Live",
            " live",
            "test\n",
            "version-live",
            "version-test",
            "VERSION-TEST",
            "main",
            "",
            nil
          ] do
        raw = put_in(raw("recording.bubble.json"), ["source", "branch"], branch)
        invalid(Recording.from_map(raw))
      end

      raw = put_in(raw("recording.bubble.json"), ["source", "branch"], "wtfreplay_v2")
      assert {:ok, _} = Recording.from_map(raw)
    end

    test "a Bubble recording keeps the branch ID and host it was recorded from" do
      raw =
        raw("recording.bubble.json")
        |> put_in(["source", "branch_id"], "4k2xq")
        |> put_in(["source", "host"], "beta.example.com")

      assert {:ok, rec} = Recording.from_map(raw)
      assert %{branch: "wtfreplay", branch_id: "4k2xq", host: "beta.example.com"} = rec.source
      assert Recording.to_map(rec)["source"]["branch_id"] == "4k2xq"

      # Older recordings without them keep their canonical form.
      {:ok, old} = Recording.from_map(raw("recording.bubble.json"))
      assert old.source.branch_id == nil
      refute Map.has_key?(Recording.to_map(old)["source"], "host")

      for id <- ["live", "test", "version-test", "wtfreplay", "4K2XQ", ""] do
        invalid(Recording.from_map(put_in(raw, ["source", "branch_id"], id)))
      end

      for host <- ["https://beta.example.com", "other.bubbleapps.io", "127.0.0.1", "localhost"] do
        invalid(Recording.from_map(put_in(raw, ["source", "host"], host)))
      end
    end

    test "probe M1: the source app is a Bubble app ID, not a domain" do
      for app <- ["app.example.com", "https://acme.bubbleapps.io", "Acme", " acme", ""] do
        raw = put_in(raw("recording.bubble.json"), ["source", "app"], app)
        invalid(Recording.from_map(raw), "app")
      end
    end

    test "the source matches the oracle" do
      raw = Map.put(raw("recording.bubble.json"), "oracle", "model")
      invalid(Recording.from_map(raw), "model source")

      raw = Map.put(raw("recording.model.json"), "oracle", "bubble")
      invalid(Recording.from_map(raw), "bubble source")
    end

    test "observations are unique and sorted" do
      raw = Map.update!(raw("recording.bubble.json"), "observations", &Enum.reverse/1)
      {:ok, rec} = Recording.from_map(raw)
      assert Recording.to_json(rec) == Recording.to_json(recording())

      dup = Map.update!(raw("recording.bubble.json"), "observations", &[hd(&1) | &1])
      invalid(Recording.from_map(dup), "duplicate")
    end

    test "observation values are validated by kind" do
      bad = [
        %{"op" => "o2", "kind" => "visible", "record" => nil, "value" => true},
        %{"op" => "o2", "kind" => "visible", "record" => "task_w1", "value" => "yes"},
        %{"op" => "o1", "kind" => "record_set", "record" => "task_w1", "value" => %{}},
        %{"op" => "o1", "kind" => "status", "record" => nil, "value" => 99},
        %{"op" => "o1", "kind" => "visible_fields", "record" => "t", "value" => ["a", "a"]},
        %{
          "op" => "o1",
          "kind" => "step_trace",
          "record" => nil,
          "value" => [%{"workflow" => "w", "step" => 0, "action" => "x"}]
        },
        %{
          "op" => "o1",
          "kind" => "db_diff",
          "record" => nil,
          "value" => [%{"change" => "moved", "type" => "t", "record" => "r"}]
        },
        %{
          "op" => "o1",
          "kind" => "dom_text",
          "record" => nil,
          "value" => %{"e" => %{"visible" => true, "text" => 1}}
        }
      ]

      for obs <- bad, do: invalid(Observation.from_map(obs))
    end

    test "an unordered record set is canonicalized; an ordered one keeps its order" do
      {:ok, unordered} =
        Observation.from_map(%{
          "op" => "o1",
          "kind" => "record_set",
          "value" => %{"ordered" => false, "records" => ["b", "a"]}
        })

      assert unordered.value.records == ["a", "b"]

      {:ok, ordered} =
        Observation.from_map(%{
          "op" => "o1",
          "kind" => "record_set",
          "value" => %{"ordered" => true, "records" => ["b", "a"]}
        })

      assert ordered.value.records == ["b", "a"]
    end

    test "check_scenario rejects observations the scenario does not make" do
      rec = recording()
      s = scenario()

      {:ok, stray} =
        Observation.from_map(%{
          "op" => "o2",
          "kind" => "visible",
          "record" => "task_w2",
          "value" => true
        })

      invalid(
        Recording.check_scenario(%{rec | observations: [stray | rec.observations]}, s),
        "do not fit"
      )

      {:ok, ordered} =
        Observation.from_map(%{
          "op" => "o1",
          "kind" => "record_set",
          "value" => %{"ordered" => true, "records" => []}
        })

      invalid(Recording.check_scenario(%{rec | observations: [ordered]}, s), "do not fit")
      invalid(Recording.check_scenario(rec, %{s | id: "other"}), "another scenario")
    end

    test "comparable/2 applies ignoring masks, not tolerance masks" do
      {:ok, obs} =
        Observation.from_map(%{
          "op" => "call",
          "kind" => "db_diff",
          "value" => [
            %{
              "change" => "created",
              "type" => "t",
              "record" => "new_1",
              "fields" => %{"id_text" => %{"text" => "x"}, "Modified Date" => %{"date" => 5}}
            },
            %{
              "change" => "updated",
              "type" => "t",
              "record" => "task_w1",
              "fields" => %{"id_text" => %{"text" => "y"}}
            }
          ]
        })

      masks = [
        %Mask{op: "call", kind: :db_diff, pointer: "/*/fields/id_text", reason: :created_id},
        %Mask{
          op: "call",
          kind: :db_diff,
          pointer: "/*/fields/Modified Date",
          reason: :time,
          tolerance_ms: 5000
        },
        %Mask{op: "call", kind: :db_diff, pointer: "/7/record", reason: :random},
        %Mask{op: "other", kind: :db_diff, pointer: "/0", reason: :random}
      ]

      [created, updated] = Mask.masked_value(obs, masks)
      assert created["fields"]["id_text"] == %{"masked" => "created_id"}
      assert created["fields"]["Modified Date"] == %{"date" => 5}
      assert updated["fields"]["id_text"] == %{"masked" => "created_id"}

      rec = recording()
      comparable = Recording.comparable(rec)
      assert comparable[{"o2", :values, "task_w1"}] == %{}
      field = %Mask{op: "o2", kind: :values, pointer: "/slug", reason: :differential}
      tolerant = %Mask{op: "o2", kind: :values, pointer: "/x", reason: :time, tolerance_ms: 5}
      assert Recording.comparable(rec, [field, tolerant])[{"o2", :visible, "task_w1"}] == false
    end
  end

  describe "staleness" do
    test "a recording is stale when the scenario, its source or the seed changes" do
      seed = seed()
      s = scenario()
      rec = recording()

      assert Staleness.recording(rec, s, seed) == []
      assert Staleness.recording(rec, %{s | persona: "w1_member"}, seed) == [:scenario_changed]

      assert Staleness.recording(rec, %{s | source_sha256: String.duplicate("0", 64)}, seed) ==
               [:scenario_changed, :source_changed]

      assert Staleness.recording(rec, s, %{seed | records: tl(seed.records)}) == [:seed_changed]
      assert Staleness.recording(%{rec | complete: false}, s, seed) == [:recording_incomplete]
    end

    test "editing masks makes a recording stale" do
      s = scenario()
      assert Staleness.recording(recording(), %{s | masks: []}, seed()) == [:scenario_changed]
    end
  end
end
