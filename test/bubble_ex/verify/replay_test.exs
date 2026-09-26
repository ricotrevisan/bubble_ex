defmodule BubbleEx.Verify.ReplayTest do
  # Everything here runs against BubbleEx.Test.FakeBubble through a Req
  # plug: no request leaves the VM, and no real Bubble app is ever called.
  use ExUnit.Case, async: true

  alias BubbleEx.{Error, HTTP}
  alias BubbleEx.Test.FakeBubble
  alias BubbleEx.Verify.{Mask, Observation, Recording, Scenario, Seed}

  alias BubbleEx.Verify.Replay.{
    Cleanup,
    Client,
    CredentialScan,
    Differential,
    Kit,
    Ledger,
    Names,
    Recorder,
    Seeder,
    Session,
    Target
  }

  @admin FakeBubble.admin_token()
  @prefix "/version-wtfreplay/api/1.1/"

  # --- fixtures ------------------------------------------------------------------------

  defp start_fake(opts \\ []) do
    fake = FakeBubble.start(opts)
    HTTP.put_process_options(plug: FakeBubble.plug(fake))
    on_exit(fn -> HTTP.delete_process_options() end)
    fake
  end

  defp target do
    {:ok, t} = Target.new("acme", "wtfreplay", @admin)
    t
  end

  defp names do
    {:ok, names} =
      Names.new(
        types: %{"custom.task" => "task", "user" => "user", "custom.workspace" => "workspace"},
        fields: %{
          "custom.task" => %{
            "title_text" => "Title",
            "secret_text" => "Secret",
            "workspace_custom_workspace" => "Workspace",
            "Created By" => "Created By",
            "Created Date" => "Created Date",
            "Modified Date" => "Modified Date"
          },
          "user" => %{
            "email" => "email",
            "admin_boolean" => "Admin",
            "workspace_custom_workspace" => "Workspace",
            "Created Date" => "Created Date",
            "Modified Date" => "Modified Date"
          },
          "custom.workspace" => %{
            "name_text" => "Name",
            "Created Date" => "Created Date",
            "Modified Date" => "Modified Date"
          }
        }
      )

    names
  end

  defp client(opts \\ []) do
    {:ok, c} =
      Client.new(
        target(),
        [names: names(), sleep: fn ms -> send(self(), {:slept, ms}) end] ++ opts
      )

    c
  end

  defp seed do
    {:ok, seed} =
      Seed.new(
        id: "replay_test",
        personas: %{
          "anonymous" => %{user: nil},
          "alice" => %{user: "user_a"},
          "bob" => %{user: "user_b"}
        },
        records: [
          %{
            key: "user_a",
            type: "user",
            fields: %{
              "email" => {:text, "alice@replay.wtf.invalid"},
              "admin_boolean" => {:boolean, false},
              "workspace_custom_workspace" => {:ref, "ws_1"}
            }
          },
          %{
            key: "user_b",
            type: "user",
            fields: %{"email" => {:text, "bob@replay.wtf.invalid"}}
          },
          %{key: "ws_1", type: "custom.workspace", fields: %{"name_text" => {:text, "W1"}}},
          %{
            key: "task_a",
            type: "custom.task",
            fields: %{
              "Created By" => {:ref, "user_a"},
              "title_text" => {:text, "A"},
              "secret_text" => {:text, "s-a"},
              "workspace_custom_workspace" => {:ref, "ws_1"}
            }
          },
          %{
            key: "task_b",
            type: "custom.task",
            fields: %{"Created By" => {:ref, "user_b"}, "title_text" => {:text, "B"}}
          }
        ]
      )

    seed
  end

  defp privacy_scenario(seed, persona, observe \\ [:visible, :visible_fields]) do
    {:ok, s} =
      Scenario.new(
        id: "privacy_read.custom.task.#{persona}",
        kind: :privacy_read,
        check: "privacy_read",
        seed: %{id: seed.id, sha256: Seed.sha256(seed)},
        persona: persona,
        subjects: %{type: "custom.task"},
        ops: [
          %{id: "search", op: :search, type: "custom.task", sort: nil, observe: [:record_set]},
          %{id: "get.task_a", op: :get, type: "custom.task", record: "task_a", observe: observe},
          %{id: "get.task_b", op: :get, type: "custom.task", record: "task_b", observe: observe}
        ],
        source_sha256: String.duplicate("5", 64)
      )

    s
  end

  defp api_scenario(seed, workflow, auth) do
    {:ok, s} =
      Scenario.new(
        id: "api_workflow.#{workflow}.alice",
        kind: :api_workflow,
        check: "api_workflow",
        seed: %{id: seed.id, sha256: Seed.sha256(seed)},
        persona: "alice",
        ops: [
          %{
            id: "call",
            op: :call_api_workflow,
            workflow: workflow,
            auth: auth,
            params: %{"task" => {:ref, "task_a"}},
            observe: [:status, :response]
          }
        ],
        source_sha256: String.duplicate("6", 64)
      )

    s
  end

  defp dir do
    dir = Path.join(System.tmp_dir!(), "replay-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp ledger(run_id \\ "r1", opts \\ []) do
    {:ok, ledger} = Ledger.new(target(), run_id, opts)
    ledger
  end

  defp record(client, seed, scenarios, opts \\ []) do
    opts = opts |> Keyword.put_new(:run_id, "t1") |> Keyword.put_new_lazy(:ledger_dir, &dir/0)
    {:ok, plan} = Recorder.plan(client, seed, scenarios, opts)
    Recorder.record(client, seed, scenarios, [plan_sha256: plan.sha256] ++ opts)
  end

  defp requests(fake, method), do: Enum.filter(FakeBubble.log(fake), &(&1.method == method))

  # --- the guard --------------------------------------------------------------------------

  describe "Target" do
    test "accepts an app ID and a wtfreplay branch only" do
      for branch <- ~w(wtfreplay wtfreplay-2 wtfreplay_v5) do
        assert {:ok, %Target{branch: ^branch}} = Target.new("acme", branch, @admin)
      end

      for branch <-
            [
              "live",
              "test",
              "version-test",
              "version-live",
              "version-wtfreplay",
              "Wtfreplay",
              "WTFREPLAY",
              "wtf-replay",
              "wtf_replay",
              "xwtfreplay",
              " wtfreplay",
              "wtfreplay ",
              "wtfreplay/../live",
              "wtfreplay%2F..%2Flive",
              "wtfreplay.evil",
              "wtfreplay\n",
              "",
              nil,
              :wtfreplay,
              "wtfreplay" <> String.duplicate("x", 60)
            ] do
        assert {:error, %Error{kind: :invalid_input, context: %{reason: :not_a_replay_branch}}} =
                 Target.new("acme", branch, @admin),
               "accepted branch #{inspect(branch)}"
      end

      for app <- [
            "acme.com",
            "acme.bubbleapps.io",
            "https://acme.bubbleapps.io",
            "https://app.acme.com/version-wtfreplay",
            "Acme",
            "acme/version-live",
            "-acme",
            "",
            nil,
            String.duplicate("a", 64)
          ] do
        assert {:error, %Error{context: %{reason: :not_an_app_id}}} =
                 Target.new(app, "wtfreplay", @admin),
               "accepted app #{inspect(app)}"
      end

      for token <- [nil, "", "short", "has a space in it", "tab\there-012345"] do
        assert {:error, %Error{kind: :invalid_input}} = Target.new("acme", "wtfreplay", token)
      end
    end

    test "builds branch URLs from validated segments only" do
      t = target()
      root = "https://acme.bubbleapps.io/version-wtfreplay/api/1.1"
      assert Target.api_root(t) == root
      assert {:ok, root <> "/obj/task"} == Target.data_url(t, "task")
      assert {:ok, root <> "/obj/task/1700x12"} == Target.data_url(t, "task", "1700x12")
      assert {:ok, root <> "/wf/wtf_replay_login"} == Target.workflow_url(t, "wtf_replay_login")

      for bad <- ["../live", "task/../x", "Task", "", "task?x=1", "a%2Fb"] do
        assert {:error, _} = Target.data_url(t, bad)
      end

      for id <- ["../1x2", "1x2/..", "abc", "1x2?", ""] do
        assert {:error, _} = Target.data_url(t, "task", id)
      end
    end

    test "check_url refuses anything outside the branch's API" do
      t = target()
      assert :ok = Target.check_url(t, Target.api_root(t) <> "/obj/task?limit=1")

      for url <- [
            "https://acme.bubbleapps.io/version-test/api/1.1/obj/task",
            "https://acme.bubbleapps.io/api/1.1/obj/task",
            "https://acme.bubbleapps.io/version-wtfreplay2/api/1.1/obj/task",
            "https://other.bubbleapps.io/version-wtfreplay/api/1.1/obj/task",
            "https://acme.com/version-wtfreplay/api/1.1/obj/task",
            "http://acme.bubbleapps.io/version-wtfreplay/api/1.1/obj/task",
            "https://acme.bubbleapps.io/version-wtfreplay/api/1.1/../../version-live/api/1.1/obj/x",
            "https://acme.bubbleapps.io/version-wtfreplay/api/1.1/obj/a%2F..%2F..",
            "https://acme.bubbleapps.io/version-wtfreplay/api/1.1/obj/task#x",
            nil
          ] do
        assert {:error, %Error{context: %{reason: :outside_replay_branch}}} =
                 Target.check_url(t, url),
               "accepted #{inspect(url)}"
      end
    end

    test "Inspect never shows the admin token" do
      refute inspect(target()) =~ @admin
      assert inspect(target()) =~ "REDACTED"

      session = Session.put_user(%Session{}, "user_a", "a@x.invalid", "pw-secret-123")
      session = Session.put_token(session, "user_a", "tok-secret-456")
      refute inspect(session) =~ "pw-secret-123"
      refute inspect(session) =~ "tok-secret-456"
    end
  end

  # --- client: budgets, backoff, redirects -------------------------------------------------

  describe "Client" do
    test "stops at the call budget before sending" do
      fake = start_fake()
      c = client(max_calls: 2)
      assert {:ok, _} = Client.search(c, "custom.task", :admin, ids: ["1x1"])
      assert {:ok, _} = Client.search(c, "custom.task", :admin, ids: ["1x1"])

      assert {:error, %Error{kind: :request_failed, context: %{reason: :budget_exhausted}}} =
               Client.search(c, "custom.task", :admin, ids: ["1x1"])

      assert length(FakeBubble.log(fake)) == 2
      assert Client.calls(c) == 2
    end

    test "stops at the wall-time budget" do
      start_fake()
      c = client(max_wall_ms: 1)
      Process.sleep(5)

      assert {:error, %Error{context: %{reason: :budget_exhausted, budget: :wall_time}}} =
               Client.search(c, "custom.task", :admin, ids: ["1x1"])
    end

    test "backs off on 429 (Retry-After) and 5xx for reads" do
      fake =
        start_fake(
          script: [
            {"GET", "/obj/task", 429, [{"retry-after", "2"}]},
            {"GET", "/obj/task", 503, []}
          ]
        )

      c = client(retry_base_delay: 10)
      assert {:ok, []} = Client.search(c, "custom.task", :admin, ids: ["1x1"])
      assert_received {:slept, 2000}
      assert_received {:slept, 20}
      assert Client.calls(c) == 3
      assert length(FakeBubble.log(fake)) == 3
    end

    test "gives up after max_retries and caps the delay" do
      start_fake(script: List.duplicate({"GET", "/obj/task", 503, []}, 5))
      c = client(max_retries: 2, retry_base_delay: 50_000, max_retry_delay: 100)

      assert {:error, %Error{kind: :http_error, context: %{status: 503}}} =
               Client.search(c, "custom.task", :admin, ids: ["1x1"])

      assert Client.calls(c) == 3
      assert_received {:slept, 100}
    end

    test "never retries a create on 5xx (it may have created a record), only on 429" do
      fake = start_fake(script: [{"POST", "/obj/workspace", 502, []}])
      c = client()

      assert {:error, %Error{context: %{status: 502}}} =
               Client.create(c, "custom.workspace", %{"Name" => "x"}, :admin)

      assert length(requests(fake, "POST")) == 1

      fake = start_fake(script: [{"POST", "/obj/workspace", 429, []}])
      c = client(retry_base_delay: 1)
      assert {:ok, _id} = Client.create(c, "custom.workspace", %{"Name" => "x"}, :admin)
      assert length(requests(fake, "POST")) == 2
    end

    test "refuses redirects" do
      start_fake(script: [{"GET", "/obj/task", 302, [{"location", "https://acme.com/"}]}])

      assert {:error, %Error{context: %{reason: :redirect_refused}}} =
               Client.search(client(), "custom.task", :admin, ids: ["1x1"])
    end

    test "errors carry no body or credential" do
      start_fake()
      c = client()

      assert {:error, %Error{} = error} =
               Client.search(c, "custom.task", {:user, "user-token-not-issued-0000"},
                 ids: ["1x1"]
               )

      assert error.kind == :unauthorized
      refute inspect(error) =~ "user-token-not-issued"
      refute inspect(error) =~ @admin
    end

    test "telemetry metadata never carries tokens" do
      start_fake()
      parent = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach(id, [:bubble_ex, :http, :request, :stop], &__MODULE__.forward/4, parent)

      on_exit(fn -> :telemetry.detach(id) end)
      assert {:ok, _} = Client.search(client(), "custom.task", :admin, ids: ["1x1"])
      assert_received {:telemetry, meta}
      refute inspect(meta) =~ @admin
    end
  end

  def forward(_event, _measurements, meta, parent), do: send(parent, {:telemetry, meta})

  # --- ledger and cleanup --------------------------------------------------------------------

  describe "ledger" do
    test "only ledger records can be updated or deleted" do
      fake =
        start_fake(owner_records: [%{type: "task", fields: %{"Title" => "owner's own"}}])

      c = client()
      [{owner_id, _}] = Map.to_list(FakeBubble.records(fake))
      ledger = ledger()

      assert {:error, %Error{kind: :invalid_input}} = Client.delete_seeded(c, ledger, "task_x")
      assert {:error, %Error{}} = Ledger.put(ledger, "k", "custom.task", "../#{owner_id}")

      {:ok, id} = Client.create(c, "custom.task", %{"Title" => "mine"}, :admin)
      {:ok, ledger} = Ledger.put(ledger, "mine", "custom.task", id)
      assert {:error, _} = Ledger.put(ledger, "other", "custom.task", id)

      assert :ok = Client.update_seeded(c, ledger, "mine", %{"Title" => "mine 2"})
      assert {:ok, ledger} = Client.delete_seeded(c, ledger, "mine")
      assert Ledger.live(ledger) == []
      # A deleted entry is not deleted twice.
      assert {:error, _} = Client.delete_seeded(c, ledger, "mine")

      assert Map.keys(FakeBubble.records(fake)) == [owner_id]
      assert Enum.all?(requests(fake, "DELETE"), &String.ends_with?(&1.path, id))
    end

    test "the ledger JSON is credential-scanned" do
      {:ok, ledger} = Ledger.put(ledger(), "k", "custom.task", "1700x1")
      assert {:ok, json} = Ledger.to_json(ledger, [@admin])
      assert json =~ "1700x1"

      ledger = %{ledger | run_id: @admin}
      assert {:error, %Error{kind: :export_blocked}} = Ledger.to_json(ledger, [@admin])
    end
  end

  # --- credential scan --------------------------------------------------------------------------

  describe "CredentialScan" do
    test "refuses the run's secrets, bearer tokens, detector hits and credential members" do
      secret = "persona-token-abcdef123456"

      for text <- [
            ~s({"a": "x #{secret} y"}),
            ~s({"a": "#{Base.encode64(secret)}"}),
            ~s({"a": "#{URI.encode_www_form(secret <> "/+")}"}),
            ~s({"h": "Bearer abcdefghijklmnop"}),
            ~s({"k": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"}),
            ~s({"response": {"token": "abc"}}),
            ~s({"x": [{"api_key": "v"}]}),
            ~s({"password": "p"})
          ] do
        assert {:error, %Error{kind: :export_blocked} = e} =
                 CredentialScan.check(text, [secret, secret <> "/+"]),
               "passed #{text}"

        refute inspect(e) =~ secret
      end

      assert :ok = CredentialScan.check(~s({"token_text": "a", "password": null}), [secret])
      assert :ok = CredentialScan.check(%{"values" => %{"title_text" => "hello"}}, [secret])
    end
  end

  # --- seeding --------------------------------------------------------------------------------

  describe "Seeder" do
    test "signs users up with run emails, creates records as their creators, defers references" do
      fake = start_fake()
      c = client()
      assert {:ok, state} = Seeder.seed(c, seed(), ledger())

      assert Enum.map(state.ledger.entries, & &1.key) == ~w(user_a user_b task_a task_b ws_1)

      signups =
        Enum.filter(FakeBubble.log(fake), &String.ends_with?(&1.path, "wtf_replay_signup"))

      assert Enum.map(signups, & &1.body["email"]) ==
               ["alice+r1@replay.wtf.invalid", "bob+r1@replay.wtf.invalid"]

      records = FakeBubble.records(fake)
      task_a = records[Ledger.id(state.ledger, "task_a")]
      assert task_a.creator == Ledger.id(state.ledger, "user_a")
      assert task_a.fields["Workspace"] == Ledger.id(state.ledger, "ws_1")
      refute Map.has_key?(task_a.fields, "Created By")

      user_a = records[Ledger.id(state.ledger, "user_a")]
      assert user_a.fields["Workspace"] == Ledger.id(state.ledger, "ws_1")
      assert user_a.fields["Admin"] == false

      # Persona tokens are in the session, never in the ledger.
      {:ok, json} = Ledger.to_json(state.ledger, Session.secrets(state.session) ++ [@admin])
      refute json =~ "user-token-"
    end

    test "a failure returns the partial ledger" do
      start_fake(workflows: ~w(wtf_replay_signup))
      assert {:error, %Error{}, state} = Seeder.seed(client(), seed(), ledger())
      assert [%{key: "user_a", state: :created}] = state.ledger.entries
    end
  end

  # --- recording --------------------------------------------------------------------------------

  describe "Recorder" do
    test "double-records complete Bubble recordings, masks what differs, and cleans up" do
      fake = start_fake(owner_records: [%{type: "task", fields: %{"Title" => "owner"}}])
      [owner_id] = Map.keys(FakeBubble.records(fake))
      seed = seed()

      scenarios = [
        privacy_scenario(seed, "alice", [:visible, :visible_fields, :values]),
        privacy_scenario(seed, "bob"),
        privacy_scenario(seed, "anonymous")
      ]

      c = client()
      assert {:ok, result} = record(c, seed, scenarios)

      # Nothing outside the branch, owner data untouched, every seeded record gone.
      log = FakeBubble.log(fake)

      assert Enum.all?(
               log,
               &(&1.host == "acme.bubbleapps.io" and String.starts_with?(&1.path, @prefix))
             )

      assert Map.keys(FakeBubble.records(fake)) == [owner_id]
      refute Enum.any?(log, &(&1.method in ["DELETE", "PATCH"] and &1.path =~ owner_id))
      assert result.report.leftovers == []
      assert length(result.ledgers) == 2

      # Searches were constrained to the run's own records.
      for %{method: "GET", path: @prefix <> "obj/task", query: q} <- log do
        [%{"key" => "_id", "constraint_type" => "in", "value" => ids}] =
          Jason.decode!(q["constraints"])

        refute owner_id in ids
      end

      assert length(result.recordings) == 3
      assert result.report.complete |> length() == 3
      by_id = Map.new(result.recordings, &{&1.scenario.id, &1})

      for {path, json} <- result.files do
        assert {:ok, rec} = Recording.from_json(json)
        assert path == ".wtf/verification/recordings/#{rec.scenario.id}.json"
        assert rec.oracle == :bubble and rec.complete and rec.runs == 2
        assert rec.source == %{app: "acme", branch: "wtfreplay", app_version: nil}
        scenario = Enum.find(scenarios, &(&1.id == rec.scenario.id))
        assert rec.scenario.sha256 == Scenario.sha256(scenario)
        assert :ok = Recording.check_scenario(rec, scenario)
        refute json =~ @admin
        refute json =~ "user-token-"
      end

      alice = by_id["privacy_read.custom.task.alice"]
      obs = Map.new(alice.observations, &{Observation.key(&1), &1.value})
      assert obs[{"search", :record_set, nil}] == %{ordered: false, records: ["task_a"]}
      assert obs[{"get.task_a", :visible, "task_a"}] == true
      assert obs[{"get.task_b", :visible, "task_b"}] == false

      assert obs[{"get.task_a", :visible_fields, "task_a"}] ==
               [
                 "Created By",
                 "Created Date",
                 "Modified Date",
                 "secret_text",
                 "title_text",
                 "workspace_custom_workspace"
               ]

      values = obs[{"get.task_a", :values, "task_a"}]
      assert values["title_text"] == {:text, "A"}
      assert values["Created By"] == {:ref, "user_a"}
      assert values["workspace_custom_workspace"] == {:ref, "ws_1"}

      # Dates differ between the two runs: masked per field, verdicts never.
      assert Enum.map(alice.masks, &{&1.op, &1.kind, &1.pointer, &1.reason}) == [
               {"get.task_a", :values, "/Created Date", :differential},
               {"get.task_a", :values, "/Modified Date", :differential}
             ]

      assert :ok = Mask.check_class(alice.masks, :privacy)

      anon = by_id["privacy_read.custom.task.anonymous"]
      assert Enum.find(anon.observations, &(&1.kind == :record_set)).value.records == []

      # Only the kit's own workflows were called.
      workflows = for %{path: @prefix <> "wf/" <> name} <- log, uniq: true, do: name
      assert Enum.sort(workflows) == ~w(wtf_replay_login wtf_replay_signup)

      # Each run's journal is on disk and ends fully deleted.
      for run <- result.report.runs do
        assert {:ok, loaded} = Ledger.load(run.journal)
        assert Ledger.live(loaded) == [] and Ledger.unconfirmed(loaded) == []
      end
    end

    test "delete-after-seed leaves dangling references and reports what they calibrate" do
      fake = start_fake()
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice"), privacy_scenario(seed, "bob")]
      deps = %{{"privacy_read.custom.task.bob", "get.task_b"} => [:empty_equals_empty]}

      assert {:ok, result} =
               record(client(), seed, scenarios, delete_after_seed: ["ws_1"], dependencies: deps)

      [ledger | _] = result.ledgers
      assert %{state: :deleted} = Ledger.fetch(ledger, "ws_1")
      assert Ledger.live(ledger) == []

      ws_deletes =
        Enum.filter(requests(fake, "DELETE"), &String.contains?(&1.path, "/obj/workspace/"))

      assert length(ws_deletes) == 2

      calibration = Map.new(result.report.calibration, &{{&1.scenario, &1.op}, &1.flags})

      assert calibration[{"privacy_read.custom.task.alice", "get.task_a"}] == [
               :dangling_ref_is_empty
             ]

      assert calibration[{"privacy_read.custom.task.alice", "get.task_b"}] == [
               :dangling_ref_is_empty
             ]

      assert calibration[{"privacy_read.custom.task.bob", "search"}] == [:dangling_ref_is_empty]

      assert calibration[{"privacy_read.custom.task.bob", "get.task_b"}] == [
               :empty_equals_empty
             ]
    end

    test "record_matrix passes the Matrix dependencies" do
      start_fake()
      seed = seed()
      scenario = privacy_scenario(seed, "bob")
      deps = %{{scenario.id, "search"} => [:everyone_exclusive]}
      matrix = %{seed: seed, scenarios: [scenario], dependencies: deps}
      {:ok, plan} = Recorder.plan_matrix(client(), matrix, run_id: "m")

      assert {:ok, result} =
               Recorder.record_matrix(client(), matrix,
                 run_id: "m",
                 plan_sha256: plan.sha256,
                 ledger_dir: dir()
               )

      assert [%{op: "search", flags: [:everyone_exclusive]}] = result.report.calibration
    end

    test "refuses a recording that would carry a credential" do
      start_fake(quirks: [:leak])
      seed = seed()
      scenario = privacy_scenario(seed, "alice", [:visible, :values])
      assert {:ok, result} = record(client(), seed, [scenario])
      assert result.recordings == [] and result.files == []

      assert [%{scenario: "privacy_read.custom.task.alice", error: %{kind: :export_blocked}}] =
               result.report.refused
    end

    test "a budget that runs out mid-run gives incomplete recordings and still cleans up" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]
      {:ok, plan} = Recorder.plan(client(), seed, scenarios, run_id: "b")
      fake = start_fake(script: List.duplicate({"GET", "/obj/task", 429, []}, 6))
      c = client(max_calls: plan.calls, retry_base_delay: 1, max_retries: 6)

      assert {:ok, result} = record(c, seed, scenarios, run_id: "b")
      assert [%Recording{complete: false}] = result.recordings
      assert [%{why: why}] = result.report.incomplete
      assert why in [:budget_exhausted, :seeding_failed]
      assert %{error: %{reason: :budget_exhausted}} = List.last(result.report.runs)
      assert result.report.complete == []
      # Cleanup has its own allowance: nothing is left behind.
      assert FakeBubble.records(fake) == %{}
      assert result.report.leftovers == []
    end

    test "nothing is sent without a matching dry run, within budget, for supported ops" do
      fake = start_fake()
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]
      c = client()

      assert {:error, %Error{context: %{reason: :plan_not_confirmed}}} =
               Recorder.record(c, seed, scenarios, [])

      assert {:error, %Error{context: %{reason: :plan_not_confirmed}}} =
               Recorder.record(c, seed, scenarios, plan_sha256: String.duplicate("0", 64))

      {:ok, plan} = Recorder.plan(c, seed, scenarios)
      {:ok, other} = Recorder.plan(c, seed, scenarios, runs: 3)
      refute plan.sha256 == other.sha256

      assert {:error, %Error{context: %{reason: :over_budget}}} =
               Recorder.record(client(max_calls: 5), seed, scenarios,
                 plan_sha256:
                   elem(Recorder.plan(client(max_calls: 5), seed, scenarios), 1).sha256,
                 ledger_dir: dir()
               )

      assert {:error, %Error{context: %{reason: :no_ledger_dir}}} =
               Recorder.record(c, seed, scenarios, plan_sha256: plan.sha256)

      assert {:error, _} = Recorder.plan(c, seed, scenarios, runs: 1)

      {:ok, trigger} =
        Scenario.new(
          id: "workflow.x.alice",
          kind: :workflow,
          check: "workflow_side_effects",
          seed: %{id: seed.id, sha256: Seed.sha256(seed)},
          persona: "alice",
          ops: [%{id: "t", op: :trigger, workflow: "x", params: %{}, observe: [:db_diff]}],
          source_sha256: String.duplicate("7", 64)
        )

      assert {:error, %Error{message: message}} = Recorder.plan(c, seed, [trigger])
      assert message =~ "cannot record"

      # App API workflows are not replay-safe until V7: refused, whatever the auth.
      for auth <- [:admin, :persona, :none] do
        assert {:error, %Error{message: message}} =
                 Recorder.plan(c, seed, [api_scenario(seed, "echo_now", auth)])

        assert message =~ "V7"
      end

      assert {:error, _} = Recorder.plan(c, seed, scenarios, delete_after_seed: ["nope"])
      assert FakeBubble.log(fake) == []
    end

    test "the preflight blocks a branch without the kit before any write" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]

      for opts <- [
            [workflows: ~w(wtf_replay_signup)],
            [exposed: ~w(task user)],
            [meta: false]
          ] do
        fake = start_fake(opts)
        assert {:error, %Error{message: message}} = record(client(), seed, scenarios)
        assert message =~ "replay kit"
        assert Enum.all?(FakeBubble.log(fake), &(&1.method == "GET"))
      end
    end

    test "preflight reports each check" do
      start_fake(exposed: ~w(task user))

      assert {:ok, report} =
               Kit.preflight(client(), %Kit{}, ~w(custom.task custom.workspace user))

      refute report.ok?

      assert %{status: :missing} =
               Enum.find(report.checks, &(&1[:type] == "custom.workspace"))

      assert %{status: :ok} = Enum.find(report.checks, &(&1[:workflow] == "wtf_replay_login"))
      assert :privacy_rules_unchanged_from_parent in report.manual
    end
  end

  # --- differential masking --------------------------------------------------------------------

  # --- journal, crash safety, resume, unconfirmed entries ------------------------------------

  describe "journal and cleanup" do
    test "an intent is journaled (fsynced) before the create, and load rebuilds the ledger" do
      start_fake(script: [{"POST", "/obj/workspace", 502, []}])
      d = dir()
      ledger = ledger("j1", dir: d)
      c = client()

      assert {:ok, ledger} = Ledger.intend(ledger, "ws_1", "custom.workspace")
      assert {:ok, loaded} = Ledger.load(ledger.path)
      assert [%{key: "ws_1", state: :intended, id: nil}] = loaded.entries

      assert {:error, _} = Client.create(c, "custom.workspace", %{"Name" => "x"}, :admin)
      assert {:ok, id} = Client.create(c, "custom.workspace", %{"Name" => "x"}, :admin)
      assert {:ok, ledger} = Ledger.confirm(ledger, "ws_1", id)

      # A torn last line (a crash mid-write) is ignored.
      File.write!(ledger.path, ~s({"event":"del), [:append])
      assert {:ok, loaded} = Ledger.load(ledger.path)
      assert [%{key: "ws_1", state: :created, id: ^id}] = loaded.entries

      # Run IDs are never reused.
      assert {:error, _} = Ledger.new(target(), "j1", dir: d)
    end

    test "a create whose answer is lost stays unconfirmed and is reported, never searched" do
      fake = start_fake(script: [{"POST", "/obj/task", 502, []}])
      d = dir()
      seed = seed()

      assert {:ok, result} =
               record(client(), seed, [privacy_scenario(seed, "alice")], ledger_dir: d)

      assert [%{key: "task_a", type: "custom.task", id: nil, why: :unconfirmed}] =
               result.report.leftovers

      assert [%{error: %{kind: :http_error}}] = result.report.runs
      # Cleanup never searched tasks by anything but ledger IDs.
      refute Enum.any?(
               FakeBubble.log(fake),
               &((&1.query["constraints"] || "") =~ "equals" and &1.path =~ "task")
             )

      assert FakeBubble.records(fake) == %{}
    end

    test "a sign-up with a lost answer or an odd user_id is found by its exact run email and deleted" do
      for quirk <- [:lost_signup, :odd_user_id] do
        fake = start_fake(quirks: [quirk])
        seed = seed()
        assert {:ok, result} = record(client(), seed, [privacy_scenario(seed, "alice")])

        assert result.report.leftovers == []
        assert FakeBubble.records(fake) == %{}

        [lookup] =
          for %{path: @prefix <> "obj/user", query: q} <- FakeBubble.log(fake),
              q["constraints"] =~ "equals",
              do: Jason.decode!(q["constraints"])

        assert [%{"key" => "email", "constraint_type" => "equals", "value" => email}] = lookup
        assert email == "alice+t1-1@replay.wtf.invalid"
      end
    end

    test "a crash mid-run still cleans up, from the journal" do
      fake = start_fake(owner_records: [%{type: "workspace", fields: %{"Name" => "owner"}}])
      [owner_id] = Map.keys(FakeBubble.records(fake))
      seed = seed()

      progress = fn
        {:seeded, _} -> raise "boom"
        _ -> :ok
      end

      assert {:ok, result} =
               record(client(), seed, [privacy_scenario(seed, "alice")], progress: progress)

      assert [%{error: %{reason: :crashed}}] = result.report.runs
      assert [%Recording{complete: false}] = result.recordings
      assert Map.keys(FakeBubble.records(fake)) == [owner_id]
      assert result.report.leftovers == []
    end

    test "resume deletes only what a dead run's journal lists" do
      fake = start_fake(owner_records: [%{type: "task", fields: %{"Title" => "owner"}}])
      [owner_id] = Map.keys(FakeBubble.records(fake))
      d = dir()

      # The run dies after seeding (no cleanup ran).
      assert {:ok, state} = Seeder.seed(client(), seed(), ledger("dead", dir: d))
      assert map_size(FakeBubble.records(fake)) == 6

      {:ok, other} = Target.new("acme", "wtfreplay-2", @admin)
      {:ok, wrong} = Client.new(other, names: names())

      assert {:error, %Error{context: %{reason: :wrong_target}}} =
               Cleanup.resume(wrong, state.ledger.path)

      assert {:ok, %{leftovers: []}} = Cleanup.resume(client(), state.ledger.path)
      assert Map.keys(FakeBubble.records(fake)) == [owner_id]
      refute Enum.any?(requests(fake, "DELETE"), &(&1.path =~ owner_id))

      # Resuming again is harmless: nothing is live any more.
      assert {:ok, %{leftovers: []}} = Cleanup.resume(client(), state.ledger.path)
    end
  end

  describe "constrained searches" do
    test "an empty ID list makes no call; the preflight probes with an impossible ID" do
      fake = start_fake()
      assert {:ok, []} = Client.search(client(), "custom.task", :admin, ids: [])
      assert FakeBubble.log(fake) == []

      assert {:error, _} = Client.search(client(), "custom.task", :admin, [])

      assert {:ok, :exposed} = Client.probe(client(), "custom.task")
      [%{query: q}] = FakeBubble.log(fake)
      assert [%{"value" => ["0x0"]}] = Jason.decode!(q["constraints"])
    end

    test "a search Bubble does not constrain stops at the first page" do
      fake =
        start_fake(
          quirks: [:ignore_constraints],
          owner_records: [%{type: "task", fields: %{"Title" => "owner"}}]
        )

      assert {:error, %Error{context: %{reason: :constraint_ignored}}} =
               Client.probe(client(), "custom.task")

      assert {:error, %Error{context: %{reason: :constraint_ignored}}} =
               Client.search(client(page_size: 1), "custom.task", :admin, ids: ["1x1"])

      assert length(FakeBubble.log(fake)) == 2
    end
  end

  defp obs(op, kind, record, value),
    do: %Observation{op: op, kind: kind, record: record, value: value}

  describe "Differential" do
    test "differing verdicts are unstable, differing values are masked per field" do
      a = [
        obs("g", :visible, "r", true),
        obs("g", :values, "r", %{"t" => {:text, "x"}, "d" => {:date, 1}})
      ]

      b = [
        obs("g", :visible, "r", false),
        obs("g", :values, "r", %{"t" => {:text, "x"}, "d" => {:date, 2}})
      ]

      merged = Differential.merge([a, b], :privacy)
      assert [%{op: "g", kind: :visible, why: :verdict_differs}] = merged.unstable
      assert [%Mask{pointer: "/d", reason: :differential, kind: :values}] = merged.masks
      assert Differential.masked_share(merged) == 0.5
    end

    test "elsewhere the differing leaves are masked, a differing root is unstable" do
      a = [obs("c", :response, nil, %{"x" => [1, %{"id" => "a"}]}), obs("c", :status, nil, 200)]
      b = [obs("c", :response, nil, %{"x" => [1, %{"id" => "b"}]}), obs("c", :status, nil, 500)]
      merged = Differential.merge([a, b], :behavior)
      assert [%Mask{pointer: "/x/1/id"}] = merged.masks
      assert [%{kind: :status, why: :whole_value_differs}] = merged.unstable

      assert [%{why: :missing_in_a_run}] =
               Differential.merge([a, tl(a)], :behavior).unstable
    end

    test "in privacy scenarios a field seen in one run only, or any other kind, is unstable" do
      a = [obs("g", :values, "r", %{"t" => {:text, "x"}, "s" => {:text, "secret"}})]
      b = [obs("g", :values, "r", %{"t" => {:text, "x"}})]
      merged = Differential.merge([a, b], :privacy)
      assert merged.masks == []
      assert [%{why: :field_visibility_differs}] = merged.unstable

      a = [obs("c", :response, nil, %{"count" => 1})]
      b = [obs("c", :response, nil, %{"count" => 2})]
      assert [%{why: :not_maskable_in_class}] = Differential.merge([a, b], :privacy).unstable
      assert [%Mask{pointer: "/count"}] = Differential.merge([a, b], :behavior).masks
    end

    test "pointers are escaped" do
      assert Differential.diff(%{"a/b" => 1, "c~" => 1}, %{"a/b" => 2, "c~" => 2}, "") ==
               ["/a~1b", "/c~0"]
    end
  end
end
