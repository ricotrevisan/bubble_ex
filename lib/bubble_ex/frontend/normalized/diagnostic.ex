defmodule BubbleEx.Frontend.Normalized.Diagnostic do
  @moduledoc false

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          refs: [String.t()],
          details: map()
        }

  @enforce_keys [:code, :message]
  defstruct [:code, :message, refs: [], details: %{}]
end
