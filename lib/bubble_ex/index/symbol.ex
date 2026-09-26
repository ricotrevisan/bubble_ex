defmodule BubbleEx.Index.Symbol do
  @moduledoc """
  One named thing in a Bubble app, identified by stable Bubble IDs only.

  `id` is `"<kind>:<part>/<part>…"`, built by `id/2` from the Bubble IDs
  that identify the symbol (`/` and `~` inside a part are escaped as in a
  JSON pointer). It never contains a display name, so renaming something in
  the Bubble editor never changes its ID:

  | kind              | parts                          | example                          |
  |-------------------|--------------------------------|----------------------------------|
  | `:data_type`      | type key                       | `data_type:task`                 |
  | `:field`          | type key, field key            | `field:task/title_text`          |
  | `:option_set`     | option set key                 | `option_set:status`              |
  | `:option_value`   | option set key, db value       | `option_value:status/open`       |
  | `:option_attribute` | option set key, attribute key | `option_attribute:status/color`  |
  | `:page`           | page (or mobile view) ID       | `page:bAbC`                      |
  | `:reusable`       | reusable element ID            | `reusable:bXyZ`                  |
  | `:element`        | element ID                     | `element:bQrS`                   |
  | `:workflow`       | workflow ID                    | `workflow:bTuV`                  |
  | `:action`         | action ID                      | `action:bWxY`                    |
  | `:api_group`      | API Connector group ID         | `api_group:bLmN`                 |
  | `:api_call`       | group ID, call ID              | `api_call:bLmN/bOpQ`             |
  | `:privacy_rule`   | type key, rule key             | `privacy_rule:task/owner_`       |
  | `:plugin`         | marketplace plugin ID          | `plugin:1488796042609x768734193128308700` |

  Pages, reusables, elements, workflows and actions use the Bubble `id`
  member (what other definitions reference), falling back to the map key.
  Option values use their `db_value` (what expressions and stored data
  reference), falling back to the map key.

  `parent` is the containing symbol's ID (field -> data type, action ->
  workflow, element -> parent element/page/reusable, …). `path` is the RFC
  6901 JSON pointer of the definition in the supplied app JSON. `attrs`
  holds kind-specific facts; see `BubbleEx.Index`.
  """

  @type kind ::
          :data_type
          | :field
          | :option_set
          | :option_value
          | :option_attribute
          | :page
          | :reusable
          | :element
          | :workflow
          | :action
          | :api_group
          | :api_call
          | :privacy_rule
          | :plugin

  @type id :: String.t()

  @type t :: %__MODULE__{
          id: id(),
          kind: kind(),
          bubble_id: String.t(),
          name: String.t() | nil,
          parent: id() | nil,
          path: String.t(),
          attrs: map()
        }

  @enforce_keys [:id, :kind, :bubble_id, :path]
  defstruct [:id, :kind, :bubble_id, :name, :parent, :path, attrs: %{}]

  @kinds ~w(data_type field option_set option_value option_attribute page reusable element
            workflow action api_group api_call privacy_rule plugin)a

  @doc "All symbol kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Symbol ID for `kind` and its identifying Bubble IDs.

      iex> BubbleEx.Index.Symbol.id(:field, ["task", "title_text"])
      "field:task/title_text"
  """
  @spec id(kind(), [String.t()] | String.t()) :: id()
  def id(kind, part) when is_binary(part), do: id(kind, [part])

  def id(kind, parts) when kind in @kinds and is_list(parts),
    do: Atom.to_string(kind) <> ":" <> Enum.map_join(parts, "/", &escape/1)

  defp escape(part), do: part |> String.replace("~", "~0") |> String.replace("/", "~1")
end
