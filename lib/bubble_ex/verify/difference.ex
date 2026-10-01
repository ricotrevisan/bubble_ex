defmodule BubbleEx.Verify.Difference do
  @moduledoc """
  Known, intentional differences between Bubble and the generated app
  (WTF-426): where the target's privacy policy is **stricter than Bubble
  by design**, and every case the privacy matrix has of it.

  Verification keeps two readings apart:

    * **Bubble semantics** - `BubbleEx.Verify.Interpreter` under its
      defaults (`BubbleEx.Verify.Interpreter.Assumptions.defaults/0`),
      calibrated against Bubble recordings: what Bubble does
    * **the target policy** - the generated Ash policies, which the
      interpreter predicts under `Assumptions.target/0` (the compiler's
      fail-safe reading)

  `policy/0` lists the flags on which the two differ by an owner's
  decision, and in which direction. Today there are six:

    * `actor_empty_denies` (scope `:rule_conditions`). Bubble treats an
      empty value on the user's side (a logged-out user, or a user
      without the value a condition reads) as equal to an empty record
      value, so a condition such as `Current User's team = This Thing's
      team` grants a logged-out user access to a record with no team. The
      owner decided (2026-09-29) that the generated policies keep denying
      there.
    * `logged_out_user_is_empty`, `empty_yes_no_is_no`,
      `everyone_exclusive` and `everyone_guards_record_values` (scope
      `:rule_conditions`, WTF-467). The 2026-10-01 replay (WTF-385) showed
      that Bubble treats a logged-out user as a temporary user (never
      equal to a record's user, its fields empty), reads an empty yes/no
      as no, and applies the `everyone` rule's grants to every user, on
      top of the other rules (so the compiler's record-value guard on its
      reach has nothing to guard). Each would widen the generated
      policies; by the owner's standing rule they stay stricter: a
      logged-out actor is empty and denies every comparison reading it,
      `x is no` needs a stored no, and the `everyone` rule's grants reach
      only users no rule lacking them matches, record values guarded.
      Where the target would be *less* strict than Bubble (`x is not no`
      on an empty yes/no: Bubble reads no, the compiled
      `is_distinct_from(x, false)` holds), the matrix reports an
      unintended difference.
    * `hidden_field_constraint_matches` (scope `:search_constraints`,
      `privacy: :enforced` only, WTF-457). In Bubble, viewing a field and
      using it as a search constraint are separate permissions: a page
      search constrained (or sorted) on a field the user may not view
      matches its stored value, an oracle on the hidden values (the
      2026-10-01 replay, WTF-385: a logged-out visitor's `= aaa` found 1
      of 2 records, `is not empty` 2, `is empty` 0; Bubble's manual flags
      such fields, "constrainable fields: non-viewable but filterable").
      Elsewhere Bubble differs: a backend workflow's search reads the
      field as empty, a Data API search matches nothing; only a field the
      user may not constrain on (non-filterable) makes a page search find
      nothing (`non_filterable_constraint_excludes`). The generated app
      matches nothing on a record whose field the user may not view (as
      the Data API): it returns only the records where the user may view
      every field the search's filter or sort reads, in either polarity
      (`<namespace>.Privacy.SearchFields`, per actor and record). The
      owner decided (2026-10-01) to stay stricter. The
      privacy matrix does not exercise it (its constrained searches cover
      only non-filterable fields); the generated policies report each type
      it applies to (`:ash_policy_hidden_search_stricter_than_bubble`).

  `flags/1` splits them by scope: the matrix's cases, the structural list
  and the rules' diagnostics name only `:rule_conditions` flags.

  A difference is **intended** only when it is stricter (the target shows
  a subset of what Bubble shows: not visible where Bubble is, fewer
  fields, fewer records found) and follows from the policy's flags alone:
  the interpreter with just those flags at their target reading predicts
  what the target predicts. Anything else is a real difference and fails.

  ## The per-case record

  A `%Difference{}` is one observation of one scenario op where the target
  is intended to differ: `bubble` is the value Bubble's reading predicts,
  `target` the stricter value the policies must produce, `flags` the
  policy flags responsible and `rules` the privacy rules whose outcome
  changes (Bubble rule IDs; `"everyone"` for the `everyone` rule's reach).
  `BubbleEx.Verify.Matrix` computes them for every scenario it
  synthesizes (`matrix.differences`, and the owner-repo file
  `.wtf/verification/differences/<seed id>.json`); the generated matrix
  tests expect the `target` values (`BubbleEx.Target.Ash.MatrixTests`),
  and `BubbleEx.Verify.Result` reports a result whose differences are all
  listed here as `intended_difference`, which counts as passing
  (`BubbleEx.Verify.Result.evaluate/3` checks each against this record).

  `summary/1` is the owner's list: per type and rule, the flags, the
  personas and how many observations differ. `structural/1` is the same
  list without seed data: every compiled rule whose condition reads the
  current user or compares a stored yes/no, and every `everyone` rule
  whose grants the target narrows, where the target may deny what Bubble
  grants.
  """

  alias BubbleEx.{CanonicalJson, Error, Model}
  alias BubbleEx.Expression.IR
  alias BubbleEx.Verify.{DataApi, Json, Observation}
  alias BubbleEx.Verify.Interpreter
  alias BubbleEx.Verify.Interpreter.Assumptions

  @format "bubble_ex.verify.differences"
  @schema_version 1
  @kinds [:visible, :visible_fields, :record_set]

  # The owner's standing rule ("stay stricter"), applied to the flags the
  # 2026-10-01 replay flipped (WTF-467).
  @standing "owner standing rule (WTF-467, 2026-10-01): stay stricter than Bubble"

  @policy %{
    actor_empty_denies: %{
      bubble: false,
      target: true,
      direction: :stricter,
      scope: :rule_conditions,
      decision: "owner, 2026-09-29 (WTF-426): stay stricter than Bubble",
      summary:
        "Bubble treats an empty value on the user's side (logged out, or a user without the " <>
          "value a condition reads) as equal to an empty record value and grants access; " <>
          "the generated policies deny"
    },
    logged_out_user_is_empty: %{
      bubble: false,
      target: true,
      direction: :stricter,
      scope: :rule_conditions,
      decision: @standing,
      summary:
        "Bubble treats a logged-out user as a temporary user: a user of its own, never equal " <>
          "to a record's user, with empty fields (so `This Thing's owner is not Current User` " <>
          "holds); the generated policies treat a logged-out actor as empty and deny every " <>
          "comparison reading it"
    },
    empty_yes_no_is_no: %{
      bubble: true,
      target: false,
      direction: :stricter,
      scope: :rule_conditions,
      decision: @standing,
      summary:
        "Bubble reads an empty yes/no as no, so `x is no` holds on a record whose x is empty; " <>
          "the generated policies compile `x == false`, which an empty x does not match"
    },
    everyone_exclusive: %{
      bubble: false,
      target: true,
      direction: :stricter,
      scope: :rule_conditions,
      decision: @standing,
      summary:
        "Bubble applies the everyone rule's grants to every user, on top of what the other " <>
          "rules grant; the generated policies grant them only where none of the rules " <>
          "lacking the permission holds"
    },
    everyone_guards_record_values: %{
      bubble: false,
      target: true,
      direction: :stricter,
      scope: :rule_conditions,
      decision: @standing,
      summary:
        "The generated policies' everyone grant also needs every record value the rules " <>
          "lacking the permission read to be non-empty; Bubble has no such guard (its " <>
          "everyone rule reaches every user)"
    },
    hidden_field_constraint_matches: %{
      bubble: true,
      target: false,
      direction: :stricter,
      scope: :search_constraints,
      decision: "owner, 2026-10-01 (WTF-457): stay stricter than Bubble",
      summary:
        "A Bubble page search evaluates a constraint or sort on a field the user may not " <>
          "view against its stored value (an oracle on hidden values; replayed 2026-10-01); " <>
          "with enforced policies the generated app matches nothing there: it returns only " <>
          "the records where the user may view every field the filter or sort reads"
    }
  }

  for {flag, %{bubble: b, target: t}} <- @policy do
    if Assumptions.defaults()[flag] != b or Assumptions.target()[flag] != t,
      do: raise("BubbleEx.Verify.Difference policy #{flag} disagrees with Assumptions")
  end

  @enforce_keys [:scenario, :op, :kind, :type, :bubble, :target]
  defstruct [
    :scenario,
    :op,
    :kind,
    :record,
    :type,
    :persona,
    :bubble,
    :target,
    flags: [],
    rules: []
  ]

  @type kind :: :visible | :visible_fields | :record_set
  @type t :: %__MODULE__{
          scenario: String.t(),
          op: String.t(),
          kind: kind(),
          record: String.t() | nil,
          type: String.t(),
          persona: String.t() | nil,
          bubble: term(),
          target: term(),
          flags: [atom()],
          rules: [String.t()]
        }

  @doc "The format name of the owner-repo differences file."
  @spec format() :: String.t()
  def format, do: @format

  @doc """
  The target policy: per flag on which the target intentionally differs
  from Bubble, `%{bubble, target, direction, decision, summary}`.
  """
  @spec policy() :: %{atom() => map()}
  def policy, do: @policy

  @doc "The policy's flags, sorted."
  @spec flags() :: [atom()]
  def flags, do: @policy |> Map.keys() |> Enum.sort()

  @doc """
  The policy's flags of one scope, sorted: `:rule_conditions` (how a
  privacy rule's condition reads; the privacy matrix checks them) or
  `:search_constraints` (how a search's own constraints and sort read the
  fields a user may not view; `privacy: :enforced` only, outside the
  matrix, whose constrained searches cover only non-filterable fields).
  """
  @spec flags(:rule_conditions | :search_constraints) :: [atom()]
  def flags(scope),
    do: for({flag, %{scope: ^scope}} <- @policy, do: flag) |> Enum.sort()

  @doc """
  `assumptions` with the policy's flags at their target reading: the
  interpreter under them shows what the intended differences alone
  change.
  """
  @spec intended(Assumptions.t()) :: Assumptions.t()
  def intended(assumptions),
    do: Enum.reduce(@policy, assumptions, fn {flag, p}, acc -> Map.put(acc, flag, p.target) end)

  @doc """
  Whether `target` is stricter than (or equal to) `bubble` for an
  observation kind: not visible where Bubble is, a subset of the fields,
  a subset of the records.
  """
  @spec stricter?(kind(), term(), term()) :: boolean()
  def stricter?(:visible, bubble, target), do: target == bubble or (bubble and not target)

  def stricter?(:visible_fields, bubble, target),
    do: MapSet.subset?(MapSet.new(target), MapSet.new(bubble))

  def stricter?(:record_set, %{records: bubble}, %{records: target}),
    do: MapSet.subset?(MapSet.new(target), MapSet.new(bubble))

  def stricter?(_kind, _bubble, _target), do: false

  @doc """
  Whether a compiled rule condition can differ between Bubble and the
  target under the policy: it reads the current user (an atom with an
  empty user-side value is where `actor_empty_denies` decides, a
  logged-out user where `logged_out_user_is_empty` does), or it compares
  a stored yes/no with something other than `yes` (an empty one is where
  `empty_yes_no_is_no` decides).
  """
  @spec affected?(IR.t() | nil) :: boolean()
  def affected?(ir), do: rule_flags(ir) != []

  @doc """
  The policy flags under which a compiled rule condition can make the
  target stricter than Bubble (see `affected?/1`), sorted:
  `actor_empty_denies` and `logged_out_user_is_empty` when it reads the
  current user, `empty_yes_no_is_no` when it compares a stored yes/no
  with other than `yes`.
  """
  @spec rule_flags(IR.t() | nil) :: [atom()]
  def rule_flags(nil), do: []

  def rule_flags(%IR{} = ir) do
    actor =
      if :current_user in IR.ops(ir),
        do: [:actor_empty_denies, :logged_out_user_is_empty],
        else: []

    yes_no = if yes_no_comparison?(ir), do: [:empty_yes_no_is_no], else: []
    Enum.sort(actor ++ yes_no)
  end

  # `x is y` / `is not` with a stored yes/no on one side and anything but
  # the literal `yes` on the other.
  defp yes_no_comparison?(%IR{op: op, args: [l, r]} = ir) when op in [:eq, :neq],
    do: yes_no_pair?(l, r) or yes_no_pair?(r, l) or Enum.any?(ir.args, &yes_no_comparison?/1)

  defp yes_no_comparison?(%IR{args: args}), do: Enum.any?(args, &yes_no_comparison?/1)
  defp yes_no_comparison?(list) when is_list(list), do: Enum.any?(list, &yes_no_comparison?/1)
  defp yes_no_comparison?(_), do: false

  defp yes_no_pair?(%IR{op: op, type: "boolean"}, other) when op in [:field, :fallback],
    do: not match?(%IR{op: :literal, args: [true]}, other)

  defp yes_no_pair?(_, _), do: false

  @doc """
  The structural list, from the Model alone: every rule whose condition
  compiles and can differ (`affected?/1`), where the target may deny what
  Bubble grants (`%{type, rule, flags}`, Bubble IDs, sorted), plus the
  `everyone` rule of a type when it grants something some other rule
  lacks (`everyone_narrowed?/3`): Bubble's `everyone` rule reaches every
  user, the target's only the users no rule lacking the grant matches.
  """
  @spec structural(Model.t()) :: [%{type: String.t(), rule: String.t(), flags: [atom()]}]
  def structural(%Model{} = model) do
    {:ok, interpreter} = Interpreter.new(model, assumptions: Assumptions.target())

    for {type_id, %{status: :rules} = info} <- Enum.sort(interpreter.types),
        affected = for(%{ir: ir, rule: r} <- info.rules, affected?(ir), do: r.id),
        rule <- Enum.sort(affected) ++ everyone(info),
        do: %{type: type_id, rule: rule, flags: flags(:rule_conditions)}
  end

  defp everyone(%{default: %{permissions: %{} = p}} = info) do
    others = Enum.map(info.rules, & &1.rule.permissions)

    if grants?(p) and everyone_narrowed?(p, others, MapSet.to_list(info.field_ids)),
      do: ["everyone"],
      else: []
  end

  defp everyone(_info), do: []

  @doc """
  Whether the `everyone` rule's reach differs between Bubble and the
  target (`everyone_exclusive`, `everyone_guards_record_values`): its
  permissions `everyone` grant a view, a search or a field (of `fields`,
  the type's field IDs) that some rule's permissions in `others` (nil:
  grants nothing) lack. Bubble then grants it to every user, the target
  only where none of those rules holds.
  """
  @spec everyone_narrowed?(map() | nil, [map() | nil], [String.t()]) :: boolean()
  def everyone_narrowed?(nil, _others, _fields), do: false

  def everyone_narrowed?(everyone, others, fields) do
    granted = granted(everyone, fields)

    MapSet.size(granted) > 0 and
      Enum.any?(others, &(not MapSet.subset?(granted, granted(&1, fields))))
  end

  defp grants?(p), do: p.view_all == true or (p.view_fields || []) != [] or p.search_for == true

  defp granted(nil, _fields), do: MapSet.new()

  defp granted(p, fields) do
    shown =
      if p.view_all == true, do: fields, else: Enum.filter(p.view_fields || [], &(&1 in fields))

    view = if p.view_all == true or shown != [], do: [:view], else: []
    search = if p.search_for == true, do: [:search], else: []
    MapSet.new(view ++ search ++ Enum.map(shown, &{:field, &1}))
  end

  # --- applying the record ----------------------------------------------------------

  @doc "The cases of scenario `scenario_id`."
  @spec for_scenario([t()], String.t()) :: [t()]
  def for_scenario(cases, scenario_id), do: Enum.filter(cases, &(&1.scenario == scenario_id))

  @doc """
  The observations the target must produce: each observation a case
  covers (same op, kind and record) whose value is the case's `bubble`
  value takes the case's `target` value. An observation whose value is
  something else (a Bubble recording that did not show what the
  interpreter predicts) is kept: the difference is not there to excuse.
  """
  @spec to_target([Observation.t()], [t()]) :: [Observation.t()]
  def to_target(observations, cases) do
    Enum.map(observations, fn o ->
      case Enum.find(cases, &covers?(&1, o)) do
        %__MODULE__{target: target} -> %{o | value: target}
        nil -> o
      end
    end)
  end

  @doc """
  `to_target/2` for observations seen through the Data API (a Bubble
  recording; `held` is `BubbleEx.Verify.DataApi.held_map/1`): a get whose
  recorded answer is the cases' Bubble answer (`DataApi.answer/3`) takes
  the cases' target answer (ID-only as `visible: false` with no fields).
  Searches as in `to_target/2`.
  """
  @spec to_target([Observation.t()], [t()], %{String.t() => [String.t()]}) :: [Observation.t()]
  def to_target(observations, cases, held) do
    {gets, others} = Enum.split_with(cases, &(&1.kind in [:visible, :visible_fields]))

    answers =
      gets
      |> Enum.group_by(&{&1.op, &1.record})
      |> Map.new(fn {{_op, record} = key, cs} ->
        h = Map.get(held, record, DataApi.always_held())
        v = Enum.find(cs, &(&1.kind == :visible))
        f = Enum.find(cs, &(&1.kind == :visible_fields))

        # A get whose fields differ is visible in Bubble; one whose
        # visibility alone differs shows no field either way.
        bubble = DataApi.answer((v && v.bubble) || is_nil(v), (f && f.bubble) || [], h)
        target = DataApi.answer(if(v, do: v.target, else: true), (f && f.target) || [], h)
        {key, {bubble, target}}
      end)

    recorded = recorded_answers(observations)

    observations
    |> Enum.map(fn o ->
      with {bubble, target} <- answers[{o.op, o.record}],
           true <- o.kind in [:visible, :visible_fields],
           ^bubble <- recorded[{o.op, o.record}] do
        %{o | value: answer_value(o.kind, target)}
      else
        _ -> o
      end
    end)
    |> to_target(others)
  end

  defp recorded_answers(observations) do
    observations
    |> Enum.filter(&(&1.kind in [:visible, :visible_fields]))
    |> Enum.group_by(&{&1.op, &1.record})
    |> Map.new(fn {key, obs} ->
      visible = Enum.any?(obs, &(&1.kind == :visible and &1.value == true))
      fields = Enum.find_value(obs, [], &(&1.kind == :visible_fields && &1.value))
      {key, if(visible and fields != [], do: {:fields, Enum.sort(fields)}, else: :id_only)}
    end)
  end

  defp answer_value(:visible, :id_only), do: false
  defp answer_value(:visible, {:fields, _}), do: true
  defp answer_value(:visible_fields, :id_only), do: []
  defp answer_value(:visible_fields, {:fields, fields}), do: fields

  defp covers?(c, %Observation{} = o),
    do:
      c.op == o.op and c.kind == o.kind and c.record == o.record and
        same?(c.kind, c.bubble, o.value)

  defp same?(:visible_fields, a, b), do: Enum.sort(a) == Enum.sort(b)
  defp same?(:record_set, %{records: a}, %{records: b}), do: Enum.sort(a) == Enum.sort(b)
  defp same?(_kind, a, b), do: a == b

  @doc """
  The case of `cases` (one scenario's) that explains a result diff entry
  (`record_visible`, `field_visible` or `record_set`, atom-keyed:
  `expected` is Bubble's value, `actual` the subject's), or nil. The entry
  must be stricter than Bubble, and within what the case takes away: a
  record the case hides or shows fewer fields of, a field the case hides,
  records the case drops from the search. Comparisons against Bubble
  recordings see both sides through the Data API (`BubbleEx.Verify.DataApi`),
  where a record left with no held field answers ID-only: with `held`
  (`DataApi.held_map/1`), a `record_visible` entry may stem from a case on
  the record's fields when the target shows none of its held fields.
  Without `held` it may not. An entry whose `actual` is missing (the op
  never ran) is never an intended difference.
  """
  @spec explaining([t()], map(), %{String.t() => [String.t()]} | nil) :: t() | nil
  def explaining(cases, entry, held \\ nil),
    do: Enum.find(cases, &explains?(&1, entry, held))

  defp explains?(%{kind: :visible} = c, %{op: "record_visible"} = e, _held),
    do:
      c.record == e[:record] and e[:expected] == true and e[:actual] == false and
        c.target == false

  defp explains?(%{kind: :visible_fields} = c, %{op: "record_visible"} = e, held)
       when is_map(held) do
    record_held = Map.get(held, c.record, DataApi.always_held())
    shown = Enum.filter(c.target, &(&1 in record_held))
    c.record == e[:record] and e[:expected] == true and e[:actual] == false and shown == []
  end

  defp explains?(c, e, _held), do: explains?(c, e)

  defp explains?(%{kind: :visible} = c, %{op: "field_visible"} = e),
    do:
      c.record == e[:record] and e[:expected] == true and e[:actual] == false and
        c.target == false

  defp explains?(%{kind: :visible_fields} = c, %{op: "field_visible"} = e),
    do:
      c.record == e[:record] and e[:expected] == true and e[:actual] == false and
        e[:field] in c.bubble and e[:field] not in c.target

  defp explains?(%{kind: :record_set} = c, %{op: "record_set"} = e) do
    with expected when is_list(expected) <- e[:expected],
         actual when is_list(actual) <- e[:actual] do
      dropped = expected -- actual
      removable = c.bubble.records -- c.target.records
      actual -- expected == [] and dropped != [] and dropped -- removable == []
    else
      _ -> false
    end
  end

  defp explains?(_c, _e), do: false

  @doc "A diff entry annotated with the case explaining it (`intended` flags and `rules`)."
  @spec annotate(map(), t()) :: map()
  def annotate(entry, %__MODULE__{} = c),
    do: Map.merge(entry, %{intended: Enum.map(c.flags, &Atom.to_string/1), rules: c.rules})

  # --- the owner's list ---------------------------------------------------------------

  @doc """
  The owner's list: per (type, rule), the flags, the personas and the
  number of observations where the target is stricter than Bubble. A
  case changing several rules counts for each. Sorted by type and rule.
  """
  @spec summary([t()]) :: [map()]
  def summary(cases) do
    cases
    |> Enum.flat_map(fn c -> for r <- rules_or_type(c), do: {{c.type, r}, c} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.map(fn {{type, rule}, group} ->
      %{
        type: type,
        rule: rule,
        flags: group |> Enum.flat_map(& &1.flags) |> Enum.uniq() |> Enum.sort(),
        personas:
          group |> Enum.map(& &1.persona) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
        observations: length(group),
        decision:
          group
          |> Enum.flat_map(& &1.flags)
          |> Enum.uniq()
          |> Enum.map(&@policy[&1].decision)
          |> Enum.uniq()
          |> Enum.join("; ")
      }
    end)
  end

  defp rules_or_type(%{rules: []}), do: [nil]
  defp rules_or_type(%{rules: rules}), do: rules

  # --- JSON ------------------------------------------------------------------------------

  @doc """
  The owner-repo differences document for a seed (`%{id, sha256}`): the
  policy and every case, in scenario, op, kind and record order.
  """
  @spec to_doc([t()], %{id: String.t(), sha256: String.t()}) :: map()
  def to_doc(cases, seed) do
    %{
      "format" => @format,
      "schema_version" => @schema_version,
      "seed" => %{"id" => seed.id, "sha256" => seed.sha256},
      "policy" =>
        Map.new(@policy, fn {flag, p} ->
          {Atom.to_string(flag),
           %{
             "bubble" => p.bubble,
             "target" => p.target,
             "direction" => Atom.to_string(p.direction),
             "decision" => p.decision,
             "summary" => p.summary
           }}
        end),
      "cases" => cases |> sort() |> Enum.map(&case_json/1)
    }
  end

  @doc "Canonical JSON of `to_doc/2`."
  @spec to_json([t()], %{id: String.t(), sha256: String.t()}) :: String.t()
  def to_json(cases, seed), do: cases |> to_doc(seed) |> CanonicalJson.encode()

  @doc "Sorts cases by scenario, op, kind and record."
  @spec sort([t()]) :: [t()]
  def sort(cases), do: Enum.sort_by(cases, &{&1.scenario, &1.op, &1.kind, &1.record})

  defp case_json(c) do
    %{
      "scenario" => c.scenario,
      "op" => c.op,
      "kind" => Atom.to_string(c.kind),
      "record" => c.record,
      "type" => c.type,
      "persona" => c.persona,
      "flags" => Enum.map(c.flags, &Atom.to_string/1),
      "rules" => c.rules,
      "bubble" => value_json(c, c.bubble),
      "target" => value_json(c, c.target)
    }
  end

  defp value_json(c, v),
    do: Observation.value_json(%Observation{op: c.op, kind: c.kind, record: c.record, value: v})

  @doc """
  Decodes a differences document: `{:ok, %{seed: %{id, sha256}, cases}}`.
  A policy that differs from this library's (another flag, direction or
  reading) is `:invalid_input`: the record must be the one this version
  would write.
  """
  @spec from_map(term()) :: {:ok, %{seed: map(), cases: [t()]}} | {:error, Error.t()}
  def from_map(map) do
    members = ~w(format schema_version seed policy cases)

    with :ok <- Json.envelope(map, @format, @schema_version, members, members, "differences"),
         :ok <- same_policy(map["policy"]),
         {:ok, seed} <- seed_ref(map["seed"]),
         {:ok, cases} <- Json.list(map["cases"], "differences cases", &case_from_map/1) do
      {:ok, %{seed: seed, cases: sort(cases)}}
    end
  end

  @doc "Decodes JSON text (see `from_map/1`)."
  @spec from_json(String.t()) :: {:ok, %{seed: map(), cases: [t()]}} | {:error, Error.t()}
  def from_json(text), do: Json.from_json(text, "differences", &from_map/1)

  defp same_policy(policy) do
    if policy == to_doc([], %{id: "x", sha256: nil})["policy"],
      do: :ok,
      else: Json.error("the differences' policy is not this library's", %{policy: policy})
  end

  defp seed_ref(%{"id" => id, "sha256" => sha} = map) when map_size(map) == 2 do
    with {:ok, id} <- Json.symbol(id, "differences seed id"),
         {:ok, sha} <- Json.sha256(sha, "differences seed sha256"),
         do: {:ok, %{id: id, sha256: sha}}
  end

  defp seed_ref(other), do: Json.error("differences seed must be {id, sha256}", %{seed: other})

  defp case_from_map(map) do
    keys = ~w(scenario op kind record type persona flags rules bubble target)

    with :ok <- Json.members(map, keys, keys -- ["record", "persona"], "difference case"),
         {:ok, scenario} <- Json.symbol(map["scenario"], "difference scenario"),
         {:ok, kind} <- Json.enum(map["kind"], @kinds, "difference kind"),
         {:ok, type} <- Json.string(map["type"], "difference type"),
         {:ok, flags} <- case_flags(map["flags"]),
         {:ok, rules} <- Json.string_set(map["rules"], "difference rules"),
         {:ok, bubble} <- case_value(map, "bubble"),
         {:ok, target} <- case_value(map, "target"),
         :ok <- case_stricter(kind, bubble.value, target.value) do
      {:ok,
       %__MODULE__{
         scenario: scenario,
         op: bubble.op,
         kind: kind,
         record: bubble.record,
         type: type,
         persona: map["persona"],
         flags: flags,
         rules: rules,
         bubble: bubble.value,
         target: target.value
       }}
    end
  end

  defp case_flags(list) when is_list(list) and list != [] do
    known = Enum.map(flags(), &Atom.to_string/1)

    if Enum.all?(list, &(&1 in known)),
      do: {:ok, list |> Enum.map(&String.to_existing_atom/1) |> Enum.uniq() |> Enum.sort()},
      else:
        Json.error("a difference names flags outside the policy", %{flags: list, policy: known})
  end

  defp case_flags(other), do: Json.error("a difference needs its policy flags", %{flags: other})

  defp case_value(map, key),
    do:
      Observation.from_map(%{
        "op" => map["op"],
        "kind" => map["kind"],
        "record" => map["record"],
        "value" => map[key]
      })

  defp case_stricter(kind, bubble, target) do
    if bubble != target and stricter?(kind, bubble, target),
      do: :ok,
      else: Json.error("a difference must be stricter than Bubble", %{kind: kind})
  end
end
