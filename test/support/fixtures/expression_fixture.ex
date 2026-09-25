defmodule BubbleEx.Test.ExpressionFixture do
  @moduledoc false

  # The synthetic app of the expression compiler tests
  # (test/support/expression/app.json, all data invented): users, roles,
  # workspaces and tasks with privacy rules covering the real-app condition
  # shapes, a page with groups, a repeating group, inputs, a plugin element
  # and a reusable instance, workflows with data steps, an API workflow and
  # a database trigger. Plus small builders for expression JSON.

  alias BubbleEx.Expression
  alias BubbleEx.Expression.{Env, Schema, Tree}
  alias BubbleEx.Model
  alias BubbleEx.Target.Ash

  @path "test/support/expression/app.json"
  @external_resource @path
  @app @path |> File.read!() |> Jason.decode!()

  def app, do: @app

  def model do
    {:ok, model} = Model.build(@app)
    model
  end

  def project(model \\ model()) do
    {:ok, project} = Ash.map(model)
    project
  end

  @doc "An environment in the fixture app; `opts` as `BubbleEx.Expression.Env.new/2`."
  def env(opts \\ []) do
    model = Keyword.get_lazy(opts, :model, &model/0)
    Env.new(model, Keyword.merge([tree: Tree.build(@app)], Keyword.delete(opts, :model)))
  end

  @doc "The environment of a privacy rule condition on data type `type`."
  def rule_env(type, opts \\ []) do
    env([this_type: Schema.thing_type(type), this_binder: :rule_record] ++ opts)
  end

  def parse!(raw, env) do
    opts = [
      schema: env.schema,
      path: env.path,
      this_type: env.this_type,
      this_binder: env.this_binder
    ]

    {:ok, %{ast: ast}} = Expression.parse(raw, opts)
    ast
  end

  # --- expression JSON ---------------------------------------------------------------

  def src(type, props \\ nil),
    do: if(props, do: %{"type" => type, "properties" => props}, else: %{"type" => type})

  def msg(name, args \\ nil, props \\ nil) do
    %{"type" => "Message", "name" => name}
    |> put_if("args", args)
    |> put_if("properties", props)
  end

  @doc "Appends operator `messages` to the end of `source`'s chain."
  def chain(source, []), do: source

  def chain(%{"next" => next} = source, messages),
    do: Map.put(source, "next", chain(next, messages))

  def chain(source, [message | rest]), do: Map.put(source, "next", chain(message, rest))

  def text(parts) do
    %{
      "type" => "TextExpression",
      "entries" =>
        parts |> Enum.with_index() |> Map.new(fn {p, i} -> {Integer.to_string(i), p} end)
    }
  end

  def cu, do: src("CurrentUser")
  def this, do: src("InjectedValue")
  def el(id), do: src("GetElement", %{"element_id" => id})

  def opt(set, value),
    do: src("OneOptionValue", %{"option_set" => "option." <> set, "option_value" => value})

  def search(type, constraints, options \\ %{}) do
    props =
      Map.merge(options, %{
        "type_to_find" => type,
        "constraints" =>
          constraints |> Enum.with_index() |> Map.new(fn {c, i} -> {Integer.to_string(i), c} end)
      })

    src("Search", props)
  end

  def con(key, op, value), do: %{"key" => key, "constraint_type" => op, "value" => value}

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
