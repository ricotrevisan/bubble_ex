defmodule BubbleEx.Load.Secret do
  @moduledoc """
  A credential (the Bubble admin API token) wrapped so that inspecting it,
  or anything holding it (a client map in a crash report, a
  `FunctionClauseError`), prints `#Secret<redacted>`. `value/1` is the
  only way to the text.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  @doc false
  @spec new(String.t()) :: t()
  def new(value) when is_binary(value), do: %__MODULE__{value: value}

  @doc "The wrapped text."
  @spec value(t()) :: String.t()
  def value(%__MODULE__{value: value}), do: value

  defimpl Inspect do
    def inspect(_secret, _opts), do: "#Secret<redacted>"
  end
end
