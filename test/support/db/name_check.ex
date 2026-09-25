defmodule BubbleEx.Test.NameCheck do
  @moduledoc false

  # Static validity checks for the encoders that convert names (WTF-391):
  # every name a generated artifact declares must be unique in its scope.
  #
  #   * Ecto: parsed with `Code.string_to_quoted!/1` (so the output is valid
  #     Elixir syntax); per schema, the primary key, `field`, `embeds_*`,
  #     `belongs_to` names and their foreign keys (Ecto rejects a repeat at
  #     compile time); per migration, the `add` columns (PostgreSQL rejects
  #     a repeat); across the file, module and table names, and the
  #     PostgreSQL relations (tables and indexes, cut to 63 bytes).
  #   * Convex: table keys of `defineSchema`, field keys per `defineTable`
  #     and per external `v.object`, and `const` names (TS1117 / TS2451).
  #   * Zod: `export const` / `export type` names and keys per object.
  #   * Xano: table names, and field names per table (and per `children`).
  #
  # Each function returns the repeated names, `[]` when the output is valid.

  @spec duplicates(atom(), String.t()) :: [String.t()]
  def duplicates(:ecto, content), do: ecto(content)
  def duplicates(:convex, content), do: convex(content)
  def duplicates(:zod, content), do: zod(content)
  def duplicates(:xano, content), do: xano(content)

  # --- Ecto ---------------------------------------------------------------------

  defp ecto(content) do
    ast = Code.string_to_quoted!(content)
    modules = collect(ast, &module/1)

    names =
      Enum.flat_map(modules, fn {name, body} ->
        scoped(name, collect(body, &schema_name/1)) ++ scoped(name, collect(body, &add_name/1))
      end)

    tables = collect(ast, &schema_table/1)

    # PostgreSQL keeps tables and indexes in one namespace and cuts every
    # identifier to 63 bytes.
    relations = collect(ast, &relation/1) |> Enum.map(&binary_part(&1, 0, min(63, byte_size(&1))))

    repeated(names) ++
      repeated(Enum.map(modules, &"module #{elem(&1, 0)}")) ++
      repeated(Enum.map(tables, &"table #{&1}")) ++
      repeated(Enum.map(relations, &"relation #{&1}"))
  end

  defp relation({:create, _, [{:table, _, [name | _]} | _]}) when is_binary(name), do: [name]

  defp relation({:create, _, [{:index, _, [table, columns | rest]}]}) when is_binary(table) do
    default = Enum.join([table | Enum.map(columns, &Atom.to_string/1)] ++ ["index"], "_")

    case rest do
      [opts] -> [opts |> Keyword.get(:name, default) |> to_string()]
      [] -> [default]
    end
  end

  defp relation(_), do: nil

  defp scoped(module, names), do: Enum.map(names, &"#{module}: #{&1}")

  defp module({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}),
    do: [{Enum.join(parts, "."), body}]

  defp module(_), do: nil

  defp schema_table({:schema, _, [table, _]}) when is_binary(table), do: [table]
  defp schema_table(_), do: nil

  defp schema_name({:@, _, [{:primary_key, _, [{:{}, _, [name | _]}]}]}), do: [name]
  defp schema_name({:@, _, [{:primary_key, _, [{name, _}]}]}) when is_atom(name), do: [name]

  defp schema_name({macro, _, [name | _]}) when macro in [:field, :embeds_one, :embeds_many],
    do: [name]

  defp schema_name({:belongs_to, _, [name, _module, opts]}),
    do: [name, Keyword.get(opts, :foreign_key, :"#{name}_id")]

  defp schema_name({:belongs_to, _, [name, _module]}), do: [name, :"#{name}_id"]
  defp schema_name(_), do: nil

  defp add_name({:add, _, [name | _]}) when is_atom(name), do: [name]
  defp add_name(_), do: nil

  # Pre-order walk collecting `fun`'s non-nil results.
  defp collect(ast, fun) do
    {_, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          found -> {node, acc ++ List.wrap(found)}
        end
      end)

    acc
  end

  # --- Convex -------------------------------------------------------------------

  defp convex(content) do
    lines = String.split(content, "\n")
    consts = for line <- lines, [_, name] <- [Regex.run(~r/^const (\w+) =/, line)], do: name

    tables =
      for line <- lines, [_, name] <- [Regex.run(~r/^  (\w+): defineTable\(/, line)], do: name

    fields =
      blocks(lines, ~r/^(?:  (\w+): defineTable\(\{|const (\w+) = v\.object\(\{)$/, fn line ->
        case Regex.run(~r/^\s+(\w+): /, line) do
          [_, key] -> key
          _ -> nil
        end
      end)

    repeated(Enum.map(consts, &"const #{&1}")) ++
      repeated(Enum.map(tables, &"table #{&1}")) ++ fields
  end

  # --- Zod ----------------------------------------------------------------------

  defp zod(content) do
    lines = String.split(content, "\n")

    consts =
      for line <- lines, [_, name] <- [Regex.run(~r/^export const (\w+) =/, line)], do: name

    types = for line <- lines, [_, name] <- [Regex.run(~r/^export type (\w+) =/, line)], do: name

    keys =
      blocks(lines, ~r/^export const (\w+) = z\.(?:looseObject|object)\(\{$/, fn line ->
        case Regex.run(~r/^  (?:get )?('(?:[^'\\]|\\.)*'|[A-Za-z_$][\w$]*)(?:\(\))?[: ]/, line) do
          [_, key] -> key
          _ -> nil
        end
      end)

    repeated(Enum.map(consts, &"const #{&1}")) ++
      repeated(Enum.map(types, &"type #{&1}")) ++ keys
  end

  # Groups the keys (`key_fun`) of the lines between a line matching `open`
  # and the next `})`, returning the repeated ones as "block: key".
  defp blocks(lines, open, key_fun) do
    {groups, _current} =
      Enum.reduce(lines, {[], nil}, fn line, {groups, current} ->
        cond do
          match = Regex.run(open, line) ->
            {groups, {match |> tl() |> Enum.reject(&(&1 == "")) |> hd(), []}}

          current != nil and String.match?(line, ~r/^\s*\}\)/) ->
            {[current | groups], nil}

          current != nil ->
            {block, keys} = current
            {groups, {block, keys ++ List.wrap(key_fun.(line))}}

          true ->
            {groups, current}
        end
      end)

    groups
    |> Enum.reverse()
    |> Enum.flat_map(fn {block, keys} -> keys |> repeated() |> Enum.map(&"#{block}: #{&1}") end)
  end

  # --- Xano ---------------------------------------------------------------------

  defp xano(content) do
    tables = content |> Jason.decode!() |> Enum.filter(&Map.has_key?(&1, "name"))

    repeated(Enum.map(tables, &"table #{&1["name"]}")) ++
      Enum.flat_map(tables, &xano_fields(&1["name"], &1["fields"]))
  end

  defp xano_fields(scope, fields) do
    own = fields |> Enum.map(& &1["name"]) |> repeated() |> Enum.map(&"#{scope}: #{&1}")

    nested =
      Enum.flat_map(fields, fn
        %{"children" => children, "name" => name} -> xano_fields("#{scope}.#{name}", children)
        _ -> []
      end)

    own ++ nested
  end

  defp repeated(names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> to_string(name) end)
    |> Enum.sort()
  end
end
