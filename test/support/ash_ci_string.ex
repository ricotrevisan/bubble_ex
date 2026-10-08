defmodule Ash.CiString do
  @moduledoc false
  # Stands in for Ash's case-insensitive string in tests (bubble_ex does not
  # depend on Ash): the generated runtime recognizes it by its struct name
  # and reads it with `to_string/1`, as Ash's String.Chars implementation.
  defstruct [:string, lowered?: false, case_insensitive?: true]

  defimpl String.Chars do
    def to_string(%{string: string, lowered?: true}), do: String.downcase(string)
    def to_string(%{string: string}), do: string
  end
end
