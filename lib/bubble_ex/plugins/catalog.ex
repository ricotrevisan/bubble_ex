defmodule BubbleEx.Plugins.Catalog do
  @moduledoc """
  Public marketplace plugins with a known native equivalent, for the
  `:plugin` finding's `replace_native` option (`BubbleEx.Findings`).

  Entries are keyed by marketplace plugin ID and name the stack-neutral
  equivalent that covers what the plugin does; a target adapter decides how
  its stack expresses it. Only public, marketplace-listed plugins are
  listed. A plugin that is not here gets `rebuild` (and `drop`) only.

  | Equivalent | Meaning |
  |------------|---------|
  | `:hand_written_code` | the plugin runs code the app author wrote (JavaScript, server scripts, expressions): port that code by hand |
  | `:date_time_input` | a standard date/time input |
  | `:select_input` | a standard (multi-)select input |
  | `:autocomplete_input` | a standard input with client-side filtering / autocomplete |
  | `:icon_set` | a standard icon component (same icon set) |
  | `:tooltip` | a standard tooltip component |
  | `:toast` | a standard toast / flash message component |
  | `:clipboard` | the browser clipboard API from a client-side action |
  | `:keyboard_shortcut` | a client-side key binding |
  | `:markdown_renderer` | a standard Markdown-to-HTML renderer |
  | `:sortable_list` | a standard drag-and-drop sortable list |
  | `:chart` | a standard charting component |
  | `:calendar` | a standard calendar component |
  | `:timer` | a client-side timer/countdown |
  """

  @type equivalent ::
          :hand_written_code
          | :date_time_input
          | :select_input
          | :autocomplete_input
          | :icon_set
          | :tooltip
          | :toast
          | :clipboard
          | :keyboard_shortcut
          | :markdown_renderer
          | :sortable_list
          | :chart
          | :calendar
          | :timer

  @type entry :: %{name: String.t(), equivalent: equivalent()}

  # Public marketplace plugins (names as listed on bubble.io/plugins).
  @entries %{
    "1488796042609x768734193128308700" => %{name: "Toolbox", equivalent: :hand_written_code},
    "1495642567089x595986733356023800" => %{
      name: "Air Date Time Picker",
      equivalent: :date_time_input
    },
    "1518279603919x687476512969195500" => %{
      name: "Air Keyboard Shortcut",
      equivalent: :keyboard_shortcut
    },
    "1553006094610x835866904531566600" => %{
      name: "Fuzzy search & Autocomplete",
      equivalent: :autocomplete_input
    },
    "1553798969094x282191533018710000" => %{name: "Air Calendar", equivalent: :calendar},
    "1583351916526x278359543482941440" => %{name: "Apex Chart", equivalent: :chart},
    "1618916043803x877032991371296800" => %{name: "Heroicons", equivalent: :icon_set},
    "1633100358403x239657077467774980" => %{
      name: "Better Timer/Stopwatch/Countdown",
      equivalent: :timer
    },
    "1657473130919x213731060929265660" => %{name: "1T - Dropdown", equivalent: :select_input},
    "1658529043551x529931311906553860" => %{name: "Advanced Tooltip", equivalent: :tooltip},
    "1659259586969x934092730321338400" => %{name: "Copy to Clipboard", equivalent: :clipboard},
    "1664737464989x536991279033614340" => %{
      name: "Markdown Pro",
      equivalent: :markdown_renderer
    },
    "1671931039487x948734435613999100" => %{
      name: "Drag & Drop Repeating Group",
      equivalent: :sortable_list
    },
    "1687646425772x182731664379346940" => %{
      name: "Instant Search",
      equivalent: :autocomplete_input
    },
    "1733570662553x397656958620663800" => %{name: "Toast Notifications", equivalent: :toast}
  }

  @equivalents ~w(hand_written_code date_time_input select_input autocomplete_input icon_set
                  tooltip toast clipboard keyboard_shortcut markdown_renderer sortable_list chart
                  calendar timer)a

  if Enum.any?(@entries, fn {_, %{equivalent: e}} -> e not in @equivalents end),
    do: raise("unknown plugin equivalent")

  @doc "The catalog entry of marketplace plugin `id`, or `:error`."
  @spec fetch(String.t()) :: {:ok, entry()} | :error
  def fetch(id) when is_binary(id), do: Map.fetch(@entries, id)

  @doc "Every equivalent an entry may name."
  @spec equivalents() :: [equivalent()]
  def equivalents, do: @equivalents
end
