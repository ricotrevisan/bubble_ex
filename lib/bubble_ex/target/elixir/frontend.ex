defmodule BubbleEx.Target.Elixir.Frontend do
  @moduledoc """
  Compiles the value bindings of a normalized frontend
  (`BubbleEx.Frontend.Normalized`: dynamic text, labels, placeholders,
  sources) to Elixir, for the pages the Phoenix target scaffolds (WTF-370).

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, frontend} = BubbleEx.Frontend.normalize(app)
      {:ok, compiled} = BubbleEx.Target.Elixir.Frontend.compile(app, model, project, frontend)
      {:ok, files} = BubbleEx.Target.Phoenix.render(project, frontend: frontend, expressions: compiled)

  Each binding is typed in its element's environment (the element is the
  host: `This element`, `Parent group`, the current cell) by
  `BubbleEx.Expression.Compiler`, then compiled by
  `BubbleEx.Target.Elixir`. The result maps the binding's ID to the
  compiled `%{source, bindings, runtime, loads, type, file?}` (`type`: the
  binding's Bubble type, e.g. `"image"`; `file?`: it shows exactly one
  file or image value, alone or as the only part of a dynamic text besides
  a leading `"https:"`/`"http:"`, as Bubble's image sources often are; then
  `file` is `%{source, bindings}` of just that value's link, nil when
  empty); a binding that does not
  compile is absent (the page keeps a residue marker for it).

  ## Visibility conditionals (WTF-477)

  An element's `:condition` binding (its conditional states,
  `BubbleEx.Frontend.Conditions`) compiles when every state that sets
  `is_visible` compiles: each condition is typed and compiled in the
  element's environment like a value, the same path and inputs as the
  element's dynamic text (so a condition reading page data reads what the
  page loads, through its policies). The result is one yes/no expression,
  `raw?: true`, that folds the states in Bubble's order from the
  element's visibility on page load: the last state whose condition is
  true decides; an empty condition is false. `visibility` is
  `%{states, initial, constant?}` (`constant?`: every state sets the
  visibility on page load, so the result never changes). A button's
  "isn't clickable" compiles alike (`Conditions.disabled_id/1`), and a
  Text's content or a button's label whose states set its text (WTF-582,
  `Conditions.text_id/1`): one `cond` whose clauses are the states'
  conditions, tested last first, and the texts they set, compiled like the
  element's dynamic text, else the content on page load (a literal or the
  element's own binding); `text` keeps the parts
  (`Conditions.text_source/2`), so a target can print the values again
  (as BBCode nodes). It compiles only when every condition and every text
  does. Anything else conditionals set (colors, icons…) is not compiled
  here.

  A condition, like a shown value, may read a URL parameter as its type
  (text, a number, a yes/no, a date) and the URL's path (its segments,
  or the first one after the page's name): the page keeps the URL, read
  as Bubble reads it (replayed 2026-10-07). A thing read from the URL
  compiles, but the page does not keep it (only its data sources and
  workflows read it); a list parameter ("is a list", not replayed) does
  not compile.

  A condition may also read `Current page width` (WTF-520): the page
  keeps the viewport's width, so a width test that is not a breakpoint
  rule of its own (`Current page width < 768 and …`, or one the export
  keeps as an element conditional) decides with the width the browser
  reports, again on a resize; while the page has no width yet, the
  conditional keeps the value on page load (a first `is_nil` clause),
  whatever its shape. A width compared to a named breakpoint
  (`Current page width < Tablet`) compares it to that breakpoint's width
  in the app's breakpoint settings, fixed at compile time; a breakpoint
  the settings do not define does not compile.

  `Current date/time` and `Current page name` compile too (replayed
  2026-10-19). Bubble computes the date/time once per evaluation and never
  evaluates it again on its own (no timer, not even on a resize), and it
  is never empty: the page reads the time when it renders, with no timer.
  Bubble offers the page's name only inside a reusable element, where it
  is the host page's Bubble name (the editor's, whatever else the path
  holds); the page passes it down to the reusable element. On a page
  itself the editor refuses it, so the page does not keep it there and
  says why.

  Another element's `is visible` (and `isn't visible`) on the same page
  or reusable element compiles to that element's visibility, folded from
  its conditionals and its ancestors' up to the one the reader shares, when
  only the server decides it (WTF-578, `ElementVisibility`): no workflow
  step shows, hides, toggles or animates it, no overlay or runtime
  container (a repeating group's cell, a table) is on the way. Its
  conditions' inputs become the reader's.

  A repeating group's `is loading` compiles to a constant no (replayed
  2026-10-19): in Bubble it stays no while a search waits for its
  response, the old rows still shown, and is yes only for a few
  milliseconds as rows render, a flicker no condition can rely on.

  A visibility conditional that does not compile (a condition with no IR
  or no Elixir, a non-literal visibility, an overlay's: a Popup, Group
  Focus or Floating Group is shown and hidden by workflows) is absent too;
  `residue/2` lists it as `:element_condition` residue for the plan.

  ## Options

    * `:runtime` - the runtime module the source calls (default
      `"Bubble.Runtime"`; the Phoenix target passes its own)
    * `:namespace` - root namespace of the generated enums
    * `:file_url` - the function shown file and image values go through
      (`BubbleEx.Target.Elixir`'s option), default
      `"<namespace>Web.Uploads.url"`: the Phoenix target's safe file route
      (WTF-415), so pages never link a raw stored file URL
  """

  alias BubbleEx.{Error, Expression, Model}
  alias BubbleEx.Expression.{Compiler, Env, IR, Tree}
  alias BubbleEx.Frontend.{Conditions, Normalized}
  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Target.Ash.Project
  alias BubbleEx.Target.Elixir, as: ElixirTarget
  alias BubbleEx.Target.Elixir.Frontend.ElementVisibility

  @type compiled :: %{
          required(:source) => String.t(),
          required(:bindings) => [map()],
          required(:runtime) => [atom()],
          required(:loads) => map(),
          required(:type) => String.t() | nil,
          required(:file?) => boolean(),
          optional(:file) => %{source: String.t(), bindings: [map()]},
          optional(:raw?) => boolean(),
          optional(:visibility) => %{
            states: pos_integer(),
            initial: boolean(),
            constant?: boolean(),
            fixed: boolean() | nil
          }
        }

  @spec compile(map(), Model.t(), Project.t(), Normalized.t(), keyword()) ::
          {:ok, %{String.t() => compiled()}} | {:error, Error.t()}
  def compile(app, model, project, frontend, opts \\ [])

  def compile(app, %Model{} = model, %Project{} = project, %Normalized{} = frontend, opts)
      when is_map(app) and not is_struct(app) and is_list(opts) do
    env = Env.new(model, tree: Tree.build(app), searches: :page, loading_status: :constant)
    opts = Keyword.put(opts, :element_visibility, ElementVisibility.index(app, frontend, env))

    nodes = Enum.flat_map(frontend.pages ++ frontend.reusables, &nodes/1)

    compiled =
      for node <- nodes,
          {slot, %{kind: kind, id: id, payload: payload}} <- node.bindings,
          result = compile_kind(kind, payload, node, slot_env(slot, node, env), project, opts),
          into: %{},
          do: {id, result}

    disabled =
      for %Node{kind: :button} = node <- nodes,
          %{kind: :condition, id: id, payload: payload} <- [node.bindings["condition"]],
          result = compile_disabled(payload, node, env, project, opts),
          into: %{},
          do: {Conditions.disabled_id(id), result}

    texts =
      for %Node{kind: kind} = node <- nodes,
          kind in [:text, :button],
          %{kind: :condition, id: id, payload: payload} <- [node.bindings["condition"]],
          result = compile_text(payload, node, env, project, opts),
          into: %{},
          do: {Conditions.text_id(id), result}

    {:ok, compiled |> Map.merge(disabled) |> Map.merge(texts)}
  end

  def compile(_app, _model, _project, _frontend, _opts),
    do:
      {:error,
       Error.new(:invalid_input, "expected app JSON, its Model, its Ash project and its frontend")}

  @doc """
  The `:element_condition` residue of `frontend` (`BubbleEx.Plan.Residue`):
  one entry per element whose visibility conditionals `compiled` (the
  result of `compile/5`) lacks, `detail.states` the states that set its
  visibility.
  """
  @spec residue(Normalized.t(), %{String.t() => compiled()}) :: [Residue.t()]
  def residue(%Normalized{} = frontend, compiled) when is_map(compiled) do
    nodes = Enum.flat_map(frontend.pages ++ frontend.reusables, &nodes/1)

    visibility =
      for node <- nodes,
          %{kind: :condition, id: id, payload: payload} <- [node.bindings["condition"]],
          states = Conditions.visibility(payload),
          states != [],
          not Map.has_key?(compiled, id),
          %{bubble_id: bubble_id} when is_binary(bubble_id) <- [node.source],
          uniq: true,
          do:
            Residue.entry("element:" <> bubble_id, :element_condition, %{states: length(states)})

    buttons =
      for %Node{kind: :button} = node <- nodes,
          %{kind: :condition, id: id, payload: payload} <- [node.bindings["condition"]],
          %{bubble_id: bubble_id} when is_binary(bubble_id) <- [node.source],
          {property, states} <-
            button_unlowered(payload, id, compiled, node.attributes["disabled"] == true),
          do:
            Residue.entry("element:" <> bubble_id, :element_condition, %{
              states: states,
              property: property
            })

    texts =
      for %Node{kind: :text} = node <- nodes,
          %{kind: :condition, id: id, payload: payload} <- [node.bindings["condition"]],
          %{bubble_id: bubble_id} when is_binary(bubble_id) <- [node.source],
          states = length(Conditions.property(payload, "text")),
          states > 0,
          not Map.has_key?(compiled, Conditions.text_id(id)),
          do:
            Residue.entry("element:" <> bubble_id, :element_condition, %{
              states: states,
              property: "text"
            })

    visibility ++ buttons ++ texts
  end

  # The button properties the page leaves at their page-load value although
  # a conditional sets them (WTF-520): "isn't clickable" and its text
  # (WTF-582) when they do not compile (the button is then disabled, fail
  # closed; its text is the one on page load), its icon and its kind
  # (label, icon) always. `{property, states}`.
  @unlowered_button_properties ~w(icon button_type)

  @doc false
  @spec button_unlowered(term(), String.t(), map()) :: [{String.t(), pos_integer()}]
  def button_unlowered(payload, condition_id, compiled, initial \\ false) do
    disabled = length(Conditions.disabled_states(payload, initial))

    disabled =
      if disabled > 0 and not Map.has_key?(compiled, Conditions.disabled_id(condition_id)),
        do: [{"button_disabled", disabled}],
        else: []

    texts = length(Conditions.property(payload, "text"))

    texts =
      if texts > 0 and not Map.has_key?(compiled, Conditions.text_id(condition_id)),
        do: [{"text", texts}],
        else: []

    disabled ++
      texts ++
      for key <- @unlowered_button_properties,
          n = length(Conditions.property(payload, key)),
          n > 0,
          do: {key, n}
  end

  defp nodes(%Node{} = node), do: [node | Enum.flat_map(node.children, &nodes/1)]

  # A Dropdown's choice label (WTF-596) is about the choice: `This <type>`
  # is the choice it labels (`{:this, :context}`, bound by the page to each
  # choice it renders).
  defp slot_env("choice_label", %Node{kind: :dropdown, content: content}, env) do
    case content do
      %{"choices" => %{data_type: type}} when is_binary(type) ->
        %{env | this_type: type, this_binder: :context}

      _ ->
        env
    end
  end

  defp slot_env(_slot, _node, env), do: env

  defp compile_kind(:value, payload, node, env, project, opts),
    do: compile_binding(payload, node, env, project, opts)

  defp compile_kind(:condition, payload, node, env, project, opts),
    do: compile_visibility(payload, node, env, project, opts)

  defp compile_kind(_kind, _payload, _node, _env, _project, _opts), do: nil

  # An overlay is shown and hidden by workflows (its `runtime` model).
  defp compile_visibility(_payload, %Node{runtime: %{"boundary" => "overlay"}}, _, _, _),
    do: nil

  defp compile_visibility(payload, %Node{source: source} = node, env, project, opts) do
    env = %{env | host: source && source.bubble_id}

    # A condition reading the element's own visibility back is not
    # decided (`ElementVisibility`).
    own_opts = Keyword.put(opts, :visibility_of, env.host)

    with [_ | _] = states <- Conditions.visibility(payload),
         {:ok, parts} <- compile_states(states, env, project, own_opts),
         initial = node.box[:hidden?] != true,
         {parts, default} = settle(parts, initial),
         {:ok, bindings} <- merge_bindings(parts),
         true <- Enum.all?(bindings, &page_input?(&1.input)) do
      results = Enum.map(parts, &elem(&1, 2))

      %{
        source: fold_source(parts, bindings, default),
        bindings: bindings,
        runtime: results |> Enum.flat_map(& &1.runtime) |> Enum.uniq() |> Enum.sort(),
        loads: merge_loads(results),
        type: "boolean",
        approximated: [],
        file?: false,
        raw?: true,
        visibility: %{
          states: length(states),
          initial: initial,
          # Every state left sets the visibility it has on page load:
          # whatever holds, nothing changes.
          constant?:
            default == initial and
              Enum.all?(parts, fn {_source, visible?, _} -> visible? == initial end),
          # Every condition decided when compiling (settle/2): the
          # value it always has, else nil.
          fixed: if(parts == [], do: default)
        }
      }
    else
      _ -> nil
    end
  end

  # A button's "isn't clickable" conditionals (`button_disabled`), folded
  # like visibility from its state on page load: the `disabled` attribute.
  # Absent when one does not compile (the page then renders the button
  # disabled, fail closed).
  defp compile_disabled(payload, %Node{source: source} = node, env, project, opts) do
    env = %{env | host: source && source.bubble_id}

    initial = node.attributes["disabled"] == true

    with [_ | _] = states <- Conditions.disabled_states(payload, initial),
         {:ok, parts} <- compile_states(states, env, project, opts),
         {parts, default} = settle(parts, initial),
         {:ok, bindings} <- merge_bindings(parts),
         true <- Enum.all?(bindings, &page_input?(&1.input)) do
      results = Enum.map(parts, &elem(&1, 2))

      %{
        source: fold_source(parts, bindings, default),
        bindings: bindings,
        runtime: results |> Enum.flat_map(& &1.runtime) |> Enum.uniq() |> Enum.sort(),
        loads: merge_loads(results),
        type: "boolean",
        approximated: [],
        file?: false,
        raw?: true,
        property: %{
          name: "disabled",
          states: length(states),
          initial: initial,
          constant?:
            default == initial and
              Enum.all?(parts, fn {_source, value, _} -> value == initial end),
          fixed: if(parts == [], do: default)
        }
      }
    else
      _ -> nil
    end
  end

  # A Text's content or a button's label whose conditionals set its text
  # (WTF-582), folded like visibility from its content on page load: the
  # last state whose condition is yes sets it. Every condition and every
  # state's text must compile, as the content itself when dynamic.
  defp compile_text(payload, %Node{source: source} = node, env, project, opts) do
    env = %{env | host: source && source.bubble_id}

    with [_ | _] = states <- Conditions.property(payload, "text"),
         {:ok, base} <- text_value(base_text(node), node, env, project, opts),
         {:ok, branches} <- text_branches(states, node, env, project, opts),
         {base, branches} = settle_texts(base, branches),
         results = [base | Enum.flat_map(branches, fn {c, v} -> [c, v] end)],
         {:ok, bindings} <- merge_bindings(Enum.map(results, &{nil, nil, &1})),
         true <- Enum.all?(bindings, &page_input?(&1.input)) do
      runtime = Keyword.get(opts, :runtime, "Bubble.Runtime")

      text = %{
        base: text_part(base, runtime),
        branches:
          Enum.map(branches, fn {condition, value} ->
            Map.put(text_part(value, runtime), :condition, truth(condition.source))
          end),
        guards: width_vars(bindings)
      }

      %{
        source: Conditions.text_source(text, & &1.shown),
        bindings: bindings,
        runtime: results |> Enum.flat_map(& &1.runtime) |> Enum.uniq() |> Enum.sort(),
        loads: merge_loads(results),
        type: "text",
        approximated: Enum.flat_map(results, &Map.get(&1, :approximated, [])) |> Enum.uniq(),
        file?: false,
        raw?: true,
        text: text,
        # Not `property`: like the element's dynamic text, a value never
        # refuses a relationship that was not loaded (it reads as empty).
        states: length(states)
      }
    else
      _ -> nil
    end
  end

  # A text's value as compiled and as shown text (the runtime's
  # `display/1`, as the page shows a value, unless it already is text: a
  # literal, a concatenation or a `display/1` or `text/1` call).
  defp text_part(%{source: source} = result, runtime) do
    shown =
      case Code.string_to_quoted(source) do
        {:ok, literal} when is_binary(literal) -> source
        {:ok, {:<>, _, _}} -> source
        {:ok, {{:., _, [_module, fun]}, _, [_]}} when fun in [:text, :display] -> source
        _ -> "#{runtime}.display(#{source})"
      end

    %{source: source, shown: shown, literal?: Map.get(result, :literal?, false)}
  end

  defp width_vars(bindings) do
    for %{var: var, input: {:page_data, %{"name" => "Current Page Width"}}} <- bindings,
        do: var
  end

  # A Text's content, a button's label: `{:literal, text}` or a binding's
  # payload.
  defp base_text(%Node{kind: kind, content: content, bindings: bindings}) do
    slot = if kind == :text, do: "text", else: "label"

    case {content && content[slot], bindings[slot]} do
      {_, %{kind: :value, payload: payload}} -> payload
      {%{resolved: value}, _} -> {:literal, value}
      _ -> {:literal, ""}
    end
  end

  defp text_branches(states, node, env, project, opts) do
    Enum.reduce_while(states, {:ok, []}, fn {condition, value}, {:ok, acc} ->
      with {:ok, condition} <- compile_condition(condition, env, project, opts),
           {:ok, value} <- text_value(value, node, env, project, opts) do
        {:cont, {:ok, acc ++ [{condition, value}]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  # A text a state sets, or the content on page load: a literal, or an
  # expression compiled as the element's dynamic text.
  defp text_value({:literal, value}, _node, _env, _project, _opts)
       when is_binary(value) or is_number(value),
       do: {:ok, literal_text(to_string(value))}

  defp text_value(value, _node, _env, _project, _opts) when value in [nil, ""],
    do: {:ok, literal_text("")}

  defp text_value(value, node, env, project, opts) when is_binary(value) or is_number(value),
    do: text_value({:literal, value}, node, env, project, opts)

  defp text_value(value, %Node{} = node, env, project, opts) when is_map(value) do
    case compile_binding(value, node, env, project, opts) do
      %{source: _} = result -> {:ok, Map.put_new(result, :loads, %{})}
      nil -> :error
    end
  end

  defp text_value(_value, _node, _env, _project, _opts), do: :error

  defp literal_text(text),
    do: %{source: inspect(text), bindings: [], runtime: [], loads: %{}, literal?: true}

  # The states in Bubble's order as one `cond`: the last true one decides,
  # else `default` (the value on page load, or the one a state decided
  # when compiling sets, see settle/2), also until the page has a width.
  defp fold_source(parts, bindings, default) do
    clauses =
      parts
      |> Enum.reverse()
      |> Enum.map_join("\n", fn {source, value, _result} -> "#{truth(source)} -> #{value}" end)

    "cond do\n#{width_guard(bindings, default)}#{clauses}\ntrue -> #{default}\nend"
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  # States whose condition is decided when compiling (a literal: an
  # element's visibility read from inside it, WTF-578) as Bubble applies
  # them: a no never applies, and the last yes sets the value every
  # earlier state and the page-load value would. `{parts, default}`.
  defp settle(parts, initial) do
    last_yes =
      parts
      |> Enum.with_index()
      |> Enum.filter(fn {{source, _value, _result}, _i} -> literal?(source, true) end)
      |> List.last()

    {parts, default} =
      case last_yes do
        nil -> {parts, initial}
        {{_source, value, _result}, i} -> {Enum.drop(parts, i + 1), value}
      end

    {Enum.reject(parts, fn {source, _value, _result} -> literal?(source, false) end), default}
  end

  defp literal?(source, value), do: Code.string_to_quoted(source) == {:ok, value}

  # settle/2 for a text's states: `{base, branches}`.
  defp settle_texts(base, branches) do
    {parts, base} =
      branches
      |> Enum.map(fn {condition, value} -> {condition.source, value, condition} end)
      |> settle(base)

    {base, Enum.map(parts, fn {_source, value, condition} -> {condition, value} end)}
  end

  # Bubble always knows the page's width; the page does not before its
  # first connected render (the static render, a test's socket): until
  # then a conditional reading it keeps the value on page load, whatever
  # its shape (`is not`, `is empty`, `or`, `not` would otherwise decide on
  # an empty width).
  defp width_guard(bindings, initial) do
    for %{var: var, input: {:page_data, %{"name" => "Current Page Width"}}} <- bindings,
        into: "",
        do: "is_nil(#{var}) -> #{initial}\n"
  end

  # What a page can supply a condition with: the current user, an
  # element's state (custom states, input values, a group's data), the
  # page's or the current cell's thing, what the URL holds, the
  # viewport's width (`Current page width`, WTF-520), the current date and
  # time and the host page's name (replayed 2026-10-19) (the target
  # decides per page whether it does). Anything else (the app's version…)
  # would be a value nothing sets, never the one Bubble reads.
  @page_inputs [:element_state, :page_thing, :cell_thing, :cell_index, :url_parameter]
  @page_values ["Current Page Width", "Current Date/Time", "Current Page Name"]

  defp page_input?(:current_user), do: true
  defp page_input?({:page_data, %{"name" => name}}) when name in @page_values, do: true
  defp page_input?({kind, _ref}) when kind in @page_inputs, do: true
  defp page_input?(_input), do: false

  # A condition's source as a clause: true only for `true` (an empty
  # value is false). Comparisons and boolean operators already are.
  @boolean_ops [:==, :!=, :===, :!==, :<, :>, :<=, :>=, :and, :or, :not, :is_nil, :in]

  defp truth(source) do
    case Code.string_to_quoted(source) do
      {:ok, {op, _, args}} when op in @boolean_ops and is_list(args) -> source
      {:ok, boolean} when is_boolean(boolean) -> source
      _ -> "(#{source}) == true"
    end
  end

  defp compile_states(states, env, project, opts) do
    Enum.reduce_while(states, {:ok, []}, fn
      {_condition, nil}, _acc ->
        {:halt, :error}

      {condition, visible?}, {:ok, acc} ->
        case compile_condition(condition, env, project, opts) do
          {:ok, result} -> {:cont, {:ok, acc ++ [{result.source, visible?, result}]}}
          :error -> {:halt, :error}
        end
    end)
  end

  # A condition is a yes/no expression; compiled as a value (not shown).
  defp compile_condition(condition, env, project, opts) when is_map(condition) do
    with {:ok, %{ast: ast}} <- Expression.parse(condition, schema: env.schema),
         {:ok, %{ir: %IR{type: "boolean"} = ir}} <- Compiler.compile(ast, env),
         ir = element_visibility(ir, env, opts),
         {:ok, %{source: code} = result} when is_binary(code) <-
           ElixirTarget.compile(ir, project, Keyword.delete(target_opts(opts), :display)) do
      {:ok, result}
    else
      _ -> :error
    end
  end

  defp compile_condition(_condition, _env, _project, _opts), do: :error

  # An element's `is visible` the page decides (WTF-578): its visibility,
  # inlined (`ElementVisibility.inline/4`).
  defp element_visibility(ir, env, opts) do
    seen =
      case Keyword.get(opts, :visibility_of) do
        id when is_binary(id) -> MapSet.new([id])
        _ -> MapSet.new()
      end

    ElementVisibility.inline(ir, env.host, seen, Keyword.get(opts, :element_visibility))
  end

  # One variable per input across the states (variables are named from
  # their input, so a name naming two inputs cannot be shared).
  defp merge_bindings(parts) do
    bindings = parts |> Enum.flat_map(fn {_, _, result} -> result.bindings end) |> Enum.uniq()

    if bindings |> Enum.uniq_by(& &1.var) |> length() == length(bindings),
      do: {:ok, Enum.sort_by(bindings, & &1.var)},
      else: :error
  end

  defp merge_loads(results) do
    results
    |> Enum.map(& &1.loads)
    |> Enum.reduce(%{}, fn loads, acc ->
      Map.merge(acc, loads, fn _var, a, b -> Enum.sort(Enum.uniq(a ++ b)) end)
    end)
  end

  @file_types ["file", "image"]
  @schemes ["https:", "http:"]

  # The one file or image value a binding shows, or nil: the value itself,
  # or the only part of a dynamic text besides empty literals and a leading
  # "https:"/"http:" (Bubble's stored file URLs are protocol-relative, so
  # apps prefix a scheme; the app's route needs none).
  defp shown_file(%IR{type: type} = ir) when type in @file_types, do: ir

  defp shown_file(%IR{op: :concat, args: parts}) do
    case Enum.reject(parts, &empty_text?/1) do
      [%IR{op: :literal, args: [scheme]}, %IR{type: type} = part]
      when scheme in @schemes and type in @file_types ->
        part

      [%IR{type: type} = part] when type in @file_types ->
        part

      _ ->
        nil
    end
  end

  defp shown_file(_ir), do: nil

  defp empty_text?(%IR{op: :literal, args: [""]}), do: true
  defp empty_text?(_ir), do: false

  defp compile_binding(payload, %Node{source: source}, env, project, opts) do
    env = %{env | host: source && source.bubble_id}
    parse_opts = [schema: env.schema, this_type: env.this_type, this_binder: env.this_binder]

    with {:ok, %{ast: ast}} <- Expression.parse(payload, parse_opts),
         {:ok, %{ir: ir}} when not is_nil(ir) <- Compiler.compile(ast, env),
         ir = element_visibility(ir, env, opts),
         {:ok, %{source: code} = result} when is_binary(code) <-
           ElixirTarget.compile(ir, project, target_opts(opts)) do
      result
      |> Map.take([:source, :bindings, :runtime, :loads])
      |> Map.merge(%{type: ir.type, approximated: approximated(result.diagnostics)})
      |> Map.merge(file_value(shown_file(ir), project, opts))
    else
      _ -> nil
    end
  end

  # The format parts the runtime only approximates (see
  # `BubbleEx.Target.Elixir.Formats`), which the page marks.
  defp approximated(diagnostics) do
    for %{code: :elixir_format_approximated, details: %{constructs: constructs}} <- diagnostics,
        construct <- constructs,
        do: construct
  end

  # A binding showing one file value also compiles to just its link
  # (`<Web>.Uploads.url/1`, nil when empty): what an image source or a
  # link's href needs.
  defp file_value(nil, _project, _opts), do: %{file?: false}

  defp file_value(ir, project, opts) do
    case ElixirTarget.compile(ir, project, target_opts(opts)) do
      {:ok, %{source: code, bindings: bindings}} when is_binary(code) ->
        %{file?: true, file: %{source: code, bindings: bindings}}

      _ ->
        %{file?: false}
    end
  end

  defp target_opts(opts) do
    namespace = Keyword.get(opts, :namespace, "MyApp")

    [
      runtime: Keyword.get(opts, :runtime, "Bubble.Runtime"),
      namespace: namespace,
      file_url: Keyword.get(opts, :file_url, namespace <> "Web.Uploads.url"),
      display: true
    ]
  end
end
