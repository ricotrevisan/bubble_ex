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
    ExposureWaiver,
    Kit,
    Ledger,
    Names,
    Recorder,
    Seeder,
    Session,
    Target
  }

  @admin FakeBubble.admin_token()
  @branch_id FakeBubble.branch_id()
  @nonce FakeBubble.marker_nonce()
  @t [branch_id: FakeBubble.branch_id(), marker_nonce: FakeBubble.marker_nonce()]
  @prefix "/version-#{FakeBubble.branch_id()}/api/1.1/"

  # --- fixtures ------------------------------------------------------------------------

  defp start_fake(opts \\ []) do
    fake = FakeBubble.start(opts)
    HTTP.put_process_options(plug: FakeBubble.plug(fake))
    on_exit(fn -> HTTP.delete_process_options() end)
    fake
  end

  defp target(opts \\ []) do
    {:ok, t} =
      Target.new(
        "acme",
        "wtfreplay",
        @admin,
        [branch_id: @branch_id, marker_nonce: FakeBubble.marker_nonce()] ++ opts
      )

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

  # Transport tests start from a client whose target is already verified
  # (set directly, so no marker call pollutes their logs or budgets); the
  # verification itself is tested with `verified: false` and through the
  # recorder, whose preflight always verifies.
  defp client(opts \\ []) do
    {verified, opts} = Keyword.pop(opts, :verified, true)
    {target_opts, opts} = Keyword.pop(opts, :target, [])

    {:ok, c} =
      Client.new(
        target(target_opts),
        [names: names(), sleep: fn ms -> send(self(), {:slept, ms}) end] ++ opts
      )

    if verified, do: :atomics.put(c.verified, 1, 1)
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

  # The fake's privacy hides tasks and users from logged-out callers
  # (proven), and shows workspaces to everyone: an empty fake has no owner
  # workspace to show, so the tests accept that type unproven.
  @anonymous [
    anonymous_proof: %{"task" => :hidden, "user" => :hidden},
    allow_unproven: ["custom.workspace"]
  ]

  defp record(client, seed, scenarios, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:run_id, "t1")
      |> Keyword.put_new_lazy(:ledger_dir, &dir/0)
      |> then(&Keyword.merge(@anonymous, &1))

    {:ok, plan} = Recorder.plan(client, seed, scenarios, opts)
    Recorder.record(client, seed, scenarios, [plan_sha256: plan.sha256] ++ opts)
  end

  defp requests(fake, method), do: Enum.filter(FakeBubble.log(fake), &(&1.method == method))

  # Reads, and the tokenless marker check: nothing that could write.
  defp read_only?(fake) do
    Enum.all?(FakeBubble.log(fake), fn e ->
      e.method == "GET" or (e.path == @prefix <> "wf/wtf_replay_marker" and e.auth == nil)
    end)
  end

  # --- the guard --------------------------------------------------------------------------

  describe "Names" do
    test "option values go to the Data API as display text and come back as keys" do
      {:ok, names} =
        Names.new(
          types: %{"custom.ev" => "ev"},
          fields: %{"custom.ev" => %{"status_os" => "Status"}},
          options: %{"custom.ev" => %{"status_os" => %{"sent" => "Sent", "done" => "Done"}}}
        )

      assert {:ok, {:option, "Sent"}} =
               Names.to_api(names, "custom.ev", "status_os", {:option, "sent"})

      assert {:ok, {:list, [{:option, "Done"}, {:option, "Sent"}]}} =
               Names.to_api(
                 names,
                 "custom.ev",
                 "status_os",
                 {:list, [{:option, "done"}, {:option, "sent"}]}
               )

      assert {:option, "sent"} =
               Names.from_api(names, "custom.ev", "status_os", {:option, "Sent"})

      assert {:error, %Error{context: %{reason: :unknown_option}}} =
               Names.to_api(names, "custom.ev", "status_os", {:option, "nope"})

      # Non-option values pass through.
      assert {:ok, {:text, "x"}} = Names.to_api(names, "custom.ev", "other", {:text, "x"})

      # An option with no mapping is an error to send, and a display text
      # the model does not know is a mismatch, never passed on as a key.
      assert {:error, %Error{context: %{reason: :unmapped_option_field}}} =
               Names.to_api(names, "custom.ev", "other", {:option, "k"})

      assert {:json, %{"unmapped_option" => true}} =
               Names.from_api(names, "custom.ev", "status_os", {:option, "Unknown"})

      assert {:json, %{"unmapped_option" => true}} =
               Names.from_api(names, "custom.ev", "other", {:option, "Other"})

      assert {:list, [{:option, "done"}, {:json, %{"unmapped_option" => true}}]} =
               Names.from_api(
                 names,
                 "custom.ev",
                 "status_os",
                 {:list, [{:option, "Done"}, {:option, "?"}]}
               )
    end

    test "an option field whose display texts repeat has no mapping, so sending it fails" do
      {:ok, names} = Names.new(options: %{"custom.ev" => %{"dup_os" => :ambiguous}})

      assert {:error, %Error{context: %{reason: :ambiguous_option_field}}} =
               Names.to_api(names, "custom.ev", "dup_os", {:option, "a"})

      assert {:json, %{"unmapped_option" => true}} =
               Names.from_api(names, "custom.ev", "dup_os", {:option, "A"})
    end
  end

  describe "Target" do
    test "accepts an app ID and a wtfreplay branch only" do
      for branch <- ~w(wtfreplay wtfreplay-2 wtfreplay_v5) do
        assert {:ok, %Target{branch: ^branch}} =
                 Target.new("acme", branch, @admin, @t)
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
                 Target.new("acme", branch, @admin, @t),
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
                 Target.new(app, "wtfreplay", @admin, @t),
               "accepted app #{inspect(app)}"
      end

      for token <- [nil, "", "short", "has a space in it", "tab\there-012345"] do
        assert {:error, %Error{kind: :invalid_input}} =
                 Target.new("acme", "wtfreplay", token, @t)
      end
    end

    test "URLs use the operator-supplied branch ID; live and test are refused" do
      assert {:error, %Error{context: %{reason: :missing_branch_id}}} =
               Target.new("acme", "wtfreplay", @admin)

      for id <- ~w(4k2xq 1a2b 7qz0p abcdef123456 0000a) do
        assert {:ok, %Target{branch: "wtfreplay", branch_id: ^id}} =
                 Target.new("acme", "wtfreplay", @admin, branch_id: id, marker_nonce: @nonce)
      end

      for id <- [
            "live",
            "test",
            "version-test",
            "version-live",
            "version-4k2xq",
            "wtfreplay",
            "abcd",
            "12345",
            "03124",
            "abcdef",
            "4K2XQ",
            "4k2",
            "4k2xq/../live",
            "4k2xq ",
            "4k2%2F",
            String.duplicate("1", 13),
            "",
            nil,
            :live,
            12_345
          ] do
        assert {:error, %Error{context: %{reason: :not_a_branch_id}}} =
                 Target.new("acme", "wtfreplay", @admin, branch_id: id, marker_nonce: @nonce),
               "accepted branch ID #{inspect(id)}"
      end

      t = target()
      assert Target.api_root(t) == "https://acme.bubbleapps.io/version-#{@branch_id}/api/1.1"
    end

    test "an owner-confirmed custom host replaces bubbleapps.io, exactly" do
      t = target(host: "beta.example.com")
      assert t.host == "beta.example.com"
      root = "https://beta.example.com/version-#{@branch_id}/api/1.1"
      assert Target.api_root(t) == root
      assert :ok = Target.check_url(t, root <> "/obj/task?limit=1")

      for url <- [
            "https://acme.bubbleapps.io/version-#{@branch_id}/api/1.1/obj/task",
            "https://beta.example.com.evil.com/version-#{@branch_id}/api/1.1/obj/task",
            "https://evil.beta.example.com/version-#{@branch_id}/api/1.1/obj/task",
            "https://beta.example.com:8443/version-#{@branch_id}/api/1.1/obj/task",
            "https://beta.example.com:443/version-#{@branch_id}/api/1.1/obj/task",
            "http://beta.example.com/version-#{@branch_id}/api/1.1/obj/task",
            "https://BETA.example.com/version-#{@branch_id}/api/1.1/obj/task",
            "https://beta.example.com/version-live/api/1.1/obj/task",
            "https://beta.example.com/api/1.1/obj/task"
          ] do
        assert {:error, %Error{context: %{reason: :outside_replay_branch}}} =
                 Target.check_url(t, url),
               "accepted #{inspect(url)}"
      end

      assert target(host: "acme.bubbleapps.io").host == "acme.bubbleapps.io"

      for host <- [
            "https://beta.example.com",
            "beta.example.com/",
            "beta.example.com:443",
            "Beta.example.com",
            "beta.example.com.",
            "localhost",
            "127.0.0.1",
            "10.0.0.8",
            "[::1]",
            "0x7f.1",
            "other.bubbleapps.io",
            "bubbleapps.io",
            "acme.bubble.io",
            "bubble.io",
            "user@beta.example.com",
            "beta example.com",
            "",
            nil
          ] do
        assert {:error, %Error{context: %{reason: :not_a_replay_host}}} =
                 Target.new("acme", "wtfreplay", @admin, @t ++ [host: host]),
               "accepted host #{inspect(host)}"
      end

      refute inspect(t) =~ @admin
      assert inspect(t) =~ "beta.example.com"
    end

    test "builds branch URLs from validated segments only" do
      t = target()
      root = "https://acme.bubbleapps.io/version-#{@branch_id}/api/1.1"
      assert Target.api_root(t) == root
      assert {:ok, root <> "/obj/task"} == Target.data_url(t, "task")
      assert {:ok, root <> "/obj/task/1700x12"} == Target.data_url(t, "task", "1700x12")
      assert {:ok, root <> "/wf/wtf_replay_login"} == Target.workflow_url(t, "wtf_replay_login")

      for bad <- [
            "../live",
            "task/../x",
            "Task",
            "",
            "task?x=1",
            "a%2Fb",
            ".",
            "..",
            "a b",
            "a#b"
          ] do
        assert {:error, _} = Target.data_url(t, bad)
      end

      # Bubble's type paths keep dots, colons and emoji (`/meta`'s `get`).
      assert {:ok, root <> "/obj/00.thing-join"} == Target.data_url(t, "00.thing-join")
      assert {:ok, root <> "/obj/%F0%9F%92%AC" <> "workspace"} == Target.data_url(t, "💬workspace")
      assert {:ok, url} = Target.data_url(t, "🪄mq:answers", "1700x12")
      assert :ok = Target.check_url(t, url)
      # Emoji sequences keep their joiner and variation selector.
      assert {:ok, _} = Target.data_url(t, "\u{1F468}\u200D\u{1F469}x")
      assert {:ok, _} = Target.data_url(t, "\u{1F399}\uFE0Fmsgs")

      # Look-alikes of separators and dots, bidi overrides, zero-width and
      # other invisible or non-NFKC characters are refused.
      for bad <- [
            "a\uFF0Fb",
            "a\uFF0Eb",
            "\uFF0E\uFF0E",
            "a\u2215b",
            "a\u2044b",
            "a\u202Eb",
            "a\u200Bb",
            "a\u2060b",
            "a\uFEFFb",
            "\uFF41bc",
            "a\u00A0b",
            "a\u0000b",
            "a\uE000b"
          ] do
        assert {:error, %Error{context: %{reason: :invalid_segment}}} = Target.data_url(t, bad),
               "accepted #{inspect(bad)}"
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
            "https://acme.bubbleapps.io/version-wtfreplay/api/1.1/obj/task",
            "https://acme.bubbleapps.io/version-#{@branch_id}x/api/1.1/obj/task",
            "https://other.bubbleapps.io/version-#{@branch_id}/api/1.1/obj/task",
            "https://acme.bubbleapps.io/version-#{@branch_id}/api/1.1/../../version-live/api/1.1/obj/x",
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
    test "a record answered with its ID only is hidden, as Bubble answers privacy-hidden records" do
      start_fake()
      c = client()
      assert {:ok, id} = Client.create(c, "custom.task", %{"Title" => "t"}, :admin)
      assert {:ok, {:found, %{"Title" => "t"}}} = Client.get(c, "custom.task", id, :admin)
      # The fake's tasks are hidden from logged-out callers: 200 with `_id` only.
      assert {:ok, :not_found} = Client.get(c, "custom.task", id, :none)
    end

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
    @tag :tmp_dir
    test "the journal and its directory are owner-only", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "ledgers/nested")
      {:ok, ledger} = Ledger.new(target(), "perm", dir: dir)
      {:ok, _} = Ledger.intend(ledger, "k", "custom.task")
      assert {:ok, %File.Stat{mode: mode}} = File.stat(ledger.path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert {:ok, %File.Stat{mode: dmode}} = File.stat(dir)
      assert Bitwise.band(dmode, 0o777) == 0o700

      # An existing, group-readable directory is made owner-only.
      open = Path.join(tmp, "open")
      File.mkdir_p!(open)
      File.chmod!(open, 0o755)
      assert {:ok, _} = Ledger.new(target(), "perm", dir: open)
      assert {:ok, %File.Stat{mode: omode}} = File.stat(open)
      assert Bitwise.band(omode, 0o777) == 0o700
    end

    @tag :tmp_dir
    test "a journal is created exclusively: an existing file or link is never reused",
         %{tmp_dir: tmp} do
      dir = Path.join(tmp, "ledgers")
      assert {:ok, _} = Ledger.new(target(), "once", dir: dir)
      assert {:error, %Error{message: message}} = Ledger.new(target(), "once", dir: dir)
      assert message =~ "already exists"

      elsewhere = Path.join(tmp, "elsewhere.jsonl")
      File.write!(elsewhere, "")
      :ok = File.ln_s(elsewhere, Path.join(dir, "link.jsonl"))
      assert {:error, _} = Ledger.new(target(), "link", dir: dir)
      assert File.read!(elsewhere) == ""
    end

    @tag :tmp_dir
    test "a directory that cannot be made owner-only refuses the run", %{tmp_dir: tmp} do
      file = Path.join(tmp, "file")
      File.write!(file, "")

      assert {:error, %Error{context: %{reason: :ledger_write_failed}}} =
               Ledger.new(target(), "x", dir: Path.join(file, "sub"))
    end

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

  describe "creator: :admin_field" do
    test "persona-created records are made as admin with an explicit Created By, same recordings" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice"), privacy_scenario(seed, "bob")]

      start_fake()
      assert {:ok, by_token} = record(client(), seed, scenarios)

      fake = start_fake(quirks: [:refuse_user_create])
      d = dir()

      assert {:ok, by_admin} =
               record(client(), seed, scenarios, creator: :admin_field, ledger_dir: d)

      # No create carried a persona's token; the tasks named their creator.
      creates =
        for %{method: "POST", path: @prefix <> "obj/" <> _} = e <- FakeBubble.log(fake), do: e

      assert creates != [] and Enum.all?(creates, &(&1.auth == "Bearer " <> @admin))

      assert Enum.count(creates, &(&1.path == @prefix <> "obj/task")) == 4

      assert by_admin.report.complete |> Enum.sort() == by_token.report.complete |> Enum.sort()
      assert by_admin.report.leftovers == []
      assert FakeBubble.records(fake) == %{}

      obs = fn r -> Map.new(r.recordings, &{&1.scenario.id, &1.observations}) end
      assert obs.(by_admin) == obs.(by_token)

      # Journaled: seed keys only, never an ID or email.
      [journal | _] = Path.wildcard(Path.join(d, "*.jsonl")) |> Enum.sort()

      events =
        journal |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert [
               %{"event" => "creator", "key" => "task_a", "user" => "user_a", "ok" => true},
               %{"event" => "creator", "key" => "task_b", "user" => "user_b", "ok" => true}
             ] = Enum.filter(events, &(&1["event"] == "creator"))

      refute File.read!(journal) =~ "\"Created By\""
    end

    test "a Created By Bubble does not store stops seeding and cleans up" do
      fake = start_fake(quirks: [:ignore_created_by])
      seed = seed()

      assert {:ok, result} =
               record(client(), seed, [privacy_scenario(seed, "alice")], creator: :admin_field)

      assert [%{error: %{reason: :creator_not_set, type: "custom.task"}} | _] = result.report.runs
      assert result.report.complete == []
      assert result.report.leftovers == []
      assert FakeBubble.records(fake) == %{}
    end

    test "the creator mode is validated and part of the plan hash" do
      start_fake()
      seed = seed()
      s = [privacy_scenario(seed, "alice")]
      c = client()
      opts = Keyword.merge(@anonymous, run_id: "t1")

      assert {:ok, token} = Recorder.plan(c, seed, s, opts)
      assert {:ok, admin} = Recorder.plan(c, seed, s, [creator: :admin_field] ++ opts)
      assert token.sha256 != admin.sha256
      # One read-back per persona-created record, per run.
      assert admin.calls == token.calls + 2 * 2

      assert {:error, %Error{kind: :invalid_input}} =
               Recorder.plan(c, seed, s, [creator: :both] ++ opts)
    end
  end

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

      # Searches were constrained to the run's own records; the only
      # unconstrained read is the preflight's anonymous probe (no token).
      for %{method: "GET", path: @prefix <> "obj/task", query: q, auth: auth} <- log,
          q["constraints"] != nil or auth != nil do
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

        assert rec.source == %{
                 app: "acme",
                 branch: "wtfreplay",
                 branch_id: @branch_id,
                 host: "acme.bubbleapps.io",
                 app_version: nil
               }

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
      assert Enum.sort(workflows) == ~w(wtf_replay_login wtf_replay_marker wtf_replay_signup)

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

    test "explicit empties are cleared after creation, journaled, and a refused clear makes dependents incomplete" do
      {:ok, seed} =
        Seed.new(
          id: "empties",
          personas: %{"alice" => %{user: "user_a"}},
          records: [
            %{
              key: "user_a",
              type: "user",
              fields: %{
                "email" => {:text, "alice@replay.wtf.invalid"},
                "workspace_custom_workspace" => {:ref, "ws_1"}
              }
            },
            %{key: "ws_1", type: "custom.workspace", fields: %{"name_text" => {:text, "W1"}}},
            %{
              key: "task_a",
              type: "custom.task",
              fields: %{"Created By" => {:ref, "user_a"}, "title_text" => nil}
            },
            %{
              key: "task_b",
              type: "custom.task",
              fields: %{"Created By" => {:ref, "user_a"}, "title_text" => {:text, "B"}}
            }
          ]
        )

      tasks = privacy_scenario(seed, "alice", [:visible, :visible_fields, :values])

      {:ok, workspace} =
        Scenario.new(
          id: "privacy_read.custom.workspace.alice",
          kind: :privacy_read,
          check: "privacy_read",
          seed: %{id: seed.id, sha256: Seed.sha256(seed)},
          persona: "alice",
          subjects: %{type: "custom.workspace"},
          ops: [
            %{
              id: "get.ws_1",
              op: :get,
              type: "custom.workspace",
              record: "ws_1",
              observe: [:visible]
            }
          ],
          source_sha256: String.duplicate("7", 64)
        )

      defaults = %{"task" => %{"Title" => "untitled"}}

      # Bubble stores the default; the driver clears it, ledger-keyed.
      fake = start_fake(defaults: defaults)
      d = dir()
      assert {:ok, result} = record(client(), seed, [tasks, workspace], ledger_dir: d)
      assert result.report.incomplete == []

      alice = Enum.find(result.recordings, &(&1.scenario.id == tasks.id))

      fields =
        Enum.find(alice.observations, &(&1.kind == :visible_fields and &1.record == "task_a"))

      refute "title_text" in fields.value

      clears = for %{method: "PATCH", body: %{"Title" => nil}} = e <- FakeBubble.log(fake), do: e
      assert length(clears) == 2

      events =
        for run <- result.report.runs,
            line <- run.journal |> File.read!() |> String.split("\n", trim: true),
            event = Jason.decode!(line),
            event["event"] == "cleared",
            do: event

      assert [%{"key" => "task_a", "fields" => ["title_text"], "ok" => true}, _] = events
      assert FakeBubble.records(fake) == %{}

      # A refused clear: the task scenario reads task_a, so it is incomplete;
      # the workspace scenario does not depend on it and records.
      fake = start_fake(defaults: defaults, quirks: [:refuse_clear])
      assert {:ok, result} = record(client(), seed, [tasks, workspace])
      assert [%{scenario: id, why: :clear_failed}] = result.report.incomplete
      assert id == tasks.id
      assert result.report.complete == [workspace.id]
      assert Enum.all?(result.report.runs, &(&1.uncleared == %{"task_a" => ["title_text"]}))
      assert result.report.leftovers == []
      assert FakeBubble.records(fake) == %{}
    end

    test "record_matrix passes the Matrix dependencies" do
      start_fake()
      seed = seed()
      scenario = privacy_scenario(seed, "bob")
      deps = %{{scenario.id, "search"} => [:everyone_exclusive]}
      matrix = %{seed: seed, scenarios: [scenario], dependencies: deps}
      {:ok, plan} = Recorder.plan_matrix(client(), matrix, [run_id: "m"] ++ @anonymous)

      assert {:ok, result} =
               Recorder.record_matrix(
                 client(),
                 matrix,
                 [run_id: "m", plan_sha256: plan.sha256, ledger_dir: dir()] ++ @anonymous
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
      opts = [run_id: "b", anonymous_cap: 100] ++ @anonymous
      {:ok, plan} = Recorder.plan(client(), seed, scenarios, opts)
      fake = start_fake(script: List.duplicate({"GET", "/obj/task", 429, []}, 6))
      c = client(max_calls: plan.calls, retry_base_delay: 1, max_retries: 6)

      assert {:ok, result} = record(c, seed, scenarios, opts)
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
            [workflows: ~w(wtf_replay_marker wtf_replay_signup)],
            [exposed: ~w(task user)],
            [workflows: ~w(wtf_replay_signup wtf_replay_login)],
            [meta: false]
          ] do
        fake = start_fake(opts)
        assert {:error, %Error{message: message}} = record(client(), seed, scenarios)
        assert message =~ "replay kit" or message =~ "did not prove it is the replay branch"
        assert read_only?(fake)
      end
    end

    test "preflight reports each check" do
      start_fake(exposed: ~w(task user))

      assert {:ok, report} =
               Kit.preflight(client(), %Kit{}, ~w(custom.task custom.workspace user),
                 personas: true
               )

      refute report.ok?

      assert %{status: :missing} =
               Enum.find(report.checks, &(&1[:type] == "custom.workspace"))

      assert %{status: :ok} = Enum.find(report.checks, &(&1[:workflow] == "wtf_replay_login"))
      assert :privacy_rules_unchanged_from_parent in report.manual
    end

    test "the sign-up and login workflows are needed only for a seed with users" do
      start_fake(workflows: ~w(wtf_replay_marker))

      assert {:ok, report} = Kit.preflight(client(), %Kit{}, ~w(custom.task), personas: true)

      assert %{status: :missing} =
               Enum.find(report.checks, &(&1[:workflow] == "wtf_replay_signup"))

      assert {:ok, report} = Kit.preflight(client(), %Kit{}, ~w(custom.task))
      refute Enum.any?(report.checks, &Map.has_key?(&1, :workflow))
    end

    test "the anonymous exposure probe refuses a type that shows a logged-out visitor fields" do
      # The fake's workspaces are visible to everyone: an owner workspace
      # with a name leaks it to anonymous callers once the type is exposed.
      fake =
        start_fake(
          owner_records: [
            %{type: "workspace", fields: %{"Name" => "owner-private-name"}},
            %{type: "task", fields: %{"Title" => "owner-task"}}
          ]
        )

      seed = seed()

      assert {:error, %Error{context: %{preflight: checks}}} =
               record(client(), seed, [privacy_scenario(seed, "alice")])

      assert %{status: :exposed, extra_fields: ["Name"], records: 1} =
               Enum.find(
                 checks,
                 &(&1[:check] == :anonymous_exposure and &1.type == "custom.workspace")
               )

      assert %{status: :ok, anonymous: :proven_hidden, records: 0} =
               Enum.find(
                 checks,
                 &(&1[:check] == :anonymous_exposure and &1.type == "custom.task")
               )

      # Names and counts only: no value or ID reaches the report, and nothing was written.
      refute inspect(checks) =~ "owner-private-name"
      refute inspect(checks) =~ ~r/\d+x\d+/
      assert read_only?(fake)

      anonymous =
        for %{auth: nil, path: @prefix <> "obj/" <> _, query: q} = e <- FakeBubble.log(fake),
            q["constraints"] == nil,
            do: e

      assert anonymous != []
      assert Enum.all?(anonymous, &(&1.query["limit"] == "100"))
    end

    test "IDs and dates alone pass only when the metadata lists no other field, or with a proof" do
      only_ids = %{"workspace" => %{"fields" => ["_id", "Created Date", "Modified Date"]}}
      with_name = %{"workspace" => %{"fields" => [%{"key" => "Name"}, %{"key" => "_id"}]}}
      check = fn report -> Enum.find(report.checks, &(&1[:check] == :anonymous_exposure)) end

      # An empty field is omitted by Bubble: a record with no value shows nothing.
      start_fake(owner_records: [%{type: "workspace", fields: %{}}], meta_types: only_ids)
      assert {:ok, report} = Kit.preflight(client(), %Kit{}, ~w(custom.workspace))
      assert report.ok?
      assert %{status: :ok, anonymous: :ids_only, records: 1, remaining: 0} = check.(report)

      for types <- [with_name, nil] do
        start_fake(owner_records: [%{type: "workspace", fields: %{}}], meta_types: types)
        assert {:ok, report} = Kit.preflight(client(), %Kit{}, ~w(custom.workspace))
        refute report.ok?
        assert %{status: :may_leak} = check.(report)

        # allow_unproven does not cover a type a logged-out caller can see.
        assert {:ok, report} =
                 Kit.preflight(client(), %Kit{}, ~w(custom.workspace),
                   allow_unproven: ["custom.workspace"]
                 )

        assert %{status: :may_leak} = check.(report)

        assert {:ok, report} =
                 Kit.preflight(client(), %Kit{}, ~w(custom.workspace),
                   anonymous_proof: %{"workspace" => :hidden}
                 )

        assert %{status: :ok, anonymous: :proven_hidden} = check.(report)
      end
    end

    test "reads Bubble's metadata field objects, by display name or ID as the Data API keys them" do
      # Bubble lists `%{id, display, type}` objects, built-in fields included,
      # `_id` as `unique ID` (WTF-385).
      builtin = fn names -> Enum.map(names, &%{"id" => &1, "display" => &1, "type" => "text"}) end
      unique_id = %{"id" => "_id", "display" => "unique ID", "type" => "text"}

      ids_only = %{
        "workspace" => %{
          "display" => "Workspace",
          "fields" => [unique_id | builtin.(["Created Date", "Modified Date"])]
        }
      }

      with_name = %{
        "workspace" => %{
          "display" => "Workspace",
          "fields" =>
            [unique_id | builtin.(["Created Date"])] ++
              [%{"id" => "name_text", "display" => "Name", "type" => "text"}]
        }
      }

      # A field of the app displayed "unique ID" is a real field, not `_id`.
      impostor = %{
        "workspace" => %{
          "display" => "Workspace",
          "fields" =>
            [unique_id | builtin.(["Created Date", "Modified Date"])] ++
              [%{"id" => "unique_id_text", "display" => "unique ID", "type" => "text"}]
        }
      }

      check = fn ->
        Enum.find(
          elem(Kit.preflight(client(), %Kit{}, ~w(custom.workspace)), 1).checks,
          &(&1[:check] == :anonymous_exposure)
        )
      end

      for captions <- [true, false] do
        start_fake(
          owner_records: [%{type: "workspace", fields: %{}}],
          meta_types: ids_only,
          captions: captions
        )

        assert %{status: :ok, anonymous: :ids_only} = check.()

        start_fake(
          owner_records: [%{type: "workspace", fields: %{}}],
          meta_types: with_name,
          captions: captions
        )

        assert %{status: :may_leak} = check.()

        start_fake(
          owner_records: [%{type: "workspace", fields: %{}}],
          meta_types: impostor,
          captions: captions
        )

        assert %{status: :may_leak} = check.()
      end
    end

    test "no record for a logged-out caller is unproven unless proven or accepted, with a warning" do
      start_fake()
      assert {:ok, report} = Kit.preflight(client(), %Kit{}, ~w(custom.workspace))
      refute report.ok?

      assert %{status: :unproven, anonymous: :no_records, records: 0} =
               Enum.find(report.checks, &(&1[:check] == :anonymous_exposure))

      assert {:ok, report} =
               Kit.preflight(client(), %Kit{}, ~w(custom.workspace),
                 allow_unproven: ["custom.workspace"]
               )

      assert report.ok?
      assert [%{type: "custom.workspace", warning: warning}] = report.warnings
      assert warning =~ "unproven"
    end

    test "the anonymous probe pages up to its cap and reports it" do
      owners = for _ <- 1..230, do: %{type: "workspace", fields: %{}}
      fake = start_fake(owner_records: owners)

      assert {:ok, %{status: :answered, records: 150, remaining: 80, capped: true}} =
               Client.anonymous_probe(client(), "custom.workspace", 150)

      assert {:ok, %{records: 230, remaining: 0, capped: false, extra_fields: []}} =
               Client.anonymous_probe(client(), "custom.workspace", 1000)

      pages = for %{auth: nil, query: q} <- FakeBubble.log(fake), do: {q["cursor"], q["limit"]}
      assert pages == [{"0", "100"}, {"100", "50"}, {"0", "100"}, {"100", "100"}, {"200", "100"}]
    end

    test "anonymous_proof proves only types whose every rule grants nothing" do
      rule = fn perms -> %{permissions: struct(BubbleEx.Privacy.Permissions, perms)} end
      nothing = rule.(view_all: false, search_for: false, view_fields: [])

      model = %{
        data_types: [
          %{id: "a", privacy: :present, rules: [nothing, nothing]},
          %{id: "b", privacy: :present, rules: [nothing, rule.(view_fields: ["f"])]},
          %{id: "c", privacy: :present, rules: [rule.(search_for: true)]},
          %{id: "d", privacy: :none, rules: []},
          %{id: "e", privacy: :present, rules: [%{permissions: nil}]},
          %{id: "user", privacy: :present, rules: [nothing]}
        ]
      }

      assert Kit.anonymous_proof(model) == %{"a" => :hidden, "user" => :hidden}
    end

    test "no token reaches a host that is not the replay branch" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]

      for {fake_opts, step} <- [
            {[impostor: true], :meta},
            {[host: "acme.example.com", impostor: true], :meta},
            {[marker_nonce: "another-nonce-0123456789"], :marker},
            {[marker_branch: "wtfreplay-2"], :marker},
            {[workflows: ~w(wtf_replay_signup wtf_replay_login)], :marker}
          ] do
        fake = start_fake(fake_opts)
        target = Keyword.take(fake_opts, [:host])

        assert {:error, %Error{context: %{reason: :unverified_target, step: ^step}}} =
                 record(client(verified: false, target: target), seed, scenarios)

        assert FakeBubble.log(fake) != []
        assert Enum.all?(FakeBubble.log(fake), &(&1.auth == nil)), inspect(fake_opts)
        refute Enum.any?(FakeBubble.log(fake), &(&1.path =~ "/obj/"))
      end
    end

    test "an unverified client sends no token at all, before any wire attempt" do
      fake = start_fake()
      c = client(verified: false)

      for call <- [
            fn -> Client.meta(c) end,
            fn -> Client.create(c, "custom.workspace", %{"Name" => "x"}, :admin) end,
            fn -> Client.search(c, "custom.task", {:user, "tok-0123456789"}, ids: ["1x2"]) end,
            fn -> Client.call_kit(c, %Kit{}, :signup, %{}) end
          ] do
        assert {:error, %Error{context: %{reason: :unverified_target}}} = call.()
      end

      assert FakeBubble.log(fake) == []
      assert Client.calls(c) == 0
      assert {:ok, %{"get" => _}} = Client.verify(c, %Kit{})
      assert Client.verified?(c)
      assert {:ok, %{status: 200}} = Client.meta(c)
    end

    test "persona seeding needs a safely exposed User Data API; logged-out only does not" do
      seed = seed()

      fake = start_fake(exposed: ~w(task workspace))

      assert {:error, %Error{context: %{preflight: checks}}} =
               record(client(), seed, [privacy_scenario(seed, "alice")])

      assert %{status: :missing, detail: detail} =
               Enum.find(checks, &(&1[:check] == :persona_cleanup))

      assert detail =~ "logged-out"
      assert read_only?(fake)

      assert {:ok, %{ok?: true, checks: checks}} =
               Kit.preflight(client(), %Kit{}, ~w(custom.task custom.workspace), @anonymous)

      refute Enum.any?(checks, &(&1[:check] == :persona_cleanup))

      # A seed without users records logged-out, with User not exposed.
      {:ok, anon_seed} =
        Seed.new(
          id: "logged_out",
          personas: %{"anonymous" => %{user: nil}},
          records: [
            %{key: "ws_1", type: "custom.workspace", fields: %{"name_text" => {:text, "W1"}}},
            %{key: "task_a", type: "custom.task", fields: %{"title_text" => {:text, "A"}}},
            %{key: "task_b", type: "custom.task", fields: %{"title_text" => {:text, "B"}}}
          ]
        )

      fake = start_fake(exposed: ~w(task workspace))

      assert {:ok, result} =
               record(client(), anon_seed, [privacy_scenario(anon_seed, "anonymous")])

      assert result.report.leftovers == []
      assert [%Recording{complete: true}] = result.recordings
      assert FakeBubble.records(fake) == %{}

      refute Enum.any?(
               FakeBubble.log(fake),
               &(&1.path =~ "/obj/user" or &1.path =~ ~r"/wf/wtf_replay_(signup|login)")
             )
    end

    test "a custom-domain app: bubbleapps.io redirects and is refused; the confirmed host records" do
      host = "beta.example.com"
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]

      fake = start_fake(host: host)
      assert {:error, %Error{context: %{reason: :redirect_refused}}} = Client.meta(client())
      assert [%{host: "acme.bubbleapps.io"}] = FakeBubble.log(fake)

      fake = start_fake(host: host)
      {:ok, c} = Client.new(target(host: host), names: names(), sleep: fn _ -> :ok end)
      assert {:ok, result} = record(c, seed, scenarios)
      assert result.report.leftovers == []
      assert result.report.host == host and result.report.branch_id == @branch_id

      assert Enum.all?(
               FakeBubble.log(fake),
               &(&1.host == host and String.starts_with?(&1.path, @prefix))
             )

      for {_path, json} <- result.files do
        assert {:ok, rec} = Recording.from_json(json)
        assert rec.source.host == host and rec.source.branch_id == @branch_id
        assert rec.source.branch == "wtfreplay"
      end
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

    test "a persona's refused create is reported as :user_create_refused, with no token" do
      start_fake(quirks: [:refuse_user_create])
      seed = seed()

      assert {:ok, result} =
               record(client(), seed, [privacy_scenario(seed, "alice")], ledger_dir: dir())

      assert [
               %{
                 error: %{
                   kind: :unauthorized,
                   reason: :user_create_refused,
                   status: 401,
                   type: "custom.task",
                   as: :user
                 }
               }
             ] = result.report.runs

      report = inspect(result.report, limit: :infinity)
      refute report =~ @admin
      # The personas signed up and logged in; their tokens never reach the report.
      refute report =~ "user-token-"
    end

    test "a persona's create refused without Bubble's JSON is not labelled a Bubble refusal" do
      start_fake(quirks: [:edge_block_user_create])
      seed = seed()

      assert {:ok, result} =
               record(client(), seed, [privacy_scenario(seed, "alice")], ledger_dir: dir())

      assert [
               %{
                 error: %{
                   kind: :forbidden,
                   reason: :user_create_not_bubble,
                   status: 403,
                   bubble: nil,
                   as: :user
                 }
               }
             ] = result.report.runs

      refute inspect(result.report, limit: :infinity) =~ "user-token-"
    end

    test "an admin create refused keeps its status and type, without the persona reason" do
      start_fake(script: [{"POST", "/obj/workspace", 401, []}])

      assert {:error, %Error{kind: :unauthorized, context: context}} =
               Client.create(client(), "custom.workspace", %{"Name" => "x"}, :admin)

      assert %{status: 401, type: "custom.workspace", as: :admin} = context
      refute Map.has_key?(context, :reason)
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
          for %{path: @prefix <> "obj/user", query: %{"constraints" => c} = q} <-
                FakeBubble.log(fake),
              c =~ "equals",
              do: Jason.decode!(q["constraints"])

        assert [%{"key" => "email", "constraint_type" => "equals", "value" => email}] = lookup
        assert email == "alice+t1-1@replay.wtf.invalid"
      end
    end

    test "a crash mid-run still cleans up, from the journal" do
      fake = start_fake(owner_records: [%{type: "task", fields: %{"Title" => "owner"}}])
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

      for {branch, opts} <- [
            {"wtfreplay-2", [branch_id: @branch_id]},
            {"wtfreplay", [branch_id: "9z9zz"]},
            {"wtfreplay", [branch_id: @branch_id, host: "beta.example.com"]}
          ] do
        {:ok, other} = Target.new("acme", branch, @admin, [marker_nonce: @nonce] ++ opts)
        {:ok, wrong} = Client.new(other, names: names())

        assert {:error, %Error{context: %{reason: :wrong_target}}} =
                 Cleanup.resume(wrong, state.ledger.path)
      end

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

  # --- owner exposure waiver ----------------------------------------------------------------

  # A waiver lives in an owner-only directory outside any git checkout:
  # under the system temp dir here (never the repository).
  defp waiver_dir do
    base = Path.join(System.tmp_dir!(), "replay-waiver-#{System.unique_integer([:positive])}")
    dir = Path.join(base, "waivers")
    File.mkdir_p!(dir)
    File.chmod!(base, 0o700)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(base) end)
    dir
  end

  defp iso(dt), do: DateTime.to_iso8601(dt)

  defp waiver_doc(overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Map.merge(
      %{
        "format" => "bubble_ex.verify.replay_exposure_waiver",
        "version" => 1,
        "app" => "acme",
        "branch" => "wtfreplay",
        "branch_id" => @branch_id,
        "host" => "acme.bubbleapps.io",
        "types" => %{"user" => "user"},
        "issued_at" => iso(DateTime.add(now, -60)),
        "expires_at" => iso(DateTime.add(now, 3600)),
        "approved_by" => "Test Owner (owner of acme)",
        "approval_reference" =>
          ~s(2026-01-01, chat: "You may expose User anonymously on wtfreplay for this run")
      },
      overrides
    )
  end

  defp write_waiver(dir, doc, name \\ "run.json") do
    path = Path.join(dir, name)
    File.write!(path, if(is_binary(doc), do: doc, else: Jason.encode!(doc)))
    File.chmod!(path, 0o600)
    path
  end

  defp load!(overrides \\ %{}) do
    path = write_waiver(waiver_dir(), waiver_doc(overrides))
    {:ok, waiver} = ExposureWaiver.load_waiver(path)
    {waiver, path}
  end

  defp sha(path), do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

  # User visible to logged-out callers, with an owner user holding an email.
  defp exposed_user_fake(opts \\ []) do
    start_fake(
      [
        user_anonymous: true,
        owner_records: [%{type: "user", fields: %{"email" => "owner@example.test"}}]
      ] ++ opts
    )
  end

  defp reason({:error, %Error{context: %{reason: reason}}}), do: reason
  defp reason(other), do: other

  defp anonymous_check(checks, type),
    do: Enum.find(checks, &(&1[:check] == :anonymous_exposure and &1.type == type))

  describe "owner exposure waiver" do
    test "fail-closed by default; a loaded waiver passes only its types' findings and keeps them" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]

      fake = exposed_user_fake()

      assert {:error, %Error{context: %{preflight: checks}}} =
               record(client(), seed, scenarios)

      assert %{status: :exposed, extra_fields: ["email"]} = anonymous_check(checks, "user")
      assert %{status: :missing} = Enum.find(checks, &(&1[:check] == :persona_cleanup))
      assert read_only?(fake)

      {waiver, path} = load!()
      fake = exposed_user_fake()
      [owner_id] = Map.keys(FakeBubble.records(fake))

      assert {:ok, result} = record(client(), seed, scenarios, exposure_waiver: waiver)

      # The actual finding stays in the report, marked and warned.
      checks = result.report.preflight.checks

      assert %{
               status: :exposed,
               probe_status: :answered,
               extra_fields: ["email"],
               records: 1,
               waived: true,
               warning: warning
             } = anonymous_check(checks, "user")

      assert warning =~ "OWNER-WAIVED ANONYMOUS EXPOSURE"
      assert %{type: "user", warning: warning} in result.report.preflight.warnings
      assert %{status: :ok} = Enum.find(checks, &(&1[:check] == :persona_cleanup))
      refute Map.has_key?(anonymous_check(checks, "custom.task"), :waived)

      # The waiver file's hash is in the report and every ledger journal.
      digest = sha(path)
      assert %{sha256: ^digest, types: %{"user" => "user"}} = result.report.exposure_waiver
      assert result.report.preflight.exposure_waiver.sha256 == digest
      refute inspect(result.report) =~ path

      for ledger <- result.ledgers do
        assert ledger.exposure_waiver_sha256 == digest
        assert {:ok, %Ledger{exposure_waiver_sha256: ^digest}} = Ledger.load(ledger.path)
        assert %{"exposure_waiver_sha256" => ^digest} = Ledger.to_map(ledger)
      end

      assert [%Recording{complete: true}] = result.recordings
      assert result.report.leftovers == []
      assert Map.keys(FakeBubble.records(fake)) == [owner_id]
    end

    test "only :exposed and :may_leak of listed types can be waived" do
      only_ids = %{"workspace" => %{"fields" => [%{"key" => "Name"}, %{"key" => "_id"}]}}
      types = ~w(custom.workspace user)

      # A waiver for Task does not cover User.
      exposed_user_fake()
      {waiver, _} = load!(%{"types" => %{"custom.task" => "task"}})

      assert {:ok, report} =
               Kit.preflight(client(), %Kit{}, ~w(custom.task user), exposure_waiver: waiver)

      refute report.ok?
      refute Map.has_key?(anonymous_check(report.checks, "user"), :waived)

      # :may_leak is waivable and keeps its possible field names.
      start_fake(owner_records: [%{type: "workspace", fields: %{}}], meta_types: only_ids)
      {waiver, _} = load!(%{"types" => %{"custom.workspace" => "workspace"}})

      assert {:ok, report} =
               Kit.preflight(client(), %Kit{}, types, exposure_waiver: waiver)

      assert %{status: :may_leak, possible_fields: ["Name"], waived: true} =
               anonymous_check(report.checks, "custom.workspace")

      # :unproven (no record answered) is not: allow_unproven stays the only way.
      start_fake()
      {waiver, _} = load!(%{"types" => %{"custom.workspace" => "workspace"}})

      assert {:ok, report} =
               Kit.preflight(client(), %Kit{}, types, exposure_waiver: waiver)

      refute report.ok?
      assert %{status: :unproven} = check = anonymous_check(report.checks, "custom.workspace")
      refute Map.has_key?(check, :waived)

      # A type the Data API does not expose stays :missing.
      start_fake(exposed: ~w(task))
      {waiver, _} = load!()

      assert {:ok, report} = Kit.preflight(client(), %Kit{}, ~w(user), exposure_waiver: waiver)
      refute report.ok?
      assert %{status: :missing} = Enum.find(report.checks, &(&1[:check] == :data_api))
      refute anonymous_check(report.checks, "user")
    end

    test "cannot be forged in memory; the file is the only authority" do
      refute Enum.any?(
               ExposureWaiver.__info__(:functions),
               fn {name, _} -> name in [:new, :build, :from_map, :accept, :owner_accepted] end
             )

      {waiver, path} = load!()
      fake = exposed_user_fake()
      c = client(verified: false)
      types = ~w(user)

      forged = [
        # Built in code, pointing nowhere.
        struct!(ExposureWaiver, Map.from_struct(%{waiver | path: path <> ".missing"})),
        # A loaded waiver widened in memory.
        %{waiver | types: Map.put(waiver.types, "custom.task", "task")},
        %{waiver | expires_at: DateTime.add(waiver.expires_at, 86_400)},
        %{waiver | branch_id: "9zz9z"},
        %{waiver | sha256: String.duplicate("0", 64)},
        # Not a waiver at all.
        Map.from_struct(waiver),
        %{owner_accepted: true, types: ["user"]},
        true
      ]

      for bad <- forged do
        assert reason(Kit.preflight(c, %Kit{}, types, exposure_waiver: bad)) in [
                 :exposure_waiver_changed,
                 :exposure_waiver_unreadable
               ],
               inspect(bad)

        assert {:error, %Error{}} =
                 Recorder.plan(client(), seed(), [privacy_scenario(seed(), "alice")],
                   exposure_waiver: bad
                 )
      end

      # Refused before any request (the marker check included).
      assert FakeBubble.log(fake) == []
    end

    test "the file must be 0600 in a 0700 directory, owned by this user, outside git" do
      dir = waiver_dir()
      path = write_waiver(dir, waiver_doc())
      assert {:ok, _} = ExposureWaiver.load_waiver(path)

      File.chmod!(path, 0o644)
      assert reason(ExposureWaiver.load_waiver(path)) == :exposure_waiver_not_private
      File.chmod!(path, 0o400)
      assert reason(ExposureWaiver.load_waiver(path)) == :exposure_waiver_not_private
      File.chmod!(path, 0o600)

      File.chmod!(dir, 0o750)
      assert reason(ExposureWaiver.load_waiver(path)) == :exposure_waiver_not_private
      File.chmod!(dir, 0o700)

      # A symlink to a private file is not the file.
      link = Path.join(dir, "link.json")
      File.ln_s!(path, link)
      assert reason(ExposureWaiver.load_waiver(link)) == :exposure_waiver_not_private

      # Owned by another user.
      {:ok, dir_stat} = File.lstat(dir)
      {:ok, file_stat} = File.lstat(path)
      assert ExposureWaiver.private_stat?(dir_stat, file_stat, file_stat.uid)
      refute ExposureWaiver.private_stat?(dir_stat, file_stat, file_stat.uid + 1)

      refute ExposureWaiver.private_stat?(
               dir_stat,
               %{file_stat | uid: file_stat.uid + 1},
               file_stat.uid
             )

      refute ExposureWaiver.private_stat?(
               %{dir_stat | uid: dir_stat.uid + 1},
               file_stat,
               dir_stat.uid
             )

      # A hard link: two names for one file.
      File.ln!(path, Path.join(dir, "hard.json"))
      assert reason(ExposureWaiver.load_waiver(path)) == :exposure_waiver_not_private
      File.rm!(Path.join(dir, "hard.json"))
      assert {:ok, _} = ExposureWaiver.load_waiver(path)

      # Inside a git checkout (never committed).
      repo = Path.dirname(dir)
      File.mkdir_p!(Path.join(repo, ".git"))
      assert reason(ExposureWaiver.load_waiver(path)) == :exposure_waiver_in_repository
      File.rm_rf!(Path.join(repo, ".git"))

      # Reached through a symlink into a checkout's subdirectory: the real
      # path is walked, so the checkout's .git is found.
      checkout = Path.join(repo, "checkout")
      inner = Path.join([checkout, "sub", "waivers"])
      File.mkdir_p!(Path.join(checkout, ".git"))
      File.mkdir_p!(inner)
      File.chmod!(inner, 0o700)
      write_waiver(inner, waiver_doc())
      File.ln_s!(Path.join(checkout, "sub"), Path.join(repo, "outside"))
      via_link = Path.join([repo, "outside", "waivers", "run.json"])
      assert {:ok, real} = ExposureWaiver.real_path(Path.dirname(via_link))
      assert real == inner
      assert reason(ExposureWaiver.load_waiver(via_link)) == :exposure_waiver_in_repository

      # The file read must be the file checked (inode, size, mtime).
      {:ok, before} = File.lstat(path, time: :posix)
      bytes = File.read!(path)
      assert ExposureWaiver.stable?(before, before, bytes)
      refute ExposureWaiver.stable?(before, %{before | inode: before.inode + 1}, bytes)
      refute ExposureWaiver.stable?(before, %{before | mtime: before.mtime + 1}, bytes)
      refute ExposureWaiver.stable?(before, %{before | size: before.size + 1}, bytes)
      refute ExposureWaiver.stable?(before, before, bytes <> " ")

      # Relative, unnormalized, missing.
      assert reason(ExposureWaiver.load_waiver("waivers/run.json")) == :exposure_waiver_malformed

      assert reason(ExposureWaiver.load_waiver(Path.join([dir, "..", "waivers", "run.json"]))) ==
               :exposure_waiver_malformed

      assert reason(ExposureWaiver.load_waiver(Path.join(dir, "none.json"))) ==
               :exposure_waiver_unreadable
    end

    test "the file must be exact: owner statement, dated reference, UTC window of at most 24h" do
      dir = waiver_dir()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      load = fn doc -> reason(ExposureWaiver.load_waiver(write_waiver(dir, doc))) end

      for overrides <- [
            %{"approved_by" => ""},
            %{"approved_by" => nil},
            %{"approval_reference" => "the owner said yes, trust me"},
            %{"format" => "something_else"},
            %{"version" => 2},
            %{"extra" => true},
            %{"types" => %{}},
            %{"types" => ["user"]},
            %{"types" => %{"*" => "user"}},
            %{"types" => %{"user" => "*"}},
            %{"types" => %{"custom.*" => "task"}},
            %{"branch" => "live"},
            %{"branch" => "test"},
            %{"branch" => "main"},
            %{"branch_id" => "live"},
            %{"branch_id" => "test"},
            %{"app" => "acme.bubbleapps.io"},
            %{"host" => "other.bubbleapps.io"},
            %{"expires_at" => "2026-01-01T09:00:00+02:00"},
            %{"expires_at" => "tomorrow"}
          ] do
        assert load.(waiver_doc(overrides)) == :exposure_waiver_malformed, inspect(overrides)
      end

      assert load.(Map.delete(waiver_doc(), "approval_reference")) == :exposure_waiver_malformed

      # Duplicate keys (last-wins parsers would hide the first).
      dup =
        waiver_doc()
        |> Jason.encode!()
        |> String.replace(~s("types":), ~s("types":{"user":"user"},"types":))

      assert load.(dup) == :exposure_waiver_malformed

      for {issued, expires} <- [{0, 86_401}, {-3600, 86_000}, {3600, 60}] do
        doc =
          waiver_doc(%{
            "issued_at" => iso(DateTime.add(now, issued)),
            "expires_at" => iso(DateTime.add(now, expires))
          })

        assert load.(doc) == :exposure_waiver_window
      end

      assert {:ok, _} =
               ExposureWaiver.load_waiver(
                 write_waiver(
                   dir,
                   waiver_doc(%{
                     "issued_at" => iso(now),
                     "expires_at" => iso(DateTime.add(now, 86_400))
                   })
                 )
               )
    end

    test "the scope must equal the target, types and Data API paths exactly" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]

      for overrides <- [
            %{"app" => "acme-2", "host" => "acme-2.bubbleapps.io"},
            %{"branch" => "wtfreplay2"},
            %{"branch_id" => "5k2xq"},
            %{"host" => "app.example.test"},
            %{"types" => %{"user" => "users"}},
            %{"types" => %{"custom.task" => "tasks"}},
            %{"types" => %{"user" => "user", "custom.project" => "project"}},
            %{"types" => %{"custom.user" => "user"}}
          ] do
        fake = exposed_user_fake()
        {waiver, _} = load!(overrides)

        assert reason(Recorder.plan(client(), seed, scenarios, exposure_waiver: waiver)) ==
                 :exposure_waiver_scope_mismatch,
               inspect(overrides)

        assert reason(Kit.preflight(client(), %Kit{}, ~w(user), exposure_waiver: waiver)) ==
                 :exposure_waiver_scope_mismatch

        assert FakeBubble.log(fake) == []
      end

      # A custom host is in scope only when the target has it.
      exposed_user_fake(host: "app.example.test")
      {waiver, _} = load!(%{"host" => "app.example.test"})
      c = client(target: [host: "app.example.test"])
      assert {:ok, %{ok?: true}} = Kit.preflight(c, %Kit{}, ~w(user), exposure_waiver: waiver)
    end

    test "expiry: refused before the run, and a run stops cleanly when it expires mid-run" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice"), privacy_scenario(seed, "bob")]
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      fake = exposed_user_fake()

      {expired, _} =
        load!(%{
          "issued_at" => iso(DateTime.add(now, -7200)),
          "expires_at" => iso(DateTime.add(now, -3600))
        })

      assert reason(Recorder.plan(client(), seed, scenarios, exposure_waiver: expired)) ==
               :exposure_waiver_expired

      # A clock in the past cannot revive it.
      past = fn -> DateTime.add(now, -5400) end

      assert reason(Recorder.plan(client(), seed, scenarios, exposure_waiver: expired, now: past)) ==
               :exposure_waiver_expired

      {future, _} =
        load!(%{
          "issued_at" => iso(DateTime.add(now, 600)),
          "expires_at" => iso(DateTime.add(now, 3600))
        })

      assert reason(Recorder.plan(client(), seed, scenarios, exposure_waiver: future)) ==
               :exposure_waiver_not_yet_valid

      assert FakeBubble.log(fake) == []

      # Valid at the preflight; the clock passes expiry once run 1 is seeded.
      fake = exposed_user_fake()
      [owner_id] = Map.keys(FakeBubble.records(fake))
      {waiver, _} = load!()

      clock = fn ->
        if Process.get(:waiver_jump),
          do: DateTime.add(DateTime.utc_now(), 7200),
          else: DateTime.utc_now()
      end

      progress = fn
        {:seeded, _} -> Process.put(:waiver_jump, true)
        _ -> :ok
      end

      assert {:ok, result} =
               record(client(), seed, scenarios,
                 exposure_waiver: waiver,
                 now: clock,
                 progress: progress
               )

      # One run only, stopped before its first scenario, cleaned up.
      assert [%{error: %{reason: :exposure_waiver_expired}, uncleared: %{}}] = result.report.runs
      assert result.recordings == [] or Enum.all?(result.recordings, &(not &1.complete))

      assert Enum.sort(result.report.incomplete) ==
               Enum.sort(for s <- scenarios, do: %{scenario: s.id, why: :exposure_waiver_expired})

      assert result.report.leftovers == []
      assert Map.keys(FakeBubble.records(fake)) == [owner_id]

      refute Enum.any?(
               FakeBubble.log(fake),
               &(&1.method == "GET" and &1.path =~ "/obj/task/" and &1.auth != nil and
                   &1.auth != "Bearer " <> @admin)
             )
    end

    test "editing or deleting the file mid-run revokes it; cleanup still runs" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]

      for revoke <- [
            fn path -> File.write!(path, File.read!(path) <> " ") end,
            &File.rm!/1
          ] do
        fake = exposed_user_fake()
        [owner_id] = Map.keys(FakeBubble.records(fake))
        {waiver, path} = load!()

        progress = fn
          {:seeded, _} -> revoke.(path)
          _ -> :ok
        end

        assert {:ok, result} =
                 record(client(), seed, scenarios, exposure_waiver: waiver, progress: progress)

        assert [%{error: %{reason: why}}] = result.report.runs
        assert why in [:exposure_waiver_changed, :exposure_waiver_unreadable]
        assert result.report.leftovers == []
        assert Map.keys(FakeBubble.records(fake)) == [owner_id]
      end
    end

    test "the waiver file's hash is bound into the dry-run hash" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]
      exposed_user_fake()

      dir = waiver_dir()
      doc = waiver_doc()
      {:ok, a} = ExposureWaiver.load_waiver(write_waiver(dir, doc, "a.json"))

      {:ok, b} =
        ExposureWaiver.load_waiver(
          write_waiver(dir, Map.put(doc, "approved_by", "Another Owner"), "b.json")
        )

      {:ok, same} = ExposureWaiver.load_waiver(write_waiver(dir, doc, "c.json"))

      {:ok, none} = Recorder.plan(client(), seed, scenarios, @anonymous)
      {:ok, plan_a} = Recorder.plan(client(), seed, scenarios, [exposure_waiver: a] ++ @anonymous)
      {:ok, plan_b} = Recorder.plan(client(), seed, scenarios, [exposure_waiver: b] ++ @anonymous)

      {:ok, plan_same} =
        Recorder.plan(client(), seed, scenarios, [exposure_waiver: same] ++ @anonymous)

      assert length(Enum.uniq([none.sha256, plan_a.sha256, plan_b.sha256])) == 3
      assert plan_same.sha256 == plan_a.sha256

      opts = [run_id: "h1", ledger_dir: dir()] ++ @anonymous

      for {waiver, confirmed} <- [{b, plan_a}, {nil, plan_a}, {a, none}] do
        fake = exposed_user_fake()

        assert reason(
                 Recorder.record(
                   client(),
                   seed,
                   scenarios,
                   [plan_sha256: confirmed.sha256, exposure_waiver: waiver] ++ opts
                 )
               ) == :plan_not_confirmed

        assert FakeBubble.log(fake) == []
      end
    end

    test "the admin token never appears in a waived run's report or ledgers" do
      seed = seed()
      exposed_user_fake()
      {waiver, _} = load!()

      assert {:ok, result} =
               record(client(), seed, [privacy_scenario(seed, "alice")], exposure_waiver: waiver)

      refute inspect(result.report, limit: :infinity, printable_limit: :infinity) =~ @admin
      assert result.report.exposure_waiver.sha256 == waiver.sha256

      for ledger <- result.ledgers do
        refute inspect(ledger, limit: :infinity, printable_limit: :infinity) =~ @admin
        refute ledger |> Ledger.to_map() |> Jason.encode!() =~ @admin
        refute File.read!(ledger.path) =~ @admin
        assert {:ok, _} = Ledger.to_json(ledger, [@admin])
      end
    end

    test "target verification still runs, tokenless, before any token is sent" do
      seed = seed()
      scenarios = [privacy_scenario(seed, "alice")]
      {waiver, _} = load!()

      fake = exposed_user_fake(marker_nonce: "another-nonce-0123456789")

      assert {:error, %Error{context: %{reason: :unverified_target, step: :marker}}} =
               record(client(verified: false), seed, scenarios, exposure_waiver: waiver)

      assert FakeBubble.log(fake) != []
      assert Enum.all?(FakeBubble.log(fake), &(&1.auth == nil))
      refute Enum.any?(FakeBubble.log(fake), &(&1.path =~ "/obj/"))
    end
  end
end
