defmodule BubbleEx.Workflows.Explanation do
  @moduledoc false
  alias BubbleEx.AppTree.Expr
  alias BubbleEx.AppTree.Expr.Explanation, as: Expression
  alias BubbleEx.Workflows.{ExplanationContext, Source}

  @conditions ~w(condition only_when %c)
  @flags ~w(workflow_disabled action_disabled disabled)
  @type_keys ~w(type_to_create thing_type %tt)
  @aliases [
    ~w(type %x),
    ~w(properties %p),
    ~w(id %id),
    @type_keys,
    ~w(initial_values %i2),
    ~w(changes %cs),
    ~w(to_change %tc),
    ~w(key %k),
    ~w(value %v),
    ~w(action_kind %ak)
  ]

  @spec describe(term(), list(), map()) :: map()
  def describe(raw, path, context) when is_map(raw) do
    type = Source.value(raw, ~w(type %x))
    {pk, props} = Source.get(raw, ~w(properties %p)) || {"properties", %{}}
    detail = intent(type, raw, path, props, path ++ [pk], context)
    conditions = conditions(raw, path, context)
    flags = flags(raw, path)
    unknown = unknown_properties(props, path ++ [pk], keys(type)) ++ unknown_node(raw, path)

    collisions =
      collisions(raw, path) ++
        collisions(props, path ++ [pk]) ++
        if(length(conditions) > 1,
          do: [
            Expression.unknown(
              raw,
              path,
              "Multiple condition representations; combination is unresolved"
            )
          ],
          else: []
        )

    children = [detail] ++ Enum.map(conditions, & &1.expression) ++ flags ++ unknown ++ collisions

    Expression.record(
      "workflow_node",
      raw,
      path,
      Expression.combine(children),
      detail.text,
      children
    )
    |> Map.merge(%{
      intent: detail,
      conditions: conditions,
      flags: flags,
      uninterpreted: unknown ++ collisions
    })
  end

  def describe(raw, path, _), do: Expression.unknown(raw, path, "Malformed workflow/action")

  @spec conditions(map(), list(), map()) :: [map()]
  def conditions(raw, path, context) do
    own_conditions(raw, path, context) ++
      Enum.flat_map(~w(properties %p), fn key ->
        own_conditions(Map.get(raw, key), path ++ [key], context)
      end)
  end

  defp own_conditions(raw, path, context) when is_map(raw) do
    for key <- @conditions, Map.has_key?(raw, key) do
      value = Map.fetch!(raw, key)
      expression = Expr.explain(value, path ++ [key], context)
      # A reference or literal alone is not automatically a boolean condition.
      expression =
        if expression.status == "fully_supported" and
             Map.get(expression, :data_type) != "boolean",
           do: %{
             expression
             | status: "unresolved",
               text: "Condition is not a proven boolean: " <> expression.text
           },
           else: expression

      %{
        path: expression.path,
        raw: value,
        status: expression.status,
        text: expression.text,
        expression: expression,
        diagnostics:
          if(expression.status == "fully_supported",
            do: [],
            else: [
              Source.diagnostic(
                :unresolved_condition,
                path ++ [key],
                "Condition includes unavailable or uninterpreted source; never treated as unconditional."
              )
            ]
          )
      }
    end
  end

  defp own_conditions(_, _, _), do: []

  defp intent("ButtonClicked", raw, path, props, pp, context) do
    target =
      property(props, pp, ~w(element_id %ei), fn value, p ->
        ExplanationContext.reference("element", value, p, context)
      end)

    Expression.record("event", raw, path, target.status, "When #{target.text} is clicked", [
      target
    ])
  end

  defp intent("PageLoaded", raw, path, _, _, _),
    do: Expression.record("event", raw, path, "fully_supported", "When the page loads")

  defp intent("NewThing", raw, path, props, pp, context) do
    target =
      property(props, pp, @type_keys, fn value, p ->
        ExplanationContext.reference("data_type", value, p, context)
      end)

    changes = assignments(props, pp, ~w(initial_values %i2), target, context)

    Expression.record(
      "create",
      raw,
      path,
      Expression.combine([target, changes]),
      "Create #{target.text}; #{changes.text}",
      [target, changes]
    )
    |> Map.merge(%{target: target, assignments: changes})
  end

  defp intent("ChangeThing", raw, path, props, pp, context) do
    target = property(props, pp, ~w(to_change %tc), &Expr.explain(&1, &2, context))
    changes = assignments(props, pp, ~w(changes %cs), target, context)

    Expression.record(
      "change",
      raw,
      path,
      Expression.combine([target, changes]),
      "Change #{target.text}; #{changes.text}",
      [target, changes]
    )
    |> Map.merge(%{target: target, assignments: changes})
  end

  defp intent(_, raw, path, _, _, _),
    do: Expression.unknown(raw, path, "Intent outside the verified vocabulary")

  defp assignments(props, path, keys, target, context) do
    property(props, path, keys, &assignment_collection(&1, &2, target, context))
  end

  defp assignment_collection(raw, path, target, context) do
    case Expression.ordered(raw) do
      {:ok, entries} ->
        children =
          Enum.map(entries, fn {key, value} ->
            assignment(value, path ++ [key], target, context)
          end)

        text =
          if children == [],
            do: "no explicit field assignments",
            else: Enum.map_join(children, "; ", & &1.text)

        Expression.record("assignments", raw, path, Expression.combine(children), text, children)

      :error ->
        Expression.unknown(raw, path, "Malformed assignments or unresolved assignment order")
    end
  end

  defp assignment(raw, path, target, context) when is_map(raw) do
    field =
      property(raw, path, ~w(key %k), fn id, p ->
        context.field.(Map.get(target, :data_type), id, p)
        |> Map.put(:raw, id)
        |> Map.put(:path, Source.pointer(p))
      end)

    value = property(raw, path, ~w(value %v), &Expr.explain(&1, &2, context))
    operation = operation(raw, path)

    extras =
      unknown_properties(raw, path, ~w(key %k value %v action_kind %ak)) ++ collisions(raw, path)

    children = [field, value, operation] ++ extras

    Expression.record(
      "assignment",
      raw,
      path,
      Expression.combine(children),
      "#{operation.text} #{field.text} = #{value.text}",
      children
    )
    |> Map.merge(%{field: field, value: value, operation: operation})
  end

  defp assignment(raw, path, _, _), do: Expression.unknown(raw, path, "Malformed assignment")

  defp operation(raw, path) do
    case Source.get(raw, ~w(action_kind %ak)) do
      nil ->
        %{
          kind: "assignment_operation",
          path: Source.pointer(path),
          status: "fully_supported",
          text: "set",
          children: [],
          basis: "absent action_kind in editor-verified assignment"
        }

      {key, value} when value in [%{"type" => "Empty"}, %{"%x" => "Empty"}] ->
        Expression.record("assignment_operation", value, path ++ [key], "fully_supported", "set")

      {key, value} ->
        Expression.unknown(value, path ++ [key], "Unproven assignment operation")
    end
  end

  defp property(raw, path, keys, fun) do
    case Source.get(raw, keys) do
      {key, value} -> fun.(value, path ++ [key])
      nil -> Expression.unavailable(path, "Missing #{hd(keys)}")
    end
  end

  defp flags(raw, path) do
    own_flags(raw, path) ++
      Enum.flat_map(~w(properties %p), &own_flags(Map.get(raw, &1), path ++ [&1]))
  end

  defp own_flags(raw, path) when is_map(raw) do
    for key <- @flags, Map.has_key?(raw, key) do
      value = Map.fetch!(raw, key)

      Expression.record(
        "flag",
        value,
        path ++ [key],
        if(is_boolean(value), do: "fully_supported", else: "unresolved"),
        "#{key}: #{Jason.encode!(value)}"
      )
    end
  end

  defp own_flags(_, _), do: []

  defp keys("NewThing"), do: @type_keys ++ ~w(initial_values %i2)
  defp keys("ChangeThing"), do: ~w(to_change %tc changes %cs)
  defp keys("ButtonClicked"), do: ~w(element_id %ei)
  defp keys(_), do: []

  defp unknown_properties(raw, path, known) when is_map(raw) do
    (Map.keys(raw) -- (known ++ @conditions ++ @flags))
    |> Enum.sort()
    |> Enum.map(&Expression.unknown(Map.fetch!(raw, &1), path ++ [&1], "Uninterpreted property"))
  end

  defp unknown_properties(raw, path, _),
    do: [Expression.unknown(raw, path, "Malformed properties")]

  defp unknown_node(raw, path),
    do: unknown_properties(raw, path, ~w(type %x id %id name %nm properties %p actions))

  defp collisions(raw, path) when is_map(raw) do
    @aliases
    |> Enum.filter(fn keys -> Enum.count(keys, &Map.has_key?(raw, &1)) > 1 end)
    |> Enum.map(fn _ ->
      Expression.unknown(raw, path, "Alias collision; selected display is not authoritative")
    end)
  end

  defp collisions(_, _), do: []
end
