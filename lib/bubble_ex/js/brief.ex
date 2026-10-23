defmodule BubbleEx.Js.Brief do
  @moduledoc """
  A rewrite brief for a script that is not page-only (WTF-608): what the
  owner's developer (or agent) needs to port it by hand. Plain data with
  string values, JSON-safe:

    * `what` - what it is and does, in a sentence
    * `inputs` - what it reads: Toolbox's `properties.<name>` (with their
      type and source when the caller knows them)
    * `publishes` - the "Javascript to Bubble" functions it calls
      (`bubble_fn_<suffix>`)
    * `uses` - the page APIs it uses (`document.querySelector`, …)
    * `why` - why it was not converted, one line per reason
    * `shape` - a suggested shape for the port in the generated Phoenix
      LiveView app

  Built from a `BubbleEx.Js` analysis; never holds the script itself (the
  developer reads it in Bubble or in the app JSON at the subject's path).
  """

  alias BubbleEx.Js

  @kinds %{
    run_js: "a Toolbox \"Run javascript\" step",
    html: "an HTML element's script",
    expression: "a Toolbox \"Expression\" element",
    list_item_expression: "a Toolbox \"List Item Expression\" element",
    list_of_numbers: "a Toolbox \"List of Numbers\" element"
  }

  @doc """
  The brief of `analysis` for a script of `kind` (`:run_js`, `:html`,
  `:expression`, `:list_item_expression`, `:list_of_numbers`). `inputs`:
  `%{name, type, path}` per input the caller lowered (default: the names
  the script reads).
  """
  @spec build(Js.t(), atom(), [map()]) :: map()
  def build(%Js{} = analysis, kind, inputs \\ nil) do
    inputs =
      inputs ||
        Enum.map(analysis.reads, &%{name: &1})

    %{
      what: what(analysis, kind),
      inputs: Enum.map(inputs, &stringify/1),
      publishes: Enum.map(analysis.publishes, &("bubble_fn_" <> &1)),
      uses: analysis.uses,
      why: Enum.map(analysis.reasons, &why/1),
      shape: shape(analysis)
    }
  end

  @doc "Why, in a line, for a reason of `BubbleEx.Js`."
  @spec why({atom(), String.t()}) :: String.t()
  def why({:network, name}), do: "it makes a network request (#{name})"
  def why({:code, name}), do: "it runs code it builds, or reaches past the page (#{name})"
  def why({:html, name}), do: "it writes HTML (#{name}): data could become markup"

  def why({:url, name}),
    do: "it reads or changes the URL, cookies, other windows or loaded files (#{name})"

  def why({:attribute, name}), do: "it sets an attribute the browser may run (#{name})"
  def why({:computed_member, name}), do: "it reads a property by a computed name (#{name})"

  def why({:unknown_global, name}),
    do:
      "it uses #{name}, which the app's export does not define (a header script, a library or another plugin)"

  def why({:global_write, name}), do: "it shares the global #{name} with another script"

  def why({:window_member, name}),
    do: "it uses #{name}, a global of the page another script may define"

  def why({:navigator_member, name}), do: "it uses #{name}"
  def why({:property, name}), do: "it reads #{name}, which Toolbox does not pass"

  def why({:unresolved_publish, name}),
    do: "it calls #{name}, which no Javascript to Bubble element defines"

  def why({:timer_string, name}), do: "it gives #{name} something that may be code as text"
  def why({:unreadable, name}), do: "it could not be checked: #{name}"
  def why({:too_long, _}), do: "it is too long to check"

  def why({:dynamic, _}),
    do: "Bubble builds its text from dynamic values: data would become code"

  def why({:unembeddable, name}), do: "it contains #{name}, which would end its script element"
  def why({:markup, _}), do: "the element shows markup besides its scripts"
  def why({:no_script, name}), do: "it runs no script of the app's: it computes a value (#{name})"
  def why({:param_type, name}), do: "it is given #{name}, a value the page cannot pass as data"

  def why({:reads_published, name}),
    do: "a later step of its workflow reads what it publishes (bubble_fn_#{name}) at once"

  def why({kind, name}), do: "#{kind}: #{name}"

  defp what(analysis, kind) do
    parts =
      [
        list("reads", Enum.map(analysis.reads, &("properties." <> &1))),
        list("publishes with", Enum.map(analysis.publishes, &("bubble_fn_" <> &1))),
        list("uses", analysis.uses)
      ]
      |> Enum.reject(&is_nil/1)

    String.capitalize(Map.get(@kinds, kind, "a script")) <>
      if(parts == [], do: "", else: ": it " <> Enum.join(parts, "; "))
  end

  defp list(_verb, []), do: nil
  defp list(verb, items), do: "#{verb} #{Enum.join(items, ", ")}"

  # The suggestion follows the first kind of reason, by how much the port
  # changes.
  # Reason kinds, by how much the port changes: the first one present
  # picks the suggestion.
  @shapes [
    :no_script,
    :network,
    :dynamic,
    :html,
    :markup,
    :unknown_global,
    :window_member,
    :global_write
  ]

  defp shape(%Js{reasons: reasons} = analysis) do
    kinds = reasons |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    base = base_shape(Enum.find(@shapes, &MapSet.member?(kinds, &1)), reasons)

    if analysis.publishes == [],
      do: base,
      else:
        base <>
          " What it publishes goes back with the hook's pushEvent(\"bubble:publish\", …): the page " <>
          "sets the Javascript to Bubble element's states and runs its event's workflows."
  end

  defp base_shape(:no_script, _reasons),
    do:
      "Compute the value in Elixir where the page keeps its data (an assign), and drop the element."

  defp base_shape(:network, _reasons),
    do:
      "Make the request on the server: an API Connector call or a Req call in the LiveView's " <>
        "handle_event/3, with any secret in config/runtime.exs; send the page only the result, " <>
        "with push_event/3, for a colocated hook to apply."

  defp base_shape(:dynamic, _reasons),
    do:
      "Rewrite it as a fixed script in a colocated LiveView hook that takes the dynamic values " <>
        "as data (data-* attributes or push_event/3), or compute the value in Elixir; never " <>
        "build script text from data."

  defp base_shape(kind, _reasons) when kind in [:html, :markup],
    do:
      "Render the markup in HEEx, where the server escapes the data, or set textContent from a " <>
        "colocated LiveView hook."

  defp base_shape(kind, reasons) when kind in [:unknown_global, :window_member, :global_write] do
    globals =
      for({k, n} <- reasons, k in [:unknown_global, :window_member, :global_write], do: n)
      |> Enum.uniq()
      |> Enum.join(", ")

    "Port what it relies on (#{globals}) into a colocated LiveView hook, or load the library " <>
      "from the root layout and call it from the hook; pass the inputs as data (data-* " <>
      "attributes or push_event/3) and keep shared state in the LiveView, not in globals."
  end

  defp base_shape(_kind, _reasons),
    do:
      "Port it to a colocated LiveView hook (<script :type={Phoenix.LiveView.ColocatedHook}>) " <>
        "and pass its inputs as data (data-* attributes or push_event/3)."

  defp stringify(map) do
    Map.new(map, fn {k, v} ->
      {k, if(is_atom(v) and not is_nil(v), do: Atom.to_string(v), else: v)}
    end)
  end
end
