defmodule BubbleEx.Frontend.Export.Result do
  @moduledoc """
  Successful frontend export. JSON artifacts are the deterministic encoding of
  `model`, `bindings`, `findings`, `coverage`, and `manifest`. HTML/CSS strings
  are not included.
  """

  alias BubbleEx.Frontend.Normalized

  @type t :: %__MODULE__{
          out_dir: String.t(),
          files: [String.t()],
          model: Normalized.t(),
          bindings: [map()],
          findings: [map()],
          coverage: map(),
          manifest: map()
        }

  @enforce_keys [:out_dir, :files, :model, :bindings, :findings, :coverage, :manifest]
  defstruct [:out_dir, :files, :model, :bindings, :findings, :coverage, :manifest]
end
