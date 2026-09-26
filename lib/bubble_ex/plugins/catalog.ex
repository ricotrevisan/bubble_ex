defmodule BubbleEx.Plugins.Catalog do
  @moduledoc """
  Public marketplace plugins whose features have a known native
  equivalent, for the `:plugin` finding's `replace_native` option
  (`BubbleEx.Findings`).

  Entries are keyed by marketplace plugin ID and map each feature (the
  member code of an element, an element's event or action, or a plugin
  action; an element's states go with the element) to the stack-neutral
  equivalent that covers it; a target adapter decides how its stack
  expresses it. A feature that is not listed (e.g. a plugin's API calls, or
  an element with no standard counterpart) has no equivalent: a plugin is
  offered `replace_native` only when every feature the app uses has one.
  Only public, marketplace-listed plugins are listed.

  | Equivalent | Level | Meaning |
  |------------|-------|---------|
  | `:hand_written_code` | code | the plugin runs code the app author wrote (JavaScript, server scripts, expressions): port that code by hand |
  | `:date_time_input` | component | a standard date/time input |
  | `:select_input` | component | a standard (multi-)select input |
  | `:autocomplete_input` | component | a standard input with filtering / autocomplete |
  | `:icon_set` | component | a standard icon component (same icon set) |
  | `:tooltip` | component | a standard tooltip component |
  | `:toast` | component | a standard toast / flash message component |
  | `:clipboard` | component | the browser clipboard API from a client-side action |
  | `:keyboard_shortcut` | component | a client-side key binding |
  | `:markdown_renderer` | component | a standard Markdown-to-HTML renderer |
  | `:sortable_list` | component | a standard drag-and-drop sortable list |
  | `:chart` | component | a standard charting component |
  | `:calendar` | component | a standard calendar component |
  | `:timer` | component | a client-side timer/countdown |

  A `code`-level equivalent is a port of the author's code, not a drop-in
  component: findings relying on one are low confidence.
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

  @type entry :: %{name: String.t(), features: %{String.t() => equivalent()}}

  # Public marketplace plugins (names as listed on bubble.io/plugins):
  # {name, [equivalent: member codes]}.
  @raw %{
    "1657473130919x213731060929265660" =>
      {"1T - Dropdown", [select_input: ~w(AAb AAh ABg ABk ACB ACH ACK ACL ACM ADC AEG)]},
    "1658529043551x529931311906553860" =>
      {"Advanced Tooltip", [tooltip: ~w(AAV ABU ABV ABW ABX ABY ABZ ABg ABh ABp ACA)]},
    "1553798969094x282191533018710000" =>
      {"Air Calendar",
       [
         calendar:
           ~w(AAC AAX AAY AAw AAz ABI ABZ ABa ABb ABc ABd ADH ADS ADg AEi AFO AFg AFk AFl AFo AFu AGA AGB AIy AJK AJg AJi AJn AJy AKB AOF AOd AOg AOi AOl AOv APG APK APN APf)
       ]},
    "1495642567089x595986733356023800" =>
      {"Air Date Time Picker",
       [date_time_input: ~w(ACX ADK ADL ADM ADN ADd ADe ADf ADh ADv ADw AEM)]},
    "1518279603919x687476512969195500" =>
      {"Air Keyboard Shortcut", [keyboard_shortcut: ~w(AAC AAE)]},
    "1583351916526x278359543482941440" =>
      {"Apex Chart",
       [
         chart:
           ~w(AAC ABn ABs ABy ACH ACI ACL ACU AEa AEn AEu AEw AFC AFE AFH AFh AFn AFr AFv AFy AGC AGI AGP AGW AGb AHn AII AIr AIs AIt AIu AIv AIw AIx AIy AIz AJA AJB AJC AMB AMH AMI AND ANP ANU ANV ANW ANX ANi ANs AOC AOM AOW AOg AOq APA APC APE APH API APJ APM APP APQ APT APU APX APY APb APc APf APg APj APk APn APo APr APs APv APw AQA AQB AQE ASM ASN AST ASV ASX ASh ASj ASk AVF AVx AWA AWC AWD AWF AWG AWI AWJ AWL AWM AWO AWP AWR AWS AWU AWV AWX AWY AWl AWm AWw AWy AWz AXB AXC AZI AZV AZX AZZ AZe AZp AZu AZv AcK AdW Ade Adg Adi Adj Adt Adv Adw Ady Adz Ags AhK AiB AiD AiF AiK AiL AiV AiX AiY Aia Aib Akq AlW Alp AnS Anx Auh Aui Aus Auu Auv Auy AxL AyV AyW Ayg Ayi Ayj Ayo Ayp BBO BBV BBW BCb BCi BCj BCm BCr BCv BDD BDz BEF BEG BEQ BES BET BEV BEW BGc BGr BGt BHr BHs BIW BIl BIn BJT BJf BJh BJj BJk BJv BJx BJy BKA BKD BKE BKF BKH BKI BOD BPx BPy BPz)
       ]},
    "1659259586969x934092730321338400" => {"Copy to Clipboard", [clipboard: ~w(AAD)]},
    "1671931039487x948734435613999100" =>
      {"Drag & Drop Repeating Group", [sortable_list: ~w(AAC AAJ AAM)]},
    "1553006094610x835866904531566600" =>
      {"Fuzzy search & Autocomplete", [autocomplete_input: ~w(AAC AAd)]},
    "1618916043803x877032991371296800" =>
      {"Heroicons", [icon_set: ~w(AAC AAI AAJ AAK AAW AAb ABG ABY ABj)]},
    "1687646425772x182731664379346940" => {"Instant Search", [autocomplete_input: ~w(AAC)]},
    "1664737464989x536991279033614340" => {"Markdown Pro", [markdown_renderer: ~w(AAC AAX AAY)]},
    "1633100358403x239657077467774980" =>
      {"Better Timer/Stopwatch/Countdown",
       [timer: ~w(AAC AAG AAI AAJ AAN AAP AAy ABL ABN ABQ ABk ABm ABu)]},
    "1733570662553x397656958620663800" => {"Toast Notifications", [toast: ~w(AAH ABN)]},
    "1488796042609x768734193128308700" =>
      {"Toolbox", [hand_written_code: ~w(AAC AAI AAP AAX AAY AAe AAg AAn ABL ABM)]}
  }

  @entries Map.new(@raw, fn {id, {name, groups}} ->
             {id,
              %{
                name: name,
                features: for({e, codes} <- groups, c <- codes, into: %{}, do: {c, e})
              }}
           end)

  @equivalents ~w(hand_written_code date_time_input select_input autocomplete_input icon_set
                  tooltip toast clipboard keyboard_shortcut markdown_renderer sortable_list chart
                  calendar timer)a

  @code_level [:hand_written_code]

  if Enum.any?(@entries, fn {_, %{features: f}} ->
       Enum.any?(f, &(elem(&1, 1) not in @equivalents))
     end),
     do: raise("unknown plugin equivalent")

  @doc "The catalog entry of marketplace plugin `id`, or `:error`."
  @spec fetch(String.t()) :: {:ok, entry()} | :error
  def fetch(id) when is_binary(id), do: Map.fetch(@entries, id)

  @doc "The equivalent of feature `code` of plugin `id`, or nil."
  @spec equivalent(String.t(), String.t()) :: equivalent() | nil
  def equivalent(id, code) do
    case fetch(id) do
      {:ok, %{features: features}} -> Map.get(features, code)
      :error -> nil
    end
  end

  @doc "Every equivalent an entry may name."
  @spec equivalents() :: [equivalent()]
  def equivalents, do: @equivalents

  @doc "Whether `equivalent` is a code-level port rather than a standard component."
  @spec code_level?(equivalent()) :: boolean()
  def code_level?(equivalent), do: equivalent in @code_level
end
