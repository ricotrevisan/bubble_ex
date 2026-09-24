defmodule BubbleEx.Expression.Diagnostic do
  @moduledoc """
  A structured note about part of an expression or privacy rule the parser
  could not fully model. `path` is an RFC 6901 JSON pointer into the supplied
  JSON, so every diagnostic can be traced to its exact source.

  Codes:

    * `:unknown_operator` — an operator outside the vocabulary (kept as `Raw`)
    * `:unknown_source` — a source type outside the vocabulary (kept as `Raw`)
    * `:unexpected_shape` — a known operator/source with missing or extra
      operands (kept as `Raw`)
    * `:malformed_node` — not an expression object at all (kept as `Raw`)
    * `:alias_collision` — the same key spelled both readable and compact
    * `:unresolved_order` — text entries whose order cannot be established
    * `:uninterpreted_field` — an unexpected member, preserved for round-trip
    * `:unresolved_field` — a field name absent from the subject's data type
    * `:unresolved_property` — an accessor on a subject of unknown type
    * `:unknown_constraint` — a constraint operator outside the vocabulary
    * `:unknown_permission` / `:invalid_permission` — privacy-rule permissions
      that are unmodeled or not booleans/field lists
    * `:missing_condition` — a non-default privacy rule without a condition
  """

  @type severity :: :error | :warning | :info
  @type t :: %__MODULE__{
          code: atom(),
          severity: severity(),
          path: String.t(),
          message: String.t()
        }

  @enforce_keys [:code, :severity, :path, :message]
  defstruct [:code, :severity, :path, :message]

  @severity %{
    unknown_operator: :error,
    unknown_source: :error,
    unexpected_shape: :error,
    malformed_node: :error,
    alias_collision: :error,
    unresolved_order: :error,
    invalid_permission: :error,
    uninterpreted_field: :warning,
    unresolved_field: :warning,
    unknown_constraint: :warning,
    unknown_permission: :warning,
    missing_condition: :warning,
    unresolved_property: :info
  }

  @spec new(atom(), list(), String.t()) :: t()
  def new(code, path, message),
    do: %__MODULE__{
      code: code,
      severity: Map.fetch!(@severity, code),
      path: pointer(path),
      message: message
    }

  @spec pointer(list()) :: String.t()
  defdelegate pointer(path), to: BubbleEx.Workflows.Source
end
