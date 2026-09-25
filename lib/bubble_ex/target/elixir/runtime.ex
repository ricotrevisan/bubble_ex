defmodule BubbleEx.Target.Elixir.Runtime do
  @moduledoc """
  The contract of the runtime module that Elixir compiled by
  `BubbleEx.Target.Elixir` calls (`Bubble.Runtime` by default). The
  generated app implements it (`@behaviour BubbleEx.Target.Elixir.Runtime`
  while bubble_ex is a dependency, or the same functions without it);
  bubble_ex ships no implementation.

  Every function receives possibly-empty values (`nil`) and must follow
  Bubble: an empty value is never an error. The functions in `stubs/0`
  have Bubble behavior this contract does not pin down yet (formats,
  calendars, keyword matching); a generated app must implement them
  against Bubble and test them there.
  """

  @type value :: term()

  @doc "A value as Bubble shows it in text: `nil` is `\"\"`, `1.0` is `\"1\"`, yes/no, dates."
  @callback text(value()) :: String.t()
  @doc "`is empty`: nil, `\"\"` or `[]`."
  @callback empty?(value()) :: boolean()
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
  @callback json_encode(value()) :: value()
  @callback url_encode(value()) :: value()
  @callback is_email(value()) :: boolean()
  @callback abs(value()) :: value()
  @callback round(value()) :: value()
  @callback to_text(value()) :: value()
  @callback to_number(value()) :: value()
  @doc "`formatted as` a date; `format` is Bubble's format text, nil for its default."
  @callback format_date(value(), String.t() | nil) :: value()
  @doc "`formatted as` a number; `options` are Bubble's settings verbatim."
  @callback format_number(value(), map()) :: value()
  @callback format_boolean(value(), value(), value()) :: value()
  @callback truncate(value(), value()) :: value()
  @callback replace(value(), value(), value(), boolean()) :: value()
  @callback split(value(), value()) :: value()
  @doc "`+(seconds)` … `+(years)`."
  @callback date_add(value(), value(), :second | :minute | :hour | :day | :month | :year) ::
              value()
  @callback date_floor(value(), String.t()) :: value()
  @callback date_part(value(), String.t()) :: value()
  @doc "`text contains string`: substring."
  @callback text_contains?(value(), value()) :: boolean()
  @doc "`text contains`: Bubble's keyword match."
  @callback text_contains_words?(value(), value()) :: boolean()

  @stubs ~w(format_date format_number format_boolean date_add date_floor date_part
            text_contains_words? capitalize_words json_encode url_encode is_email)a

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
