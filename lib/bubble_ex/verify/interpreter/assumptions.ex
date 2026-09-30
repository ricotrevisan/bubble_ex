defmodule BubbleEx.Verify.Interpreter.Assumptions do
  @moduledoc """
  The Bubble semantics the privacy interpreter (`BubbleEx.Verify.Interpreter`)
  rests on, each behind a named flag so that calibration against Bubble
  recordings (V5 of WTF-358) can flip one and see which expectations
  change.

  **Two readings, kept apart (WTF-426).**

    * `defaults/0` is **Bubble's reading**: what the interpreter predicts
      Bubble does. It starts from the compiler's fail-safe reading and
      takes each flag calibration settled (`evidence/0`): today only
      `actor_empty_denies`, refuted by the V5 run (Bubble treats an empty
      actor-side value as equal to an empty record value).
    * `target/0` is the **generated policies' reading**: the compiler's
      fail-safe reading, which `BubbleEx.Target.Ash.Expressions` and the
      generated Ash policies (`privacy: :unverified`) implement. With it
      the interpreter predicts what the compiled policies select.

  Where the two differ by an owner decision, the target is stricter than
  Bubble on purpose: `BubbleEx.Verify.Difference` holds that policy and
  records every case it applies to, so verification reports them as
  known, intentional differences instead of failures. A flag that differs
  without such a decision is a real difference.

  | flag | Bubble (default) | target | the `true` reading | the `false` reading |
  |------|------------------|--------|--------------------|---------------------|
  | `actor_empty_denies` | `false` | `true` | an atomic comparison reading an empty value from the current user (or a logged-out user) is false in either polarity; `is empty` on the user's side needs a logged-in user | the user's empty values compare like any other empty value (`x is y` holds when both are empty, `x is not y` holds, `doesn't contain` on an empty list holds, a logged-out user's fields are empty) |
  | `empty_equals_empty` | `true` | `true` | between two record-side values, empty `is` empty (and `is not` is false) | an empty value never equals anything, so `is` is false and `is not` holds |
  | `empty_yes_no_is_no` | `false` | `false` | an empty yes/no field reads as no | an empty yes/no field is neither yes nor no (`x is no` is false) |
  | `empty_list_contains_nothing` | `true` | `true` | a record-side list that is empty `doesn't contain` anything | `doesn't contain` on an empty list is false |
  | `dangling_ref_is_empty` | `true` | `true` | `is empty` on a reference to a record that no longer exists holds | such a reference is not empty (its stored ID counts) |
  | `everyone_exclusive` | `true` | `true` | the `everyone` rule applies only to users no other rule matches | the `everyone` rule's grants apply to every user |
  | `everyone_guards_record_values` | `true` | `true` | the `everyone` rule's grant of a permission some rules lack also needs every record value those rules' conditions read to be non-empty (the compiler's hedge: record-side emptiness is unverified); a value read only by an emptiness test (`is empty`, `is not empty`) is not guarded, since negating that test is exact (WTF-430) | no such guard: plain negation |
  | `builtin_fields_hidden_unless_listed` | `true` | `true` | when a rule does not view all fields, built-in fields (Created Date, Modified Date, Created By, Slug, email) are hidden unless listed | built-in fields are visible whenever the record is |
  | `no_visible_field_unreadable` | `true` | `true` | a record of which the user may view no field is not visible by direct view (`get`) | it is visible, with no fields |
  | `absent_permission_denied` | `true` | `true` | a permission flag the rule does not state is not granted | an absent flag grants |
  | `empty_text_contains_nothing` | `true` | `true` | `text contains` with an empty text is false (its negation holds); with an empty part, false in either polarity | an empty side reads as `""` (every text contains `""`) |
  | `ordering_with_empty_false` | `true` | `true` | `>`, `<`, `>=`, `<=` with an empty side are false in either polarity | an empty side reads as zero (0, the epoch, `""`) |
  | `empty_item_not_contained` | `true` | `true` | a record-side list `doesn't contain` an empty item | `doesn't contain` an empty item is false |
  | `search_independent_of_view` | `true` | `true` | `search_for` alone decides whether a record is found in searches | a record is found only when it is also visible by ID |
  | `logged_out_user_is_empty` | `true` | `true` | a logged-out user has no identity: `Current User` is empty | a logged-out user is Bubble's temporary user: a user of its own (never equal to a record's user) with empty fields |
  | `defaults_applied_at_creation` | `true` | `true` | a record created without a value for a field that has a default (WTF-338: defaults are kept) stores the default: a field a record omits reads as its default; an explicitly empty field (`null` in a seed) stays empty | a field a record omits is empty; defaults are never applied |
  | `non_filterable_constraint_excludes` | `true` | `true` | a search constrained on a field the user may not search by (a privacy rule's non-filterable fields) does not find the records where the user may not; the generated policies (`<namespace>.Privacy.SearchFields`) return only the records where the user may | such a constraint is ignored for those records: they are found as by the unconstrained search |

  ## Calibration evidence

  `evidence/0` records, per flag, what the last calibration run showed
  (the V5 run of WTF-385, 2026-09-29: 480 scenarios, 1,224 ops; counts
  are ops whose expectation depends on the flag, compared fairly, that is
  restricted to the fields the record holds: `BubbleEx.Verify.DataApi`):

    * `:refuted` - Bubble reads it the other way; the Bubble default was
      flipped (`actor_empty_denies`, 14 agree / 69 disagree, flipping
      fixes 64 and breaks 5)
    * `:supported` - the default agrees (`builtin_fields_hidden_unless_listed`,
      `no_visible_field_unreadable`, `search_independent_of_view`)
    * `:leaning_flipped` - the samples lean the other way but are too few
      to flip (`logged_out_user_is_empty`, `everyone_exclusive`,
      `empty_yes_no_is_no`); the matrix adds witnesses for them
      (`unsettled/0`, `BubbleEx.Verify.Matrix.Coverage`)
    * `:unclear` - mixed (`everyone_guards_record_values`)
    * `:not_exercised` - no recorded check depended on it (the other
      eight, and `non_filterable_constraint_excludes`, added after the
      run)

  A flag is flipped only on a `:refuted` verdict. The run's other
  findings: 68 disagreements came from privacy rules changed since the
  export the matrix was built from (refresh the export before the next
  run); an ID-only `get` answer is ambiguous (`BubbleEx.Verify.DataApi`);
  and Bubble's `ignore_empty_constraints` was inconclusive (all three
  variants found nothing).

  The four of WTF-384/385 (the Bubble semantics the compiler's
  `privacy: :unverified` gate rests on) are `empty_equals_empty`,
  `empty_yes_no_is_no`, `empty_list_contains_nothing` and
  `dangling_ref_is_empty` (`wtf_384/0`).

  `defaults_applied_at_creation` is not a compiler hedge: the generated
  Ash resources carry the same defaults (`BubbleEx.Target.Ash`), so either
  reading agrees with them only for records created without the field. It
  is the interpreter's reading of when Bubble applies a field's default
  (on creation, through every creation path: workflows, the Data API, bulk
  uploads). A Data API create was seen storing defaults (WTF-385), but no
  matrix check has depended on it yet.

  Not listed: Bubble's `ignore_empty_constraints` default. It only matters
  for searches inside a condition, which the interpreter does not evaluate
  (such rules are unsolved).
  """

  alias BubbleEx.Error

  # Bubble's reading (calibrated). The target's reading is `@target`.
  @flags [
    actor_empty_denies: false,
    empty_equals_empty: true,
    empty_yes_no_is_no: false,
    empty_list_contains_nothing: true,
    dangling_ref_is_empty: true,
    everyone_exclusive: true,
    everyone_guards_record_values: true,
    builtin_fields_hidden_unless_listed: true,
    no_visible_field_unreadable: true,
    absent_permission_denied: true,
    empty_text_contains_nothing: true,
    ordering_with_empty_false: true,
    empty_item_not_contained: true,
    search_independent_of_view: true,
    logged_out_user_is_empty: true,
    defaults_applied_at_creation: true,
    non_filterable_constraint_excludes: true
  ]

  # The generated policies' reading: the compiler's fail-safe one.
  @target Keyword.put(@flags, :actor_empty_denies, true)

  # The last calibration run (V5 of WTF-385, 2026-09-29): ops that depend
  # on the flag, agreeing and disagreeing (fair comparison), and how many
  # disagreements flipping it fixes and agreements it breaks.
  @run "V5 (WTF-385, 2026-09-29)"
  @evidence %{
    actor_empty_denies: {:refuted, 14, 69, 64, 5},
    logged_out_user_is_empty: {:leaning_flipped, 1, 7, 7, 0},
    everyone_exclusive: {:leaning_flipped, 24, 13, 5, 0},
    empty_yes_no_is_no: {:leaning_flipped, 0, 2, 2, 0},
    everyone_guards_record_values: {:unclear, 12, 3, 2, 0},
    builtin_fields_hidden_unless_listed: {:supported, 35, 14, 0, 27},
    no_visible_field_unreadable: {:supported, 328, 98, 0, 215},
    search_independent_of_view: {:supported, 5, 24, 0, 5}
  }

  @type name ::
          :actor_empty_denies
          | :empty_equals_empty
          | :empty_yes_no_is_no
          | :empty_list_contains_nothing
          | :dangling_ref_is_empty
          | :everyone_exclusive
          | :everyone_guards_record_values
          | :builtin_fields_hidden_unless_listed
          | :no_visible_field_unreadable
          | :absent_permission_denied
          | :empty_text_contains_nothing
          | :ordering_with_empty_false
          | :empty_item_not_contained
          | :search_independent_of_view
          | :logged_out_user_is_empty
          | :defaults_applied_at_creation
          | :non_filterable_constraint_excludes
  @type t :: %{name() => boolean()}
  @type status :: :refuted | :supported | :leaning_flipped | :unclear | :not_exercised
  @type evidence :: %{
          status: status(),
          run: String.t(),
          agree: non_neg_integer(),
          disagree: non_neg_integer(),
          flip_fixes: non_neg_integer(),
          flip_breaks: non_neg_integer()
        }

  @doc "Every flag name, in the documented order."
  @spec names() :: [name()]
  def names, do: Keyword.keys(@flags)

  @doc "The flags of the WTF-384/385 replay tests."
  @spec wtf_384() :: [name()]
  def wtf_384,
    do: [
      :empty_equals_empty,
      :empty_yes_no_is_no,
      :empty_list_contains_nothing,
      :dangling_ref_is_empty
    ]

  @doc "The defaults: Bubble's reading, as calibrated (`evidence/0`)."
  @spec defaults() :: t()
  def defaults, do: Map.new(@flags)

  @doc """
  The generated policies' reading: the compiler's fail-safe one. The
  interpreter under it predicts what the compiled Ash policies select.
  """
  @spec target() :: t()
  def target, do: Map.new(@target)

  @doc """
  Per flag, what the last calibration run showed (see the moduledoc):
  status, run, and the agreeing and disagreeing ops that depend on it,
  with how many disagreements flipping it fixes and agreements it breaks.
  """
  @spec evidence() :: %{name() => evidence()}
  def evidence do
    Map.new(names(), fn flag ->
      {status, agree, disagree, fixes, breaks} =
        Map.get(@evidence, flag, {:not_exercised, 0, 0, 0, 0})

      {flag,
       %{
         status: status,
         run: @run,
         agree: agree,
         disagree: disagree,
         flip_fixes: fixes,
         flip_breaks: breaks
       }}
    end)
  end

  @doc """
  The flags calibration has not settled (leaning, unclear or not
  exercised), in the documented order: the matrix looks for more
  witnesses of them.
  """
  @spec unsettled() :: [name()]
  def unsettled do
    evidence = evidence()

    for flag <- names(),
        evidence[flag].status in [:leaning_flipped, :unclear, :not_exercised],
        do: flag
  end

  @doc """
  The defaults with `overrides` (a map or keyword list of flag names to
  booleans) applied. An unknown flag or a non-boolean value is
  `:invalid_input`.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(overrides \\ []) do
    Enum.reduce_while(overrides, {:ok, defaults()}, fn
      {name, value}, {:ok, acc} when is_boolean(value) and is_map_key(acc, name) ->
        {:cont, {:ok, Map.put(acc, name, value)}}

      {name, value}, _acc ->
        {:halt,
         {:error,
          Error.new(:invalid_input, "unknown interpreter assumption or non-boolean value", %{
            assumption: name,
            value: value,
            allowed: names()
          })}}
    end)
  end

  @doc "The flags of `assumptions` that differ from the defaults (Bubble's reading), in order."
  @spec changed(t()) :: [name()]
  def changed(assumptions),
    do: for({name, default} <- @flags, Map.fetch!(assumptions, name) != default, do: name)

  @doc "`assumptions` with `name` flipped."
  @spec flip(t(), name()) :: t()
  def flip(assumptions, name), do: Map.update!(assumptions, name, &(not &1))

  @doc "JSON form: flag names to booleans."
  @spec to_map(t()) :: %{String.t() => boolean()}
  def to_map(assumptions), do: Map.new(assumptions, fn {k, v} -> {Atom.to_string(k), v} end)
end
