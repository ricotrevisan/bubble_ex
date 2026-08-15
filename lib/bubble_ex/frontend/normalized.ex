defmodule BubbleEx.Frontend.Normalized do
  @moduledoc """
  Versioned, serializable normalized frontend model (#25).

  Normalization is a pure transformation of one decoded app payload. Network
  facts (downloaded asset hashes, fetch failures) do not live here.
  """

  alias BubbleEx.Frontend.Normalized.{Diagnostic, Identity, Node, Source, Style}

  @schema_version 1

  @type t :: %__MODULE__{
          normalized_schema_version: pos_integer(),
          identity: Identity.t(),
          source: Source.t(),
          pages: [Node.t()],
          reusables: [Node.t()],
          styles: [Style.t()],
          diagnostics: [Diagnostic.t()]
        }

  defstruct [
    :identity,
    :source,
    :pages,
    :reusables,
    :styles,
    :diagnostics,
    normalized_schema_version: @schema_version
  ]

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version
end
