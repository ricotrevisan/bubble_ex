defmodule BubbleEx.Verify.Interpreter do
  @moduledoc """
  The model interpreter (V2 of the WTF-358 verification proposal): evaluates
  an app's privacy rules (`BubbleEx.Privacy`, through the typed expression
  IR) over seed data for a persona, and says what that persona may see:

      {:ok, interpreter} = BubbleEx.Verify.Interpreter.new(model)
      {:ok, ds} = BubbleEx.Verify.Interpreter.Dataset.from_seed(seed)

      {:ok, %Access{visible: true, fields: ["title_text"], searchable: false}} =
        BubbleEx.Verify.Interpreter.access(interpreter, ds, "u.w1_member", "r.task.1")

  Its verdicts are expectations, never evidence about Bubble: recordings
  made from them have the oracle `model`, which never counts as
  Bubble-verified (decision D2 on WTF-358). V5 calibrates them against
  Bubble recordings.

  ## Semantics

  Rule conditions: `BubbleEx.Verify.Interpreter.Eval`. Permissions, as
  `BubbleEx.Privacy.DataType` documents them and the generated Ash policies
  implement them: a user holds a permission when any rule whose condition
  they match grants it, or the `everyone` rule grants it and applies to them
  (it applies to users no other rule matches; for a permission, "no rule
  lacking it matches", evaluated as the negated conditions with their
  guards). `view` (direct view by ID) needs `view_all` or a non-empty list
  of existing visible fields; each field is visible under `view_all` or
  when listed; `search` is `search_for`. A type listed without rules has
  Bubble's public defaults (everything visible and searchable).

  Every Bubble semantic the model has not verified is a named flag of
  `BubbleEx.Verify.Interpreter.Assumptions`, defaulting to the compiler's
  fail-safe reading. `access/4` reports in `assumptions` the flags its
  verdict depends on: those consulted whose flip changes the verdict.

  ## What it shares with the Ash target (scope of the cross-check)

  The interpreter evaluates the IR of the shared expression compiler
  (`BubbleEx.Expression.Typing` / `Compiler`), the same IR the Ash backend
  lowers. Its agreement with the generated policies
  (`scripts/ash_compile_check.sh`) therefore checks the IR-to-Ash lowering
  and the policy generator, **not the compiler**: a typing or lowering bug
  in the compiler would reach both sides alike. The hand-authored
  expectation tables (`test/support/expression/expectations/privacy.json`,
  `test/support/target/ash/expectations/policies.json`) stay the
  independent signal, and Bubble recordings (V5) the ground truth. An
  evaluator working on the AST directly would remove the shared step (a
  follow-up).

  `everyone_applies/5` is the rule-level form of the `everyone` rule's
  reach (no other rule holds, negated conditions with their guards), the
  same function the verdicts use per permission; `observe/4` and
  `mutate/4` serve mutation coverage (`BubbleEx.Verify.Matrix.Coverage`).

  ## Unknown

  A rule whose condition does not compile to IR, or uses a construct the
  interpreter does not evaluate (`Eval.supported/1`), is *unsupported*: its
  condition is unknown, and so is any verdict it could decide (three-valued:
  a grant is true if a determined rule grants it, false if every relevant
  rule is determined and none does, otherwise `:unknown`). The generated
  Ash policies deny in exactly those cases (a rule that does not compile
  grants nothing), so an unknown verdict is never a grant there. Types that
  are deleted or whose rules the source does not include are unknown.
  """

  alias BubbleEx.{Error, Model}
  alias BubbleEx.Expression.{Compiler, Env, IR, Schema}
  alias BubbleEx.Model.DataType
  alias BubbleEx.Privacy.Rule
  alias BubbleEx.Verify.Interpreter.{Assumptions, Dataset, Defaults, Eval}

  defmodule Access do
    @moduledoc """
    What one persona may see of one record (`BubbleEx.Verify.Interpreter.access/4`).

      * `visible` - viewable by ID (`get`); `:unknown` when an unsupported
        rule could decide it
      * `fields` - the field IDs it may view (sorted; `_id` is implied when
        visible); `unknown_fields` those an unsupported rule could decide
      * `searchable` - found by searches
      * `assumptions` - the `BubbleEx.Verify.Interpreter.Assumptions` flags
        whose flip would change this verdict
      * `reason` - why a verdict is unknown, or nil
    """
    @enforce_keys [:record, :type]
    defstruct [
      :record,
      :type,
      :reason,
      visible: :unknown,
      searchable: :unknown,
      fields: [],
      unknown_fields: [],
      assumptions: []
    ]

    @type t :: %__MODULE__{
            record: String.t(),
            type: String.t(),
            visible: boolean() | :unknown,
            searchable: boolean() | :unknown,
            fields: [String.t()],
            unknown_fields: [String.t()],
            assumptions: [atom()],
            reason: String.t() | nil
          }
  end

  @enforce_keys [:model, :assumptions]
  defstruct [:model, :assumptions, types: %{}, defaults: %{}]

  @type rule_info :: %{
          rule: Rule.t(),
          ir: BubbleEx.Expression.IR.t() | nil,
          status: :ok | {:unsupported, String.t()},
          record_values: list()
        }
  @type type_info :: %{
          type: DataType.t(),
          status: :rules | :public | {:unknown, String.t()},
          fields: [%{id: String.t(), builtin: boolean()}],
          field_ids: MapSet.t(),
          rules: [rule_info()],
          default: Rule.t() | nil
        }
  @type t :: %__MODULE__{
          model: Model.t(),
          assumptions: Assumptions.t(),
          types: %{String.t() => type_info()},
          defaults: Defaults.t()
        }

  @doc """
  Compiles every privacy rule of `model` for evaluation.

  ## Options

    * `:assumptions` - overrides of `BubbleEx.Verify.Interpreter.Assumptions`
      (a map or keyword list of flags to booleans)
  """
  @spec new(Model.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(model, opts \\ [])

  def new(%Model{} = model, opts) do
    with {:ok, assumptions} <- Assumptions.new(Keyword.get(opts, :assumptions, [])) do
      types = Map.new(model.data_types, &{&1.id, type_info(&1, model)})

      {:ok,
       %__MODULE__{
         model: model,
         assumptions: assumptions,
         types: types,
         defaults: Defaults.build(model)
       }}
    end
  end

  def new(_, _), do: {:error, Error.new(:invalid_input, "expected a BubbleEx.Model")}

  @doc "The same interpreter under other assumptions (overrides of the defaults)."
  @spec with_assumptions(t(), map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def with_assumptions(%__MODULE__{} = interpreter, overrides) do
    with {:ok, assumptions} <- Assumptions.new(overrides),
         do: {:ok, %{interpreter | assumptions: assumptions}}
  end

  defp type_info(%DataType{} = type, model) do
    fields =
      for f <- type.system_fields ++ type.fields,
          not f.deleted,
          f.system != :unique_id,
          do: %{id: f.id, builtin: not is_nil(f.system)}

    fields = fields |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.id)
    {default, others} = Enum.split_with(type.rules, & &1.default?)

    %{
      type: type,
      status: type_status(type),
      fields: fields,
      field_ids: MapSet.new(fields, & &1.id),
      rules: Enum.map(others, &rule_info(&1, type, model)),
      default: List.first(default)
    }
  end

  defp type_status(%DataType{deleted: true}), do: {:unknown, "deleted data type"}
  defp type_status(%DataType{privacy: :present}), do: :rules
  defp type_status(%DataType{privacy: :none}), do: :public

  defp type_status(%DataType{}),
    do: {:unknown, "the source does not include the type's privacy rules"}

  defp rule_info(%Rule{condition: nil} = rule, _type, _model),
    do: %{rule: rule, ir: nil, status: {:unsupported, "no condition"}, record_values: []}

  defp rule_info(%Rule{} = rule, type, model) do
    env =
      Env.new(model,
        this_type: Schema.thing_type(type.id),
        this_binder: :rule_record,
        subject: %{type: type.id, rule: rule.id}
      )

    {:ok, compiled} = Compiler.compile(rule.condition, env)

    status =
      case compiled.ir do
        nil -> {:unsupported, "not compiled: " <> codes(compiled.diagnostics)}
        ir -> with({:error, what} <- Eval.supported(ir), do: {:unsupported, what})
      end

    %{
      rule: rule,
      ir: compiled.ir,
      status: status,
      record_values:
        if(compiled.ir, do: compiled.ir |> Eval.record_values() |> Enum.uniq(), else: [])
    }
  end

  defp codes(diagnostics) do
    diagnostics
    |> Enum.filter(&(&1.severity == :error))
    |> Enum.map(&Atom.to_string(&1.code))
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> "no IR"
      codes -> Enum.join(codes, ", ")
    end
  end

  @doc "The compiled information of data type `type_id`, or nil."
  @spec type(t(), String.t()) :: type_info() | nil
  def type(%__MODULE__{types: types}, type_id), do: Map.get(types, type_id)

  @doc """
  Whether rule `rule_id` of type `type_id` holds for `user` (a user record
  key, nil when logged out) and record `this`: `{:ok, boolean, flags}` with
  the assumption flags consulted, or `{:unknown, reason}`.
  """
  @spec condition(t(), Dataset.t(), String.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, boolean(), [atom()]} | {:unknown, String.t()}
  def condition(%__MODULE__{} = interpreter, ds, user, type_id, rule_id, this) do
    with %{rules: rules} <- type(interpreter, type_id),
         %{} = info <- Enum.find(rules, &(&1.rule.id == rule_id)) do
      case rule_holds(info, true, ctx(interpreter, ds, user, this, interpreter.assumptions)) do
        {:unknown, reason} -> {:unknown, reason}
        {b, flags} -> {:ok, b, Enum.uniq(flags)}
      end
    else
      _ -> {:unknown, "no such rule"}
    end
  end

  @doc """
  What `user` (a user record key, nil when logged out) may see of record
  `key`: a `BubbleEx.Verify.Interpreter.Access`. `{:error, _}` when the
  record is not in the dataset.
  """
  @spec access(t(), Dataset.t(), String.t() | nil, String.t()) ::
          {:ok, Access.t()} | {:error, Error.t()}
  def access(%__MODULE__{} = interpreter, %Dataset{} = ds, user, key) do
    case Dataset.fetch(ds, key) do
      nil ->
        {:error, Error.new(:invalid_input, "no record with this key", %{record: key})}

      %{type: type_id} ->
        {access, consulted} =
          verdict(interpreter, ds, user, key, type_id, interpreter.assumptions)

        {:ok, %{access | assumptions: depends_on(interpreter, ds, user, key, access, consulted)}}
    end
  end

  # The flags consulted whose flip changes the verdict.
  # A record may omit a field with a default anywhere a condition reads:
  # `defaults_applied_at_creation` is consulted whenever the app has one.
  defp depends_on(interpreter, ds, user, key, access, consulted) do
    consulted =
      if interpreter.defaults == %{},
        do: consulted,
        else: [:defaults_applied_at_creation | consulted]

    for flag <- Assumptions.names(),
        flag in consulted,
        flipped = Assumptions.flip(interpreter.assumptions, flag),
        {other, _} = verdict(interpreter, ds, user, key, access.type, flipped),
        observable(other) != observable(access),
        do: flag
  end

  defp observable(%Access{} = a), do: {a.visible, a.fields, a.unknown_fields, a.searchable}

  # A logged-out user is empty, or (`logged_out_user_is_empty: false`)
  # Bubble's temporary user: a key no record has, so its fields are empty
  # and it equals no stored user.
  @temporary_user "~temporary_user"

  defp ctx(interpreter, ds, user, this, flags) do
    effective =
      if is_nil(user) and not flags.logged_out_user_is_empty, do: @temporary_user, else: user

    %{
      ds: ds,
      user: effective,
      logged_in: not is_nil(user),
      this: this,
      flags: flags,
      model: interpreter.model,
      defaults: interpreter.defaults
    }
  end

  defp verdict(interpreter, ds, user, key, type_id, flags) do
    base = %Access{record: key, type: type_id}

    case type(interpreter, type_id) do
      nil ->
        {%{base | reason: "unknown data type"}, []}

      %{status: {:unknown, reason}} ->
        {%{base | reason: reason}, []}

      %{status: :public} = info ->
        {%{base | visible: true, searchable: true, fields: Enum.map(info.fields, & &1.id)}, []}

      %{status: :rules} = info ->
        rules_verdict(info, base, ctx(interpreter, ds, user, key, flags))
    end
  end

  defp rules_verdict(info, base, ctx) do
    results = Enum.map(info.rules, &rule_result(&1, ctx))

    {view, f1} = view(info, results, ctx)
    {search, f2} = search_grant(info, results, ctx, view)
    {fields, unknown, f3} = fields(info, results, view, ctx)

    reason =
      if :unknown in [view, search] or unknown != [],
        do: unsupported_reason(results)

    access = %{
      base
      | visible: view,
        searchable: search,
        fields: fields,
        unknown_fields: unknown,
        reason: reason
    }

    {access, Enum.uniq(f1 ++ f2 ++ f3)}
  end

  defp unsupported_reason(results) do
    results
    |> Enum.flat_map(fn
      %{why: nil} -> []
      %{why: why, info: info} -> ["#{info.rule.id}: #{why}"]
    end)
    |> Enum.join("; ")
  end

  defp rule_result(info, ctx) do
    {pos, why} = settle(rule_holds(info, true, ctx))
    {neg, _} = settle(rule_holds(info, false, ctx))
    %{info: info, pos: pos, neg: neg, why: why}
  end

  defp settle({:unknown, why}), do: {{:unknown, []}, why}
  defp settle(result), do: {result, nil}

  defp rule_holds(%{status: {:unsupported, why}}, _positive, _ctx), do: {:unknown, why}

  defp rule_holds(%{ir: ir}, positive, ctx) do
    Eval.holds(ir, positive, ctx)
  catch
    {:unsupported, what} -> {:unknown, what}
  end

  defp view(info, results, ctx) do
    {visible, flags} = grant(info, results, ctx, &view_any(&1, &2, info))

    if visible == false and not ctx.flags.no_visible_field_unreadable,
      do: {true, [:no_visible_field_unreadable | flags]},
      else:
        {visible, if(visible == false, do: [:no_visible_field_unreadable | flags], else: flags)}
  end

  defp fields(_info, _results, false, _ctx), do: {[], [], []}

  defp fields(info, _results, :unknown, _ctx), do: {[], Enum.map(info.fields, & &1.id), []}

  defp fields(info, results, true, ctx) do
    Enum.reduce(info.fields, {[], [], []}, fn field, {yes, unknown, flags} ->
      {v, more} = field_grant(info, results, field, ctx)

      case v do
        true -> {yes ++ [field.id], unknown, flags ++ more}
        false -> {yes, unknown, flags ++ more}
        :unknown -> {yes, unknown ++ [field.id], flags ++ more}
      end
    end)
  end

  defp field_grant(info, results, %{id: id, builtin: builtin}, ctx) do
    {v, flags} = grant(info, results, ctx, &view_field(&1, &2, id, info))

    cond do
      not builtin or v != false ->
        {v, flags}

      ctx.flags.builtin_fields_hidden_unless_listed ->
        {false, [:builtin_fields_hidden_unless_listed | flags]}

      true ->
        {true, [:builtin_fields_hidden_unless_listed | flags]}
    end
  end

  # --- grants ---------------------------------------------------------------------

  # A permission: any matching rule granting it, or the everyone rule when
  # it grants it and applies.
  defp grant(info, results, ctx, grants?) do
    {partition, flags} =
      Enum.map_reduce(results, [], fn r, flags ->
        {g, more} = grants?.(r.info.rule.permissions, ctx)
        {{g, r}, flags ++ more}
      end)

    granting = for {true, r} <- partition, do: r
    lacking = for {false, r} <- partition, do: r

    {rules, f1} = or3(Enum.map(granting, & &1.pos))
    {everyone, f2} = everyone(info, lacking, ctx, grants?)
    {v, f3} = or3([{rules, []}, {everyone, []}])
    {v, flags ++ f1 ++ f2 ++ f3}
  end

  defp everyone(%{default: nil}, _lacking, _ctx, _grants?), do: {false, []}

  defp everyone(%{default: default}, lacking, ctx, grants?) do
    case grants?.(default.permissions, ctx) do
      {false, flags} ->
        {false, flags}

      {true, flags} when lacking == [] ->
        {true, flags}

      {true, flags} ->
        {v, more} = applies(lacking, ctx)
        {v, flags ++ more}
    end
  end

  # Whether the everyone rule applies, as far as the rules `others` go:
  # none of them holds (their negated conditions, with the compiler's
  # record-value guard), or, under `everyone_exclusive: false`, always.
  defp applies(others, ctx) do
    if ctx.flags.everyone_exclusive do
      {none, f1} = and3(Enum.map(others, & &1.neg))
      {guard, f2} = record_guard(others, ctx)
      {v, _} = and3([{none, []}, {guard, []}])
      {v, [:everyone_exclusive | f1 ++ f2]}
    else
      {true, [:everyone_exclusive]}
    end
  end

  # Search: `search_for`, and (`search_independent_of_view: false`) also
  # visible by ID.
  defp search_grant(info, results, ctx, view) do
    {search, flags} = grant(info, results, ctx, &flag(&1, :search_for, &2))

    cond do
      search != true or view == true -> {search, flags}
      ctx.flags.search_independent_of_view -> {search, [:search_independent_of_view | flags]}
      true -> {view, [:search_independent_of_view | flags]}
    end
  end

  # The compiler's hedge: every record value the lacking rules read must
  # be non-empty (`everyone_guards_record_values`).
  defp record_guard(lacking, ctx) do
    values = lacking |> Enum.flat_map(& &1.info.record_values) |> Enum.uniq()

    {empty, flags} =
      Enum.reduce(values, {false, []}, fn ir, {empty, flags} ->
        {e, more} =
          try do
            Eval.value_empty?(ir, ctx)
          catch
            {:unsupported, _} -> {false, []}
          end

        {empty or e, flags ++ more}
      end)

    cond do
      not empty -> {true, flags}
      ctx.flags.everyone_guards_record_values -> {false, [:everyone_guards_record_values | flags]}
      true -> {true, [:everyone_guards_record_values | flags]}
    end
  end

  defp view_any(nil, _ctx, _info), do: {false, []}

  defp view_any(perms, ctx, info) do
    {all, flags} = flag(perms, :view_all, ctx)
    {all or visible_fields(perms, info) != [], flags}
  end

  defp view_field(nil, _ctx, _id, _info), do: {false, []}

  defp view_field(perms, ctx, id, info) do
    {all, flags} = flag(perms, :view_all, ctx)
    {all or id in visible_fields(perms, info), flags}
  end

  defp visible_fields(perms, info),
    do: for(f <- perms.view_fields || [], MapSet.member?(info.field_ids, f), do: f)

  defp flag(nil, _name, _ctx), do: {false, []}

  defp flag(perms, name, ctx) do
    case Map.fetch!(perms, name) do
      b when is_boolean(b) -> {b, []}
      nil -> {not ctx.flags.absent_permission_denied, [:absent_permission_denied]}
    end
  end

  # Three-valued or / and over `{value, flags}` (value true, false or
  # `{:unknown, reason}` / `:unknown`).
  defp or3(results) do
    Enum.reduce(results, {false, []}, fn {v, flags}, {acc, all} ->
      {combine(:or, acc, known(v)), all ++ List.wrap(flags)}
    end)
  end

  defp and3(results) do
    Enum.reduce(results, {true, []}, fn {v, flags}, {acc, all} ->
      {combine(:and, acc, known(v)), all ++ List.wrap(flags)}
    end)
  end

  defp known(:unknown), do: :unknown
  defp known(b) when is_boolean(b), do: b

  defp combine(:or, true, _), do: true
  defp combine(:or, _, true), do: true
  defp combine(:or, :unknown, _), do: :unknown
  defp combine(:or, _, :unknown), do: :unknown
  defp combine(:or, false, false), do: false
  defp combine(:and, false, _), do: false
  defp combine(:and, _, false), do: false
  defp combine(:and, :unknown, _), do: :unknown
  defp combine(:and, _, :unknown), do: :unknown
  defp combine(:and, true, true), do: true

  @doc """
  The records of type `type_id` that `user` finds in a search: `{:ok,
  %{records: keys, unknown: keys}}`, where `unknown` holds the records an
  unsupported rule could decide.
  """
  @spec search(t(), Dataset.t(), String.t() | nil, String.t()) ::
          {:ok, %{records: [String.t()], unknown: [String.t()], assumptions: [atom()]}}
  def search(%__MODULE__{} = interpreter, %Dataset{} = ds, user, type_id) do
    accesses =
      for key <- Dataset.keys(ds, type_id) do
        {:ok, access} = access(interpreter, ds, user, key)
        access
      end

    {:ok,
     %{
       records: for(%{searchable: true, record: k} <- accesses, do: k),
       unknown: for(%{searchable: :unknown, record: k} <- accesses, do: k),
       assumptions:
         accesses
         |> Enum.flat_map(& &1.assumptions)
         |> Enum.uniq()
         |> Enum.sort_by(&Enum.find_index(Assumptions.names(), fn n -> n == &1 end))
     }}
  end

  @doc "Whether an access verdict is fully determined (no unknown part)."
  @spec determined?(Access.t()) :: boolean()
  def determined?(%Access{visible: v, searchable: s, unknown_fields: u}),
    do: v != :unknown and s != :unknown and u == []

  @doc "Every rule with a condition and whether the interpreter evaluates it."
  @spec rules(t()) :: [%{type: String.t(), rule: String.t(), status: term()}]
  def rules(%__MODULE__{} = interpreter) do
    for {type_id, info} <- Enum.sort(interpreter.types),
        r <- info.rules,
        do: %{type: type_id, rule: r.rule.id, status: r.status}
  end

  @doc """
  Whether the `everyone` rule of `type_id` applies to `user` for record
  `key`: no other rule holds, computed exactly as the verdicts compute it
  (negated conditions with their guards, `everyone_exclusive`,
  `everyone_guards_record_values`). `true`, `false` or `:unknown`.
  """
  @spec everyone_applies(t(), Dataset.t(), String.t() | nil, String.t(), String.t()) ::
          boolean() | :unknown
  def everyone_applies(%__MODULE__{} = interpreter, ds, user, type_id, key) do
    info = type(interpreter, type_id)
    ctx = ctx(interpreter, ds, user, key, interpreter.assumptions)
    {v, _} = applies(Enum.map(info.rules, &rule_result(&1, ctx)), ctx)
    v
  end

  @doc """
  The observable verdict for `user` on record `key` (visible, fields,
  unknown fields, searchable) without the dependency analysis; `{:need,
  key, field}` throws from open records pass through (matrix synthesis).
  """
  @spec observe(t(), Dataset.t(), String.t() | nil, String.t()) :: tuple()
  def observe(%__MODULE__{} = interpreter, ds, user, key) do
    %{type: type_id} = Dataset.fetch(ds, key)
    {access, _} = verdict(interpreter, ds, user, key, type_id, interpreter.assumptions)
    observable(access)
  end

  @doc """
  The interpreter with rule `rule_id` of `type_id` mutated: `:drop`
  removes it (for `everyone`, its grants), `:negate` negates its
  condition. For mutation coverage: a rule is observable when a mutant
  changes some recorded verdict.
  """
  @spec mutate(t(), String.t(), String.t(), :drop | :negate) :: t()
  def mutate(%__MODULE__{} = interpreter, type_id, "everyone", :drop),
    do: update_in(interpreter.types[type_id], &%{&1 | default: nil})

  def mutate(%__MODULE__{} = interpreter, type_id, rule_id, :drop),
    do:
      update_in(interpreter.types[type_id].rules, fn rules ->
        Enum.reject(rules, &(&1.rule.id == rule_id))
      end)

  def mutate(%__MODULE__{} = interpreter, type_id, rule_id, :negate),
    do:
      update_in(interpreter.types[type_id].rules, fn rules ->
        Enum.map(rules, fn
          %{rule: %{id: ^rule_id}, ir: %IR{} = ir} = info ->
            %{info | ir: IR.node(:not, [ir], "boolean")}

          info ->
            info
        end)
      end)

  @doc false
  # For matrix synthesis: evaluate a rule's condition with the given flags,
  # letting `{:need, key, field}` throws through.
  @spec eval_rule(t(), rule_info(), Dataset.t(), String.t() | nil, String.t()) ::
          {boolean(), [atom()]} | {:unknown, String.t()}
  def eval_rule(%__MODULE__{} = interpreter, info, ds, user, this),
    do: rule_holds(info, true, ctx(interpreter, ds, user, this, interpreter.assumptions))
end
