defmodule BubbleEx.Target.Ash.Expr do
  @moduledoc """
  An `Ash.Expr` described as plain data: a filter over one resource, as
  `BubbleEx.Target.Ash.Expressions` derives it from an expression's
  `BubbleEx.Expression.IR`. `BubbleEx.Target.Ash.Source.expr/1` prints it
  as `expr(...)`. No Ash dependency.

    * `resource` - the module (relative to the root namespace) whose
      records the filter selects
    * `source` - Bubble IDs of what it came from (e.g. `%{type: "task",
      rule: "owner_"}` for a privacy rule's condition)
    * `expr` - the expression tree (below)
    * `actor_loads` - relationship paths the actor must have loaded for the
      `^actor(...)` templates (`[["current_role"]]` for
      `^actor([:current_role, :workspace_id])`); Ash raises on a template
      path through an unloaded relationship
    * `arguments` - the context inputs the filter reads as `^arg(:name)`:
      `%{name, input, type}` with the IR's input kind and Bubble IDs;
      with `keywords: true`, the `ILIKE` patterns of the input's words
      (`BubbleEx.Target.Keywords.patterns/1`) rather than its value
    * `sort` - `[{attribute, :asc_nils_last | :desc_nils_last}]` for a
      search's sort (empty values last in both directions, as Bubble sorts
      things; replay 2026-10-07), or
      `[:random]` for Bubble's random sort (no field: a new order on
      every read; `BubbleData.random_sort/1` in the generated app)

  ## Expression tree

  Tagged tuples with string names:

  | Node | Prints as |
  |------|-----------|
  | `{:ref, ["project"], "title"}` | `project.title` (relationship path, then attribute) |
  | `{:actor, ["current_role", "workspace_id"]}` | `^actor([:current_role, :workspace_id])` (`^actor(:id)` for one) |
  | `{:arg, "name"}` | `^arg(:name)` |
  | `{:pin, "name"}` | `^name`: a variable of the code around the filter (`BubbleEx.Target.Ash.Source.filter/1`) |
  | `{:value, term}` | the literal |
  | `{:op, "==", left, right}` | `left == right` (also `!=`, `>`, `<`, `>=`, `<=`, `in`, `+`, `-`, `*`, `/`, and `\|\|`: the left value, or the right one when it is nil) |
  | `{:and, [a, b]}` / `{:or, [a, b]}` | `a and b` / `a or b` |
  | `{:not, x}` | `not x` |
  | `{:call, "is_nil", [x]}` | `is_nil(x)` (also `is_not_distinct_from`, `is_distinct_from`, `contains`, `string_downcase`, `length`, …) |
  """

  @enforce_keys [:resource, :expr]
  defstruct [:resource, :expr, source: %{}, actor_loads: [], arguments: [], sort: []]

  @type node_ ::
          {:ref, [String.t()], String.t()}
          | {:actor, [String.t()]}
          | {:arg, String.t()}
          | {:pin, String.t()}
          | {:value, term()}
          | {:op, String.t(), node_(), node_()}
          | {:and, [node_()]}
          | {:or, [node_()]}
          | {:not, node_()}
          | {:call, String.t(), [node_()]}

  @type t :: %__MODULE__{
          resource: String.t(),
          expr: node_(),
          source: map(),
          actor_loads: [[String.t()]],
          arguments: [%{name: String.t(), input: {atom(), map()}, type: String.t() | nil}],
          sort: [{String.t(), :asc_nils_last | :desc_nils_last}] | [:random]
        }

  @doc "JSON form: string keys; tuples become lists, atoms strings."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = e), do: json(Map.from_struct(e))

  defp json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json()
  defp json(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp json(value), do: value
end
