defmodule BubbleEx.Target.Ash.MatrixTests do
  @moduledoc """
  Generated privacy-matrix tests for an Ash project (WTF-383, V3 of the
  WTF-358 verification proposal, §3.2 "Phoenix side"): from a
  `BubbleEx.Target.Ash.Project` mapped with `privacy: :unverified` and a
  privacy matrix (a `BubbleEx.Verify.Seed`, its `privacy_read`
  `BubbleEx.Verify.Scenario`s and their expected
  `BubbleEx.Verify.Recording`s, e.g. `BubbleEx.Verify.Matrix.synthesize/2`
  or the decoded `.wtf/verification/` files), one ExUnit module for the
  generated project that checks its policies against the expectations.

      {:ok, matrix} = BubbleEx.Verify.Matrix.synthesize(model, app: app_id)
      {:ok, project} = BubbleEx.Target.Ash.map(model, [], privacy: :unverified)
      {:ok, out} = MatrixTests.render(project, matrix, namespace: "MyApp")
      File.write!("test/my_app/privacy_matrix_test.exs", out.source)

  ## The emitted module

    * `setup_all` checks out the repo's Ecto sandbox in shared mode and
      seeds every seed record with `Ash.Seed.seed!/2` (no actions, no
      policies; a field the seed omits is empty, so attributes with a
      default are seeded as nil), keyed by Bubble IDs: the primary key of each record is the
      Bubble ID the ledger (`:ledger`) binds its seed key to. Without a
      ledger (no replay yet) each key gets a deterministic synthetic
      Bubble-shaped ID (`synthetic_id/1`). Values are converted from
      `BubbleEx.Verify.Value`s to the attributes' Ash types (references to
      the referenced record's ID). The transaction is rolled back after the
      module
    * one test per scenario (grouped by type in `describe` blocks): the
      persona's actor is loaded with the generated `<ns>.Privacy.load_actor/1`
      (nil when logged out), then each op runs: `get` reads the record by
      primary key (`Ash.get/3`, the keyed `:read`) and observes `visible`
      and `visible_fields` (the fields whose value is not an
      `%Ash.ForbiddenField{}`, as Bubble field IDs); `search` reads the
      `:search` action and observes the `record_set` (seed keys). The
      observations must equal the expected recording's
    * with `WTF_VERIFY_OBSERVATIONS` set to a directory, each test first
      writes what it observed as `<dir>/<test module>/<scenario id>.json`
      (`bubble_ex.verify.observations`, see `observations_dir/2` and
      `read_observations/1`), passing or not, so `results/3` can turn a run
      into `BubbleEx.Verify.Result`s for `Result.evaluate/3`

  Everything is in Bubble vocabulary (seed keys, field Bubble IDs), so the
  expectations compare unchanged with Bubble recordings. The tests need no
  network, and are deterministic: the output depends only on the inputs.

  ## Oracles

  The expected recording of a scenario is the Bubble recording given in
  `:recordings` for it, when there is one (V5), else the matrix's (oracle
  `model`: the privacy interpreter, never Bubble-verified, decision D2 on
  WTF-358). A Bubble recording must be complete, fit the scenario
  (`Recording.check_scenario/2`) and not be stale
  (`BubbleEx.Verify.Staleness.recording/3`); anything else is an error,
  never a silent fallback to the model.

  ## Scope

  `privacy_read` scenarios with unsorted `search` ops and `get` ops that
  observe `visible` and `visible_fields` (what `Matrix` synthesizes). Ops the
  interpreter could not decide are not in the matrix's scenarios (its
  report counts them as skipped). The tests do not cover the known
  limitations of the policies (see `BubbleEx.Target.Ash`): aggregates over
  hidden fields through `:search`, and filters through gated
  relationships.

  ## Options (`render/3`)

    * `:namespace` - root namespace the project was rendered with
      (`BubbleEx.Target.Ash.Source`), default `"MyApp"`
    * `:repo` - the repo module, default `"<namespace>.Repo"`
    * `:module` - the test module, default `"<namespace>.PrivacyMatrixTest"`
    * `:ledger` - `%{seed key => Bubble ID}`; keys it lacks get synthetic IDs
    * `:recordings` - Bubble recordings, preferred over the matrix's
  """

  alias BubbleEx.Error
  alias BubbleEx.Target.Ash.{Attribute, Project, Resource}
  alias BubbleEx.Verify.{Json, Matrix, Observation, Recording, Result, Scenario, Seed, Staleness}

  @observations_format "bubble_ex.verify.observations"
  @env "WTF_VERIFY_OBSERVATIONS"

  @type plan :: %{
          required(:seed) => Seed.t(),
          required(:scenarios) => [Scenario.t()],
          required(:recordings) => [Recording.t()],
          optional(atom()) => term()
        }

  @type rendered :: %{
          source: String.t(),
          module: String.t(),
          ids: %{String.t() => String.t()},
          counts: %{String.t() => non_neg_integer() | map()}
        }

  @doc "The environment variable naming the directory the tests write observations to."
  @spec observations_env() :: String.t()
  def observations_env, do: @env

  @doc """
  Renders the ExUnit module for `project` and the matrix `plan` (a
  `BubbleEx.Verify.Matrix` or any map with `seed`, `scenarios` and
  `recordings`). Returns the formatted `source`, the test `module`, the
  `ids` (seed key => primary key) and `counts` (scenarios, ops,
  observations, records, personas, and scenarios per oracle).
  """
  @spec render(Project.t(), plan(), keyword()) :: {:ok, rendered()} | {:error, Error.t()}
  def render(project, plan, opts \\ [])

  def render(%Project{privacy: :unverified} = project, %{seed: %Seed{} = seed} = plan, opts) do
    namespace = Keyword.get(opts, :namespace, "MyApp")

    ctx = %{
      namespace: namespace,
      repo: Keyword.get(opts, :repo, namespace <> ".Repo"),
      module: Keyword.get(opts, :module, namespace <> ".PrivacyMatrixTest"),
      resources: Map.new(project.resources, &{&1.source.type, &1}),
      structs: Map.new(project.typed_structs, &{&1.module, &1})
    }

    with :ok <- modules(ctx),
         {:ok, ids} <- ids(seed, Keyword.get(opts, :ledger, %{})),
         {:ok, expected} <- expected(plan, Keyword.get(opts, :recordings, [])),
         {:ok, rows} <- rows(seed, ids, ctx),
         {:ok, tests} <- tests(expected, seed, ctx) do
      source = source(ctx, seed, ids, rows, tests)

      {:ok,
       %{
         source: source,
         module: ctx.module,
         ids: ids,
         counts: counts(seed, expected)
       }}
    end
  end

  def render(%Project{privacy: privacy}, _plan, _opts),
    do:
      {:error,
       Error.new(
         :invalid_input,
         "matrix tests need a project mapped with privacy: :unverified",
         %{
           privacy: privacy
         }
       )}

  def render(_project, _plan, _opts),
    do: {:error, Error.new(:invalid_input, "expected a Target.Ash Project and a privacy matrix")}

  defp modules(ctx) do
    bad =
      for {what, name} <- [namespace: ctx.namespace, repo: ctx.repo, module: ctx.module],
          not (name =~ ~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/),
          do: what

    if bad == [],
      do: :ok,
      else: {:error, Error.new(:invalid_input, "invalid module names", %{options: bad})}
  end

  # --- IDs ------------------------------------------------------------------------------

  @doc """
  A deterministic Bubble-shaped ID (`<13 digits>x<18 digits>`) for a seed
  key, used as the record's primary key until a replay ledger binds the key
  to the ID Bubble returned.
  """
  @spec synthetic_id(String.t()) :: String.t()
  def synthetic_id(key) do
    <<a::unsigned-64, b::unsigned-64, _::binary>> = :crypto.hash(:sha256, key)
    ms = 1_700_000_000_000 + rem(a, 100_000_000_000)
    "#{ms}x" <> String.pad_leading(Integer.to_string(rem(b, 1_000_000_000_000_000_000)), 18, "0")
  end

  defp ids(seed, ledger) do
    ids =
      Map.new(
        seed.records,
        &{&1.key, Map.get_lazy(ledger, &1.key, fn -> synthetic_id(&1.key) end)}
      )

    dupes =
      ids
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.filter(&match?({_, [_, _ | _]}, &1))

    cond do
      not Enum.all?(Map.values(ids), &(is_binary(&1) and &1 != "")) ->
        {:error, Error.new(:invalid_input, "ledger IDs must be non-empty strings")}

      dupes != [] ->
        {:error,
         Error.new(:invalid_input, "two seed records share a primary key", %{
           keys: dupes |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort()
         })}

      true ->
        {:ok, ids}
    end
  end

  # --- expectations -----------------------------------------------------------------------

  # [{scenario, recording}] in scenario ID order: a Bubble recording when
  # given for the scenario, else the plan's.
  defp expected(plan, bubble) do
    bubble = Map.new(bubble, &{&1.scenario.id, &1})
    model = Map.new(plan.recordings, &{&1.scenario.id, &1})

    plan.scenarios
    |> Enum.sort_by(& &1.id)
    |> map_ok(fn scenario ->
      with {:ok, recording} <- pick(scenario, bubble[scenario.id], model[scenario.id], plan.seed),
           do: {:ok, {scenario, recording}}
    end)
  end

  defp pick(scenario, nil, nil, _seed),
    do: {:error, Error.new(:invalid_input, "no recording for scenario", %{scenario: scenario.id})}

  defp pick(scenario, nil, recording, seed), do: usable(scenario, recording, seed)

  defp pick(scenario, %Recording{oracle: :bubble} = recording, _model, seed),
    do: usable(scenario, recording, seed)

  defp pick(scenario, _recording, _model, _seed),
    do:
      {:error,
       Error.new(:invalid_input, "recordings: expected Bubble recordings", %{
         scenario: scenario.id
       })}

  defp usable(scenario, recording, seed) do
    with :ok <- supported(scenario),
         :ok <- Recording.check_scenario(recording, scenario) do
      stale = Staleness.recording(recording, scenario, seed)

      cond do
        not recording.complete ->
          {:error,
           Error.new(:invalid_input, "the recording is incomplete", %{scenario: scenario.id})}

        stale != [] ->
          {:error,
           Error.new(:invalid_input, "the recording is stale", %{
             scenario: scenario.id,
             reasons: stale
           })}

        recording.masks != [] ->
          {:error,
           Error.new(:invalid_input, "recording masks are not supported", %{scenario: scenario.id})}

        true ->
          {:ok, recording}
      end
    end
  end

  defp supported(%Scenario{kind: :privacy_read, subjects: %{type: _}} = s) do
    bad =
      for op <- s.ops,
          op[:persona] != nil or
            not (match?(%{op: :search, sort: nil}, op) or
                   (op.op == :get and op.observe -- [:visible, :visible_fields] == [])),
          do: op.id

    if bad == [],
      do: :ok,
      else:
        {:error,
         Error.new(
           :invalid_input,
           "unsupported ops (V3: unsorted search and get of visibility, as the scenario's persona)",
           %{
             scenario: s.id,
             ops: bad
           }
         )}
  end

  defp supported(s),
    do:
      {:error,
       Error.new(:invalid_input, "only privacy_read scenarios with a type subject", %{
         scenario: s.id
       })}

  # --- seed rows ----------------------------------------------------------------------------

  defp rows(seed, ids, ctx) do
    seed.records
    |> Enum.sort_by(&{&1.type, &1.key})
    |> map_ok(&row(&1, ids, ctx))
  end

  defp row(record, ids, ctx) do
    with {:ok, resource} <- resource(ctx, record.type, record.key),
         {:ok, attrs} <-
           record.fields |> Enum.sort() |> map_ok(&seed_attribute(&1, resource, record, ids, ctx)) do
      pk = {primary_key(resource).name, {:lit, ids[record.key]}}

      {:ok,
       {module(resource, ctx), record.key, Enum.sort([pk | attrs ++ empty(resource, record)])}}
    end
  end

  # A field the seed omits is empty: attributes with a default (a Bubble
  # yes/no field's "no", say) are seeded as nil, or the sandbox would hold
  # values the expectations were not computed on.
  defp empty(resource, record) do
    for a <- resource.attributes,
        a.default != nil,
        field = a.source[:field],
        not a.primary_key? and is_binary(field),
        not Map.has_key?(record.fields, field),
        do: {a.name, {:lit, nil}}
  end

  defp seed_attribute({field, value}, resource, record, ids, ctx) do
    with {:ok, attribute} <- attribute(resource, field),
         {:ok, input} <- input(value, attribute.type, attribute, ids, ctx) do
      {:ok, {attribute.name, input}}
    else
      {:error, %Error{} = e} ->
        {:error, %{e | context: Map.merge(%{record: record.key, field: field}, e.context)}}
    end
  end

  defp resource(ctx, descriptor, where) do
    type = type_id(descriptor)

    case ctx.resources[type] do
      nil ->
        {:error,
         Error.new(:invalid_input, "no resource for type", %{type: descriptor, at: where})}

      resource ->
        {:ok, resource}
    end
  end

  defp type_id(descriptor) do
    case BubbleEx.Model.Type.reference(descriptor) do
      {:data_type, id} -> id
      _ -> nil
    end
  end

  defp primary_key(%Resource{attributes: attributes}),
    do: Enum.find(attributes, & &1.primary_key?)

  defp attribute(resource, field) do
    case Enum.find(resource.attributes, &(&1.source[:field] == field and not &1.primary_key?)) do
      nil ->
        {:error,
         Error.new(:invalid_input, "no attribute for seed field", %{type: resource.source.type})}

      attribute ->
        {:ok, attribute}
    end
  end

  # A Verify.Value as the attribute's Ash input: {:lit, term} (printed with
  # inspect), {:datetime, ms}, {:decimal, text} or a list/map of those.
  defp input(nil, _type, _attribute, _ids, _ctx), do: {:ok, {:lit, nil}}

  defp input({:list, items}, {:array, item_type}, attribute, ids, ctx) do
    with {:ok, list} <- map_ok(items, &input(&1, item_type, attribute, ids, ctx)),
         do: {:ok, {:list, list}}
  end

  defp input({:ref, key}, :string, %Attribute{references: %{}}, ids, _ctx) do
    case ids[key] do
      nil -> unsupported("reference to an unknown seed record", key)
      id -> {:ok, {:lit, id}}
    end
  end

  defp input({tag, s}, :string, _attribute, _ids, _ctx) when tag in [:text, :file, :image],
    do: {:ok, {:lit, s}}

  defp input({:option, key}, {:module, _enum}, _attribute, _ids, _ctx), do: {:ok, {:lit, key}}
  defp input({:boolean, b}, :boolean, _attribute, _ids, _ctx), do: {:ok, {:lit, b}}

  defp input({tag, n}, :float, _attribute, _ids, _ctx) when tag in [:number, :date_interval],
    do: {:ok, {:lit, n}}

  defp input({:number, n}, :integer, _attribute, _ids, _ctx) do
    if n == Float.round(n),
      do: {:ok, {:lit, trunc(n)}},
      else: unsupported("a fraction for an integer", n)
  end

  defp input({:number, n}, :decimal, _attribute, _ids, _ctx),
    do: {:ok, {:decimal, Float.to_string(n)}}

  defp input({:date, ms}, type, _attribute, _ids, _ctx)
       when type in [:utc_datetime_usec, :utc_datetime],
       do: {:ok, {:datetime, ms}}

  defp input({:date, ms}, :integer, _attribute, _ids, _ctx), do: {:ok, {:lit, div(ms, 1000)}}

  defp input({:json, term}, {:module, "Types.JsonValue"}, _attribute, _ids, _ctx),
    do: {:ok, {:lit, term}}

  defp input({base, parts}, {:module, module}, _attribute, _ids, ctx)
       when base in [:geographic_address, :date_range, :number_range] do
    case ctx.structs[module] do
      %{source: %{structured: ^base}, fields: fields} ->
        {:ok,
         {:map,
          for f <- fields, into: %{} do
            component = String.to_existing_atom(f.source.component)
            {f.name, component(parts[component], f.type)}
          end}}

      _ ->
        unsupported("a #{base} value for #{module}", base)
    end
  end

  defp input(value, type, _attribute, _ids, _ctx),
    do: unsupported("a #{elem(value, 0)} value for an attribute of type #{inspect(type)}", value)

  defp component(nil, _type), do: {:lit, nil}
  defp component(ms, type) when type in [:utc_datetime_usec, :utc_datetime], do: {:datetime, ms}
  defp component(v, _type), do: {:lit, v}

  defp unsupported(message, value),
    do: {:error, Error.new(:invalid_input, "cannot seed " <> message, %{value: inspect(value)})}

  defp module(resource, ctx), do: ctx.namespace <> "." <> resource.module

  # --- tests ---------------------------------------------------------------------------------

  defp tests(expected, seed, ctx) do
    map_ok(expected, fn {scenario, recording} ->
      with {:ok, resource} <- resource(ctx, scenario.subjects.type, scenario.id),
           :ok <- personas(scenario, seed) do
        {:ok,
         %{
           scenario: scenario,
           recording: recording,
           module: module(resource, ctx),
           fields: fields(resource)
         }}
      end
    end)
  end

  # Maps `fun` (returning {:ok, v} or {:error, e}) over `list`, stopping at
  # the first error.
  defp map_ok(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp personas(scenario, seed) do
    if Map.has_key?(seed.personas, scenario.persona),
      do: :ok,
      else:
        {:error,
         Error.new(:invalid_input, "the scenario's persona is not in the seed", %{
           scenario: scenario.id,
           persona: scenario.persona
         })}
  end

  # {attribute name, field Bubble ID} of every public non-key attribute
  # that maps a Bubble field.
  defp fields(resource) do
    for a <- resource.attributes,
        not a.primary_key?,
        a.public?,
        field = a.source[:field],
        is_binary(field),
        do: {a.name, field}
  end

  # --- counts --------------------------------------------------------------------------------

  defp counts(seed, expected) do
    %{
      "scenarios" => length(expected),
      "ops" => expected |> Enum.map(fn {s, _} -> length(s.ops) end) |> Enum.sum(),
      "observations" =>
        expected |> Enum.map(fn {_, r} -> length(r.observations) end) |> Enum.sum(),
      "records" => length(seed.records),
      "personas" => map_size(seed.personas),
      "oracles" => Enum.frequencies_by(expected, fn {_, r} -> Atom.to_string(r.oracle) end)
    }
  end

  # --- source ----------------------------------------------------------------------------------

  defp source(ctx, seed, ids, rows, tests) do
    oracles = tests |> Enum.map(& &1.recording.oracle) |> Enum.uniq() |> Enum.sort()

    field_map =
      tests
      |> Enum.map(&{&1.module, &1.fields})
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {mod, fields} ->
        pairs = Enum.map_join(fields, ", ", fn {name, field} -> "{:#{name}, #{lit(field)}}" end)
        "#{mod} => [#{pairs}]"
      end)

    personas =
      seed.personas
      |> Enum.sort()
      |> Enum.map_join(", ", fn {p, %{user: user}} -> "#{lit(p)} => #{lit(user)}" end)

    id_map =
      ids |> Enum.sort() |> Enum.map_join(",\n", fn {k, id} -> "#{lit(k)} => #{lit(id)}" end)

    seed_rows =
      Enum.map_join(rows, ",\n", fn {mod, _key, attrs} ->
        "{#{mod}, %{" <>
          Enum.map_join(attrs, ", ", fn {name, v} -> "#{name}: #{term(v)}" end) <> "}}"
      end)

    describes =
      tests
      |> Enum.group_by(& &1.scenario.subjects.type)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {type, group} ->
        """
        describe #{lit("#{type} (#{hd(group).module})")} do
        #{Enum.map_join(group, "\n", &test_source/1)}
        end
        """
      end)

    """
    defmodule #{ctx.module} do
      @moduledoc \"\"\"
      Privacy-matrix tests generated by bubble_ex (BubbleEx.Target.Ash.MatrixTests,
      WTF-383) from seed #{lit(seed.id)} (sha256 #{Seed.sha256(seed)}) and #{length(tests)}
      privacy_read scenarios. Expectations: #{Enum.map_join(oracles, ", ", &oracle_text/1)}.
      Regenerate instead of editing.

      `setup_all` loads the seed records (primary keys are Bubble IDs) into
      the Ecto sandbox, rolled back after the module; each test loads the
      persona's actor with `#{ctx.namespace}.Privacy.load_actor/1` and checks
      what it can read by primary key (`:read`) and through `:search`, and
      which fields it sees, against the expected recording. With
      #{@env} set to a directory, every test writes its observations to
      `<dir>/#{ctx.module}/<scenario id>.json` for bubble_ex to turn into
      verification results.
      \"\"\"
      use ExUnit.Case, async: false

      alias Ecto.Adapters.SQL.Sandbox

      @moduletag :privacy_matrix

      @repo #{ctx.repo}
      @privacy #{ctx.namespace}.Privacy

      # Seed record key => primary key (Bubble ID).
      @ids %{
    #{id_map}
      }
      @keys Map.new(@ids, fn {key, id} -> {id, key} end)

      # Persona => the seed key of its user (nil: logged out).
      @personas %{#{personas}}

      # Per resource: {attribute, Bubble field ID} of every field it can observe.
      @fields %{
    #{field_map}
      }

      setup_all do
        :ok = Sandbox.checkout(@repo)
        Sandbox.mode(@repo, {:shared, self()})

        for {resource, attributes} <- seed_rows(), do: Ash.Seed.seed!(resource, attributes)

        :ok
      end

    #{describes}

      defp seed_rows do
        [
    #{seed_rows}
        ]
      end

      # Runs the ops as the persona, writes the observations when
      # #{@env} is set, and requires the expected ones.
      defp verify(scenario, persona, resource, ops, expected) do
        actor = actor(persona)

        observed =
          ops
          |> Enum.flat_map(fn {op, kind, record} -> observe(op, kind, record, resource, actor) end)
          |> Enum.sort()

        write(scenario, observed)
        expected = Enum.sort(expected)

        assert observed == expected,
               "\#{scenario}: the policies disagree with the expected recording " <>
                 "(missing: \#{inspect(expected -- observed)}, unexpected: \#{inspect(observed -- expected)})"
      end

      defp actor(persona) do
        case Map.fetch!(@personas, persona) do
          nil -> nil
          key -> @privacy.load_actor(Map.fetch!(@ids, key)) || flunk("no user for persona \#{persona}")
        end
      end

      defp observe(op, :search, nil, resource, actor) do
        query = Ash.Query.for_read(resource, :search, %{}, actor: actor)

        records =
          case Ash.read(query, actor: actor) do
            {:ok, records} -> Enum.map(records, &key(resource, &1))
            {:error, %Ash.Error.Forbidden{}} -> []
            {:error, error} -> flunk("\#{op}: \#{Exception.message(error)}")
          end

        [{op, :record_set, nil, records |> Enum.uniq() |> Enum.sort()}]
      end

      defp observe(op, :get, record, resource, actor) do
        case Ash.get(resource, Map.fetch!(@ids, record), actor: actor) do
          {:ok, found} ->
            [{op, :visible, record, true}, {op, :visible_fields, record, visible_fields(resource, found)}]

          {:error, error} ->
            if hidden?(error),
              do: [{op, :visible, record, false}, {op, :visible_fields, record, []}],
              else: flunk("\#{op}: \#{Exception.message(error)}")
        end
      end

      defp hidden?(%Ash.Error.Forbidden{}), do: true

      defp hidden?(%Ash.Error.Invalid{errors: errors}),
        do: Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))

      defp hidden?(_error), do: false

      defp key(resource, record) do
        [pk] = Ash.Resource.Info.primary_key(resource)
        id = Map.fetch!(record, pk)
        Map.get(@keys, id, id)
      end

      defp visible_fields(resource, record) do
        fields =
          for {attribute, field} <- Map.fetch!(@fields, resource),
              not match?(%Ash.ForbiddenField{}, Map.fetch!(record, attribute)),
              do: field

        Enum.sort(fields)
      end

      defp write(scenario, observed) do
        case System.get_env(#{lit(@env)}) do
          dir when dir in [nil, ""] ->
            :ok

          base ->
            dir = Path.join(base, inspect(__MODULE__))
            File.mkdir_p!(dir)

            doc = %{
              "format" => #{lit(@observations_format)},
              "schema_version" => 1,
              "scenario" => scenario,
              "observations" => Enum.map(observed, &observation/1)
            }

            File.write!(Path.join(dir, scenario <> ".json"), Jason.encode!(doc))
        end
      end

      defp observation({op, :record_set, nil, records}),
        do: %{"op" => op, "kind" => "record_set", "record" => nil, "value" => %{"ordered" => false, "records" => records}}

      defp observation({op, kind, record, value}),
        do: %{"op" => op, "kind" => Atom.to_string(kind), "record" => record, "value" => value}
    end
    """
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp oracle_text(:model),
    do:
      "the privacy interpreter (oracle model: never Bubble-verified; the policies are NOT VERIFIED AGAINST BUBBLE)"

  defp oracle_text(:bubble), do: "Bubble recordings (oracle bubble)"

  defp test_source(%{scenario: s, recording: r, module: mod}) do
    persona = s.persona

    ops =
      Enum.map_join(s.ops, ",\n", fn
        %{op: :search} = op -> "{#{lit(op.id)}, :search, nil}"
        %{op: :get} = op -> "{#{lit(op.id)}, :get, #{lit(op.record)}}"
      end)

    expected =
      r.observations
      |> Observation.sort()
      |> Enum.map_join(",\n", fn
        %Observation{kind: :record_set} = o ->
          "{#{lit(o.op)}, :record_set, nil, #{lit(o.value.records)}}"

        o ->
          "{#{lit(o.op)}, :#{o.kind}, #{lit(o.record)}, #{lit(o.value)}}"
      end)

    """
    @tag oracle: :#{r.oracle}
    test #{lit(s.id)} do
      verify(#{lit(s.id)}, #{lit(persona)}, #{mod}, [
    #{ops}
      ], [
    #{expected}
      ])
    end
    """
  end

  defp term({:lit, v}), do: lit(v)
  defp term({:datetime, ms}), do: "DateTime.from_unix!(#{ms}, :millisecond)"
  defp term({:decimal, text}), do: "Decimal.new(#{lit(text)})"
  defp term({:list, items}), do: "[" <> Enum.map_join(items, ", ", &term/1) <> "]"

  defp term({:map, fields}),
    do: "%{" <> Enum.map_join(Enum.sort(fields), ", ", fn {k, v} -> "#{k}: #{term(v)}" end) <> "}"

  defp lit(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  # --- results ---------------------------------------------------------------------------------

  @doc """
  Where the test module `module` (as `render/3` returned it) writes its
  observations under the `WTF_VERIFY_OBSERVATIONS` directory `base`.
  """
  @spec observations_dir(Path.t(), String.t()) :: Path.t()
  def observations_dir(base, module), do: Path.join(base, module)

  @doc """
  Reads the observations the generated tests wrote to `dir`: `%{scenario id
  => [BubbleEx.Verify.Observation]}`.
  """
  @spec read_observations(Path.t()) ::
          {:ok, %{String.t() => [Observation.t()]}} | {:error, Error.t()}
  def read_observations(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> map_ok(fn path ->
      case path |> File.read!() |> Json.from_json("observations", &observations/1) do
        {:ok, pair} -> {:ok, pair}
        {:error, e} -> {:error, %{e | context: Map.put(e.context, :path, path)}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  defp observations(map) do
    members = ~w(format schema_version scenario observations)

    with :ok <- Json.envelope(map, @observations_format, 1, members, members, "observations"),
         {:ok, scenario} <- Json.symbol(map["scenario"], "observations scenario"),
         {:ok, obs} <- Json.list(map["observations"], "observations", &Observation.from_map/1) do
      {:ok, {scenario, obs}}
    end
  end

  @doc """
  One `privacy_read` `BubbleEx.Verify.Result` per scenario of `plan`, from
  what the generated tests `observed` (`read_observations/1`), compared
  with the same expected recording `render/3` chose
  (`BubbleEx.Verify.Matrix.result/4`): `pass` or `fail` with a diff, and
  `error` for a scenario with no observations (not run). Score them with
  `BubbleEx.Verify.Result.evaluate/3` and the recording (`recording_for/3`):
  a `model` oracle passes but is never Bubble-verified.

  Options: `:app` and `:ran_at` (required), `:recordings` (as for
  `render/3`), `:actor`.
  """
  @spec results(plan(), %{String.t() => [Observation.t()]}, keyword()) ::
          {:ok, [Result.t()]} | {:error, Error.t()}
  def results(%{seed: %Seed{}} = plan, observed, opts) do
    with {:ok, expected} <- expected(plan, Keyword.get(opts, :recordings, [])) do
      map_ok(expected, fn {scenario, recording} ->
        result(scenario, recording, Map.get(observed, scenario.id), opts)
      end)
    end
  end

  defp result(scenario, _recording, nil, opts) do
    Result.new(
      id: scenario.id,
      app: Keyword.fetch!(opts, :app),
      check: scenario.check,
      status: :error,
      subjects: scenario.subjects,
      reason: "not run: no observations for the scenario",
      actor: Keyword.get(opts, :actor, "ci"),
      ran_at: Keyword.fetch!(opts, :ran_at)
    )
  end

  defp result(scenario, recording, observations, opts),
    do:
      Matrix.result(
        scenario,
        recording,
        observations,
        Keyword.take(opts, [:app, :ran_at, :actor])
      )

  @doc "The recording `render/3` and `results/3` compare `scenario_id` with."
  @spec recording_for(plan(), String.t(), keyword()) :: Recording.t() | nil
  def recording_for(plan, scenario_id, opts \\ []) do
    Enum.find(Keyword.get(opts, :recordings, []), &(&1.scenario.id == scenario_id)) ||
      Enum.find(plan.recordings, &(&1.scenario.id == scenario_id))
  end

  @doc """
  A plan from owner-repo files (`BubbleEx.Verify.Matrix.files/1`'s shape:
  `[{path, json}]`): the one seed under `seeds/`, the scenarios under
  `scenarios/privacy_read/` and the recordings under `recordings/`.
  """
  @spec plan([{String.t(), String.t()}]) :: {:ok, plan()} | {:error, Error.t()}
  def plan(files) do
    decode = fn dir, decoder ->
      files
      |> Enum.filter(fn {path, _} -> String.contains?(path, "/verification/" <> dir) end)
      |> Enum.sort()
      |> map_ok(fn {_, json} -> decoder.(json) end)
    end

    with {:ok, seeds} <- decode.("seeds/", &Seed.from_json/1),
         {:ok, scenarios} <- decode.("scenarios/privacy_read/", &Scenario.from_json/1),
         {:ok, recordings} <- decode.("recordings/", &Recording.from_json/1) do
      case seeds do
        [seed] ->
          {:ok, %{seed: seed, scenarios: scenarios, recordings: recordings}}

        _ ->
          {:error,
           Error.new(:invalid_input, "expected exactly one seed", %{seeds: length(seeds)})}
      end
    end
  end
end
