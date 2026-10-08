defmodule BubbleEx.Target.Elixir.Runtime do
  @moduledoc """
  The contract of the runtime module that Elixir compiled by
  `BubbleEx.Target.Elixir` calls (`Bubble.Runtime` by default). The
  generated app implements it (`@behaviour BubbleEx.Target.Elixir.Runtime`
  while bubble_ex is a dependency, or the same functions without it);
  bubble_ex ships no implementation.

  Every function receives possibly-empty values (`nil`) and must follow
  Bubble: an empty value is never an error. The functions in `stubs/0`
  have Bubble behavior this contract does not pin down yet (keyword
  matching, text encodings); a generated app must implement them
  against Bubble and test them there.
  """

  @type value :: term()

  @doc """
  A value as text (URL parameters, values a page workflow writes): `nil`
  is `""`, `1.0` is `"1"`, yes/no, a date Bubble's default display text in
  the user's time zone (`Oct 7, 2026 12:00 am`, replay 2026-10-07), a
  case-insensitive text (`Ash.CiString`, the generated User's email) its
  text, never its debug output (WTF-515).
  """
  @callback text(value()) :: String.t()
  @doc "`text/1` as Bubble's server converts a value (backend workflows): dates in UTC (replay 2026-10-07)."
  @callback utc_text(value()) :: String.t()
  @doc "A value as Bubble shows it on a page: `text/1` with dates in Bubble's default format."
  @callback display(value()) :: String.t()
  @doc "`is empty`: nil, `\"\"`, `[]`, or a field the user may not view (`%Ash.ForbiddenField{}`)."
  @callback empty?(value()) :: boolean()
  @doc """
  A compared value as Bubble reads it: a field the user may not view
  (`%Ash.ForbiddenField{}`) and an empty text (`""`, WTF-514: Bubble has
  no empty text apart from empty) are empty (nil), a case-insensitive text
  (`Ash.CiString`) is its text (WTF-515), any other value itself. `is` and
  `is not` compare every side that may be text or empty through it.
  """
  @callback unhidden(value()) :: value()
  @doc """
  A thing's Bubble ID: a record's `id`, an ID itself, nil otherwise (an
  empty text included, WTF-514). `is`,
  `is not` and `contains` compare things by ID through it when a side is
  not a field path (an element's thing, a property, a custom state).
  """
  @callback id(value()) :: value()
  @doc "`>`, `<`, `>=`, `<=`: false when either side is empty; dates compare as instants."
  @callback compare(:gt | :lt | :gte | :lte, value(), value()) :: boolean()
  @doc "`+` (numbers; a date plus an interval). Empty if either side is empty, as in Ash filters (Bubble's behavior with empty operands is not verified)."
  @callback add(value(), value()) :: value()
  @doc "`-` (numbers; date minus date is an interval)."
  @callback sub(value(), value()) :: value()
  @doc "`*`"
  @callback mul(value(), value()) :: value()
  @doc "`/`"
  @callback div(value(), value()) :: value()
  @doc "`%`"
  @callback mod(value(), value()) :: value()
  @doc "`defaulting to`: `d` when `x` is empty."
  @callback default(value(), value()) :: value()
  @callback lowercase(value()) :: value()
  @callback uppercase(value()) :: value()
  @callback trim(value()) :: value()
  @callback capitalize_words(value()) :: value()
  @callback text_length(value()) :: value()
  @doc """
  `:formatted as JSON-safe`: always text when not empty. A text is
  escaped; a yes/no is `"true"` or `"false"`; a number is its text
  (`text/1`), a date ISO 8601 in UTC. Compared with a text, it compares as text.
  """
  @callback json_encode(value()) :: value()
  @callback url_encode(value()) :: value()
  @callback is_email(value()) :: boolean()
  @callback abs(value()) :: value()
  @callback round(value()) :: value()
  @callback to_text(value()) :: value()
  @callback to_number(value()) :: value()
  @doc """
  `formatted as` a date; `format` is Bubble's pattern, `"iso_date"` or nil
  for its default (`BubbleEx.Target.Elixir.Formats`), shown in the user's
  time zone (the runtime's choice).
  """
  @callback format_date(value(), String.t() | nil) :: value()
  @doc "`format_date/2` in the time zone the expression names."
  @callback format_date(value(), String.t() | nil, value()) :: value()
  @doc "`formatted as` a number; `options` are Bubble's settings with readable keys."
  @callback format_number(value(), map()) :: value()
  @callback format_boolean(value(), value(), value()) :: value()
  @callback truncate(value(), value()) :: value()
  @callback replace(value(), value(), value(), boolean()) :: value()
  @callback split(value(), value()) :: value()
  @doc "`+(seconds)` … `+(years)`."
  @callback date_add(value(), value(), :second | :minute | :hour | :day | :month | :year) ::
              value()
  @doc "`rounded down to` a calendar unit, in the user's time zone."
  @callback date_floor(value(), String.t()) :: value()
  @doc "`date_floor/2` in the time zone the expression names."
  @callback date_floor(value(), String.t(), value()) :: value()
  @doc "`extract` a calendar part, in the user's time zone."
  @callback date_part(value(), String.t()) :: value()
  @doc "`date_part/2` in the time zone the expression names."
  @callback date_part(value(), String.t(), value()) :: value()
  @doc "`text contains string`: substring."
  @callback text_contains?(value(), value()) :: boolean()
  @doc "`text contains`: Bubble's keyword match."
  @callback text_contains_words?(value(), value()) :: boolean()

  @doc """
  `:converted to list`: an empty value (`empty?/1`, a field the user may
  not view included) is `[]`, a list itself, any other value a list of
  it. Every list the compiled code reads goes through it (WTF-500), so it
  must never raise.
  """
  @callback as_list(value()) :: list()
  @doc """
  `:unique elements`: the first occurrence of each item, in order. Things
  (records or Bubble IDs) are the same item when their IDs are; other
  values when equal.
  """
  @callback unique(value()) :: list()
  @doc "`:merged with`: `a`'s items, then `b`'s not in `a`, without duplicates (replay 2026-10-07)."
  @callback merge(value(), value()) :: list()
  @doc "`:minus list`: `a`'s items not in `b`, without duplicates."
  @callback minus_list(value(), value()) :: list()
  @doc """
  `:intersect with`: `b`'s items also in `a`, in `b`'s order (replay
  2026-10-07), without duplicates; a thing is a record over its ID.
  """
  @callback intersect(value(), value()) :: list()
  @doc """
  `:plus item`: `a` with `x` at the end, the whole list without duplicates;
  an empty `x` is appended (replay 2026-10-07).
  """
  @callback plus_item(value(), value()) :: list()
  @doc """
  `:sorted` on texts, numbers or dates (`descending?`): empty values first
  ascending, last descending (replay 2026-10-07); a stable sort.
  """
  @callback sort_values(value(), boolean()) :: list()
  @doc "`:minus item`: `a` without `x`."
  @callback minus_item(value(), value()) :: list()
  @doc "`:items until #n`: the first `n` items; none for an empty or non-positive `n`."
  @callback limit(value(), value()) :: list()
  @doc "`:item #n`: the `n`th item (from 1), else empty."
  @callback item_at(value(), value()) :: value()

  @stubs ~w(format_boolean text_contains_words? capitalize_words json_encode url_encode is_email)a

  @doc "Every function of the contract."
  @spec functions() :: [atom()]
  def functions,
    do:
      __MODULE__.behaviour_info(:callbacks)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.sort()

  @doc "The functions whose Bubble behavior is not pinned down yet (see the moduledoc)."
  @spec stubs() :: [atom()]
  def stubs, do: Enum.sort(@stubs)
end
