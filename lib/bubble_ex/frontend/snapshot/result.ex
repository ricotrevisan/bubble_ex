defmodule BubbleEx.Frontend.Snapshot.Result do
  @moduledoc "A published browser snapshot and its capture provenance."
  @enforce_keys [:out_dir, :files, :manifest, :findings]
  defstruct [:out_dir, :files, :manifest, :findings]

  @type t :: %__MODULE__{
          out_dir: String.t(),
          files: [String.t()],
          manifest: map(),
          findings: [map()]
        }
end
