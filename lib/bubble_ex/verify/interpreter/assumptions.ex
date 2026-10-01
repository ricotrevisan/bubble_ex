defmodule BubbleEx.Verify.Interpreter.Assumptions do
  @moduledoc """
  The Bubble semantics the privacy interpreter (`BubbleEx.Verify.Interpreter`)
  rests on, each behind a named flag so that calibration against Bubble
  recordings (V5 of WTF-358) can flip one and see which expectations
  change.

  **Two readings, kept apart (WTF-426).**

    * `defaults/0` is **Bubble's reading**: what the interpreter predicts
      Bubble does. It starts from the compiler's fail-safe reading and
      takes each flag calibration refuted (`evidence/0`):
      `actor_empty_denies` (the 2026-09-29 run: Bubble treats an empty
      actor-side value as equal to an empty record value), and
      `everyone_guards_record_values` and `logged_out_user_is_empty` (the
      2026-10-01 run, WTF-467: no record-value guard on the `everyone`
      rule's reach, and a logged-out user is Bubble's temporary user),
      plus two the samples lean on: `everyone_exclusive` (the `everyone`
      rule's grants reach every user: only 2 ops of that run tell it apart
      from an exclusive rule without the guard, both for it) and
      `empty_yes_no_is_no` (0 of 2, then 0 of 5 agreeing: an empty yes/no
      reads as no). One flag is Bubble's documented behavior instead:
      `hidden_field_constraint_matches` (WTF-457), which the compiler's
      reading never had.
    * `target/0` is the **generated policies' reading**: the compiler's
      fail-safe reading, which `BubbleEx.Target.Ash.Expressions` and the
      generated Ash policies (`privacy: :unverified`) implement. With it
      the interpreter predicts what the compiled policies select.

  Where the two differ by an owner decision (the five flags above, and
  `hidden_field_constraint_matches` with `privacy: :enforced`), the
  target is stricter than Bubble on purpose: `BubbleEx.Verify.Difference`
  holds that policy and records every case it applies to, so
  verification reports them as known, intentional differences instead of
  failures. A flag that differs
  without such a decision is a real difference.

  | flag | Bubble (default) | target | the `true` reading | the `false` reading |
  |------|------------------|--------|--------------------|---------------------|
  | `actor_empty_denies` | `false` | `true` | an atomic comparison reading an empty value from the current user (or a logged-out user) is false in either polarity; `is empty` on the user's side needs a logged-in user | the user's empty values compare like any other empty value (`x is y` holds when both are empty, `x is not y` holds, `doesn't contain` on an empty list holds, a logged-out user's fields are empty) |
  | `empty_equals_empty` | `true` | `true` | between two record-side values, empty `is` empty (and `is not` is false) | an empty value never equals anything, so `is` is false and `is not` holds |
  | `empty_yes_no_is_no` | `true` | `false` | an empty yes/no field reads as no | an empty yes/no field is neither yes nor no (`x is no` is false); `x is not no`, and `is not` between yes/no values with a record-side stored one, reads it as no under either reading (WTF-471, as the compiler) |
  | `empty_list_contains_nothing` | `true` | `true` | a record-side list that is empty `doesn't contain` anything | `doesn't contain` on an empty list is false |
  | `dangling_ref_is_empty` | `true` | `true` | `is empty` on a reference to a record that no longer exists holds | such a reference is not empty (its stored ID counts) |
  | `everyone_exclusive` | `false` | `true` | the `everyone` rule applies only to users no other rule matches | the `everyone` rule's grants apply to every user |
  | `everyone_guards_record_values` | `false` | `true` | the `everyone` rule's grant of a permission some rules lack also needs every record value those rules' conditions read to be non-empty (the compiler's hedge: record-side emptiness is unverified); a value read only by an emptiness test (`is empty`, `is not empty`) is not guarded, since negating that test is exact (WTF-430) | no such guard: plain negation |
  | `builtin_fields_hidden_unless_listed` | `true` | `true` | when a rule does not view all fields, built-in fields (Created Date, Modified Date, Created By, Slug, email) are hidden unless listed | built-in fields are visible whenever the record is |
  | `no_visible_field_unreadable` | `true` | `true` | a record of which the user may view no field is not visible by direct view (`get`) | it is visible, with no fields |
  | `absent_permission_denied` | `true` | `true` | a permission flag the rule does not state is not granted | an absent flag grants |
  | `empty_text_contains_nothing` | `true` | `true` | `text contains` with an empty text is false (its negation holds); with an empty part, false in either polarity | an empty side reads as `""` (every text contains `""`) |
  | `ordering_with_empty_false` | `true` | `true` | `>`, `<`, `>=`, `<=` with an empty side are false in either polarity | an empty side reads as zero (0, the epoch, `""`) |
  | `empty_item_not_contained` | `true` | `true` | a record-side list `doesn't contain` an empty item | `doesn't contain` an empty item is false |
  | `search_independent_of_view` | `true` | `true` | `search_for` alone decides whether a record is found in searches | a record is found only when it is also visible by ID |
  | `logged_out_user_is_empty` | `false` | `true` | a logged-out user has no identity: `Current User` is empty | a logged-out user is Bubble's temporary user: a user of its own (never equal to a record's user) with empty fields |
  | `defaults_applied_at_creation` | `true` | `true` | a record created without a value for a field that has a default (WTF-338: defaults are kept) stores the default: a field a record omits reads as its default; an explicitly empty field (`null` in a seed) stays empty | a field a record omits is empty; defaults are never applied |
  | `non_filterable_constraint_excludes` | `true` | `true` | a search constrained on a field the user may not search by (a privacy rule's non-filterable fields) does not find the records where the user may not; the generated policies (`<namespace>.Privacy.SearchFields`) return only the records where the user may | such a constraint is ignored for those records: they are found as by the unconstrained search |
  | `compared_condition_guards_record_values` | `false` | `true` | a condition compared with another yes/no as a value (`(list contains x) is y`), neither side reading the user: its negative side also needs every record value it reads to be non-empty (the compiler's hedge, WTF-471: such a negation can hold on an empty value, `empty_list_contains_nothing` / `empty_text_contains_nothing`, which no calibration has settled) | no such guard: the negation as in any condition |
  | `hidden_field_constraint_matches` | `true` | `false` | a page search constrained or sorted on a field the user may not view (but may search by) matches its stored value: view and constraint are separate permissions in Bubble (replayed 2026-10-01; a backend workflow's search reads the field as empty, a Data API search matches nothing) | a record whose field the user may not view matches nothing: only the records where the user may view the field are found; the generated policies with `privacy: :enforced` (`<namespace>.Privacy.SearchFields`, WTF-457) |

  ## Calibration evidence

  `evidence/0` records, per flag, what the calibration run that settled
  it showed (the V5 runs of WTF-385: 2026-09-29, 480 scenarios and 1,224
  ops; 2026-10-01, 498 scenarios and 1,392 ops, the model built from the
  replay branch's own export). Counts are ops whose expectation depends
  on the flag, compared fairly, that is restricted to the fields the
  record holds (`BubbleEx.Verify.DataApi`), under the reading before the
  flip:

    * `:refuted` - Bubble reads it the other way; the Bubble default was
      flipped (`actor_empty_denies`, 2026-09-29: 14 agree / 69 disagree,
      flipping fixes 64 and breaks 5, confirmed 2026-10-01 at 73 / 12;
      2026-10-01: `everyone_guards_record_values` 0 / 18, fixes 17;
      `logged_out_user_is_empty` 0 / 12, fixes 12; none breaks any)
    * `:supported` - the default agrees (`empty_equals_empty`,
      `builtin_fields_hidden_unless_listed`, `no_visible_field_unreadable`,
      `search_independent_of_view`)
    * `:leaning_flipped` - the samples lean the other way but are few
      (`empty_yes_no_is_no`: 0 / 2, then 0 / 5, flipping fixes all and
      breaks none; `everyone_exclusive`: 19 ops depended on it, 0 agreeing,
      but 17 of them are also fixed by dropping the record-value guard
      alone, so only 2 discriminate, recorded as 0 / 2, both fixed by the
      flip). Flipped all the same (WTF-467: no sample against); still
      unsettled, so the matrix adds witnesses for them (`unsettled/0`,
      `BubbleEx.Verify.Matrix.Coverage`; the next replay is to settle
      `everyone_exclusive`, WTF-358)
    * `:unclear` - mixed, or too few samples (`empty_list_contains_nothing`:
      8 agree, none disagree)
    * `:not_exercised` - no recorded check depended on it (the other
      six, and `non_filterable_constraint_excludes`; Bubble's manual
      supports its reading: a search constrained on a field a user may not
      constrain on returns nothing for that user)
    * `:documented` - no matrix check depended on it, but a targeted
      replay and Bubble's manual settle it (`hidden_field_constraint_matches`,
      WTF-457: the 2026-10-01 replay of WTF-385 found a page search
      matching a hidden field's stored value, 4 probes of 4; a backend
      workflow's search reads it as empty, a Data API search matches
      nothing). Not unsettled: the target differs from it by the owner's
      decision, and the matrix's constrained searches cover only
      non-filterable fields

  With the 2026-10-01 flips, 1,354 of the run's 1,392 ops agree (97.3%,
  from 94.7%); the 38 left are four types' anomalies, not interpreter
  semantics. `everyone_guards_record_values` is moot in Bubble's reading:
  with `everyone_exclusive` off, the `everyone` rule's reach has no guard
  to apply (17 of the 19 `everyone_exclusive` fixes are also fixed by
  dropping the guard alone; 2 tell the readings apart). The 2026-09-29
  run's other findings: 68 disagreements came from privacy rules changed
  since the export the matrix was built from (the 2026-10-01 run used a
  fresh one); an ID-only `get` answer is ambiguous
  (`BubbleEx.Verify.DataApi`); and Bubble's `ignore_empty_constraints`
  was inconclusive (all three variants found nothing).

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
    empty_yes_no_is_no: true,
    empty_list_contains_nothing: true,
    dangling_ref_is_empty: true,
    everyone_exclusive: false,
    everyone_guards_record_values: false,
    builtin_fields_hidden_unless_listed: true,
    no_visible_field_unreadable: true,
    absent_permission_denied: true,
    empty_text_contains_nothing: true,
    ordering_with_empty_false: true,
    empty_item_not_contained: true,
    search_independent_of_view: true,
    logged_out_user_is_empty: false,
    defaults_applied_at_creation: true,
    non_filterable_constraint_excludes: true,
    hidden_field_constraint_matches: true,
    compared_condition_guards_record_values: false
  ]

  # The generated policies' reading: the compiler's fail-safe one.
  @target @flags
          |> Keyword.put(:actor_empty_denies, true)
          |> Keyword.put(:empty_yes_no_is_no, false)
          |> Keyword.put(:everyone_exclusive, true)
          |> Keyword.put(:everyone_guards_record_values, true)
          |> Keyword.put(:logged_out_user_is_empty, true)
          |> Keyword.put(:hidden_field_constraint_matches, false)
          |> Keyword.put(:compared_condition_guards_record_values, true)

  # The calibration runs (V5 of WTF-385) and, per flag, the run that
  # settled it: ops that depend on the flag, agreeing and disagreeing
  # (fair comparison, under the reading before any flip), and how many
  # disagreements flipping it fixed and agreements it broke.
  @run_0929 "V5 (WTF-385, 2026-09-29)"
  @run_1001 "V5 (WTF-385, 2026-10-01)"
  @evidence %{
    actor_empty_denies: {:refuted, 14, 69, 64, 5, @run_0929},
    empty_equals_empty: {:supported, 73, 12, 11, 73, @run_1001},
    # 19 dependent ops, 17 of them also fixed by dropping the guard alone:
    # only the 2 that tell the readings apart are counted.
    everyone_exclusive: {:leaning_flipped, 0, 2, 2, 0, @run_1001},
    everyone_guards_record_values: {:refuted, 0, 18, 17, 0, @run_1001},
    logged_out_user_is_empty: {:refuted, 0, 12, 12, 0, @run_1001},
    empty_yes_no_is_no: {:leaning_flipped, 0, 5, 5, 0, @run_1001},
    empty_list_contains_nothing: {:unclear, 8, 0, 0, 8, @run_1001},
    builtin_fields_hidden_unless_listed: {:supported, 33, 16, 0, 33, @run_1001},
    no_visible_field_unreadable: {:supported, 328, 98, 0, 215, @run_0929},
    search_independent_of_view: {:supported, 5, 24, 0, 5, @run_0929},
    hidden_field_constraint_matches: {:documented, 0, 0, 0, 0, @run_1001}
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
          | :hidden_field_constraint_matches
          | :compared_condition_guards_record_values
  @type t :: %{name() => boolean()}
  @type status ::
          :refuted | :supported | :leaning_flipped | :unclear | :not_exercised | :documented
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
  Per flag, what the calibration run that settled it showed (see the
  moduledoc; the latest run for a flag no run settled): status, run, and
  the agreeing and disagreeing ops that depend on it,
  with how many disagreements flipping it fixes and agreements it breaks.
  """
  @spec evidence() :: %{name() => evidence()}
  def evidence do
    Map.new(names(), fn flag ->
      {status, agree, disagree, fixes, breaks, run} =
        Map.get(@evidence, flag, {:not_exercised, 0, 0, 0, 0, @run_1001})

      {flag,
       %{
         status: status,
         run: run,
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
