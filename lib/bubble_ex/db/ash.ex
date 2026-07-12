defmodule BubbleEx.Db.Ash do
  @moduledoc """
  Encodes a parsed Bubble database map (see `BubbleEx.Db.Reader`) into runnable
  Ash: one `Ash.Resource` per custom table (AshPostgres data layer), option
  sets as sibling resources keyed by their `display` value, plus one
  `Ash.Domain` module listing every resource.

  Same honesty as `BubbleEx.Db.Ecto`: string primary keys (Bubble `_id` /
  `display`, not UUIDs), scalar references as `belongs_to` with a synthetic
  `<field>_id` source attribute, list references degraded to `{:array, ...}`
  with no relationship, other custom types as `:map`, `:api` tables skipped.
  All identifiers go through `BubbleEx.Db.Naming`, deduped per scope, so the
  output compiles even from hostile Bubble display names.
  """

  @behaviour BubbleEx.Db.Encoder

  alias BubbleEx.Db.Naming

  @type opts :: [naming: :proper | :id, namespace: String.t()]

  @default_namespace "MyApp"

  @impl true
  @spec encode(map(), opts()) :: {:ok, String.t()}
  def encode(parsed_map, opts \\ []) do
    plan =
      Keyword.get_lazy(opts, :_external_plan, fn ->
        BubbleEx.Db.Encoder.Plan.build(parsed_map, opts)
      end)

    opts = Keyword.put(opts, :_external_plan, plan)
    namespace = namespace(opts)

    tables =
      parsed_map
      |> Map.get(:tables, [])
      |> Enum.reject(&(&1.group == :api))
      |> prepare_tables(opts)

    relationships = scalar_relationships(parsed_map)

    # Module names share one scope across the whole export. "Repo" is
    # reserved: a table named "Repo" would collide with `repo MyApp.Repo`.
    module_names =
      Naming.unique_names(
        tables,
        & &1.id,
        fn table -> Naming.pascal_case(by_naming(opts, table.name, table.id)) end,
        reserved: ["Repo"],
        suffix: fn name, n -> "#{name}#{n}" end
      )

    resources =
      Enum.map_join(tables, "\n\n", &encode_table(&1, relationships, module_names, opts))

    external = encode_external_types(parsed_map, opts)

    body =
      Enum.reject(
        [external, resources, domain_module(tables, module_names, namespace)],
        &(&1 == "")
      )
      |> Enum.join("\n\n")

    {:ok, header(namespace) <> body <> "\n"}
  end

  # Only scalar references become relationships; list references have no
  # array foreign-key, mirroring Ecto/Postgres.
  defp scalar_relationships(parsed_map) do
    parsed_map
    |> Map.get(:relationships, [])
    |> Enum.filter(fn {from, to, _dir} ->
      from != nil and to != nil and not from.deleted and not to.deleted and
        Map.get(from.type, :is_array) != true
    end)
  end

  defp encode_table(table, relationships, module_names, opts) do
    namespace = namespace(opts)
    columns = Enum.reject(table.columns, & &1.deleted)

    # References whose target table was skipped (:api) have no module to
    # point at — they degrade to plain attributes below.
    table_refs =
      Enum.filter(relationships, fn {from, to, _dir} ->
        from.table_id == table.id and Map.has_key?(module_names, to.table_id)
      end)

    {pk_cols, value_cols} = Enum.split_with(columns, & &1.primary_key)
    # PKs claim their names first so a PK always keeps its bare name — the
    # belongs_to destination_attribute derived in *other* tables depends on it.
    names = assign_names(pk_cols ++ value_cols, table_refs, opts)
    {ref_cols, plain_cols} = Enum.split_with(value_cols, &ref?(&1, table_refs))

    module = "#{namespace}.#{Map.fetch!(module_names, table.id)}"

    attribute_lines =
      Enum.map(pk_cols, &pk_attribute(&1, names)) ++
        Enum.map(plain_cols, &attribute_line(&1, names, opts))

    relationship_block =
      case ref_cols do
        [] ->
          ""

        refs ->
          "\n\n  relationships do\n" <>
            Enum.map_join(
              refs,
              "\n\n",
              &belongs_to_block(&1, table_refs, names, module_names, opts)
            ) <>
            "\n  end"
      end

    "defmodule #{module} do\n" <>
      "  use Ash.Resource, domain: #{namespace}, data_layer: AshPostgres.DataLayer\n\n" <>
      "  postgres do\n" <>
      "    table #{quoted(table_name(table, opts))}\n" <>
      "    repo #{namespace}.Repo\n" <>
      "  end\n\n" <>
      "  attributes do\n" <>
      Enum.join(attribute_lines, "\n") <>
      "\n  end" <>
      relationship_block <>
      "\n\n  actions do\n" <>
      "    defaults [:read, :destroy, create: :*, update: :*]\n" <>
      "  end\n" <>
      "end"
  end

  # One name scope per resource: PK, plain attributes, relationship names,
  # and synthetic `<field>_id` FK columns must all be mutually unique.
  defp assign_names(columns, table_refs, opts) do
    {map, _used} =
      Enum.reduce(columns, {%{}, MapSet.new()}, fn col, {map, used} ->
        base = Naming.snake_case(by_naming(opts, col.name, col.id))

        if ref?(col, table_refs) do
          {name, used} = Naming.claim(base, used)
          {fk, used} = Naming.claim(name <> "_id", used)
          {Map.put(map, col.id, %{name: name, fk: fk}), used}
        else
          {name, used} = Naming.claim(base, used)
          {Map.put(map, col.id, %{name: name, fk: nil}), used}
        end
      end)

    map
  end

  defp ref?(col, table_refs),
    do: Enum.any?(table_refs, fn {from, _to, _dir} -> from.id == col.id end)

  defp pk_attribute(col, names) do
    "    attribute :#{Map.fetch!(names, col.id).name}, :string, primary_key?: true, allow_nil?: false, public?: true"
  end

  defp attribute_line(col, names, opts) do
    "    attribute :#{Map.fetch!(names, col.id).name}, #{ash_type(col.type, opts)}, public?: true" <>
      lossy_comment(col.type)
  end

  defp lossy_comment(%{is_array: true, type: t}) when t in [:reference, :enum],
    do: "   # lossy: Bubble list of references"

  defp lossy_comment(%{is_array: true}), do: "   # lossy: Bubble list field"
  defp lossy_comment(_type), do: ""

  defp belongs_to_block(col, table_refs, names, module_names, opts) do
    {_from, to, _dir} = Enum.find(table_refs, fn {from, _to, _dir} -> from.id == col.id end)
    %{name: name, fk: fk} = Map.fetch!(names, col.id)
    target = "#{namespace(opts)}.#{Map.fetch!(module_names, to.table_id)}"
    destination = Naming.snake_case(by_naming(opts, to.name, to.id))

    "    belongs_to :#{name}, #{target} do\n" <>
      "      source_attribute :#{fk}\n" <>
      "      destination_attribute :#{destination}\n" <>
      "      attribute_type :string\n" <>
      "      attribute_writable? true\n" <>
      "      public? true\n" <>
      "    end"
  end

  defp domain_module(tables, module_names, namespace) do
    resource_lines =
      Enum.map_join(tables, "\n", fn table ->
        "    resource #{namespace}.#{Map.fetch!(module_names, table.id)}"
      end)

    "defmodule #{namespace} do\n" <>
      "  use Ash.Domain\n\n" <>
      "  resources do\n" <>
      resource_lines <>
      "\n  end\n" <>
      "end"
  end

  # Type mapping (IR -> Ash) ------------------------------------------------

  defp ash_type(%{is_array: true} = type, opts), do: "{:array, #{base_type(type, opts)}}"
  defp ash_type(type, opts), do: base_type(type, opts)

  defp base_type(%{type: :reference}, _opts), do: ":string"
  defp base_type(%{type: :enum}, _opts), do: ":string"
  defp base_type(%{type: :api}, _opts), do: ":string"

  defp base_type(%{type: :external, target: target}, opts) do
    if BubbleEx.Db.Encoder.Plan.resolved?(plan(opts), target),
      do: external_module(target, opts),
      else: ":map"
  end

  defp base_type(%{type: :opaque_external}, _opts), do: ":map"
  defp base_type(%{type: :custom, custom_type: "bubble_image"}, _opts), do: ":string"
  defp base_type(%{type: :custom, custom_type: "bubble_file"}, _opts), do: ":string"
  defp base_type(%{type: :custom}, _opts), do: ":map"
  defp base_type(%{type: :utc_datetime_usec}, _opts), do: ":utc_datetime_usec"
  defp base_type(%{type: :boolean}, _opts), do: ":boolean"
  defp base_type(%{type: :float}, _opts), do: ":float"
  defp base_type(%{type: :string}, _opts), do: ":string"
  defp base_type(_type, _opts), do: ":string"

  defp encode_external_types(_parsed_map, opts) do
    if Keyword.get(opts, :external_types, :legacy) == :preserve do
      plan = plan(opts)

      plan.order
      |> Enum.map(&Map.fetch!(plan.nodes, &1))
      |> Enum.map_join("\n\n", &external_resource(&1, opts))
    else
      ""
    end
  end

  defp external_resource(external, opts) do
    attributes = Enum.map_join(external.fields, "\n", &external_attribute(&1, external.id, opts))

    "defmodule #{external_module(external.id, opts)} do\n" <>
      "  use Ash.Resource, data_layer: :embedded\n\n" <>
      "  attributes do\n#{attributes}\n  end\n" <>
      "end"
  end

  defp external_attribute(%{type: %{type: :scalar} = type} = field, parent, opts),
    do:
      "    attribute :#{external_field_name(parent, field, opts)}, #{external_scalar(type)}, allow_nil?: true, public?: true"

  defp external_attribute(%{type: %{type: :external, target: target}} = field, parent, opts) do
    fallback? =
      (BubbleEx.Db.Encoder.Plan.cycle_edge?(plan(opts), parent, field.id) and
         not recursive_capability?(opts)) or
        not BubbleEx.Db.Encoder.Plan.resolved?(plan(opts), target)

    type =
      if fallback?,
        do: if(field.type.cardinality == :many, do: "{:array, :map}", else: ":map"),
        else: external_edge_type(field.type, opts)

    "    attribute :#{external_field_name(parent, field, opts)}, #{type}, allow_nil?: true, public?: true"
  end

  defp external_attribute(field, parent, opts),
    do:
      "    attribute :#{external_field_name(parent, field, opts)}, :map, allow_nil?: true, public?: true"

  defp external_edge_type(%{target: target, cardinality: :many}, opts),
    do: "{:array, #{external_module(target, opts)}}"

  defp external_edge_type(%{target: target}, opts), do: external_module(target, opts)

  defp external_scalar(%{scalar: scalar, cardinality: cardinality}) do
    base =
      %{
        text: ":string",
        number: ":float",
        boolean: ":boolean",
        date: ":utc_datetime_usec",
        date_unix: ":integer"
      }[scalar]

    if cardinality == :many, do: "{:array, #{base}}", else: base
  end

  defp external_module(id, opts),
    do: "#{namespace(opts)}.External.#{BubbleEx.Db.Encoder.Plan.name(plan(opts), id)}"

  defp plan(opts), do: Keyword.fetch!(opts, :_external_plan)

  defp recursive_capability?(opts),
    do:
      :recursive_new_type in (opts
                              |> Keyword.get(:external_type_capabilities, %{})
                              |> Map.get(:ash, []))

  defp external_field_name(parent, field, opts),
    do: plan(opts) |> BubbleEx.Db.Encoder.Plan.field_name(parent, field) |> Naming.snake_case()

  defp prepare_tables(tables, opts) do
    mode = Keyword.get(opts, :external_types, :legacy)
    plan = plan(opts)

    Enum.map(tables, fn table ->
      %{table | columns: Enum.map(table.columns, &prepare_column(&1, mode, plan))}
    end)
  end

  defp prepare_column(%{type: %{type: :external, target: target}} = column, :preserve, plan),
    do:
      if(BubbleEx.Db.Encoder.Plan.resolved?(plan, target),
        do: column,
        else: %{column | type: %{type: :opaque_external}}
      )

  defp prepare_column(%{type: %{type: :external}} = column, :opaque, _plan),
    do: %{column | type: %{type: :opaque_external}}

  defp prepare_column(%{type: %{type: :external}} = column, :legacy, _plan),
    do: %{column | type: %{type: :api}}

  defp prepare_column(column, _mode, _plan), do: column

  # Naming --------------------------------------------------------------------

  defp namespace(opts), do: Keyword.get(opts, :namespace, @default_namespace)

  defp table_name(table, opts), do: Naming.snake_case(by_naming(opts, table.name, table.id))

  defp by_naming(opts, proper, id) do
    case Keyword.get(opts, :naming, :proper) do
      :id -> id
      _ -> proper
    end
  end

  defp quoted(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp header(namespace) do
    """
    # Generated from a Bubble.io app by bubble_ex — deterministic, and honest
    # about what Bubble's payload cannot express:
    #
    #   * Option-set member values are not visible in the scanned payload, so
    #     option sets render as sibling resources with a :string primary key,
    #     not Ash.Type.Enum.
    #   * References keep Bubble's text `_id`/`display` keys, not UUIDs —
    #     re-key after importing your data.
    #   * A Bubble list-of-references field loses its relational semantics and
    #     renders as an array attribute (no join table is invented).
    #   * `:api` group tables (external placeholders) are omitted.
    #   * This is one file containing many modules — split one module per file
    #     when pasting into your project (lib/app/thing.ex, ...).
    #   * `#{namespace}.Repo` is referenced but not generated. Scaffold with:
    #       mix igniter.new my_app --install ash,ash_postgres
    #     then add these resources and run `mix ash.codegen --dev` while
    #     iterating (a named `mix ash.codegen <name>` when ready to ship).

    """
  end
end
