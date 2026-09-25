defmodule BubbleEx.Workflows.ExplanationContext do
  @moduledoc false
  alias BubbleEx.AppTree.Expr.Explanation, as: Expression
  alias BubbleEx.Model.{Builder, DataType, Field, Type}
  alias BubbleEx.Workflows.{Node, Source}

  @spec new(map(), list()) :: map()
  def new(index, origin) do
    %{
      resolve: &resolve(&1, &2, &3, index, origin),
      field: &field(&1, &2, &3, index),
      index: index,
      origin: origin
    }
  end

  @spec reference(String.t(), term(), list(), map()) :: map()
  def reference(kind, raw, path, context) do
    ref = Node.resolve_reference(kind, raw, path, context.origin, context.index)
    ref = prior_step(ref, kind, context)

    result =
      Expression.record("reference", raw, path, ref_status(ref), reference_text(kind, raw, ref))

    result
    |> Map.put(:reference, ref)
    |> Map.put(:data_type, reference_type(kind, raw, ref, context.index))
  end

  defp prior_step(%{status: "resolved", candidates: [candidate]} = ref, "action", context) do
    case Enum.take(context.origin, -2) do
      ["actions", current] ->
        workflow_path = Enum.drop(context.origin, -2)
        workflow = at(context.index.payload, workflow_path)
        actions = Source.value(workflow, ["actions"])

        previous_in_order(Expression.ordered(actions), ref, candidate, workflow_path, current)

      _ ->
        %{ref | status: "unavailable"}
    end
  end

  defp prior_step(ref, _, _), do: ref

  defp previous_in_order({:ok, entries}, ref, candidate, workflow_path, current) do
    paths =
      Enum.map(entries, fn {key, _} -> Source.pointer(workflow_path ++ ["actions", key]) end)

    previous = Enum.find_index(paths, &(&1 == candidate.path))

    position =
      Enum.find_index(paths, &(&1 == Source.pointer(workflow_path ++ ["actions", current])))

    if is_integer(previous) and is_integer(position) and previous < position,
      do: ref,
      else: %{ref | status: "not_previous"}
  end

  defp previous_in_order(:error, ref, _, _, _), do: %{ref | status: "unresolved_order"}

  defp resolve("CurrentPageItem", raw, path, index, [section, owner | _])
       when section in ~w(pages %p3) do
    target = get_in(index.payload, [section, owner])
    type = Source.value(Source.value(target, ~w(properties %p)), ~w(page_item_type))

    if is_binary(type),
      do: typed_source("current page's record", raw, path, type, [section, owner], index),
      else:
        Expression.unavailable(path, "Current page record type unavailable") |> Map.put(:raw, raw)
  end

  defp resolve("ThisElement", raw, path, index, [section, owner | _])
       when section in ~w(element_definitions %ed) do
    typed_source("this reusable element", raw, path, nil, [section, owner], index)
  end

  defp resolve(type, raw, path, index, origin) when type in ~w(GetElement PreviousStep) do
    keys = if type == "GetElement", do: ~w(element_id %ei), else: ~w(action_id %ai)
    kind = if type == "GetElement", do: "element", else: "action"

    case Source.get(raw, ~w(properties %p)) do
      {pk, props} when is_map(props) ->
        resolve_id(Source.get(props, keys), kind, raw, path, pk, props, new(index, origin))

      _ ->
        Expression.unknown(raw, path, "Missing reference properties")
    end
  end

  defp resolve("PageData", raw, path, _, _) do
    props = Source.value(raw, ~w(properties %p))
    name = Source.value(props, ~w(name %nm))

    if name in ["Current Page Width", "Current Page Height"] and
         Enum.all?(Map.keys(props), &(&1 in ~w(name %nm element_id %ei))) do
      Expression.record("reference", raw, path, "fully_supported", name)
    else
      Expression.unknown(raw, path, "Unproven page-data reference")
    end
  end

  defp resolve(_, raw, path, _, _),
    do: Expression.unknown(raw, path, "Unavailable expression scope")

  defp resolve_id({key, id}, kind, raw, path, pk, props, context) do
    result = reference(kind, id, path ++ [pk, key], context)
    result = %{result | path: Source.pointer(path), raw: raw}

    if Map.keys(props) == [key],
      do: result,
      else: %{
        result
        | status: "partial",
          text: result.text <> " [uninterpreted reference properties]"
      }
  end

  defp resolve_id(_, _, raw, path, _, _, _),
    do: Expression.unknown(raw, path, "Missing reference ID")

  defp typed_source(text, raw, path, type, target_path, _index) do
    Expression.record("reference", raw, path, "fully_supported", text)
    |> Map.put(:data_type, type_id(type))
    |> Map.put(:evidence, [%{path: Source.pointer(target_path)}])
  end

  defp field(type, id, path, index) when is_binary(type) and is_binary(id) do
    definitions = Map.get(index, {"data_type", type_id(type)}, [])

    candidates = Enum.flat_map(definitions, &field_candidates(&1, id, index))

    if length(definitions) > 1,
      do:
        Expression.unknown(id, path, "Ambiguous receiver data type for field #{inspect(id)}")
        |> Map.delete(:raw)
        |> Map.put(:evidence, Enum.map(candidates, &Map.delete(&1, :field))),
      else: field_result(candidates, id, path)
  end

  defp field(_, id, path, _),
    do: Expression.unavailable(path, "Field/operator #{inspect(id)}; receiver type unavailable")

  # The Model's field `id` of the data type defined at `definition.path`
  # (fields that are not JSON objects are left out), with its source as
  # evidence.
  defp field_candidates(definition, id, index) do
    for %DataType{path: path, synthesized: false, fields: fields} <- index.model.data_types,
        path == definition.path,
        %Field{id: ^id, raw: nil} = field <- fields,
        do: %{path: field.path, raw: at_pointer(index.payload, field.path), field: field}
  end

  defp field_result(candidates, id, path) do
    evidence = Enum.map(candidates, &Map.delete(&1, :field))

    case candidates do
      [%{field: field, raw: raw}] ->
        {name, field_type} = name_and_type(field, raw)

        status =
          if is_binary(name) and is_binary(field_type) and not field.deleted,
            do: "fully_supported",
            else: "partial"

        Expression.record("field_name", id, path, status, "#{inspect(name || id)} [#{id}]")
        |> Map.delete(:raw)
        |> Map.put(:path, Source.pointer(path))
        |> Map.put(:evidence, evidence)
        |> Map.put(:data_type, type_id(field_type))

      [] ->
        Expression.unavailable(path, "Field #{inspect(id)}; schema unavailable")

      _ ->
        Expression.unknown(id, path, "Ambiguous field #{inspect(id)}")
        |> Map.delete(:raw)
        |> Map.put(:evidence, evidence)
    end
  end

  # A name or type supplied in both key forms is not guessed between.
  defp name_and_type(%Field{} = field, raw) do
    conflicting = Builder.conflicting_forms(raw)
    name = if :name not in conflicting, do: field.name
    source = if :type not in conflicting, do: field.type.source
    {name, if(is_binary(source), do: source)}
  end

  defp unique_value(raw, keys) when is_map(raw) do
    case Enum.filter(keys, &Map.has_key?(raw, &1)) do
      [key] -> Map.get(raw, key)
      _ -> nil
    end
  end

  defp unique_value(_, _), do: nil

  defp ref_status(%{status: "resolved"}), do: "fully_supported"
  defp ref_status(%{status: "unavailable"}), do: "unavailable"
  defp ref_status(_), do: "unresolved"

  defp reference_text(kind, raw, %{status: "resolved", candidates: [c]}) do
    caption = if is_binary(c.name), do: inspect(c.name) <> " ", else: ""
    "#{reference_label(kind)} #{caption}[#{inspect(raw)}]"
  end

  defp reference_text(kind, raw, ref),
    do: "#{reference_label(kind)} [#{inspect(raw)}; #{ref.status}]"

  defp reference_label("action"), do: "result of action"
  defp reference_label("data_type"), do: "record of type"
  defp reference_label(kind), do: kind

  defp reference_type("data_type", raw, %{status: "resolved"}, _), do: type_id(raw)

  defp reference_type("action", _, %{status: "resolved", candidates: [c]}, index) do
    source = at_pointer(index.payload, c.path)

    if unique_value(source, ~w(type %x)) == "NewThing",
      do:
        type_id(
          unique_value(unique_value(source, ~w(properties %p)), ~w(type_to_create thing_type %tt))
        ),
      else: nil
  end

  defp reference_type(_, _, _, _), do: nil
  # The data type a record descriptor names (`"custom.task"` -> `"task"`);
  # other descriptors as supplied.
  defp type_id(descriptor) when is_binary(descriptor) do
    case {Type.list_item(descriptor), Type.reference(descriptor)} do
      {nil, {:data_type, id}} -> id
      _ -> descriptor
    end
  end

  defp type_id(_), do: nil

  @spec at_pointer(map(), String.t()) :: term()
  def at_pointer(payload, pointer) do
    path =
      pointer
      |> String.split("/")
      |> tl()
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))

    at(payload, path)
  end

  defp at(value, []), do: value
  defp at(value, [key | rest]) when is_map(value), do: at(Map.get(value, key), rest)

  # Path segments are integers for list entries, or strings when parsed from
  # a pointer.
  defp at(value, [key | rest]) when is_list(value) and is_integer(key),
    do: at(Enum.at(value, key), rest)

  defp at(value, [key | rest]) when is_list(value) do
    case Integer.parse(key) do
      {index, ""} -> at(Enum.at(value, index), rest)
      _ -> nil
    end
  end

  defp at(_, _), do: nil
end
