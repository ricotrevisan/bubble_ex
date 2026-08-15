defmodule BubbleEx.Frontend.Normalized.Identity do
  @moduledoc false

  @type t :: %__MODULE__{bubble_id: String.t(), app_version: String.t()}

  @enforce_keys [:bubble_id, :app_version]
  defstruct [:bubble_id, :app_version]
end
