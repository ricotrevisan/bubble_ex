defmodule BubbleEx.Target.Ash.DecisionsTest do
  # BubbleEx.Target.Ash applying owner decisions (WTF-401, WTF-352 cut 1):
  # goldens per transform and combined, over the synthetic findings export
  # taken through Findings -> Decision -> resolve -> applicable
  # (BubbleEx.Test.DecidedFixture), the input contract, rename validation,
  # the applied record and both privacy modes. All data is invented.
  #
  # Regenerate the goldens after an intended change with
  #
  #     BUBBLE_EX_UPDATE_GOLDEN=1 mix test test/bubble_ex/target/ash/decisions_test.exs
  use ExUnit.Case, async: true

  alias BubbleEx.{CanonicalJson, Decision, Finding, Model}
  alias BubbleEx.Decision.Applied
  alias BubbleEx.Target.Ash
  alias BubbleEx.Target.Ash.{Calculation, Project, Source}
  alias BubbleEx.Test.DecidedFixture

  @golden "test/support/target/ash/golden/decisions"
  @sha String.duplicate("a", 64)

  defp check_golden(path, actual) do
    if System.get_env("BUBBLE_EX_UPDATE_GOLDEN"), do: File.write!(path, actual)
    assert File.exists?(path), "missing golden #{path}; set BUBBLE_EX_UPDATE_GOLDEN=1"
    expected = File.read!(path)
    assert actual == expected or same_layout_modulo_formatter?(path, actual, expected)
  end

  # Source.render/2 formats with the running Elixir's formatter, whose line
  # breaking differs across versions (Elixir 1.20 wraps a 99-column
  # `field_policy [...] do` line that 1.18 keeps). Goldens are written with
  # the project's pinned Elixir (.tool-versions); on other versions a source
  # golden matches when both sides format to the same text.
  defp same_layout_modulo_formatter?(path, actual, expected) do
    String.ends_with?(path, ".ex.txt") and
      Version.compare(System.version(), "1.19.0") != :lt and
      reformat(actual) == reformat(expected)
  end

  defp reformat(source), do: source |> Code.format_string!() |> IO.iodata_to_binary()

  defp golden_json(project),
    do: project |> Project.to_map() |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)

  defp project!(set, opts \\ []) do
    {:ok, project} = DecidedFixture.project(set, opts)
    project
  end

  defp resource(project, type), do: Enum.find(project.resources, &(&1.source.type == type))

  defp attribute(project, type, field),
    do: Enum.find(resource(project, type).attributes, &(&1.source[:field] == field))

  defp calculation(project, type, field) do
    Enum.find(resource(project, type).calculations, &(&1.source[:field] == field))
  end

  defp faithful do
    {:ok, model} = DecidedFixture.app() |> Model.build()
    model
  end

  defp map(model, applied, opts \\ []),
    do: Ash.map(model, applied, Keyword.put_new(opts, :decisions_sha256, @sha))

  defp message({:error, %BubbleEx.Error{kind: :invalid_input, message: message}}), do: message

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

  # A rename Decision.new would reject (e.g. a core module name), for the
  # generator's own checks.
  defp raw_rename(subject, slot, name) do
    decision = %Decision{
      key: "",
      kind: :rename,
      revision: 1,
      subject: subject,
      target: "ash",
      choice: :accept,
      params: %{slot: String.to_existing_atom(slot), name: name}
    }

    %Applied{
      key: Decision.key(decision),
      kind: :rename,
      transform: :rename,
      subject: subject,
      target: "ash",
      params: decision.params
    }
  end

  describe "goldens" do
    for set <- DecidedFixture.sets() do
      @set set
      test "#{set} renders its golden source (privacy: :omit)" do
        {:ok, source} = @set |> project!() |> Source.render()
        check_golden(Path.join(@golden, "#{@set}.ex.txt"), source)
      end
    end

    test "combined matches its golden Project" do
      check_golden(
        Path.join(@golden, "combined.project.json"),
        golden_json(project!(:combined)) <> "\n"
      )
    end

    test "combined renders its golden source (privacy: :unverified)" do
      {:ok, source} = :combined |> project!(privacy: :unverified) |> Source.render()
      check_golden(Path.join(@golden, "combined.unverified.ex.txt"), source)
    end

    test "every golden is checked" do
      expected =
        Enum.map(DecidedFixture.sets(), &"#{&1}.ex.txt") ++
          ~w(combined.project.json combined.unverified.ex.txt)

      assert @golden |> File.ls!() |> Enum.sort() == Enum.sort(expected)
    end
  end

  describe "refine_number_type" do
    test "an accept stores an integer, a modify a decimal" do
      project = project!(:refine)
      assert attribute(project, "project", "task_count_number").type == :integer
      assert attribute(project, "task", "points_number").type == :decimal
      # untouched numbers stay floats
      assert attribute(project, "project", "score_number").type == :float
    end

    test "a default follows the type; a fractional default is no integer" do
      app = "test/support/target/ash/defaults.json" |> File.read!() |> Jason.decode!()
      {:ok, model} = Model.build(app)
      subject = %{type: "card", field: "count_number"}

      proposal = fn to ->
        %{transform: :refine_number_type, field: "field:card/count_number", from: :number, to: to}
      end

      {:ok, integer} = map(model, [applied_finding(:number_type, subject, proposal.(:integer))])
      assert %{type: :integer, default: {:value, 3}} = attribute(integer, "card", "count_number")

      {:ok, decimal} = map(model, [applied_finding(:number_type, subject, proposal.(:decimal))])
      a = attribute(decimal, "card", "count_number")
      assert %{type: :decimal, default: {:value, {:decimal, "3.0"}}} = a
      {:ok, source} = Source.render(decimal)
      assert source =~ ~s/attribute :count, :decimal,/
      assert source =~ ~s/default: Decimal.new("3.0")/

      fractional =
        put_in(app, ["user_types", "card", "fields", "count_number", "default_val"], 2.5)

      {:ok, model} = Model.build(fractional)

      assert map(model, [applied_finding(:number_type, subject, proposal.(:integer))])
             |> message() =~ "not an integer"
    end
  end

  describe "derive_from_related" do
    test "the field becomes a calculation of the same name over the relationship" do
      project = project!(:derive)
      refute attribute(project, "project", "sort_workspace_name_text")
      refute attribute(project, "project", "workspace_created_date")

      calc = calculation(project, "project", "sort_workspace_name_text")

      assert %Calculation{
               kind: :derived,
               name: "sort_workspace_name",
               type: :string,
               public?: true,
               constraints: [trim?: false, allow_empty?: true]
             } = calc

      assert calc.expr.expr == {:ref, ["workspace"], "name"}

      # a built-in source field
      created = calculation(project, "project", "workspace_created_date")
      assert created.type == :utc_datetime_usec
      assert created.expr.expr == {:ref, ["workspace"], "created_date"}

      {:ok, source} = Source.render(project)
      assert source =~ "calculate :sort_workspace_name, :string, expr(workspace.name),"
    end

    test "the calculation keeps the locked attribute name, so owned code still compiles" do
      %{model: model, applied: applied, decisions_sha256: sha} = DecidedFixture.build(:derive)
      {:ok, faithful} = Ash.map(model)

      names =
        put_in(
          faithful.names,
          ["resources", "project", "attributes", "sort_workspace_name_text"],
          "sort_key"
        )

      {:ok, project} = Ash.map(model, applied, names: names, decisions_sha256: sha)
      assert calculation(project, "project", "sort_workspace_name_text").name == "sort_key"

      assert get_in(project.names, [
               "resources",
               "project",
               "attributes",
               "sort_workspace_name_text"
             ]) ==
               "sort_key"
    end

    test "a stale derivation is an error, not a silent fallback" do
      subject = %{type: "project", field: "sort_workspace_name_text"}

      proposal = fn derivation ->
        %{
          transform: :derive_from_related,
          field: "field:project/sort_workspace_name_text",
          derivation: derivation
        }
      end

      bad = [
        # a text field is not a reference
        %{via: ["field:project/title_text"], source_field: "field:workspace/name_text"},
        # the source is on another type
        %{
          via: ["field:project/workspace_custom_workspace"],
          source_field: "field:task/title_text"
        },
        # a source of another type (date vs text)
        %{
          via: ["field:project/workspace_custom_workspace"],
          source_field: "field:workspace/Created Date"
        },
        # no path
        %{via: [], source_field: "field:workspace/name_text"}
      ]

      for derivation <- bad do
        applied = applied_finding(:denormalized_field, subject, proposal.(derivation))
        assert {:error, %{kind: :invalid_input}} = map(faithful(), [applied]), inspect(derivation)
      end
    end
  end

  describe "renames" do
    test "module, table, attribute and relationship overrides before the lock" do
      project = project!(:rename)
      initiative = resource(project, "project")
      assert initiative.module == "Initiative"
      # the table follows the module until it is locked
      assert initiative.table == "initiative"
      assert resource(project, "task").table == "todo_item"
      assert attribute(project, "project", "title_text").name == "headline"
      assert attribute(project, "project", "title_text").column == nil

      rel =
        Enum.find(initiative.relationships, &(&1.source.field == "workspace_custom_workspace"))

      assert rel.name == "team"
      assert rel.source_attribute == "team_id"

      # other resources' relationships follow the module rename
      task = resource(project, "task")
      assert Enum.find(task.relationships, &(&1.name == "project")).destination == "Initiative"
    end

    test "after the lock a rename changes Elixir names only" do
      %{model: model} = DecidedFixture.build(:rename)
      {:ok, locked} = Ash.map(model)

      applied = [
        rename(%{type: "project"}, "module", "Initiative"),
        rename(%{type: "project", field: "title_text"}, "attribute", "headline"),
        rename(%{type: "project", field: "workspace_custom_workspace"}, "attribute", "team_ref")
      ]

      {:ok, project} = map(model, applied, names: locked.names)
      initiative = resource(project, "project")
      assert initiative.module == "Initiative"
      assert initiative.table == "project"

      assert %{name: "headline", column: "title"} = attribute(project, "project", "title_text")

      assert %{name: "team_ref", column: "workspace_id"} =
               attribute(project, "project", "workspace_custom_workspace")

      assert get_in(project.names, ["resources", "project", "columns"]) == %{
               "title_text" => "title",
               "workspace_custom_workspace" => "workspace_id"
             }

      {:ok, source} = Source.render(project)

      assert source =~
               ~r/attribute :headline, :string,\s+allow_nil\?: true,\s+writable\?: true,\s+public\?: true,\s+source: :title,/

      # stored and passed back, the map gives the same Project (renaming is idempotent)
      names = project.names |> Jason.encode!() |> Jason.decode!()
      {:ok, again} = map(model, applied, names: names)
      assert Project.to_json(again) == Project.to_json(project)

      # a column name is never given to another attribute
      assert {:error, _} =
               map(model, [rename(%{type: "project", field: "note_text"}, "attribute", "title")],
                 names: names
               )

      # renamed back, the attribute needs no column
      back = [rename(%{type: "project", field: "title_text"}, "attribute", "title")]
      {:ok, back} = map(model, back, names: names)
      assert %{name: "title", column: nil} = attribute(back, "project", "title_text")
      refute Map.has_key?(get_in(back.names, ["resources", "project", "columns"]), "title_text")

      # a table has no Elixir name: renaming it after the lock is an error
      assert map(model, [rename(%{type: "task"}, "table", "todo_item")], names: locked.names)
             |> message() =~ "table name is locked"

      # renaming a locked table to its own name is not a change
      assert {:ok, _} =
               map(model, [rename(%{type: "task"}, "table", "task")], names: locked.names)
    end

    test "enum, option-set attribute and API Connector module overrides" do
      app = "test/support/model/option_sets.json" |> File.read!() |> Jason.decode!()
      {:ok, model} = Model.build(app)
      {:ok, faithful} = Ash.map(model)
      [enum | _] = faithful.enums
      set = enum.source.option_set

      applied = [rename(%{option_set: set}, "enum_module", "Level")]

      applied =
        case enum.attributes do
          [attr | _] -> [rename(attr.source, "attribute", "tone") | applied]
          [] -> applied
        end

      {:ok, project} = map(model, applied)
      renamed = Enum.find(project.enums, &(&1.source.option_set == set))
      assert renamed.module == "Enums.Level"

      if renamed.attributes != [], do: assert(hd(renamed.attributes).name == "tone")

      app = "test/support/model/external_types.json" |> File.read!() |> Jason.decode!()
      {:ok, model} = Model.build(app)
      {:ok, faithful} = Ash.map(model)
      [struct | _] = for %{source: %{external_type: _}} = s <- faithful.typed_structs, do: s
      {:ok, project} = map(model, [rename(struct.source, "module", "Payload")])
      assert Enum.any?(project.typed_structs, &(&1.module == "External.Payload"))
    end

    test "invalid renames are errors, never silently applied" do
      model = faithful()
      # "taken" is judged against the locked names (the name map passed in)
      {:ok, %{names: locked}} = Ash.map(model)

      invalid = [
        # the kind does not fit the subject
        {rename(%{type: "project", field: "title_text"}, "relationship", "heading"),
         "reference to a mapped data type"},
        {rename(%{type: "project", field: "title_text"}, "calculation", "heading"),
         "derived by a decision"},
        # reserved and core names
        {rename(%{type: "project", field: "title_text"}, "attribute", "inserted_at"), "reserved"},
        {rename(%{type: "project", field: "title_text"}, "attribute", "id"), "reserved"},
        {raw_rename(%{type: "project"}, "module", "Kernel"), "reserved"},
        {raw_rename(%{type: "project"}, "module", "Ash"), "reserved"},
        {rename(%{type: "project"}, "module", "Repo"), "reserved"},
        {rename(%{type: "project"}, "module", "Privacy"), "reserved"},
        {rename(%{type: "project"}, "module", "Deep.Name"), "one PascalCase segment"},
        {rename(%{type: "task"}, "table", "schema_migrations"), "reserved"},
        # taken in its scope
        {rename(%{type: "project"}, "module", "Workspace"), "taken"},
        {rename(%{type: "project"}, "table", "task"), "locked"},
        {rename(%{type: "project", field: "title_text"}, "attribute", "note"), "taken"},
        {rename(
           %{type: "project", field: "workspace_custom_workspace"},
           "relationship",
           "creator"
         ), "taken"},
        # subjects that are not there or not renamed
        {rename(%{type: "ghost"}, "module", "Ghost"), "not in the Model"},
        {rename(%{type: "project", field: "_id"}, "attribute", "key"), "primary key"},
        {rename(%{workflow: "wSyncOnly"}, "endpoint_path", "sync"), "no endpoints"}
      ]

      for {applied, expected} <- invalid do
        assert map(model, [applied], names: locked) |> message() =~ expected,
               inspect(applied.params)
      end

      # before the lock, a rename may not displace another definition's
      # name (it would be suffixed, then locked at first publish)
      {:error, error} = map(model, [rename(%{type: "project"}, "module", "Workspace")])
      assert error.message =~ "another definition"

      assert %{path: "resources/workspace/module", from: "Workspace", to: "Workspace2"} in error.context.displaced

      {:error, error} =
        map(model, [rename(%{type: "project", field: "title_text"}, "attribute", "note")])

      assert [%{path: "resources/project/attributes/note_text", from: "note", to: "note_2"}] =
               error.context.displaced

      # renaming both swaps them
      swap = [
        rename(%{type: "project"}, "module", "Workspace"),
        rename(%{type: "workspace"}, "module", "Project")
      ]

      {:ok, swapped} = map(model, swap)
      assert resource(swapped, "project").module == "Workspace"
      assert resource(swapped, "workspace").module == "Project"
      assert resource(swapped, "project").table == "workspace"

      # a derived field is renamed as a calculation
      %{model: model, applied: applied, decisions_sha256: sha} = DecidedFixture.build(:derive)

      attribute =
        rename(%{type: "project", field: "sort_workspace_name_text"}, "attribute", "sort_name")

      assert Ash.map(model, [attribute | applied], decisions_sha256: sha)
             |> message() =~ "rename its calculation"
    end
  end

  describe "the input contract" do
    test "decision records must be resolved first" do
      %{records: records, decisions_sha256: sha} = DecidedFixture.build(:refine)

      assert Ash.map(faithful(), records, decisions_sha256: sha) |> message() =~
               "decisions must be resolved first"

      assert map(faithful(), [%{transform: :rename}]) |> message() =~ "Decision.Applied"
    end

    test "an automatic entry must be an undecided hint" do
      [derive | _] = DecidedFixture.build(:derive).applied |> Enum.filter(&(&1.kind == :finding))
      forged = %{derive | automatic: true, basis: nil, decision_id: nil}
      assert map(faithful(), [forged]) |> message() =~ "must be a hint"
    end

    test "a stale entry is rejected" do
      [applied | _] = DecidedFixture.build(:refine).applied |> Enum.filter(&(&1.kind == :finding))

      stale = %{applied | basis: %{applied.basis | proposal_sha256: String.duplicate("c", 64)}}
      assert map(faithful(), [stale]) |> message() =~ "stale"

      unhashed = %{applied | proposal_sha256: nil, basis: nil}
      assert map(faithful(), [unhashed]) |> message() =~ "proposal_sha256"

      # the key, finding ID and subject agree
      assert map(faithful(), [%{applied | key: "finding:number_type:0"}]) |> message() =~ "key"

      other = %{applied | subject: %{type: "task", field: "title_text"}}
      assert map(faithful(), [other]) |> message() =~ "finding_id"
    end

    test "a subject missing from the Model is rejected" do
      %{applied: applied, decisions_sha256: sha} = DecidedFixture.build(:refine)
      app = DecidedFixture.app()
      deleted = put_in(app, ["user_types", "task", "fields", "points_number", "deleted"], true)
      {:ok, model} = Model.build(deleted)

      assert Ash.map(model, applied, decisions_sha256: sha) |> message() =~ "not in the Model"
    end

    test "unsupported hints applied by default are deferred; decided ones are errors" do
      %{model: model, index: index, findings: findings} = DecidedFixture.build(:refine)
      now = ~U[2026-09-26 00:00:00Z]
      {:ok, resolved} = Decision.resolve([], findings, index: index, now: now)
      automatic = Decision.applicable(resolved, findings)
      assert [_, _] = automatic
      assert Enum.all?(automatic, &(&1.automatic and &1.transform == :add_indexes))

      {:ok, project} = map(model, automatic)
      assert project.applied == []
      assert Enum.map(project.deferred, & &1.key) == Enum.map(automatic, & &1.key)
      assert Project.summary(project)["deferred"] == %{"add_indexes" => 2}

      deferred = for d <- project.diagnostics, d.code == :ash_decision_deferred, do: d
      assert length(deferred) == 2
      assert Enum.all?(deferred, &(&1.severity == :warning))

      # an owner's accept of the same hint is an error
      hint = Enum.find(findings, &(&1.kind == :search_index))
      {:ok, accept} = Decision.for_finding(hint, :accept)
      {:ok, resolved} = Decision.resolve([accept], findings, index: index, now: now)
      decided = resolved |> Decision.applicable(findings) |> Enum.reject(& &1.automatic)
      assert map(model, decided) |> message() =~ "does not apply add_indexes yet"

      list = Enum.find(findings, &(&1.kind == :list_relationship))
      {:ok, accept} = Decision.for_finding(list, :accept)
      {:ok, resolved} = Decision.resolve([accept], findings, index: index, now: now)
      applied = resolved |> Decision.applicable(findings) |> Enum.reject(& &1.automatic)

      assert map(model, applied) |> message() =~ "does not apply normalize_list_to_join yet"
    end

    test "one transform per field and unique keys" do
      subject = %{type: "task", field: "points_number"}

      refine =
        applied_finding(:number_type, subject, %{
          transform: :refine_number_type,
          field: "field:task/points_number",
          from: :number,
          to: :integer
        })

      assert map(faithful(), [refine, refine]) |> message() =~ "share a key"

      derive =
        applied_finding(:denormalized_field, subject, %{
          transform: :derive_from_related,
          field: "field:task/points_number",
          derivation: %{
            via: ["field:task/project_custom_project"],
            source_field: "field:project/score_number"
          }
        })

      assert {:ok, _} = map(faithful(), [derive])
      assert map(faithful(), [refine, derive]) |> message() =~ "two decisions transform one field"
    end

    test "plugin decisions are not the schema's: skipped" do
      plugin =
        applied_finding(:plugin, %{plugin: "1600000000000x100"}, %{
          transform: :replace_plugin,
          plugin: "plugin:1600000000000x100",
          option: :drop,
          options: [:drop],
          equivalent: nil
        })

      {:ok, faithful} = Ash.map(faithful())
      assert {:ok, project} = map(faithful(), [plugin])
      assert project.applied == [] and project.deferred == []
      assert project.resources == faithful.resources
    end

    test "decisions need decisions_sha256" do
      %{model: model, applied: applied} = DecidedFixture.build(:refine)
      assert Ash.map(model, applied) |> message() =~ "decisions_sha256"
      assert Ash.map(model, applied, decisions_sha256: "x") |> message() =~ "decisions_sha256"
      assert {:ok, %Project{decisions_sha256: nil, applied: []}} = Ash.map(model, [])
    end
  end

  describe "the applied record" do
    test "lists every applied decision with its key and hashes, and pins the set" do
      %{applied: applied, decisions_sha256: sha, findings: findings} =
        DecidedFixture.build(:combined)

      project = project!(:combined)
      assert project.decisions_sha256 == sha
      assert Enum.map(project.applied, & &1.key) == Enum.map(applied, & &1.key)
      assert project.applied == Enum.sort_by(project.applied, & &1.key)

      by_id = Map.new(findings, &{&1.id, &1})

      for record <- project.applied, record.kind == :finding do
        finding = Map.fetch!(by_id, record.finding_id)
        assert record.proposal_sha256 == finding.proposal_sha256
        assert record.basis_sha256 == finding.basis_sha256
        refute Map.has_key?(record, :decision_id)
      end

      assert Project.summary(project)["applied"] == %{
               "derive_from_related" => 2,
               "refine_number_type" => 2,
               "rename" => 5
             }

      assert Project.summary(project)["derived_calculations"] == 2
      assert project.deferred == []

      assert project.applied_sha256 ==
               project |> Project.to_map() |> Map.fetch!("applied") |> CanonicalJson.sha256()

      # record IDs are audit data: another one changes nothing
      %{model: model} = DecidedFixture.build(:combined)

      renumbered =
        Enum.map(applied, &%{&1 | decision_id: &1.decision_id && &1.decision_id <> "x"})

      {:ok, again} = Ash.map(model, renumbered, decisions_sha256: sha)
      assert Project.to_json(again) == Project.to_json(project)

      codes = Enum.frequencies_by(project.diagnostics, & &1.code)
      assert codes[:ash_decision_applied] == 4
      assert codes[:ash_name_overridden] == 5
    end

    test "is deterministic, and the returned names map back to the same Project" do
      project = project!(:combined)
      assert Project.to_json(project!(:combined)) == Project.to_json(project)

      %{model: model, applied: applied, decisions_sha256: sha} = DecidedFixture.build(:combined)
      names = project.names |> Jason.encode!() |> Jason.decode!()
      {:ok, again} = Ash.map(model, applied, names: names, decisions_sha256: sha)
      assert Project.to_json(again) == Project.to_json(project)
    end
  end

  describe "privacy modes" do
    test ":omit (the default) has only the derived calculations" do
      project = project!(:combined)
      assert project.privacy == :omit
      calcs = Enum.flat_map(project.resources, & &1.calculations)
      assert Enum.all?(calcs, &(&1.kind == :derived))
      {:ok, source} = Source.render(project)
      refute source =~ ~r/Ash\.Policy|field_polic|public\?: false/
    end

    test ":unverified guards a derived field like the field it replaces" do
      project = project!(:combined, privacy: :unverified)
      initiative = resource(project, "project")
      derived = calculation(project, "project", "sort_workspace_name_text")
      assert derived.kind == :derived

      # field policies cover the calculation
      assert Enum.any?(initiative.field_policies, &(derived.name in &1.fields))

      # it stands for a stored copy: it reads through the ungated twin of
      # the gated relationship, and its own field policy guards it
      assert Enum.any?(initiative.relationships, &(&1.name == "team" and &1.gate != nil))
      assert Enum.any?(initiative.privacy_relationships, &(&1.name == "team_for_privacy"))
      assert derived.expr.expr == {:ref, ["team_for_privacy"], "name"}

      # a calculation cannot be written: never auto-bound
      for action <- initiative.extra_actions, do: refute(derived.name in action.accept)

      # the privacy calculations come after the derived ones
      kinds = Enum.map(initiative.calculations, & &1.kind)
      assert kinds == Enum.sort_by(kinds, &(&1 == :privacy))
      assert :privacy in kinds
    end
  end
end
