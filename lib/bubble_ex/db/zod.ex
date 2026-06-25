defmodule BubbleEx.Db.Zod do
  @moduledoc """
  Encodes a parsed Bubble database map (see `BubbleEx.Db.Reader`) into
  [Zod](https://zod.dev/) schemas: one `z.object({...})` schema const per table
  plus a `z.infer` type alias, for runtime validation at a TypeScript API
  boundary when migrating data off Bubble.

  Scalars map directly (`:string` -> `z.string()`, `:float` -> `z.number()`,
  `:boolean` -> `z.boolean()`, `:utc_datetime_usec` -> `z.string().datetime()`).
  List fields (`is_array: true`) wrap their inner schema in `z.array(...)`.
  References and enums become `z.string()` (Bubble stores text ids / display
  values) with a `// reference ->` / `// enum ->` comment naming the target;
  foreign-key direction and option-set member values are not expressible in the
  IR and are therefore lost. Every non-primary-key field is `.nullish()` since
  any Bubble field can be empty. `:api` group tables (external placeholders) are
  skipped, as are deleted columns.
  """

  @behaviour BubbleEx.Db.Encoder

  @type opts :: [naming: :proper | :id | nil]

  @impl true
  @spec encode(map(), opts()) :: {:ok, String.t()}
  def encode(parsed_map, opts \\ []) do
    tables =
      parsed_map
      |> Map.get(:tables, [])
      |> Enum.reject(&(&1.group == :api))

    blocks = Enum.map_join(tables, "\n\n", &encode_table(&1, opts))

    {:ok, header() <> blocks <> "\n"}
  end

  defp header, do: "import { z } from 'zod';\n\n"

  defp encode_table(table, opts) do
    columns = Enum.reject(table.columns, & &1.deleted)
    schema = schema_const(table, opts)
    type_alias = type_name(table, opts)

    field_lines = Enum.map_join(columns, "\n", fn column -> encode_field(column, opts) end)

    "// #{table.name}\n" <>
      "export const #{schema} = z.object({\n" <>
      field_lines <>
      "\n" <>
      "});\n\n" <>
      "export type #{type_alias} = z.infer<typeof #{schema}>;"
  end

  defp encode_field(column, opts) do
    key = field_key(field_name(column, opts))
    value = field_value(column)
    "  #{key}: #{value},#{field_comment(column.type)}"
  end

  # Schema expression for one field, including nullability and array wrapping.
  defp field_value(column) do
    column.type
    |> base_expr()
    |> wrap_array(column.type)
    |> apply_nullability(column.primary_key)
  end

  defp wrap_array(expr, %{is_array: true}), do: "z.array(#{expr})"
  defp wrap_array(expr, _type), do: expr

  defp apply_nullability(expr, true), do: expr
  defp apply_nullability(expr, _not_pk), do: expr <> ".nullish()"

  # Type mapping (IR -> Zod base expression) -------------------------------------

  defp base_expr(%{type: :reference}), do: "z.string()"
  defp base_expr(%{type: :enum}), do: "z.string()"
  defp base_expr(%{type: :api}), do: "z.string()"
  defp base_expr(%{type: :custom, custom_type: "bubble_image"}), do: "z.string()"
  defp base_expr(%{type: :custom, custom_type: "bubble_file"}), do: "z.string()"
  defp base_expr(%{type: :custom}), do: "z.object({}).passthrough()"
  defp base_expr(%{type: :utc_datetime_usec}), do: "z.string().datetime()"
  defp base_expr(%{type: :boolean}), do: "z.boolean()"
  defp base_expr(%{type: :float}), do: "z.number()"
  defp base_expr(%{type: :string}), do: "z.string()"
  defp base_expr(_type), do: "z.string()"

  # Trailing comment naming a reference/enum target or a structured custom type.

  defp field_comment(%{type: :reference, custom_type: target}),
    do: " // reference -> #{target}"

  defp field_comment(%{type: :enum, custom_type: target}),
    do: " // enum -> #{target} option set (values not in IR)"

  defp field_comment(%{type: :api, custom_type: target}),
    do: " // api -> #{target}"

  defp field_comment(%{type: :custom, custom_type: "bubble_image"}), do: ""
  defp field_comment(%{type: :custom, custom_type: "bubble_file"}), do: ""

  defp field_comment(%{type: :custom, custom_type: target}),
    do: " // #{target} (structured Bubble type)"

  defp field_comment(_type), do: ""

  # Naming -----------------------------------------------------------------------

  # :proper (default) uses display names; :id uses the Bubble ids.
  defp schema_const(table, opts),
    do: pascal_case(by_naming(opts, table.name, table.id)) <> "Schema"

  defp type_name(table, opts), do: pascal_case(by_naming(opts, table.name, table.id))
  defp field_name(column, opts), do: by_naming(opts, column.name, column.id)

  defp by_naming(opts, proper, id) do
    case Keyword.get(opts, :naming, :proper) do
      :id -> id
      _ -> proper
    end
  end

  # PascalCase a display name or id: split on non-alphanumeric runs, capitalise
  # each word. Prefix an underscore if the result would start with a digit so the
  # const is always a valid TypeScript identifier.
  defp pascal_case(name) do
    pascal =
      name
      |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
      |> Enum.map_join("", &capitalize_word/1)

    cond do
      pascal == "" -> "Schema"
      String.match?(pascal, ~r/^[0-9]/) -> "_" <> pascal
      true -> pascal
    end
  end

  defp capitalize_word(<<first::utf8, rest::binary>>),
    do: String.upcase(<<first::utf8>>) <> rest

  defp capitalize_word(""), do: ""

  # An object key is emitted bare when it is a valid JS identifier, otherwise it
  # is quoted (single quotes, with embedded single quotes / backslashes escaped).
  defp field_key(name) do
    if valid_identifier?(name) do
      name
    else
      "'" <> escape_single_quoted(name) <> "'"
    end
  end

  defp valid_identifier?(name), do: String.match?(name, ~r/^[A-Za-z_$][A-Za-z0-9_$]*$/)

  defp escape_single_quoted(name) do
    name
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end
end
