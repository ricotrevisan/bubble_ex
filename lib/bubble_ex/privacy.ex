defmodule BubbleEx.Privacy do
  @moduledoc """
  Data-type privacy rules parsed from decoded Bubble app JSON.

      {:ok, %BubbleEx.Privacy{data_types: types, diagnostics: diagnostics}} =
        BubbleEx.Privacy.parse(app)

  Each rule's condition is a `BubbleEx.Expression.Ast` in which `This Thing`
  is a record of the rule's data type, typed against the app's own schema.
  The model is stack-neutral: it states what Bubble enforces, not how any
  target stack should.

  Data types are read from `user_types` in either key form (`display`/`fields`
  in `.bubble` exports, `%d`/`%f3` in the live payload). Privacy rules
  themselves (`privacy_role`) appear only in exports and editor JSON; for a
  live payload every type is `:unavailable` rather than rule-free.
  `diagnostics` itemizes everything not fully modeled, across all rules.
  """

  alias BubbleEx.{Error, Expression}
  alias BubbleEx.Expression.{Diagnostic, Schema}
  alias BubbleEx.Privacy.{DataType, Permissions, Rule}

  @enforce_keys [:data_types, :diagnostics]
  defstruct [:data_types, :diagnostics]

  @type t :: %__MODULE__{data_types: [DataType.t()], diagnostics: [Diagnostic.t()]}

  @spec parse(term()) :: {:ok, t()} | {:error, Error.t()}
  def parse(%{"user_types" => types} = app) when is_map(types) do
    schema = Schema.from_app(app)

    data_types =
      types
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, type} -> data_type(id, type, schema) end)

    diagnostics =
      Enum.flat_map(
        data_types,
        &(&1.diagnostics ++ Enum.flat_map(&1.rules, fn r -> r.diagnostics end))
      )

    {:ok, %__MODULE__{data_types: data_types, diagnostics: diagnostics}}
  end

  def parse(%{"user_types" => _}),
    do: {:error, Error.new(:invalid_input, "user_types must be an object")}

  def parse(app) when is_map(app),
    do: {:error, Error.new(:invalid_input, "app JSON has no user_types")}

  def parse(_), do: {:error, Error.new(:invalid_input, "expected a decoded app JSON object")}

  defp data_type(id, type, schema) do
    path = ["user_types", id]
    base = %DataType{id: id, availability: :unavailable, path: Diagnostic.pointer(path)}

    case type do
      %{"privacy_role" => rules} when is_map(rules) ->
        rules =
          rules
          |> Enum.sort_by(fn {rid, _} -> {rid == "everyone", rid} end)
          |> Enum.map(fn {rid, rule} ->
            rule(rid, rule, path ++ ["privacy_role", rid], id, schema)
          end)

        %{base | name: name(type), availability: :present, rules: rules}

      %{"privacy_role" => other} ->
        diag =
          Diagnostic.new(
            :malformed_node,
            path ++ ["privacy_role"],
            "privacy_role must be an object: #{inspect(other)}"
          )

        %{base | name: name(type), diagnostics: [diag]}

      %{} ->
        %{
          base
          | name: name(type),
            availability: if(export_shape?(type), do: :none, else: :unavailable)
        }

      _ ->
        %{
          base
          | diagnostics: [Diagnostic.new(:malformed_node, path, "data type must be an object")]
        }
    end
  end

  defp rule(id, raw, path, type_id, schema) when is_map(raw) do
    {condition, cdiags} = condition(raw, path, type_id, schema, id)

    {permissions, pdiags} =
      Permissions.parse(Map.get(raw, "permissions", %{}), path ++ ["permissions"])

    %Rule{
      id: id,
      name: text(raw["display"]),
      comment: text(raw["comment"]),
      default?: id == "everyone",
      condition: condition,
      permissions: permissions,
      path: Diagnostic.pointer(path),
      diagnostics: cdiags ++ pdiags ++ extras(raw, path)
    }
  end

  defp rule(id, raw, path, _type_id, _schema) do
    {condition, diags} =
      Expression.Parser.raw(raw, :malformed_node, path, "privacy rule must be an object")

    %Rule{id: id, condition: condition, path: Diagnostic.pointer(path), diagnostics: diags}
  end

  defp condition(%{"condition" => raw}, path, type_id, schema, _id) when not is_nil(raw) do
    opts = [schema: schema, this_type: Schema.thing_type(type_id), path: path ++ ["condition"]]

    case Expression.parse(raw, opts) do
      {:ok, %Expression{ast: ast, diagnostics: diags}} ->
        {ast, diags}

      {:error, _} ->
        Expression.Parser.raw(raw, :malformed_node, path ++ ["condition"], "not JSON")
    end
  end

  defp condition(_raw, _path, _type_id, _schema, "everyone"), do: {nil, []}

  defp condition(_raw, path, _type_id, _schema, _id),
    do: {nil, [Diagnostic.new(:missing_condition, path, "non-default rule has no condition")]}

  @known ~w(display comment condition permissions)
  defp extras(raw, path) do
    for key <- raw |> Map.keys() |> Enum.sort(),
        key not in @known,
        do:
          Diagnostic.new(
            :uninterpreted_field,
            path ++ [key],
            "unexpected rule member #{inspect(key)}"
          )
  end

  defp name(type), do: text(type["display"]) || text(type["%d"])

  defp export_shape?(type), do: Map.has_key?(type, "display") or Map.has_key?(type, "fields")

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil
end
