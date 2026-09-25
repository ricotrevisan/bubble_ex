defmodule BubbleEx.Model.Structured do
  @moduledoc """
  The component parts of Bubble's structured values, in Bubble's terms, so
  targets map them from here instead of hardcoding Bubble sub-fields. A
  `BubbleEx.Model.Type` of kind `:structured` names its entry by `base`
  (`BubbleEx.Model.Type.components/1`).

  | base | components |
  |------|------------|
  | `:geographic_address` | `formatted_address` (text), `lat` (number), `lng` (number) |
  | `:date_range` | `start` (date), `end` (date) |
  | `:number_range` | `min` (number), `max` (number) |
  | `:date_interval` | none: a single duration |

  `bounds` records whether each range end is included. Bubble's
  documentation available to this project does not establish it, so it is
  `:unverified` for both ends and targets must not assume either. Replace it
  once confirmed against Bubble.
  """

  @type component :: %{id: String.t(), base: :text | :number | :date}
  @type entry :: %{
          base: atom(),
          components: [component()],
          bounds: %{start: :unverified, end: :unverified} | nil
        }

  @unverified %{start: :unverified, end: :unverified}

  @catalog %{
    geographic_address: %{
      base: :geographic_address,
      components: [
        %{id: "formatted_address", base: :text},
        %{id: "lat", base: :number},
        %{id: "lng", base: :number}
      ],
      bounds: nil
    },
    date_range: %{
      base: :date_range,
      components: [%{id: "start", base: :date}, %{id: "end", base: :date}],
      bounds: @unverified
    },
    number_range: %{
      base: :number_range,
      components: [%{id: "min", base: :number}, %{id: "max", base: :number}],
      bounds: @unverified
    },
    date_interval: %{base: :date_interval, components: [], bounds: nil}
  }

  @doc "The catalog entry for a structured `base`, or nil."
  @spec fetch(atom()) :: entry() | nil
  def fetch(base), do: Map.get(@catalog, base)

  @doc "Every entry, ordered by base."
  @spec all() :: [entry()]
  def all, do: @catalog |> Map.values() |> Enum.sort_by(& &1.base)
end
