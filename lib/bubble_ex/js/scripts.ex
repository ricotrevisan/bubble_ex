defmodule BubbleEx.Js.Scripts do
  @moduledoc """
  The app author's JavaScript in an app, analyzed together (WTF-608):

    * Toolbox's "Run javascript" actions (`actions`, by action Bubble ID):
      the script runs when the step runs, with the step's `param1`…`param5`
      and `paramlist1`…`paramlist5` as `properties`
    * Toolbox's "Javascript to Bubble" elements (`publishers`, by element
      Bubble ID): each defines `bubble_fn_<suffix>`, which publishes a value
      (or `output1`…`output4`, `outputlist1`…`outputlist4`) to the element's
      states and triggers its "event"
    * the scripts of elements (`elements`, by element Bubble ID): an HTML
      element's `<script>` tags (`sources`, their bodies; page-only only when the element holds
      nothing else, its text is static and every script is page-only), a
      Toolbox "Expression" or "List Item Expression" (JavaScript Bubble
      builds from dynamic values: never page-only), a Toolbox "List of
      Numbers" (no script at all: a value to compute where the page keeps
      its data)

      {:ok, index} = BubbleEx.Index.build(app)
      scripts = BubbleEx.Js.Scripts.collect(app, index)

  Each analysis is `BubbleEx.Js.analyze/2`'s, with the app's publish
  suffixes, then `BubbleEx.Js.isolate/2`d against every other script of the
  app: a global one script assigns and another reads stays global, so
  neither is page-only. Only live symbols are read (the index's), never the
  editor's change history. Stack-neutral: it names what the scripts do, not
  how a target runs them.
  """

  alias BubbleEx.{Index, Js}
  alias BubbleEx.Index.{Plugins, Symbol}
  alias BubbleEx.Workflows.ExplanationContext

  @toolbox "1488796042609x768734193128308700"

  @codes %{
    "AAg" => :run_js,
    "AAn" => :server_script,
    "AAP" => :publisher,
    "AAX" => :publish_event,
    "AAI" => :expression,
    "AAY" => :list_item_expression,
    "AAC" => :list_of_numbers
  }

  # "Run javascript": its script, whether it runs asynchronously, and its
  # inputs.
  @script "AAh"
  @async "AAi"
  @params %{
    "ABB" => "param1",
    "ABC" => "param2",
    "ABD" => "param3",
    "ABE" => "param4",
    "ABF" => "param5",
    "ABG" => "paramlist1",
    "ABH" => "paramlist2",
    "ABI" => "paramlist3",
    "ABJ" => "paramlist4",
    "ABK" => "paramlist5"
  }
  # The documentation labels the editor shows: no behavior.
  @labels ~w(ABQ ABR)

  # "Javascript to Bubble": the suffix, whether it triggers its event,
  # publishes a value, takes several outputs and a list.
  @suffix "AAQ"
  @trigger "AAR"
  @publish "AAS"
  @value_list "AAU"
  @multiple "ABy"
  @value_state "AAV"
  @value_list_state "AAW"
  @outputs [
    {"output1", "ACI"},
    {"output2", "ACJ"},
    {"output3", "ACK"},
    {"output4", "ACL"},
    {"outputlist1", "ACM"},
    {"outputlist2", "ACN"},
    {"outputlist3", "ACO"},
    {"outputlist4", "ACP"}
  ]

  @suffix_format ~r/\A[A-Za-z0-9_]{1,64}\z/

  defstruct publishers: %{}, actions: %{}, elements: %{}

  @type publisher :: %{
          element: String.t(),
          surface: String.t() | nil,
          suffix: String.t(),
          trigger?: boolean(),
          outputs: [{String.t(), String.t()}]
        }

  @type t :: %__MODULE__{
          publishers: %{String.t() => publisher()},
          actions: %{String.t() => Js.t()},
          elements: %{String.t() => %{kind: atom(), analysis: Js.t(), sources: [String.t()]}}
        }

  @doc "Toolbox's marketplace plugin ID."
  @spec toolbox() :: String.t()
  def toolbox, do: @toolbox

  @doc """
  What a Toolbox element, action or event type is (`:run_js`,
  `:server_script`, `:publisher`, `:publish_event`, `:expression`,
  `:list_item_expression`, `:list_of_numbers`), or nil.
  """
  @spec kind(term()) :: atom() | nil
  def kind(type) do
    if Plugins.plugin(type) == @toolbox, do: Map.get(@codes, Plugins.code(type))
  end

  @doc "The member keys of a \"Run javascript\" action (its script, options, inputs, labels)."
  @spec run_js_members() :: [String.t()]
  def run_js_members, do: [@script, @async | Map.keys(@params)] ++ @labels

  @doc "A \"Run javascript\" action's inputs present in `props`: `{name, member key}`, by name."
  @spec params(map()) :: [{String.t(), String.t()}]
  def params(props) when is_map(props) do
    for {key, name} <- @params, Map.has_key?(props, key), props[key] != nil do
      {name, key}
    end
    |> Enum.sort()
  end

  @doc "A \"Run javascript\" action's script, as `text/1` reads it."
  @spec script(map()) :: {:ok, String.t()} | :dynamic | :none
  def script(props) when is_map(props), do: text(props[@script])

  @doc "Whether a \"Run javascript\" action runs asynchronously (Toolbox's default)."
  @spec async?(map()) :: boolean()
  def async?(props), do: props[@async] != false

  @doc """
  The text of a script member: `{:ok, text}` when it is static (a text, or
  a text expression of texts only), `:dynamic` when Bubble builds it from
  dynamic values, `:none` when there is none.
  """
  @spec text(term()) :: {:ok, String.t()} | :dynamic | :none
  def text(nil), do: :none
  def text(text) when is_binary(text), do: {:ok, text}

  def text(%{"type" => "TextExpression", "entries" => entries}) when is_map(entries) do
    parts =
      entries
      |> Enum.sort_by(fn {k, _} -> sort_key(k) end)
      |> Enum.map(&elem(&1, 1))

    if Enum.all?(parts, &is_binary/1), do: {:ok, Enum.join(parts)}, else: :dynamic
  end

  def text(_), do: :dynamic

  defp sort_key(k) do
    case Integer.parse(to_string(k)) do
      {n, ""} -> n
      _ -> 0
    end
  end

  @doc """
  A "Javascript to Bubble" element's publisher (`raw` its JSON): its
  suffix (a static text of letters, digits and `_`), whether it triggers
  its event, and the states it publishes (`{name, state code}`: `value`,
  or the outputs); nil when its suffix is dynamic or not of that form.
  """
  @spec publisher(map()) :: map() | nil
  def publisher(raw) when is_map(raw) do
    props = properties(raw)

    with {:ok, suffix} <- text(props[@suffix]),
         true <- Regex.match?(@suffix_format, suffix) do
      outputs =
        cond do
          props[@multiple] == true -> @outputs
          props[@publish] != true -> []
          props[@value_list] == true -> [{"value", @value_list_state}]
          true -> [{"value", @value_state}]
        end

      %{suffix: suffix, trigger?: props[@trigger] == true, outputs: outputs}
    else
      _ -> nil
    end
  end

  def publisher(_raw), do: nil

  @doc "The app's scripts and publishers, analyzed (see the moduledoc)."
  @spec collect(map(), Index.t()) :: t()
  def collect(app, %Index{} = index) when is_map(app) do
    publishers =
      for %Symbol{kind: :element} = s <- index.symbols,
          kind(s.attrs[:type]) == :publisher,
          p = publisher(at(app, s.path)),
          into: %{},
          do: {s.bubble_id, Map.merge(p, %{element: s.bubble_id, surface: surface(index, s)})}

    suffixes = publishers |> Map.values() |> Enum.map(& &1.suffix) |> Enum.uniq()

    actions =
      for %Symbol{kind: :action} = s <- index.symbols,
          kind(s.attrs[:type]) == :run_js,
          into: %{} do
        props = properties(at(app, s.path))
        {s.bubble_id, script_analysis(script(props), suffixes)}
      end

    elements =
      for %Symbol{kind: :element} = s <- index.symbols,
          entry = element_scripts(at(app, s.path), s.attrs[:type], suffixes),
          into: %{},
          do: {s.bubble_id, entry}

    shared = Js.shared(Map.values(actions) ++ Enum.map(Map.values(elements), & &1.analysis))

    %__MODULE__{
      publishers: publishers,
      actions: Map.new(actions, fn {id, a} -> {id, Js.isolate(a, shared)} end),
      elements:
        Map.new(elements, fn {id, e} -> {id, %{e | analysis: Js.isolate(e.analysis, shared)}} end)
    }
  end

  defp script_analysis(script, suffixes) do
    case script do
      {:ok, source} -> Js.analyze(source, publishes: suffixes)
      :dynamic -> Js.analyze("", dynamic: true)
      :none -> Js.analyze("", publishes: suffixes)
    end
  end

  # An element's own scripts: an HTML element's, or a Toolbox code
  # element's.
  defp element_scripts(raw, "HTML", suffixes) when is_map(raw) do
    case text(properties(raw)["html"]) do
      {:ok, html} ->
        case Regex.scan(~r/<script\b([^>]*)>(.*?)<\/script\s*>/is, html) do
          [] ->
            nil

          tags ->
            %{
              kind: :html,
              analysis: html_analysis(html, tags, suffixes),
              sources: for([_, _attrs, body] <- tags, do: body)
            }
        end

      :dynamic ->
        if Regex.match?(~r/<script\b/i, html_text(properties(raw)["html"])),
          do: %{kind: :html, analysis: Js.analyze("", dynamic: true), sources: []},
          else: nil

      :none ->
        nil
    end
  end

  defp element_scripts(raw, type, _suffixes) when is_map(raw) do
    case kind(type) do
      k when k in [:expression, :list_item_expression] ->
        %{kind: k, analysis: Js.analyze("", dynamic: true), sources: []}

      :list_of_numbers ->
        %{
          kind: :list_of_numbers,
          analysis: %Js{verdict: :owner, reasons: [{:no_script, "List of Numbers"}]},
          sources: []
        }

      _ ->
        nil
    end
  end

  defp element_scripts(_raw, _type, _suffixes), do: nil

  # Page-only when the element holds only scripts (no markup to render, no
  # attributes such as `src` on its tags) and each of them is.
  defp html_analysis(html, tags, suffixes) do
    rest = Regex.replace(~r/<script\b[^>]*>.*?<\/script\s*>/is, html, "")

    analyses =
      for [_, attrs, body] <- tags do
        if String.trim(attrs) == "",
          do: body |> Js.analyze(publishes: suffixes) |> without_inputs(),
          else: %Js{verdict: :owner, reasons: [{:url, "script attributes"}]}
      end

    merged = merge(analyses)

    if String.trim(rest) == "",
      do: merged,
      else: %{merged | verdict: :owner, reasons: Enum.sort([{:markup, "html"} | merged.reasons])}
  end

  # An element's script gets no `properties`: reading one is not page-only.
  defp without_inputs(%Js{reads: []} = analysis), do: analysis

  defp without_inputs(%Js{} = analysis),
    do: %{
      analysis
      | verdict: :owner,
        reasons: Enum.sort([{:property, "properties"} | analysis.reasons])
    }

  defp merge(analyses) do
    reasons = analyses |> Enum.flat_map(& &1.reasons) |> Enum.uniq() |> Enum.sort()

    %Js{
      verdict: if(reasons == [], do: :page_only, else: :owner),
      reads: analyses |> Enum.flat_map(& &1.reads) |> Enum.uniq() |> Enum.sort(),
      publishes: analyses |> Enum.flat_map(& &1.publishes) |> Enum.uniq() |> Enum.sort(),
      uses: analyses |> Enum.flat_map(& &1.uses) |> Enum.uniq() |> Enum.sort(),
      implicit: analyses |> Enum.flat_map(& &1.implicit) |> Enum.uniq() |> Enum.sort(),
      reasons: reasons
    }
  end

  defp html_text(%{"entries" => entries}) when is_map(entries),
    do: entries |> Map.values() |> Enum.filter(&is_binary/1) |> Enum.join()

  defp html_text(_), do: ""

  defp properties(raw) when is_map(raw) do
    case raw["properties"] do
      p when is_map(p) -> p
      _ -> %{}
    end
  end

  defp properties(_raw), do: %{}

  defp surface(_index, %Symbol{parent: nil}), do: nil

  defp surface(index, %Symbol{parent: parent}) do
    case Index.symbol(index, parent) do
      %Symbol{kind: kind} = p when kind in [:page, :reusable] -> p.id
      %Symbol{} = p -> surface(index, p)
      nil -> nil
    end
  end

  defp at(app, path) when is_binary(path), do: ExplanationContext.at_pointer(app, path)
  defp at(_app, _path), do: nil
end
