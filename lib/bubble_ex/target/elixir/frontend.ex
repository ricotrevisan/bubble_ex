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
  visibility on page load, so the result never changes). Anything else conditionals set (colors, text…) is
  not compiled here.

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
            constant?: boolean()
          }
        }

  @spec compile(map(), Model.t(), Project.t(), Normalized.t(), keyword()) ::
          {:ok, %{String.t() => compiled()}} | {:error, Error.t()}
  def compile(app, model, project, frontend, opts \\ [])

  def compile(app, %Model{} = model, %Project{} = project, %Normalized{} = frontend, opts)
      when is_map(app) and not is_struct(app) and is_list(opts) do
    env = Env.new(model, tree: Tree.build(app), searches: :page)

    compiled =
      for node <- Enum.flat_map(frontend.pages ++ frontend.reusables, &nodes/1),
          {_slot, %{kind: kind, id: id, payload: payload}} <- node.bindings,
          result = compile_kind(kind, payload, node, env, project, opts),
          into: %{},
          do: {id, result}

    {:ok, compiled}
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
    for node <- Enum.flat_map(frontend.pages ++ frontend.reusables, &nodes/1),
        %{kind: :condition, id: id, payload: payload} <- [node.bindings["condition"]],
        states = Conditions.visibility(payload),
        states != [],
        not Map.has_key?(compiled, id),
        %{bubble_id: bubble_id} when is_binary(bubble_id) <- [node.source],
        uniq: true,
        do: Residue.entry("element:" <> bubble_id, :element_condition, %{states: length(states)})
  end

  defp nodes(%Node{} = node), do: [node | Enum.flat_map(node.children, &nodes/1)]

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

    with [_ | _] = states <- Conditions.visibility(payload),
         {:ok, parts} <- compile_states(states, env, project, opts),
         {:ok, bindings} <- merge_bindings(parts),
         true <- Enum.all?(bindings, &page_input?(&1.input)) do
      initial = node.box[:hidden?] != true

      clauses =
        parts
        |> Enum.reverse()
        |> Enum.map_join("\n", fn {source, visible?, _result} ->
          "#{truth(source)} -> #{visible?}"
        end)

      source =
        "cond do\n#{clauses}\ntrue -> #{initial}\nend"
        |> Code.format_string!()
        |> IO.iodata_to_binary()

      results = Enum.map(parts, &elem(&1, 2))

      %{
        source: source,
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
          # Every state sets the visibility it has on page load: whatever
          # holds, nothing changes.
          constant?: Enum.all?(states, fn {_condition, visible?} -> visible? == initial end)
        }
      }
    else
      _ -> nil
    end
  end

  # What a page can supply a condition with: the current user, an
  # element's state (custom states, input values, a group's data) and the
  # page's or the current cell's thing (the target decides per page
  # whether it does). Anything else (URL parameters, the page's width or
  # name…) would be a value nothing sets, never the one Bubble reads.
  @page_inputs [:element_state, :page_thing, :cell_thing, :cell_index]

  defp page_input?(:current_user), do: true
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
         {:ok, %{source: code} = result} when is_binary(code) <-
           ElixirTarget.compile(ir, project, Keyword.delete(target_opts(opts), :display)) do
      {:ok, result}
    else
      _ -> :error
    end
  end

  defp compile_condition(_condition, _env, _project, _opts), do: :error

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

    with {:ok, %{ast: ast}} <- Expression.parse(payload, schema: env.schema),
         {:ok, %{ir: ir}} when not is_nil(ir) <- Compiler.compile(ast, env),
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
