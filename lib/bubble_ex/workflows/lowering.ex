defmodule BubbleEx.Workflows.Lowering do
  @moduledoc """
  Step-lowering helpers shared by the stack-neutral workflow lowerings
  (`BubbleEx.Workflows.Frontend`, WTF-372; the backend lowering of WTF-373
  uses the same vocabulary): values compiled to `BubbleEx.Expression.IR`
  (`BubbleEx.Workflows.Lowering.Expr`), the data operations (`:create`,
  `:update`, `:update_current_user`, `:delete`, `:update_list`,
  `:delete_list`) with their field changes
  (`BubbleEx.Workflows.Lowering.Change`), custom-event calls and returns,
  and the residue of action types with no lowering.

  Everything here is stack-neutral: Bubble IDs, IR and
  `BubbleEx.Plan.Residue` entries, no target names.

  ## Data operations

  | Bubble action | op | args |
  |---------------|----|------|
  | Create a new thing (`NewThing`) | `:create` | `data_type`, `changes` |
  | Make changes to a thing (`ChangeThing`) | `:update` | `data_type`, `target`, `changes` |
  | Make changes to the current user (`MakeChangeCurrentUser`) | `:update_current_user` | `data_type` (`"user"`), `changes` |
  | Delete a thing (`DeleteThing`) | `:delete` | `data_type`, `target` |
  | Make changes to a list of things (`ChangeListOfThings`) | `:update_list` | `data_type`, `target`, `changes` |
  | Delete a list of things (`DeleteListOfThings`) | `:delete_list` | `data_type`, `target` |

  A change sets a field or edits a list field (`:set`, `:add`, `:remove`,
  `:add_list`, `:remove_list`, `:set_list`, `:clear_list`).
  """

  alias BubbleEx.{Expression, Index, Model}
  alias BubbleEx.Expression.{Compiler, Env, IR}
  alias BubbleEx.Model.Type
  alias BubbleEx.Plan.Residue
  alias BubbleEx.Workflows.Lowering.{Change, Expr, Param, Return}
  alias BubbleEx.Workflows.Source

  @data_ops %{
    "NewThing" => :create,
    "ChangeThing" => :update,
    "MakeChangeCurrentUser" => :update_current_user,
    "DeleteThing" => :delete,
    "ChangeListOfThings" => :update_list,
    "DeleteListOfThings" => :delete_list
  }

  # Action members each data operation lowers (besides `condition`).
  @data_members %{
    create: ~w(thing_type initial_values),
    update: ~w(to_change changes thing_type),
    update_current_user: ~w(changes),
    delete: ~w(to_delete),
    update_list: ~w(to_change changes type_to_change),
    delete_list: ~w(to_delete type_to_delete)
  }

  @change_ops %{
    "add" => :add,
    "remove" => :remove,
    "add_list" => :add_list,
    "remove_list" => :remove_list,
    "set_list" => :set_list,
    "clear_list" => :clear_list
  }

  @doc "The data operation of a Bubble action type, or nil."
  @spec data_op(term()) :: atom() | nil
  def data_op(type) when is_binary(type), do: Map.get(@data_ops, type)
  def data_op(_type), do: nil

  @doc "The action members a data operation lowers (besides `condition`)."
  @spec data_members(atom()) :: [String.t()]
  def data_members(op), do: Map.fetch!(@data_members, op)

  @doc """
  Lowers the arguments of data operation `op` from the action's
  `props` (at `path`, the action's properties pointer as a list). `id` is
  the action's symbol; `ctx` has the `:model` and the `:index`. Returns
  `{args, residue}`.
  """
  @spec data_args(atom(), map(), list(), String.t(), Env.t(), map()) :: {map(), [Residue.t()]}
  def data_args(:create, props, path, id, env, ctx) do
    type = data_type_key(props["thing_type"]) || written_type(ctx.index, id)

    changes(props["initial_values"], path ++ ["initial_values"], type, id, env, ctx.model)
    |> with_type(type, id, %{})
  end

  def data_args(op, props, path, id, env, ctx) when op in [:update, :update_list] do
    type = written_type(ctx.index, id)
    target = expr(props["to_change"], path ++ ["to_change"], env)

    changes(props["changes"], path ++ ["changes"], type, id, env, ctx.model)
    |> with_type(type, id, %{target: target})
  end

  def data_args(:update_current_user, props, path, id, env, ctx) do
    changes(props["changes"], path ++ ["changes"], "user", id, env, ctx.model)
    |> with_type("user", id, %{})
  end

  def data_args(op, props, path, id, env, ctx) when op in [:delete, :delete_list] do
    type = written_type(ctx.index, id)
    target = expr(props["to_delete"], path ++ ["to_delete"], env)
    with_type({[], []}, type, id, %{target: target})
  end

  defp with_type({changes, residue}, nil, id, args),
    do:
      {Map.merge(args, %{data_type: nil, changes: changes}),
       [Residue.entry(id, :unresolved_reference, %{reference: "data_type"}) | residue]}

  defp with_type({changes, residue}, type, _id, args),
    do: {Map.merge(args, %{data_type: type, changes: changes}), residue}

  defp changes(entries, path, type, id, env, model) do
    fields = fields(model, type)

    entries
    |> ordered()
    |> Enum.map_reduce([], fn {k, entry}, residue ->
      entry = map(entry)

      change(
        entry,
        change_op(entry["action"]),
        type,
        fields,
        path ++ [k, "value"],
        id,
        env,
        residue
      )
    end)
    |> then(fn {changes, residue} -> {Enum.reject(changes, &is_nil/1), Enum.uniq(residue)} end)
  end

  defp change(_entry, nil, _type, _fields, _path, id, _env, residue),
    do: {nil, [Residue.entry(id, :unsupported_option, %{options: ["changes"]}) | residue]}

  defp change(entry, op, type, fields, path, id, env, residue) do
    field = text(entry["key"])

    cond do
      type != nil and not MapSet.member?(fields, field) ->
        {nil, [Residue.entry(id, :unresolved_reference, %{reference: "field"}) | residue]}

      op == :clear_list ->
        {%Change{field: field, op: op, value: nil}, residue}

      true ->
        {%Change{field: field, op: op, value: expr(entry["value"], path, env)}, residue}
    end
  end

  defp change_op(%{"type" => "Empty"}), do: :set
  defp change_op(nil), do: :set
  defp change_op(name) when is_binary(name), do: Map.get(@change_ops, name)
  defp change_op(_), do: nil

  defp fields(_model, nil), do: MapSet.new()

  defp fields(model, type) do
    case Model.data_type(model, type) do
      nil ->
        MapSet.new()

      data_type ->
        for f <- data_type.fields, not f.deleted, f.raw == nil, into: MapSet.new(), do: f.id
    end
  end

  @doc "The data type an action writes, as the index resolved it, or nil."
  @spec written_type(Index.t(), String.t()) :: String.t() | nil
  def written_type(index, id) do
    index
    |> Index.references_from(id, [:writes_type])
    |> Enum.map(fn %{to: "data_type:" <> type} -> type end)
    |> Enum.uniq()
    |> case do
      [type] -> type
      _ -> nil
    end
  end

  # --- custom events -----------------------------------------------------------------

  @doc """
  A custom event's parameters (`{param_id, param_name, btype_id, is_list,
  optional}`) or an API workflow's (`{key, value, is_list, optional,
  in_url}`), in Bubble order. Expressions reference a parameter by
  `param_id` (for API workflows the key when there is none).
  """
  @spec parameters(map()) :: [Param.t()]
  def parameters(raw) do
    raw
    |> Source.value(~w(properties %p))
    |> map()
    |> Map.get("parameters")
    |> ordered()
    |> Enum.flat_map(fn {_, p} ->
      p = map(p)
      id = text(p["param_id"]) || text(p["key"])
      base = text(p["btype_id"]) || text(p["value"])

      if id do
        [
          %Param{
            id: id,
            key: text(p["key"]) || text(p["param_name"]) || id,
            type: base && if(p["is_list"] == true, do: Type.listed(base), else: base),
            optional?: p["optional"] == true,
            in_url?: p["in_url"] == true
          }
        ]
      else
        []
      end
    end)
  end

  @doc "A custom event's return values (`{return_id, display, btype_id, is_list}`)."
  @spec returns(map()) :: [Return.t()]
  def returns(raw) do
    raw
    |> Source.value(~w(properties %p))
    |> map()
    |> Map.get("return_types")
    |> ordered()
    |> Enum.flat_map(fn {_, r} ->
      r = map(r)

      case text(r["return_id"]) do
        nil ->
          []

        id ->
          base = text(r["btype_id"])

          [
            %Return{
              id: id,
              name: text(r["display"]) || id,
              type: base && if(r["is_list"] == true, do: Type.listed(base), else: base)
            }
          ]
      end
    end)
  end

  @doc """
  The arguments of a custom-event call (`arguments`: `{param_id,
  arg_value}` entries) against the callee's parameters (nil when the
  callee does not resolve). Returns `{params, residue}`, each param
  `%{param, value}`.
  """
  @spec call_params(term(), list(), String.t(), Env.t(), [Param.t()] | nil) ::
          {[map()], [Residue.t()]}
  def call_params(arguments, path, id, env, callee_params) do
    {params, residue} =
      arguments
      |> ordered()
      |> Enum.map_reduce([], fn {k, arg}, residue ->
        arg = map(arg)
        param = text(arg["param_id"])

        cond do
          is_nil(callee_params) or not Enum.any?(callee_params, &(&1.id == param)) ->
            {nil, [Residue.entry(id, :unresolved_reference, %{reference: "parameter"}) | residue]}

          # An argument left empty in the editor passes nothing.
          not Map.has_key?(arg, "arg_value") ->
            {nil, residue}

          true ->
            value = expr(arg["arg_value"], path ++ [k, "arg_value"], env)
            {%{param: param, value: value}, residue}
        end
      end)

    residue =
      if callee_params,
        do: residue,
        else: [Residue.entry(id, :unresolved_reference, %{reference: "workflow"}) | residue]

    {Enum.reject(params, &is_nil/1), Enum.uniq(residue)}
  end

  @doc """
  The values of "Terminate this workflow" (`return_values`: `{return_id,
  return_value}`) against the workflow's own `known` returns. Returns
  `{returns, residue}`, each `%{return, value}`.
  """
  @spec terminate_returns(term(), list(), String.t(), Env.t(), [Return.t()]) ::
          {[map()], [Residue.t()]}
  def terminate_returns(values, path, id, env, known) do
    {returns, residue} =
      values
      |> ordered()
      |> Enum.map_reduce([], fn {k, r}, residue ->
        r = map(r)
        return = text(r["return_id"])

        cond do
          not Enum.any?(known, &(&1.id == return)) ->
            {nil, [Residue.entry(id, :unresolved_reference, %{reference: "return"}) | residue]}

          not Map.has_key?(r, "return_value") ->
            {nil, residue}

          true ->
            value = expr(r["return_value"], path ++ [k, "return_value"], env)
            {%{return: return, value: value}, residue}
        end
      end)

    {Enum.reject(returns, &is_nil/1), Enum.uniq(residue)}
  end

  # --- residue ---------------------------------------------------------------------

  @doc """
  Residue of an action type with no lowering: an API Connector call, a
  plugin action, an auth action, or an unsupported type.
  """
  @spec type_residue(String.t(), term()) :: [Residue.t()]
  def type_residue(id, "apiconnector2-" <> call),
    do: [Residue.entry(id, :api_connector_action, %{call: call})]

  def type_residue(id, type) do
    cond do
      p = Residue.plugin(type) -> [Residue.entry(id, :plugin_action, %{plugin: p})]
      type in Residue.auth_actions() -> [Residue.entry(id, :auth_action, %{type: type})]
      true -> [Residue.entry(id, :unsupported_action, %{type: type_text(type)})]
    end
  end

  @doc "An `:unsupported_option` entry for `options` (none: no entry)."
  @spec option_residue(String.t(), [String.t()]) :: [Residue.t()]
  def option_residue(_id, []), do: []

  def option_residue(id, options),
    do: [Residue.entry(id, :unsupported_option, %{options: Enum.sort(options)})]

  @doc """
  One `:uncompiled_expression` entry for the values of `exprs` without IR
  (none when they all compiled).
  """
  @spec expr_residue(String.t(), [Expr.t() | nil]) :: [Residue.t()]
  def expr_residue(id, exprs) do
    case for(%Expr{ir: nil} = e <- exprs, do: e) do
      [] ->
        []

      failed ->
        [
          Residue.entry(id, :uncompiled_expression, %{
            expressions: length(failed),
            constructs: failed |> Enum.flat_map(& &1.constructs) |> Enum.uniq() |> Enum.sort()
          })
        ]
    end
  end

  # --- expressions -------------------------------------------------------------------

  @doc """
  A value or condition compiled to IR in `env` (`path`: its source path as
  a list): an `Expr` with the IR, or without it and the constructs that
  stopped it. Literal texts, numbers and yes/no are literals; nil is nil.
  """
  @spec expr(term(), list(), Env.t()) :: Expr.t() | nil
  def expr(nil, _path, _env), do: nil

  def expr(value, path, env) when is_map(value) do
    pointer = Source.pointer(path)

    with {:ok, %{ast: ast}} <- Expression.parse(value, schema: env.schema, path: path),
         {:ok, %{ir: ir, diagnostics: diags}} <- Compiler.compile(ast, %{env | path: path}) do
      if ir,
        do: %Expr{path: pointer, ir: ir},
        else: %Expr{path: pointer, constructs: Residue.constructs(diags)}
    else
      _ -> %Expr{path: pointer, constructs: ["parse_failed"]}
    end
  end

  def expr(value, path, _env) when is_binary(value),
    do: %Expr{path: Source.pointer(path), ir: IR.node(:literal, [value], "text")}

  def expr(value, path, _env) when is_number(value),
    do: %Expr{path: Source.pointer(path), ir: IR.node(:literal, [value], "number")}

  def expr(value, path, _env) when is_boolean(value),
    do: %Expr{path: Source.pointer(path), ir: IR.node(:literal, [value], "boolean")}

  def expr(_value, path, _env), do: %Expr{path: Source.pointer(path), constructs: ["malformed"]}

  @doc "The expressions in lowered step arguments (for `expr_residue/2`)."
  @spec exprs_of(map()) :: [Expr.t() | nil]
  def exprs_of(args) do
    Enum.flat_map(args, fn
      {_k, %Expr{} = e} -> [e]
      {_k, list} when is_list(list) -> Enum.flat_map(list, &nested_exprs/1)
      _ -> []
    end)
  end

  defp nested_exprs(%Change{value: value}), do: [value]
  defp nested_exprs(%{value: value}), do: [value]
  defp nested_exprs(_), do: []

  # --- helpers -------------------------------------------------------------------------

  @doc "A data type descriptor's key (`custom.task` → `task`), or nil."
  @spec data_type_key(term()) :: String.t() | nil
  def data_type_key(value) when is_binary(value) do
    case Type.reference(value) do
      {:data_type, key} -> key
      _ -> nil
    end
  end

  def data_type_key(_), do: nil

  @doc """
  The entries of a Bubble collection in order: integer keys numerically,
  other keys lexically; a list by position.
  """
  @spec ordered(term()) :: [{term(), term()}]
  def ordered(map) when is_map(map) do
    entries = Enum.to_list(map)

    if Enum.all?(entries, fn {k, _} -> match?({_, ""}, Integer.parse(to_string(k))) end),
      do: Enum.sort_by(entries, fn {k, _} -> String.to_integer(to_string(k)) end),
      else: Enum.sort_by(entries, &elem(&1, 0))
  end

  def ordered(list) when is_list(list),
    do: list |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, v} end)

  def ordered(_), do: []

  @doc false
  def map(value) when is_map(value), do: value
  def map(_), do: %{}

  @doc false
  def text(value) when is_binary(value) and value != "", do: value
  def text(_), do: nil

  @doc false
  def type_text(type) when is_binary(type), do: type
  def type_text(_), do: nil
end
