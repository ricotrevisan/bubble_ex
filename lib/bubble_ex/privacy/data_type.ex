defmodule BubbleEx.Privacy.DataType do
  @moduledoc """
  The privacy rules of one data type.

  `availability` separates "no rules" from "not supplied":

    * `:present` - the source includes the type's rules (possibly none)
    * `:none` - a `.bubble` export lists the type without rules, so Bubble's
      defaults apply (everyone can view and find everything)
    * `:unavailable` - the source (e.g. the live payload, which never ships
      privacy rules) cannot say
  """

  alias BubbleEx.Expression.Diagnostic
  alias BubbleEx.Privacy.Rule

  @enforce_keys [:id, :availability, :path]
  defstruct [:id, :name, :availability, :path, rules: [], diagnostics: []]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          availability: :present | :none | :unavailable,
          path: String.t(),
          rules: [Rule.t()],
          diagnostics: [Diagnostic.t()]
        }
end
