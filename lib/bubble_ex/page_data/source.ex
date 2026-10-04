defmodule BubbleEx.PageData.Source do
  @moduledoc """
  One data source of a page (`BubbleEx.PageData`, WTF-420):

    * `id` - its index symbol (`page:<id>` for a page's thing,
      `element:<id>` otherwise)
    * `element` - the Bubble ID of the page or element whose data it is
    * `surface` - the Bubble ID of its page or reusable element;
      `surface_kind` `:page` or `:reusable`
    * `kind` - `:page_thing`, `:group`, `:list`, `:instance` or `:param`
    * `holder` - for `:instance`, the reusable element whose thing it sets;
      for `:param`, the reusable element whose property it sets
    * `param` - for `:param`, the property (`"param_<id>"`, the element
      state its reads name): its value on the instance `element`, or, when
      `element` is the reusable element itself, its default
    * `type` - the Bubble type of its value (`"custom.task"`,
      `"list.custom.task"`), when known
    * `value` - its data source as a `BubbleEx.Workflows.Lowering.Expr`
      (nil for a page's thing, which comes from the URL)
    * `cell` - the repeating group whose cell holds it, or nil
    * `page_size` - for `:list`, the items a page shows (nil: all)
    * `residue` - `BubbleEx.Plan.Residue` entries; `path` - JSON pointer
  """

  @enforce_keys [:id, :element, :surface, :kind]
  defstruct [
    :id,
    :element,
    :surface,
    :surface_kind,
    :kind,
    :holder,
    :param,
    :type,
    :value,
    :cell,
    :page_size,
    :path,
    residue: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          element: String.t(),
          surface: String.t(),
          surface_kind: :page | :reusable,
          kind: :page_thing | :group | :list | :instance | :param,
          holder: String.t() | nil,
          param: String.t() | nil,
          type: String.t() | nil,
          value: BubbleEx.Workflows.Lowering.Expr.t() | nil,
          cell: String.t() | nil,
          page_size: pos_integer() | nil,
          path: String.t() | nil,
          residue: [BubbleEx.Plan.Residue.t()]
        }

  @doc "Whether the source lowers with no residue."
  @spec native?(t()) :: boolean()
  def native?(%__MODULE__{residue: residue}), do: residue == []
end
