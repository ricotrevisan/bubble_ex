defmodule BubbleEx.Frontend.Normalized.Source do
  @moduledoc false

  @type t :: %__MODULE__{
          path: [String.t()],
          map_key: String.t() | nil,
          bubble_id: String.t() | nil,
          payload: map() | nil
        }

  defstruct path: [], map_key: nil, bubble_id: nil, payload: nil
end
