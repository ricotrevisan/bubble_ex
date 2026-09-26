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
  compiled `%{source, bindings, runtime, loads}`; a binding that does not
  compile is absent (the page keeps a residue marker for it).

  ## Options

    * `:runtime` - the runtime module the source calls (default
      `"Bubble.Runtime"`; the Phoenix target passes its own)
    * `:namespace` - root namespace of the generated enums
  """

  alias BubbleEx.{Error, Expression, Model}
  alias BubbleEx.Expression.{Compiler, Env, Tree}
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Target.Ash.Project
  alias BubbleEx.Target.Elixir, as: ElixirTarget

  @type compiled :: %{
          source: String.t(),
          bindings: [map()],
          runtime: [atom()],
          loads: map()
        }

  @spec compile(map(), Model.t(), Project.t(), Normalized.t(), keyword()) ::
          {:ok, %{String.t() => compiled()}} | {:error, Error.t()}
  def compile(app, model, project, frontend, opts \\ [])

  def compile(app, %Model{} = model, %Project{} = project, %Normalized{} = frontend, opts)
      when is_map(app) and not is_struct(app) and is_list(opts) do
    env = Env.new(model, tree: Tree.build(app))

    compiled =
      for node <- Enum.flat_map(frontend.pages ++ frontend.reusables, &nodes/1),
          {_slot, %{kind: :value, id: id, payload: payload}} <- node.bindings,
          result = compile_binding(payload, node, env, project, opts),
          into: %{},
          do: {id, result}

    {:ok, compiled}
  end

  def compile(_app, _model, _project, _frontend, _opts),
    do:
      {:error,
       Error.new(:invalid_input, "expected app JSON, its Model, its Ash project and its frontend")}

  defp nodes(%Node{} = node), do: [node | Enum.flat_map(node.children, &nodes/1)]

  defp compile_binding(payload, %Node{source: source}, env, project, opts) do
    env = %{env | host: source && source.bubble_id}

    with {:ok, %{ast: ast}} <- Expression.parse(payload, schema: env.schema),
         {:ok, %{ir: ir}} when not is_nil(ir) <- Compiler.compile(ast, env),
         {:ok, %{source: code} = result} when is_binary(code) <-
           ElixirTarget.compile(ir, project,
             runtime: Keyword.get(opts, :runtime, "Bubble.Runtime"),
             namespace: Keyword.get(opts, :namespace, "MyApp")
           ) do
      Map.take(result, [:source, :bindings, :runtime, :loads])
    else
      _ -> nil
    end
  end
end
