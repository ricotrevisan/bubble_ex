defmodule BubbleEx.Frontend.Normalized.Node do
  @moduledoc false

  # `runtime` describes behavior static markup cannot express, stack-neutrally
  # (string keys, JSON-ready), or is nil:
  #
  #   * `"boundary" => "overlay"` - a Popup, Group Focus or Floating Group:
  #     `"overlay"` (`"popup"`, `"group_focus"`, `"floating_group"`),
  #     `"initial"` (`"hidden"` or `"visible"`), `"toggle"` (`"workflow"`: shown
  #     and hidden by workflow actions), `"modal"`, `"placement"` (`"anchor"`
  #     `"viewport"` or `"element"` with its `"reference"`), `"dismiss"`
  #     (`"escape"`, `"outside_click"`), and optional `"backdrop"`, `"z_index"`
  #     (numeric stacking order) and, for a Floating Group, `"plane"`
  #     (`"front"` or `"back"` of the page's other elements).
  #   * `"boundary" => "container"` - a placeholder container whose content is
  #     rendered at runtime (a dynamic Repeating Group, a Table, a plugin
  #     container): its `children` are the normalized content, a per-item
  #     template when `"repeats"` is true. Static exports do not render them.

  @type kind ::
          :page
          | :group
          | :text
          | :image
          | :html_style
          | :icon
          | :shape
          | :button
          | :link
          | :input
          | :multiline_input
          | :checkbox
          | :dropdown
          | :radio_buttons
          | :floating_group
          | :popup
          | :group_focus
          | :reusable_definition
          | :reusable_instance
          | :repeating_group
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
          attributes: map(),
          responsive: [map()],
          occurrence: [non_neg_integer()],
          runtime: map() | nil
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
    attributes: %{},
    responsive: [],
    occurrence: [],
    runtime: nil
  ]
end
