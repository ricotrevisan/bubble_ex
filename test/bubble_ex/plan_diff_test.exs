defmodule BubbleEx.PlanDiffTest do
  use ExUnit.Case, async: true

  alias BubbleEx.{Decision, Error, Index, Model, Plan, SampleHelper}
  alias BubbleEx.Plan.{Content, Diff}
  alias BubbleEx.Test.DecidedFixture

  # Before/after pairs of the invented plan app
  # (test/support/samples/synthetic_plan_export.json; see BubbleEx.PlanTest).
  # The base gets a dynamic text and a named style on eT2, a condition on
  # wApiC's action, a field default and an option set with an attribute, so
  # edits have raw content to change.
  @app SampleHelper.load_json_sample("synthetic_plan_export")
  @now ~U[2026-09-26 00:00:00Z]

  @t2 ["pages", "pgHome", "elements", "grpBig", "elements", "t2"]
  @new_task ["api", "wfApiC", "actions", "0"]
  @call ["settings", "client_safe", "apiconnector2", "grpMail", "calls", "callSend"]
  @key String.duplicate("k", 32)

  defp text(words), do: %{"type" => "TextExpression", "entries" => %{"0" => words}}

  defp condition(value) do
    %{
      "type" => "CurrentUser",
      "properties" => %{},
      "next" => %{
        "type" => "Message",
        "name" => "is_logged_in",
        "next" => %{
          "type" => "Message",
          "name" => "equals",
          "args" => %{"0" => %{"type" => "LiteralBoolean", "properties" => %{"value" => value}}}
        }
      }
    }
  end

  defp base do
    @app
    |> put_in(@t2 ++ ["properties"], %{"text" => text("Hello"), "left" => 10, "top" => 20})
    |> put_in(@new_task ++ ["properties", "condition"], condition(true))
    |> put_in(@t2 ++ ["style"], "Text_body_")
    |> Map.put("styles", %{
      "Text_body_" => %{
        "id" => "Text_body_",
        "type" => "Text",
        "properties" => %{"font_size" => 14}
      }
    })
    |> put_in(["user_types", "task", "fields", "title_text", "default_val"], "Untitled")
    |> put_in(["user_types", "task", "fields", "state_os"], %{
      "display" => "State",
      "value" => "option.state"
    })
    |> Map.put("option_sets", %{
      "state" => %{
        "display" => "State",
        "attributes" => %{"color_text" => %{"display" => "Color", "value" => "text"}},
        "values" => %{
          "v1" => %{
            "display" => "Open",
            "db_value" => "open",
            "sort_factor" => 1,
            "color_text" => "green"
          },
          "v2" => %{
            "display" => "Done",
            "db_value" => "done",
            "sort_factor" => 2,
            "color_text" => "grey"
          }
        }
      }
    })
  end

  defp plan(app, opts \\ []) do
    {:ok, model} = Model.build(app)
    {:ok, index} = Index.build(app, model: model)
    {key, opts} = Keyword.pop(opts, :key, @key)
    {:ok, content} = Content.digests(app, model, index, key: key)

    {applied, opts} = Keyword.pop(opts, :applied, [])
    opts = Keyword.put_new(opts, :content, content)

    {:ok, plan} = Plan.build(model, index, nil, applied, [fragment_threshold: 2] ++ opts)
    plan
  end

  defp diff!(old, new) do
    {:ok, diff} = Plan.diff(old, new)
    diff
  end

  defp entry!(diff, id), do: Enum.find(diff.tasks, &(&1.task == id)) || flunk("no entry #{id}")
  defp flagged(diff), do: for(%{needs_reverify: true, task: id} <- diff.tasks, do: id)

  defp with_status(diff, status),
    do: diff.tasks |> Enum.filter(&(&1.status == status)) |> Enum.map(& &1.task) |> Enum.sort()

  setup_all do
    %{before: plan(base())}
  end

  describe "classification" do
    test "a plan against itself is all unchanged", %{before: before} do
      diff = diff!(before, before)

      assert diff.counts == %{
               unchanged: length(before.tasks),
               changed: 0,
               added: 0,
               removed: 0,
               needs_reverify: 0
             }

      assert diff.from == before.plan_sha256
      assert Enum.all?(diff.tasks, &(&1.changes == nil and &1.via == [] and &1.reasons == []))
    end

    test "renaming captions and moving elements on the canvas changes nothing", ctx do
      renamed =
        base()
        |> update_in(@t2, &Map.put(&1, "default_name", "Greeting"))
        |> update_in(@t2 ++ ["properties"], &Map.merge(&1, %{"left" => 400, "top" => 0}))
        |> put_in(
          ["pages", "pgHome", "workflows", "wfNotify", "properties", "event_name"],
          "ping"
        )
        |> put_in(["pages", "pgHome", "workflows", "wfClick", "name"], "On click")
        |> put_in(@new_task ++ ["name"], "Create the task")
        |> put_in(@new_task ++ ["comment"], "an editor note")

      diff = diff!(ctx.before, plan(renamed))
      assert diff.counts.unchanged == length(ctx.before.tasks)
      assert diff.counts.needs_reverify == 0
    end

    test "an expression's text changing changes the tasks covering it", ctx do
      edited = put_in(base(), @t2 ++ ["properties", "text"], text("Goodbye"))
      diff = diff!(ctx.before, plan(edited))

      assert with_status(diff, :changed) ==
               ~w(acceptance:page/pHome fragment:eBig generate:routes generate:surfaces
                  surface:page/pHome)

      for id <- ~w(surface:page/pHome fragment:eBig) do
        assert %{status: :changed, needs_reverify: true, reasons: [:symbols]} =
                 e = entry!(diff, id)

        assert e.changes == %{added: [], removed: [], changed: ["element:eT2"]}
      end

      # Its workflows are subtasks of the page, but none of them changed.
      assert %{status: :unchanged, needs_reverify: false} = entry!(diff, "workflow:wClick")

      # The release chain runs again.
      assert %{status: :unchanged, needs_reverify: true, reasons: [:dependency], via: via} =
               entry!(diff, "replay:app")

      assert %{task: "acceptance:page/pHome", kind: :release} in via

      refute "backend:fOne" in flagged(diff)
      refute "surface:reusable/rCard" in flagged(diff)
    end

    test "without content digests only what the index records is compared", ctx do
      edited = put_in(base(), @t2 ++ ["properties", "text"], text("Goodbye"))
      diff = diff!(plan(base(), content: nil), plan(edited, content: nil))
      assert diff.counts.changed == 0
      refute ctx.before.inputs.content_sha256 == nil
    end

    test "a removed workflow is removed; its folder and callers change", ctx do
      {_, app} = pop_in(base(), ["api", "wfApiD"])
      diff = diff!(ctx.before, plan(app))

      assert %{status: :removed, needs_reverify: false} = entry!(diff, "workflow:wApiD")

      assert %{status: :changed, changes: %{removed: removed}} = entry!(diff, "backend:fOne")
      assert removed == ~w(action:aAgain workflow:wApiD)

      # The caller's call now points at nothing, and it depended on it.
      assert %{status: :changed, needs_reverify: true, via: via} = entry!(diff, "workflow:wApiB")
      assert %{task: "workflow:wApiD", kind: :coordinate} in via

      # wApiD was the only public workflow.
      assert with_status(diff, :removed) == ~w(delivery:callers workflow:wApiD)
    end
  end

  describe "data model and API content" do
    test "a field default changes the schema and the tasks reading or writing it", ctx do
      app = put_in(base(), ["user_types", "task", "fields", "title_text", "default_val"], "New")
      diff = diff!(ctx.before, plan(app))

      assert %{status: :changed, changes: %{changed: changed}} = entry!(diff, "generate:schema")
      assert "field:task/title_text" in changed
    end

    test "an option value's display text or attribute value changes the option sets", ctx do
      path = ["option_sets", "state", "values", "v1"]

      for app <- [
            put_in(base(), path ++ ["display"], "Opened"),
            put_in(base(), path ++ ["color_text"], "blue")
          ] do
        diff = diff!(ctx.before, plan(app))

        assert %{status: :changed, changes: %{changed: ["option_value:state/open"]}} =
                 entry!(diff, "generate:option_sets")
      end
    end

    test "an option set's or field's display name is a caption", ctx do
      app =
        base()
        |> put_in(["option_sets", "state", "display"], "Status")
        |> put_in(["user_types", "task", "fields", "title_text", "display"], "Name")

      assert diff!(ctx.before, plan(app)).counts.changed == 0
    end

    test "an API call's path, body or header value changes its tasks", ctx do
      group = ["settings", "client_safe", "apiconnector2", "grpMail"]

      for app <- [
            put_in(base(), @call ++ ["url"], "https://api.mail.test/v2/send"),
            put_in(base(), @call ++ ["body"], ~s({"to": "<to>"})),
            put_in(base(), group ++ ["shared_headers", "h1", "value"], "Bearer x")
          ] do
        diff = diff!(ctx.before, plan(app))
        assert %{status: :changed} = entry!(diff, "api_group:grpMail")
        assert %{needs_reverify: true} = entry!(diff, "workflow:wClick")
      end

      # The call's caption is not content.
      assert diff!(ctx.before, plan(put_in(base(), @call ++ ["name"], "Mail it"))).counts.changed ==
               0
    end

    test "editing a named style changes the elements using it", ctx do
      app = put_in(base(), ["styles", "Text_body_", "properties", "font_size"], 16)
      diff = diff!(ctx.before, plan(app))

      assert %{status: :changed, changes: %{changed: ["element:eT2"]}} =
               entry!(diff, "surface:page/pHome")
    end
  end

  describe "content key" do
    test "digests need a key of at least 32 bytes", ctx do
      app = base()
      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)

      assert {:error, %Error{kind: :invalid_input}} = Content.digests(app, model, index)

      assert {:error, %Error{kind: :invalid_input}} =
               Content.digests(app, model, index, key: "short")

      {:ok, content} = Content.digests(app, model, index, key: @key)
      assert content.algorithm == Content.algorithm()
      assert content.key_id == Content.key_id(@key)

      assert ctx.before.inputs.content == %{
               algorithm: Content.algorithm(),
               key_id: content.key_id
             }

      refute Plan.to_json(ctx.before) =~ @key
    end

    test "another key, or none, changes every task", ctx do
      for other <- [plan(base(), key: String.duplicate("z", 32)), plan(base(), content: nil)] do
        diff = diff!(ctx.before, other)
        assert diff.content_changed
        assert diff.counts.changed == length(ctx.before.tasks)
        assert Enum.all?(diff.tasks, &(:content in &1.reasons))
      end

      refute diff!(ctx.before, plan(base())).content_changed
    end
  end

  describe "propagation" do
    test "a callee's change flags its callers, their parents and dependents", ctx do
      edited = put_in(base(), @new_task ++ ["properties", "condition"], condition(false))
      diff = diff!(ctx.before, plan(edited))

      assert %{status: :changed, changes: %{changed: ["action:aNewTask"]}} =
               entry!(diff, "workflow:wApiC")

      assert %{status: :changed} = entry!(diff, "backend:fTwo")

      assert %{
               status: :unchanged,
               needs_reverify: true,
               via: [%{task: "workflow:wApiC", kind: :calls}]
             } =
               entry!(diff, "workflow:wApiA")

      assert %{needs_reverify: true, via: [%{task: "workflow:wApiA", kind: :subtask}]} =
               entry!(diff, "backend:fOne")

      assert %{needs_reverify: true, via: via} = entry!(diff, "workflow:wClick")
      assert %{task: "workflow:wApiA", kind: :calls} in via
      assert %{needs_reverify: true} = entry!(diff, "surface:page/pHome")
      assert %{needs_reverify: true} = entry!(diff, "acceptance:page/pHome")

      # Not callers, and a parent's change does not flag its other subtasks.
      for id <- ~w(workflow:wApiB workflow:wApiD workflow:wNotify surface:reusable/rCard),
          do: refute(id in flagged(diff), id)
    end

    test "a coordinate edge's callee change flags the caller", ctx do
      wf = ["api", "wfApiD", "actions", "0", "properties", "condition"]
      diff = diff!(ctx.before, plan(put_in(base(), wf, condition(true))))

      assert %{status: :changed} = entry!(diff, "workflow:wApiD")

      assert %{needs_reverify: true, via: [%{task: "workflow:wApiD", kind: :coordinate}]} =
               entry!(diff, "workflow:wApiB")
    end

    test "early edges only order work", ctx do
      # aLogin is covered by `auth`, which surfaces and backend folders
      # follow (`early`) without using it.
      path = ["pages", "pgHome", "workflows", "wfLogin", "actions", "0", "properties"]
      diff = diff!(ctx.before, plan(put_in(base(), path, %{"remember_email" => true})))

      assert %{status: :changed} = entry!(diff, "auth")
      refute "backend:fOne" in flagged(diff)
      refute "surface:reusable/rCard" in flagged(diff)
    end

    test "generator groups do not flag every task", ctx do
      # A new field changes the schema group only.
      app =
        put_in(base(), ["user_types", "task", "fields", "note_text"], %{
          "display" => "Note",
          "value" => "text"
        })

      diff = diff!(ctx.before, plan(app))
      assert "generate:schema" in with_status(diff, :changed)
      refute "surface:page/pHome" in flagged(diff)
      refute "workflow:wApiC" in flagged(diff)
    end
  end

  describe "decisions" do
    test "a parity exception on a covered symbol flags its tasks" do
      app = base()
      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)

      {:ok, parity} =
        Decision.new(
          kind: :parity_exception,
          subject: %{workflow: "wApiC"},
          choice: :accept,
          params: %{
            scope: "scenario:create_task",
            checks: ["api_workflow"],
            bubble_behavior: "keeps a trailing space",
            chosen_behavior: "trims the title"
          }
        )

      {:ok, resolved} = Decision.resolve([parity], [], index: index, now: @now)
      {:ok, none} = Decision.resolve([], [], index: index, now: @now)

      diff = diff!(plan(app, resolved: none), plan(app, resolved: resolved))

      assert %{status: :changed, reasons: [:decisions], changes: changes} =
               entry!(diff, "workflow:wApiC")

      assert changes == %{added: [], removed: [], changed: []}
      assert %{status: :changed, reasons: [:decisions]} = entry!(diff, "backend:fTwo")
      assert %{status: :unchanged} = entry!(diff, "workflow:wApiB")
      assert Plan.task(plan(app, resolved: resolved), "workflow:wApiC").decisions_sha256
      assert Plan.task(plan(app, resolved: none), "workflow:wApiC").decisions_sha256 == nil
    end

    test "an applied decision changes the tasks it covers" do
      fixture = DecidedFixture.build(:derive)
      applied = Enum.filter(fixture.applied, &(not &1.automatic))
      {:ok, faithful} = Plan.build(fixture.model, fixture.index, nil, [])
      {:ok, decided} = Plan.build(fixture.model, fixture.index, nil, applied)

      diff = diff!(faithful, decided)
      decided_tasks = for t <- decided.tasks, t.decisions != [], do: t.id
      assert decided_tasks != []

      for id <- decided_tasks,
          %{status: :changed} = e <- [entry!(diff, id)],
          do: assert(:decisions in e.reasons, id)

      assert Enum.any?(diff.tasks, &(&1.status == :added))
    end
  end

  describe "format" do
    test "the diff is deterministic and the same from decoded JSON", ctx do
      edited = plan(put_in(base(), @t2 ++ ["properties", "text"], text("Goodbye")))
      diff = diff!(ctx.before, edited)

      decoded = fn plan -> plan |> Plan.to_json() |> Jason.decode!() end
      assert Diff.to_json(diff!(decoded.(ctx.before), decoded.(edited))) == Diff.to_json(diff)
      assert Diff.to_json(diff!(ctx.before, edited)) == Diff.to_json(diff)

      assert %{"task" => "surface:page/pHome", "status" => "changed", "reasons" => ["symbols"]} =
               diff
               |> Diff.to_map()
               |> Map.fetch!("tasks")
               |> Enum.find(&(&1["task"] == "surface:page/pHome"))
    end

    test "plans of another schema version are refused", ctx do
      old = ctx.before |> Plan.to_map() |> Map.put("schema_version", 1)
      assert {:error, %Error{kind: :invalid_input}} = Plan.diff(old, ctx.before)
      assert {:error, %Error{kind: :invalid_input}} = Plan.diff(%{}, ctx.before)
    end

    test "symbols hold IDs, parents and 128-bit hashes only", ctx do
      assert %{parent: "element:eBig", sha256: sha} = ctx.before.symbols["element:eT2"]
      assert sha =~ ~r/\A[0-9a-f]{32}\z/
    end
  end

  describe "content digests" do
    test "both key forms hash alike" do
      readable = %{
        "id" => "eX",
        "type" => "Text",
        "default_name" => "Caption",
        "properties" => %{"text" => text("Hi"), "left" => 3}
      }

      compact = %{
        "%id" => "eX",
        "%x" => "Text",
        "%p" => %{"text" => %{"%x" => "TextExpression", "%e" => %{"0" => "Hi"}}, "left" => 9}
      }

      assert Content.normalize(readable, :element) == Content.normalize(compact, :element)
    end

    test "a workflow keeps its step order" do
      wf = fn order ->
        %{
          "type" => "ButtonClicked",
          "actions" => Map.new(order, fn {k, id} -> {k, %{"id" => id}} end)
        }
      end

      assert Content.normalize(wf.([{"0", "a"}, {"1", "b"}, {"10", "c"}, {"2", "d"}]), :workflow)[
               "action_order"
             ] == ~w(a b d c)

      refute Content.normalize(wf.([{"0", "a"}, {"1", "b"}]), :workflow) ==
               Content.normalize(wf.([{"0", "b"}, {"1", "a"}]), :workflow)
    end

    test "invalid content is refused", ctx do
      %{before: plan} = ctx
      assert plan.inputs.content_sha256

      app = base()
      {:ok, model} = Model.build(app)
      {:ok, index} = Index.build(app, model: model)

      assert {:error, %Error{kind: :invalid_input}} =
               Plan.build(model, index, nil, [], content: %{"element:eT2" => "nope"})

      assert {:error, %Error{kind: :invalid_input}} =
               Plan.build(model, index, nil, [],
                 content: %Content{algorithm: 1, key_id: nil, digests: %{}}
               )

      assert {:error, %Error{kind: :invalid_input}} =
               Plan.build(model, index, nil, [], resolved: :nope)
    end
  end
end
