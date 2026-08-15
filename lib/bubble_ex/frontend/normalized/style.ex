defmodule BubbleEx.Frontend.Normalized.Style do
  @moduledoc false

  @type t :: %__MODULE__{
          exporter_id: String.t(),
          map_key: String.t(),
          slug: String.t(),
          class_name: String.t(),
          display_name: String.t() | nil,
          applies_to: String.t() | nil,
          properties: map(),
          source: BubbleEx.Frontend.Normalized.Source.t()
        }

  @enforce_keys [:exporter_id, :map_key, :slug, :class_name]
  defstruct [
    :exporter_id,
    :map_key,
    :slug,
    :class_name,
    :display_name,
    :applies_to,
    :properties,
    :source
  ]
end
