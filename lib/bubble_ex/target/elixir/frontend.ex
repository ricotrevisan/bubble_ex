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
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Target.Ash.Project
  alias BubbleEx.Target.Elixir, as: ElixirTarget

  @type compiled :: %{
          required(:source) => String.t(),
          required(:bindings) => [map()],
          required(:runtime) => [atom()],
          required(:loads) => map(),
          required(:type) => String.t() | nil,
          required(:file?) => boolean(),
          optional(:file) => %{source: String.t(), bindings: [map()]}
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
      file_url: Keyword.get(opts, :file_url, namespace <> "Web.Uploads.url")
    ]
  end
end
