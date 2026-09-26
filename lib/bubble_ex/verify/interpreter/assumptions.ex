defmodule BubbleEx.Verify.Interpreter.Assumptions do
  @moduledoc """
  The Bubble semantics the privacy interpreter (`BubbleEx.Verify.Interpreter`)
  takes on trust, each behind a named flag so that V5 calibration (WTF-358)
  can flip one and see which expectations change.

  Every default is the **compiler's fail-safe reading**: what
  `BubbleEx.Target.Ash.Expressions` and the generated Ash policies
  (`privacy: :unverified`) do. With the defaults, the interpreter predicts
  what the compiled policies select; flipping a flag predicts what Bubble
  would do if that semantic turns out otherwise.

  | flag | default | the default reading | flipped |
  |------|---------|---------------------|---------|
  | `actor_empty_denies` | `true` | an atomic comparison reading an empty value from the current user (or a logged-out user) is false in either polarity; `is empty` on the user's side needs a logged-in user | the user's empty values compare like any other empty value (`x is not y` holds, `doesn't contain` on an empty list holds, a logged-out user's fields are empty) |
  | `empty_equals_empty` | `true` | between two record-side values, empty `is` empty (and `is not` is false) | an empty value never equals anything, so `is` is false and `is not` holds |
  | `empty_yes_no_is_no` | `false` | an empty yes/no field is neither yes nor no (`x is no` is false) | an empty yes/no field reads as no |
  | `empty_list_contains_nothing` | `true` | a record-side list that is empty `doesn't contain` anything | `doesn't contain` on an empty list is false |
  | `dangling_ref_is_empty` | `true` | `is empty` on a reference to a record that no longer exists holds | such a reference is not empty (its stored ID counts) |
  | `everyone_exclusive` | `true` | the `everyone` rule applies only to users no other rule matches | the `everyone` rule's grants apply to every user |
  | `everyone_guards_record_values` | `true` | the `everyone` rule's grant of a permission some rules lack also needs every record value those rules' conditions read to be non-empty (the compiler's hedge: record-side emptiness is unverified) | no such guard: plain negation |
  | `builtin_fields_hidden_unless_listed` | `true` | when a rule does not view all fields, built-in fields (Created Date, Modified Date, Created By, Slug, email) are hidden unless listed | built-in fields are visible whenever the record is |
  | `no_visible_field_unreadable` | `true` | a record of which the user may view no field is not visible by direct view (`get`) | it is visible, with no fields |
  | `absent_permission_denied` | `true` | a permission flag the rule does not state is not granted | an absent flag grants |
  | `empty_text_contains_nothing` | `true` | `text contains` with an empty text is false (its negation holds); with an empty part, false in either polarity | an empty side reads as `""` (every text contains `""`) |
  | `ordering_with_empty_false` | `true` | `>`, `<`, `>=`, `<=` with an empty side are false in either polarity | an empty side reads as zero (0, the epoch, `""`) |
  | `empty_item_not_contained` | `true` | a record-side list `doesn't contain` an empty item | `doesn't contain` an empty item is false |
  | `search_independent_of_view` | `true` | `search_for` alone decides whether a record is found in searches | a record is found only when it is also visible by ID |
  | `logged_out_user_is_empty` | `true` | a logged-out user has no identity: `Current User` is empty | a logged-out user is Bubble's temporary user: a user of its own (never equal to a record's user) with empty fields |

  The four of WTF-384/385 (the Bubble semantics the compiler's
  `privacy: :unverified` gate rests on) are `empty_equals_empty`,
  `empty_yes_no_is_no`, `empty_list_contains_nothing` and
  `dangling_ref_is_empty` (`wtf_384/0`).

  Not listed: Bubble's `ignore_empty_constraints` default. It only matters
  for searches inside a condition, which the interpreter does not evaluate
  (such rules are unsolved).
  """

  alias BubbleEx.Error

  @flags [
    actor_empty_denies: true,
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
    logged_out_user_is_empty: true
  ]

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
  @type t :: %{name() => boolean()}

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

  @doc "The defaults: the compiler's fail-safe reading."
  @spec defaults() :: t()
  def defaults, do: Map.new(@flags)

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

  @doc "The flags of `assumptions` that differ from the defaults, sorted."
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
