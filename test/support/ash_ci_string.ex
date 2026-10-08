unless Code.ensure_loaded?(Ash.CiString) do
  defmodule Ash.CiString do
    @moduledoc false
    # Stands in for Ash 3's case-insensitive string in tests (bubble_ex does
    # not depend on Ash), with its fields and its `value/1`: the generated
    # runtime recognizes it by its struct name and reads it with
    # `to_string/1`, which Ash implements through `value/1`.
    defstruct [:string, casted?: false, case: nil]

    def value(%__MODULE__{string: string, case: :lower, casted?: false}) when is_binary(string),
      do: String.downcase(string)

    def value(%__MODULE__{string: string}), do: string

    defimpl String.Chars do
      def to_string(ci_string), do: Ash.CiString.value(ci_string)
    end
  end
end
