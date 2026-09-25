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

  alias BubbleEx.{Diagnostic, Error, Expression}
  alias BubbleEx.Expression.Schema
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
      data_types
      |> Enum.flat_map(&(&1.diagnostics ++ Enum.flat_map(&1.rules, fn r -> r.diagnostics end)))
      |> Diagnostic.normalize()

    {:ok, %__MODULE__{data_types: data_types, diagnostics: diagnostics}}
  end

  def parse(%{"user_types" => _}),
    do: {:error, Error.new(:invalid_input, "user_types must be an object")}

  def parse(app) when is_map(app),
    do: {:error, Error.new(:invalid_input, "app JSON has no user_types")}

  def parse(_), do: {:error, Error.new(:invalid_input, "expected a decoded app JSON object")}

  defp data_type(id, type, schema) when is_map(type) do
    path = ["user_types", id]
    {attrs, diags} = attributes(type, path)

    base =
      struct!(
        DataType,
        [id: id, availability: :unavailable, path: Diagnostic.pointer(path)] ++ attrs
      )

    {base, more} = rules(Map.get(type, "privacy_role", :absent), type, base, path, schema)
    %{base | diagnostics: subject(diags ++ more, %{type: id})}
  end

  defp data_type(id, type, _schema) do
    path = ["user_types", id]

    %DataType{
      id: id,
      availability: :unavailable,
      path: Diagnostic.pointer(path),
      raw: type,
      diagnostics: [
        Diagnostic.new(:malformed_node, path, "data type must be an object", subject: %{type: id})
      ]
    }
  end

  # An export lists a rule-free type without `privacy_role` (or with an empty
  # one); a compact live-payload type never carries rules at all.
  defp rules(rules, type, base, _path, _schema) when rules == :absent or rules == %{},
    do: {%{base | availability: if(export_shape?(type), do: :none, else: :unavailable)}, []}

  defp rules(rules, _type, base, path, schema) when is_map(rules) do
    parsed =
      rules
      |> Enum.sort_by(fn {rid, _} -> {rid == "everyone", rid} end)
      |> Enum.map(fn {rid, rule} ->
        rule(rid, rule, path ++ ["privacy_role", rid], base.id, schema)
      end)

    missing_default =
      if Map.has_key?(rules, "everyone"),
        do: [],
        else: [
          Diagnostic.new(:missing_default_rule, path ++ ["privacy_role"], "no everyone rule")
        ]

    {%{base | availability: :present, rules: parsed}, missing_default}
  end

  defp rules(other, _type, base, path, _schema) do
    message = "privacy_role must be an object: #{inspect(other)}"
    base = %{base | extra: Map.put(base.extra, "privacy_role", other)}
    {base, [Diagnostic.new(:malformed_node, path ++ ["privacy_role"], message)]}
  end

  @known ~w(display comment condition permissions)
  @type_members ~w(display %d fields %f3 privacy_role comment exposed_api deleted %del)

  # Type-level members other than fields and rules. Unknown or ill-typed ones
  # are kept in `extra` with a diagnostic.
  defp attributes(type, path) do
    {flags, flag_diags, extra} =
      Enum.reduce([exposed_api: ["exposed_api"], deleted: ["deleted", "%del"]], {[], [], %{}}, fn
        {field, keys}, acc -> flag(type, field, keys, path, acc)
      end)

    unknown = type |> Map.drop(@type_members) |> Enum.sort()

    unknown_diags =
      for {key, _} <- unknown,
          do:
            Diagnostic.new(
              :uninterpreted_field,
              path ++ [key],
              "unexpected data type member #{inspect(key)}"
            )

    attrs = [
      name: name(type),
      comment: text(type["comment"]),
      extra: Map.merge(extra, Map.new(unknown))
    ]

    {attrs ++ flags, flag_diags ++ unknown_diags}
  end

  defp flag(type, field, keys, path, {flags, diags, extra}) do
    case Enum.find(keys, &Map.has_key?(type, &1)) do
      nil ->
        {flags, diags, extra}

      key when is_boolean(:erlang.map_get(key, type)) ->
        {[{field, Map.fetch!(type, key)} | flags], diags, extra}

      key ->
        diag = Diagnostic.new(:uninterpreted_field, path ++ [key], "expected a boolean")
        {flags, [diag | diags], Map.put(extra, key, Map.fetch!(type, key))}
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
      extra: Map.drop(raw, @known),
      diagnostics: subject(cdiags ++ pdiags ++ extras(raw, path), %{type: type_id, rule: id})
    }
  end

  defp rule(id, raw, path, type_id, _schema) do
    {condition, diags} =
      Expression.Parser.raw(raw, :malformed_node, path, "privacy rule must be an object")

    %Rule{
      id: id,
      condition: condition,
      path: Diagnostic.pointer(path),
      diagnostics: subject(diags, %{type: type_id, rule: id})
    }
  end

  defp condition(%{"condition" => raw}, path, type_id, schema, _id) when not is_nil(raw) do
    opts = [
      schema: schema,
      this_type: Schema.thing_type(type_id),
      this_binder: :rule_record,
      path: path ++ ["condition"]
    ]

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

  defp subject(diagnostics, subject),
    do: diagnostics |> Diagnostic.put_subject(subject) |> Diagnostic.normalize()

  defp name(type), do: text(type["display"]) || text(type["%d"])

  defp export_shape?(type), do: Map.has_key?(type, "display") or Map.has_key?(type, "fields")

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil
end
