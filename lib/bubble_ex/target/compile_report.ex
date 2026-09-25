defmodule BubbleEx.Target.CompileReport do
  @moduledoc """
  How much of an app's expressions compile, as aggregate counts (string
  keys, no names or IDs): for the privacy-rule conditions (IR, then
  `Ash.Expr` via `BubbleEx.Target.Ash.Expressions`) and for every page,
  reusable-element and workflow expression (`BubbleEx.Expression.Sites`):
  IR, then Elixir (`BubbleEx.Target.Elixir`), and each search in them to
  an Ash query filter.

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, counts} = BubbleEx.Target.CompileReport.build(app, model, project)

  `unsupported` counts, per stage, the constructs that stopped
  compilation (a diagnostic's `details.construct(s)`, or its code for
  typing diagnostics), so the top of each list is the next thing to build.

  ## Options

    * `:ignore_empty_constraints` - passed to every expression's
      `BubbleEx.Expression.Env` (default nil: unknown)
  """

  alias BubbleEx.{Diagnostic, Error, Expression, Model}
  alias BubbleEx.Expression.{Compiler, IR, Sites, Tree}
  alias BubbleEx.Target.Ash.{Expressions, Project}
  alias BubbleEx.Target.Elixir, as: ElixirTarget

  @spec build(map(), Model.t(), Project.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def build(app, model, project, opts \\ [])

  def build(app, %Model{} = model, %Project{} = project, opts)
      when is_map(app) and not is_struct(app) and is_list(opts) do
    {:ok,
     %{
       "privacy" => privacy(model, project),
       "expressions" => expressions(app, model, project, opts)
     }}
  end

  def build(_app, _model, _project, _opts),
    do: {:error, Error.new(:invalid_input, "expected app JSON, its Model and its Ash project")}

  defp privacy(model, project) do
    rules = for type <- model.data_types, rule <- type.rules, do: rule
    {:ok, results} = Expressions.privacy(model, project)
    diags = Enum.flat_map(results, & &1.diagnostics)

    %{
      "rules" => length(rules),
      "rules_without_condition" => Enum.count(rules, &is_nil(&1.condition)),
      "conditions" => length(results),
      "ash_compiled" => Enum.count(results, & &1.expr),
      "ash_with_actor_loads" => Enum.count(results, &(&1.expr && &1.expr.actor_loads != [])),
      "diagnostics" => frequencies(diags, &Atom.to_string(&1.code)),
      "unsupported" =>
        unsupported(Enum.reject(results, & &1.expr) |> Enum.flat_map(& &1.diagnostics))
    }
  end

  defp expressions(app, model, project, opts) do
    tree = Tree.build(app)

    {:ok, sites} = Sites.collect(app, model, tree)

    compiled =
      Enum.map(sites, fn site ->
        env = %{site.env | ignore_empty_constraints: Keyword.get(opts, :ignore_empty_constraints)}
        compile_site(site, env, project)
      end)

    ir_ok = Enum.filter(compiled, & &1.ir)
    searches = Enum.flat_map(ir_ok, & &1.searches)

    %{
      "roots" => length(compiled),
      "by_kind" => frequencies(compiled, &Atom.to_string(&1.kind)),
      "ir_compiled" => length(ir_ok),
      "elixir_compiled" => Enum.count(ir_ok, & &1.elixir),
      "searches" => length(searches),
      "searches_ash_compiled" => Enum.count(searches, & &1),
      "unsupported" => %{
        "ir" => unsupported(Enum.flat_map(compiled, &if(&1.ir, do: [], else: &1.diagnostics))),
        "elixir" => unsupported(Enum.flat_map(ir_ok, & &1.elixir_diagnostics)),
        "ash_search" => unsupported(Enum.flat_map(ir_ok, & &1.search_diagnostics))
      }
    }
  end

  defp compile_site(site, env, project) do
    {:ok, %{ast: ast}} = Expression.parse(site.raw, schema: env.schema, path: site.path)
    {:ok, result} = Compiler.compile(ast, env)

    base = %{kind: site.kind, ir: result.ir, diagnostics: result.diagnostics}

    case result.ir do
      nil ->
        base

      ir ->
        {:ok, elixir} = ElixirTarget.compile(ir, project, path: Diagnostic.pointer(site.path))

        search_results =
          for search <- searches(ir),
              do: search |> Expressions.search(project) |> elem(1)

        Map.merge(base, %{
          elixir: elixir.source != nil,
          elixir_diagnostics: elixir.diagnostics,
          searches: Enum.map(search_results, &(&1.expr != nil)),
          search_diagnostics: Enum.flat_map(search_results, & &1.diagnostics)
        })
    end
  end

  # Searches (with their sort), outermost first.
  defp searches(%IR{op: :sort, args: [%IR{op: :search} | _]} = ir), do: [ir]
  defp searches(%IR{op: :search} = ir), do: [ir]
  defp searches(%IR{args: args}), do: Enum.flat_map(args, &nested/1)

  defp nested(%IR{} = ir), do: searches(ir)
  defp nested(list) when is_list(list), do: Enum.flat_map(list, &nested/1)
  defp nested(_), do: []

  defp unsupported(diags) do
    diags
    |> Enum.filter(&(&1.severity != :info or &1.code in [:expr_untyped_scope]))
    |> Enum.flat_map(fn d ->
      case d.details do
        %{construct: c} -> ["#{d.code}:#{c}"]
        %{constructs: cs} -> Enum.map(cs, &"#{d.code}:#{&1}")
        %{scope: s} -> ["#{d.code}:#{s}"]
        _ -> [Atom.to_string(d.code)]
      end
    end)
    |> Enum.frequencies()
  end

  defp frequencies(list, fun), do: list |> Enum.frequencies_by(fun) |> Map.new()
end
