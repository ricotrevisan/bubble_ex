defmodule BubbleEx.Frontend.Normalized.Node do
  @moduledoc false

  @type kind ::
          :page
          | :group
          | :text
          | :image
          | :shape
          | :button
          | :link
          | :input
          | :reusable_definition
          | :reusable_instance
          | :placeholder

  @type t :: %__MODULE__{
          exporter_id: String.t(),
          kind: kind(),
          variant: atom() | nil,
          name: String.t() | nil,
          map_key: String.t(),
          source: BubbleEx.Frontend.Normalized.Source.t(),
          layout: map() | nil,
          box: map(),
          style: map(),
          content: map() | nil,
          children: [t()],
          bindings: map(),
          unmapped: map(),
          placeholder?: boolean(),
          definition_ref: String.t() | nil,
          attributes: map()
        }

  @enforce_keys [:exporter_id, :kind, :map_key, :source]
  defstruct [
    :exporter_id,
    :kind,
    :variant,
    :name,
    :map_key,
    :source,
    :definition_ref,
    layout: nil,
    box: %{},
    style: %{},
    content: nil,
    children: [],
    bindings: %{},
    unmapped: %{},
    placeholder?: false,
    attributes: %{}
  ]
end
