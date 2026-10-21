defmodule BubbleEx.Target.Elixir do
  @moduledoc """
  Compiles expression IR (`BubbleEx.Expression.IR`) to an Elixir
  expression, as source text, for value expressions in generated LiveViews
  and workflow bodies (dynamic text, arithmetic, comparisons, conditions).
  Records are the generated Ash resources' structs, so field names come
  from the mapped `BubbleEx.Target.Ash.Project`.

      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, %{source: source, bindings: bindings, runtime: runtime}} =
        BubbleEx.Target.Elixir.compile(ir, project)

  The expression is pure. Its free variables are its `bindings`:
  `current_user` (the actor, nil when logged out), `this` (the context's
  record) and one variable per context input (element values, parameters,
  step results, …), named from the input and its Bubble IDs:
  `%{var, input, type}`. `loads` lists the relationship paths each record
  variable must have loaded (`%{"this" => [["project"]]}`).

  ## Semantics

  Field access is nil-safe (a field of an empty value is empty), written as
  `get_in(x, [Access.key(:a), Access.key(:b)])`. A field of an API
  Connector value (a call's result, WTF-533) is its typed struct's
  attribute when the API type has one (a data field stores it), else the
  value at its Bubble field ID in the map the generated client decoded. Records are compared by
  Bubble ID. Empty values follow `BubbleEx.Target.Ash.Expressions`: a
  comparison with a value read from the current user is false when that
  value is empty, in either polarity (negation is pushed down to the
  comparisons); between other values empty equals empty (not verified
  against Bubble), and an empty text (`""`) is empty, so `"" is nil`
  (WTF-514; Bubble has no empty text apart from empty, inferred, not
  replayed; the generated privacy policies keep `""` and nil apart, the
  stricter reading); an empty list contains nothing; `not` of an empty yes/no
  is true; `x is y` and `x is not y` between yes/no values (not
  conditions), one at least stored, read an empty one as no, as Bubble does
  (`x is no` holds on an empty x, WTF-529; `x is not no` needs a stored
  yes, WTF-471; the privacy policies keep `x is y` stricter), the current
  user's included, with no guard: `Current User's pro is no` holds when
  pro is empty and for a logged-out visitor (Bubble's temporary user has
  empty fields; WTF-529, the owner's decision for pages and workflows,
  where the policies keep denying); a comparison
  with a condition is expanded into each side's polarities, and a
  condition used as any other value is strictly true or false (never nil). `BubbleEx.Target.ElixirTest` holds both backends to one
  hand-authored expectation table.
  Everything whose Bubble behavior Elixir's operators do not match (ordering
  with empty values, arithmetic, emptiness, text formatting) is a call to a
  runtime module the generated app provides (`:runtime`, default
  `"Bubble.Runtime"`), whose contract is the behaviour
  `BubbleEx.Target.Elixir.Runtime` (`stubs/0` lists the functions whose
  Bubble behavior is not pinned down yet); `runtime` lists the functions
  used:

  | Function | Bubble |
  |----------|--------|
  | `text(x)` | a value as text (numbers as JavaScript prints them, yes/no, dates as Bubble's default display text in the user's zone, as Bubble writes them into URL parameters; replay 2026-10-07) |
  | `display(x)` | a value shown on a page (`:display`): `text/1` with dates in Bubble's default format |
  | `utc_text(x)` | `text/1` as Bubble's server converts a value (`:utc`, backend workflows): dates in UTC (replay 2026-10-07) |
  | `empty?(x)` | `is empty`: nil, `""` or `[]` |
  | `unhidden(x)` | a value `is` / `is not` compares: an empty text (`""`) or a field the user may not view is nil, a case-insensitive text its text |
  | `compare(op, a, b)` | `>`, `<`, `>=`, `<=`; false when either side is empty |
  | `add/sub/mul/div/mod(a, b)` | arithmetic; dates plus intervals |
  | `default(x, d)` | `defaulting to`: `x` unless it is empty (as `empty?/1`; a reference is its loaded record, nil when unset or gone), else `d`; a field of it reads through whichever holds |
  | `lowercase/uppercase/trim/capitalize_words/text_length/json_encode/url_encode/is_email/abs/round/to_text/to_number(x)` | the operators |
  | `ceiling(x)`, `floor(x)` | a number's `:ceiling` and `:floor` (WTF-598): the nearest whole number up or down, as JavaScript's `Math.ceil` and `Math.floor` (toward positive and negative infinity) |
  | `format_date(x, format[, zone])`, `format_number(x, options)`, `date_floor(x, unit[, zone])`, `date_part(x, unit[, zone])`, `date_add(x, n, unit)` | Bubble's date and number formats and calendar operators (`BubbleEx.Target.Elixir.Formats`); `zone` only when the expression names one |
  | `format_boolean(x, yes, no)`, `truncate(x, n)`, `replace(x, find, replace, regex?)`, `split(x, sep)`, `text_contains?(a, b)`, `text_contains_words?(a, b)` | the other formatting and text operators |
  | `date_diff(a, b, unit)` | `(a - b) :to days` … `:to seconds` (WTF-594): exact, milliseconds over the unit's; a date interval is read only so (any other use of one is not compiled) |
  | `range_start/range_end/range_middle(r)` | a date range's `min`, `max` and `average` (WTF-597) |

  List algebra (`:merged with`, `:unique elements`, `:minus list`,
  `:intersect with`, `:plus item`, `:minus item`, `:items until #`, `:item
  #`, `:converted to list`, WTF-495) calls the runtime (`merge/2`, …),
  which compares things by Bubble ID, records and IDs alike; `:filtered`
  over options, texts, numbers or dates is `Enum.filter/2` with the
  constraints per item (`item`); `:sorted` on texts, numbers or dates is
  `sort_values(list, descending?)`, and on options by a text, number or
  date attribute `sort_values_by(list, &<enum>.attributes(&1).<attr>,
  descending?)` (WTF-594), in the same order. An option's label or attribute of a list
  of options maps over it (a list attribute of each is one list of their
  items). A field of `x :converted to list` is the field of `x`, converted
  (`(x's a) :converted to list`).

  A field of a list operator's result whose things are records (`:first
  item`, `:last item`, `:item #`, `:unique elements`, `:merged with`,
  `:items until #`, `:minus`, `:intersect with`, `:plus item` over
  context inputs, query results, `This` or the current user, WTF-520) is
  that record's field, or each of those records', flattened; the
  relationships it reads are loaded on the variables the records come
  from. A chain through a list normalized to a join (a `many_to_many`)
  is each item's next step, flattened into one list (empty values
  dropped), as Bubble's `list's field`. A list of records `contains` a
  thing when one of its things has that thing's Bubble ID (the runtime's
  `id/1`), records and IDs alike; an empty thing is in no list.

  Data shapes never raise (WTF-500): every list read (`count`, `:first
  item`, `contains`, `:filtered`, a list of options or files) goes through
  the runtime's `as_list/1`, so an empty value or a field the user may not
  view (`%Ash.ForbiddenField{}`, `empty?/1`) is an empty list, and the
  current user's operands are checked with `empty?/1`; a field of a list of
  things (a search read first) is each item's, one list of their values.

  Not compiled yet (diagnosed with `:elixir_expr_unsupported`, stage
  `{:target, :elixir}`): searches, and `:filtered` or sorting of a list of
  things (these become Ash queries, `FrontendWorkflows.Lists`), other
  sorting by a field, an API Connector call used as data outside a
  page's data sources (`FrontendWorkflows.Data` reads it there),
  fields of the items of a
  list-of-things field (stored as a list of IDs: `a path through a list
  or value`, `a field of first`, ...; a page's data sources read such
  lists' records first, `FrontendWorkflows.Lists`).

  A format the runtime only approximates (an unknown number setting, a
  date pattern token or unit it does not implement, see
  `BubbleEx.Target.Elixir.Formats.approximations/2`) still compiles, with an
  `:elixir_format_approximated` warning naming the parts.

  An option is its stored key; its label is the generated enum's
  `label/1` and an attribute its `attributes/1` entry. Both are total: an
  empty or unknown option's are empty.

  With `:file_url` (a function name such as `"MyAppWeb.Uploads.url"`), a
  shown file or image value (the expression's result, or a part of a
  dynamic text) is passed through it: file fields hold storage
  references, and the frontend must link to the app's safe file route,
  never to the raw stored URL (WTF-415). A list of files maps each.
  Conditions (`is empty`, comparisons) still read the stored value.
  """

  alias BubbleEx.{Diagnostic, Error}
  alias BubbleEx.Expression.IR
  alias BubbleEx.Model.Type
  alias BubbleEx.Target.Ash.Project
  alias BubbleEx.Target.Elixir.{Conditions, Formats}

  @type result :: %{
          source: String.t() | nil,
          bindings: [map()],
          loads: %{String.t() => [[String.t()]]},
          runtime: [atom()],
          diagnostics: [Diagnostic.t()]
        }

  @type option ::
          {:runtime, String.t()}
          | {:namespace, String.t()}
          | {:subject, Diagnostic.subject()}
          | {:path, String.t() | list()}
          | {:file_url, String.t() | nil}
          | {:display, boolean()}
          | {:utc, boolean()}

  @runtime_unary ~w(lowercase uppercase trim capitalize_words text_length json_encode url_encode
                    is_email abs round ceiling floor to_text to_number)a
  @arithmetic ~w(add sub mul div mod)a
  @list_ops ~w(as_list unique merge minus_list intersect plus_item minus_item limit item_at)a
  # List operators whose result's things are their operands' (WTF-520).
  @through_lists ~w(first last item_at unique limit merge intersect minus_list minus_item plus_item picked)a
  @conditions ~w(eq neq gt lt gte lte and or not is_empty logged_in member text_contains
                 text_contains_words)a
  @boolean_values [:field, :input, :fallback, :option_attribute, :option_label, :external_field]
  @compare %{gt: :gt, lt: :lt, gte: :gte, lte: :lte}

  @doc """
  Compiles `ir` to Elixir source. See the moduledoc.

  ## Options

    * `:runtime` - the runtime module, default `"Bubble.Runtime"`
    * `:namespace` - root namespace of the generated modules, default
      `"MyApp"` (for enum modules)
    * `:subject` / `:path` - diagnostic subject and pointer
    * `:file_url` - the function a shown file or image value goes through
      (see the moduledoc); none by default
    * `:display` - parts of a dynamic text are shown on a page:
      `display(x)` (dates in Bubble's default format) instead of `text(x)`
      (URL parameters, values a page workflow writes); default false
    * `:utc` - the expression runs on the server (a backend workflow):
      parts of a dynamic text and `:converted to text` are `utc_text(x)`,
      dates in UTC as Bubble's server converts them (replay 2026-10-07);
      default false
  """
  @spec compile(IR.t(), Project.t(), [option()]) :: {:ok, result()} | {:error, Error.t()}
  def compile(ir, project, opts \\ [])

  def compile(%IR{} = ir, %Project{} = project, opts) when is_list(opts),
    do: {:ok, do_compile(ir, project, opts)}

  def compile(_ir, _project, _opts),
    do:
      {:error,
       Error.new(:invalid_input, "expected an IR node, a BubbleEx.Target.Ash.Project and options")}

  defp do_compile(ir, project, opts) do
    st = %{
      lookup: lookup(project),
      runtime: Keyword.get(opts, :runtime, "Bubble.Runtime"),
      namespace: Keyword.get(opts, :namespace, "MyApp"),
      file_url: Keyword.get(opts, :file_url),
      shown: shown(opts),
      bindings: %{},
      loads: %{},
      used: MapSet.new(),
      unsupported: [],
      approximated: [],
      item?: false
    }

    {source, st} =
      if st.shown == :display,
        do: ir |> shown_value(st) |> shown_file(ir),
        else: ir |> value(st) |> shown_file(ir)

    if source == :error or st.unsupported != [] do
      %{source: nil, bindings: [], loads: %{}, runtime: [], diagnostics: diagnostics(st, opts)}
    else
      # Redundant guards would be type warnings on Elixir 1.20 (WTF-555).
      formatted =
        source
        |> Conditions.simplify(pure: [st.runtime, st.namespace <> ".Enums"])
        |> Code.format_string!()
        |> IO.iodata_to_binary()

      %{
        source: formatted,
        bindings: st.bindings |> Map.values() |> Enum.sort_by(& &1.var),
        loads:
          Map.new(st.loads, fn {var, paths} -> {var, paths |> MapSet.to_list() |> Enum.sort()} end),
        runtime: st.used |> MapSet.to_list() |> Enum.sort(),
        diagnostics: approximations(st, opts)
      }
    end
  end

  defp shown(opts) do
    cond do
      Keyword.get(opts, :display, false) -> :display
      Keyword.get(opts, :utc, false) -> :utc_text
      true -> :text
    end
  end

  defp lookup(project) do
    dangling = BubbleEx.Target.Ash.Project.dangling(project)

    primary_keys =
      Map.new(project.resources, fn resource ->
        {resource.module, Enum.find(resource.attributes, & &1.primary_key?).name}
      end)

    types =
      Map.new(project.resources, fn resource ->
        belongs_to = Enum.filter(resource.relationships, &(&1.kind == :belongs_to))
        rels = Map.new(belongs_to, &{&1.source.field, &1.name})
        pk = Enum.find(resource.attributes, & &1.primary_key?)

        # A field referencing what an owner dropped (WTF-422) is not read:
        # a condition or value reading it is residue.
        fields =
          for a <- resource.attributes,
              a.source[:field],
              not MapSet.member?(dangling, {resource.source.type, a.source.field}),
              into: %{} do
            {a.source.field,
             %{
               attribute: a.name,
               relationship: Map.get(rels, a.source.field),
               references: a.references
             }}
          end

        fields =
          Enum.reduce(resource.relationships, fields, fn
            %{kind: :many_to_many, source: %{field: field}, name: name, destination: dest},
            fields ->
              Map.put(fields, field, %{relationship: name, list_id_key: primary_keys[dest]})

            _, fields ->
              fields
          end)

        {resource.source.type, %{pk: pk && pk.name, fields: fields}}
      end)

    enums = Map.new(project.enums, &{&1.source.option_set, &1})
    %{types: types, enums: enums, externals: externals(project)}
  end

  # API Connector types with a generated typed struct (WTF-533): external
  # type ID => field ID => `%{name, list?}`, the struct's attribute.
  defp externals(project) do
    for %{source: %{external_type: id}, fields: fields} <- project.typed_structs,
        into: %{} do
      attributes =
        for a <- fields,
            is_binary(a.source[:field]),
            into: %{},
            do: {a.source[:field], %{name: a.name, list?: match?({:array, _}, a.type)}}

      {id, attributes}
    end
  end

  # --- values ---------------------------------------------------------------------

  defp value(%IR{op: :literal, args: [v]}, st), do: {lit(v), st}
  defp value(%IR{op: :empty}, st), do: {"nil", st}

  defp value(%IR{op: :option, args: [set, _value, key]}, st) do
    case st.lookup.enums[set] do
      %{values: values} when is_binary(key) ->
        if Enum.any?(values, &(&1.value == key)),
          do: {lit(key), st},
          else: unsupported(st, {"an unmapped option", "#{set}.#{key}"})

      _ ->
        unsupported(st, {"an unmapped option set", set})
    end
  end

  defp value(%IR{op: :all_options, args: [set]}, st) do
    case st.lookup.enums[set] do
      %{module: module} -> {"#{st.namespace}.#{module}.values()", st}
      nil -> unsupported(st, {"an unmapped option set", set})
    end
  end

  defp value(%IR{op: :option_label, args: [x, set]}, st) do
    case st.lookup.enums[set] do
      nil ->
        unsupported(st, {"an unmapped option set", set})

      enum ->
        {part, st} = value(x, st)
        each(part, &"#{st.namespace}.#{enum.module}.label(#{&1})", x, false, st)
    end
  end

  defp value(%IR{op: :option_attribute, args: [x, set, attr]}, st) do
    case st.lookup.enums[set] do
      nil ->
        unsupported(st, {"an unmapped option set", set})

      enum ->
        case Enum.find(enum.attributes, &(&1.source.field == attr)) do
          nil ->
            unsupported(st, {"an unmapped option attribute", "#{set}.#{attr}"})

          %{name: name, bubble_type: bubble_type} ->
            {part, st} = value(x, st)
            call = &"#{st.namespace}.#{enum.module}.attributes(#{&1}).#{name}"
            list? = match?(%Type{cardinality: :many}, classify(bubble_type))
            each(part, call, x, list?, st)
        end
    end
  end

  defp value(%IR{op: :current_user}, st),
    do: {"current_user", bind(st, "current_user", :current_user, "user")}

  # The item a `:filtered` tests (its `This <item>`).
  defp value(%IR{op: :this, args: [:filter_item]}, %{item?: true} = st), do: {"item", st}

  defp value(%IR{op: :this, args: [binder], type: t}, st),
    do: {"this", bind(st, "this", {:this, binder}, t)}

  defp value(%IR{op: :input, args: [kind, ref], type: type}, st) do
    case Enum.find(st.bindings, fn {_, b} -> b.input == {kind, ref} end) do
      {var, _} ->
        {var, st}

      nil ->
        var = variable(kind, ref, st.bindings)
        {var, bind(st, var, {kind, ref}, type)}
    end
  end

  defp value(%IR{op: :field} = ir, st), do: path(ir, [], :value, st)

  defp value(%IR{op: :external_field} = ir, st), do: external(ir, [], st)

  # An API Connector call used as data (WTF-533) is read by the page's data
  # loader, which gives its value to what reads it (`FrontendWorkflows.Data`);
  # anywhere else it is not compiled.
  defp value(%IR{op: :api_data}, st),
    do: unsupported(st, {"an API Connector call outside page data", nil})

  # A condition used as a value: strictly true or false, never nil (WTF-471).
  defp value(%IR{op: op} = ir, st) when op in @conditions do
    {c, st} = cond(ir, st, true)
    {ok(c, &"(#{&1} == true)"), st}
  end

  # The capped input of a keyword search (WTF-520, bound by
  # `FrontendWorkflows` for `BubbleEx.Target.Ash.Expressions`).
  defp value(%IR{op: :keyword_query, args: [text]}, st) do
    {t, st} = value(text, st)
    runtime(st, :keyword_query, [t])
  end

  # Things picked by position from a list of stored IDs, read as the user
  # may view them (`FrontendWorkflows.Lists`, replay 2026-10-14): one the
  # read did not return is a thing carrying only its stored ID
  # (`picked/2`).
  defp value(%IR{op: :picked, args: [read, pick]}, st) do
    {[r, p], st} = Enum.map_reduce([read, pick], st, &value/2)
    runtime(st, :picked, [r, p])
  end

  defp value(%IR{op: :count, args: [list]}, st) do
    {l, st} = value(list, st)
    {l, st} = as_list(l, st)
    {ok(l, &"length(#{&1})"), st}
  end

  defp value(%IR{op: op, args: [list]}, st) when op in [:first, :last] do
    fun = if op == :first, do: "List.first", else: "List.last"
    {l, st} = value(list, st)
    {l, st} = as_list(l, st)
    {ok(l, &"#{fun}(#{&1})"), st}
  end

  # List algebra (WTF-495): items are compared by Bubble ID when they are
  # records or IDs, by value otherwise (the runtime's `list_key/1`).
  # The URL path's third segment or later (WTF-508): Bubble serves
  # `/<page>/<a>/<b>/...`, but the generated routes stop at
  # `/<page>/:bubble_thing` (a deeper URL is not found), so the read would
  # always be empty. Not compiled: a marker, or residue.
  defp value(
         %IR{
           op: :item_at,
           args: [
             %IR{op: :input, args: [:url_parameter, %{"path" => "segments"}]},
             %IR{op: :literal, args: [n]}
           ]
         },
         st
       )
       when is_number(n) and n >= 3,
       do:
         unsupported(
           st,
           {"a URL path segment after the second (pages route up to /<page>/<x>)", nil}
         )

  defp value(%IR{op: op, args: args}, st) when op in @list_ops do
    {parts, st} = Enum.map_reduce(args, st, &value/2)
    runtime(st, op, parts)
  end

  # `:sorted` on texts, numbers or dates (no sort field): by value, empty
  # values first ascending and last descending (replay 2026-10-07).
  defp value(%IR{op: :sort, args: [list, nil, desc]}, st) when is_boolean(desc) do
    {l, st} = value(list, st)
    runtime(st, :sort_values, [l, inspect(desc)])
  end

  # `:sorted` on a list of options by a text, number or date attribute
  # (WTF-594): `:sorted` by value's order applied to each option's
  # attribute (empty first ascending, last descending; equal keys keep
  # their order).
  defp value(%IR{op: :sort, args: [list, attr, desc]}, st)
       when is_binary(attr) and is_boolean(desc) do
    case classify(list.type) do
      %Type{kind: :option, cardinality: :many, target: set} ->
        option_sort(list, set, attr, desc, st)

      _ ->
        unsupported(st, {"sort", nil})
    end
  end

  # A date interval (`date - date`, WTF-594) as a number of days, hours,
  # minutes or seconds: exact, `(a - b) / unit`, so not whole across a
  # clock change. Any other interval (a stored one) is not compiled.
  defp value(%IR{op: :interval_to, args: [%IR{op: :sub, args: [a, b]}, unit]}, st) do
    {[x, y], st} = Enum.map_reduce([a, b], st, &value/2)
    runtime(st, :date_diff, [x, y, lit(unit)])
  end

  defp value(%IR{op: :interval_to}, st),
    do: unsupported(st, {"a date interval other than a date minus a date", nil})

  # A date range's start, end and middle (WTF-597).
  defp value(%IR{op: op, args: [range]}, st)
       when op in [:range_start, :range_end, :range_middle] do
    {r, st} = value(range, st)
    runtime(st, op, [r])
  end

  # `:filtered` over options, texts, numbers, dates or yes/no values: the
  # constraints per item. A list of things is filtered by its target (a
  # database query: the items' fields are not read here).
  defp value(%IR{op: :filter, args: [list, pred]}, st) do
    if thing_list?(list.type) do
      unsupported(st, {"filter on a list of things", nil})
    else
      {l, st} = value(list, st)
      item_filter(l, pred, st)
    end
  end

  # A date interval is read only as a number of units (`:interval_to`).
  defp value(%IR{op: :sub, type: "dateinterval"}, st),
    do: unsupported(st, {"a date interval used as a value", nil})

  defp value(%IR{op: op, args: [l, r]}, st) when op in @arithmetic do
    {[a, b], st} = Enum.map_reduce([l, r], st, &value/2)
    runtime(st, op, [a, b])
  end

  defp value(%IR{op: :concat, args: parts}, st) do
    {texts, st} =
      Enum.map_reduce(parts, st, fn
        %IR{op: :literal, args: [text]}, st when is_binary(text) ->
          {lit(text), st}

        part, st ->
          part |> shown_value(st) |> shown_file(part) |> then(fn {p, st} -> text(p, st) end)
      end)

    {all_ok("(" <> Enum.join(texts, " <> ") <> ")", texts), st}
  end

  defp value(%IR{op: :fallback, args: [x, d]}, st) do
    {[a, b], st} = Enum.map_reduce([x, d], st, &value/2)
    runtime(st, :default, [a, b])
  end

  # A conditional state's value (WTF-520): the condition holds only when
  # it is yes; an empty one does not.
  defp value(%IR{op: :if, args: [c, a, b]}, st) do
    {cs, st} = truth(c, st)
    {[x, y], st} = Enum.map_reduce([a, b], st, &value/2)
    {all_ok("(if #{cs}, do: #{x}, else: #{y})", [cs, x, y]), st}
  end

  # `:converted to text` on the server is its text in UTC.
  defp value(%IR{op: :to_text, args: [x]}, %{shown: :utc_text} = st) do
    {a, st} = value(x, st)
    runtime(st, :utc_text, [a])
  end

  defp value(%IR{op: op, args: [x]}, st) when op in @runtime_unary do
    {a, st} = value(x, st)
    runtime(st, op, [a])
  end

  # A date operator's zone is an argument only when the expression names
  # one: without it the runtime uses the user's (its `time_zone/0`).
  defp value(%IR{op: op, args: [x, setting, zone]}, st)
       when op in [:format_date, :date_floor, :date_part] do
    {a, st} = value(x, st)
    st = approximate(st, Formats.approximations(op, setting))

    case zone do
      nil ->
        runtime(st, op, [a, lit(setting)])

      zone when is_binary(zone) ->
        runtime(st, op, [a, lit(setting), lit(zone)])

      %IR{} = zone ->
        {z, st} = value(zone, st)
        runtime(st, op, [a, lit(setting), z])
    end
  end

  defp value(%IR{op: :format_number, args: [x, options]}, st) do
    {a, st} = value(x, st)
    st = approximate(st, Formats.approximations(:format_number, options))
    runtime(st, :format_number, [a, lit(options)])
  end

  defp value(%IR{op: :date_add, args: [x, n, unit]}, st) do
    {[a, b], st} = Enum.map_reduce([x, n], st, &value/2)
    runtime(st, :date_add, [a, b, lit(unit)])
  end

  defp value(%IR{op: :replace, args: [x, find, replace, regex]}, st) do
    {parts, st} = Enum.map_reduce([x, find, replace], st, &value/2)
    runtime(st, :replace, parts ++ [lit(regex)])
  end

  defp value(%IR{op: op, args: args}, st)
       when op in [:format_boolean, :truncate, :split] do
    {parts, st} = Enum.map_reduce(args, st, &value/2)
    runtime(st, op, parts)
  end

  defp value(%IR{op: op}, st), do: unsupported(st, {"#{op}", nil})

  defp option_sort(list, set, attr, desc, st) do
    with %{module: module, attributes: attributes} <- st.lookup.enums[set],
         %{name: name, bubble_type: bubble_type} <-
           Enum.find(attributes, &(&1.source.field == attr)),
         %Type{kind: :scalar, base: base, cardinality: :one} when base in [:text, :number, :date] <-
           classify(bubble_type) do
      {l, st} = value(list, st)
      key = "&#{st.namespace}.#{module}.attributes(&1).#{name}"
      runtime(st, :sort_values_by, [l, key, inspect(desc)])
    else
      nil when is_map_key(st.lookup.enums, set) ->
        unsupported(st, {"an unmapped option attribute", "#{set}.#{attr}"})

      nil ->
        unsupported(st, {"an unmapped option set", set})

      _ ->
        unsupported(st, {"sort", nil})
    end
  end

  # --- conditions ---------------------------------------------------------------------

  # A condition for `positive` or negated polarity, with the Ash backend's
  # semantics (`BubbleEx.Target.Ash.Expressions`): negation is pushed down to
  # the atomic comparisons (De Morgan) and every atom that reads an empty
  # value from the current user is false in either polarity (fail-safe).
  defp cond(%IR{op: op, args: args}, st, positive) when op in [:and, :or] do
    {parts, st} = Enum.map_reduce(args, st, &cond(&1, &2, positive))
    joiner = if positive, do: op, else: dual(op)
    {all_ok("(" <> Enum.join(parts, " #{joiner} ") <> ")", parts), st}
  end

  defp cond(%IR{op: :not, args: [x]}, st, positive), do: cond(x, st, not positive)

  defp cond(%IR{op: :literal, args: [b]}, st, positive) when is_boolean(b),
    do: {inspect(b == positive), st}

  defp cond(%IR{op: op, args: [l, r]}, st, positive) when op in [:eq, :neq] do
    cond do
      match?(%IR{op: :empty}, l) -> cond(empty_check(op, r), st, positive)
      match?(%IR{op: :empty}, r) -> cond(empty_check(op, l), st, positive)
      condition_is_literal?(l, r) -> cond(r, st, literal_polarity(op, l, positive))
      condition_is_literal?(r, l) -> cond(l, st, literal_polarity(op, r, positive))
      boolean_equality?(l, r) -> boolean_equality(op, l, r, st, positive)
      true -> atom(%IR{op: op, args: [l, r]}, st, positive)
    end
  end

  defp cond(ir, st, positive), do: atom(ir, st, positive)

  defp dual(:and), do: :or
  defp dual(:or), do: :and

  defp empty_check(:eq, x), do: IR.node(:is_empty, [x], "boolean")
  defp empty_check(:neq, x), do: IR.node(:not, [IR.node(:is_empty, [x], "boolean")], "boolean")

  # A condition (not a stored yes/no value) and a literal yes/no: `c is yes`
  # is `c`, `c is no` is `not c`.
  defp condition_is_literal?(%IR{op: :literal, args: [b]}, other) when is_boolean(b),
    do: condition?(other)

  defp condition_is_literal?(_literal, _other), do: false

  defp literal_polarity(op, %IR{args: [b]}, positive), do: op == :eq == b == positive

  defp condition?(%IR{op: op, type: "boolean"}), do: op not in @boolean_values and op != :literal
  defp condition?(_ir), do: false

  defp yes_no_eq(%IR{op: :literal, args: [false]}, _r, _a, b), do: "(#{b} != true)"
  defp yes_no_eq(_l, %IR{op: :literal, args: [false]}, a, _b), do: "(#{a} != true)"
  defp yes_no_eq(%IR{op: :literal}, _r, a, b), do: "(#{a} == #{b})"
  defp yes_no_eq(_l, %IR{op: :literal}, a, b), do: "(#{a} == #{b})"
  defp yes_no_eq(_l, _r, a, b), do: "((#{a} == true) == (#{b} == true))"

  defp yes_no_neq(%IR{op: :literal, args: [false]}, _r, _a, b), do: "(#{b} == true)"
  defp yes_no_neq(_l, %IR{op: :literal, args: [false]}, a, _b), do: "(#{a} == true)"
  defp yes_no_neq(%IR{op: :literal}, _r, a, b), do: "(#{a} != #{b})"
  defp yes_no_neq(_l, %IR{op: :literal}, a, b), do: "(#{a} != #{b})"
  defp yes_no_neq(_l, _r, a, b), do: "((#{a} == true) != (#{b} == true))"

  # A value shown as text (a part of a dynamic text, a value shown on a
  # page): `x is yes` on a stored yes/no x that is empty shows empty, not
  # no (replay 2026-10-14; `x is no` there shows yes, and a condition
  # reads `x is yes` as not holding). Anything else as `value/2`.
  defp shown_value(ir, st) do
    case yes_test_of(ir) do
      %IR{} = x ->
        {c, st} = cond(ir, st, true)
        {v, st} = value(x, st)
        {empty, st} = runtime(st, :empty?, [v])
        {all_ok("(if #{empty}, do: nil, else: #{c} == true)", [c, v, empty]), st}

      nil ->
        value(ir, st)
    end
  end

  # The stored yes/no `x` of `x is yes` (`yes is x`), else nil.
  defp yes_test_of(%IR{op: :eq, args: [%IR{op: :literal, args: [true]}, x]}),
    do: if(stored_yes_no?(x), do: x)

  defp yes_test_of(%IR{op: :eq, args: [x, %IR{op: :literal, args: [true]}]}),
    do: if(stored_yes_no?(x), do: x)

  defp yes_test_of(_ir), do: nil

  defp yes_no_pair?(l, r),
    do: (stored_yes_no?(l) or stored_yes_no?(r)) and yes_no_side?(l) and yes_no_side?(r)

  defp stored_yes_no?(%IR{op: op, type: "boolean"}), do: op in @boolean_values
  defp stored_yes_no?(_ir), do: false

  defp yes_no_side?(%IR{op: :literal, args: [b]}), do: is_boolean(b)
  defp yes_no_side?(ir), do: stored_yes_no?(ir)

  # Two yes/no sides, one a condition: expanded so that each side keeps its
  # own polarities and guards (a stored yes/no side is `is yes` / `is
  # no`, an empty one no, WTF-529). A condition's negation is not always its
  # complement (an empty value fails both), so comparing it as a plain
  # value could match where neither side holds (WTF-471).
  defp boolean_equality?(l, r), do: condition?(l) or condition?(r)

  # `a is b` between yes/no conditions that read the current user.
  defp boolean_equality(op, l, r, st, positive) do
    {[lp, ln, rp, rn], st} =
      Enum.map_reduce([{l, true}, {l, false}, {r, true}, {r, false}], st, fn {ir, pol}, st ->
        side(ir, st, pol)
      end)

    source =
      if op == :eq == positive,
        do: "((#{lp} and #{rp}) or (#{ln} and #{rn}))",
        else: "((#{lp} and #{rn}) or (#{ln} and #{rp}))"

    {all_ok(source, [lp, ln, rp, rn]), st}
  end

  defp side(ir, st, pol) do
    if condition?(ir),
      do: cond(ir, st, pol),
      else: atom(IR.node(:eq, [ir, IR.node(:literal, [pol], "boolean")], "boolean"), st, true)
  end

  defp atom(ir, st, positive) do
    case atom_(ir, st) do
      {{pos, neg, operands}, st} -> guard(if(positive, do: pos, else: neg), operands, st)
      {:error, st} -> {:error, st}
    end
  end

  # `is` / `is not`: records compare by ID; empty equals empty unless a side
  # is read from the current user (guarded). A compared value goes through
  # the runtime's `unhidden/1`, which reads it as Bubble does: a field the
  # user may not view is empty (WTF-500), and so is an empty text (`""`,
  # WTF-514: Bubble has no empty string distinct from empty), and a
  # case-insensitive text (`Ash.CiString`) is its text (WTF-515). Against
  # a literal that is no text (a number, a yes/no, an option), `==` and
  # `!=` already answer so, and the source stays plain.
  defp atom_(%IR{op: op, args: [l, r]}, st) when op in [:eq, :neq] do
    {[a, b], st} = Enum.map_reduce([l, r], st, &id_value/2)

    {[a, b], st} =
      if plain_literal?(l) or plain_literal?(r),
        do: {[a, b], st},
        else: Enum.map_reduce([{l, a}, {r, b}], st, &unhidden/2)

    # WTF-471, WTF-529: between yes/no values with a stored side, an empty
    # one reads as no, as Bubble does, in `is` as in `is not` (`x is no`
    # holds on an empty x; `x is not no` needs a stored yes). The privacy
    # policies keep `is` stricter; page and workflow conditions, as page
    # searches (`BubbleEx.Target.Ash.Expressions.search/3`), read it as
    # Bubble.
    {eq, neq} =
      if yes_no_pair?(l, r),
        do: {yes_no_eq(l, r, a, b), yes_no_neq(l, r, a, b)},
        else: {"(#{a} == #{b})", "(#{a} != #{b})"}

    {pos, neg} = if op == :eq, do: {eq, neq}, else: {neq, eq}
    # Between yes/no values the current user's empty one is no too, a
    # logged-out visitor's included: no guard (WTF-529).
    operands = if yes_no_pair?(l, r), do: [], else: [{l, a}, {r, b}]
    {all_ok({pos, neg, operands}, [a, b]), st}
  end

  # Ordering: false when either side is empty, in either polarity.
  defp atom_(%IR{op: op, args: [l, r]}, st) when is_map_key(@compare, op) do
    {[a, b], st} = Enum.map_reduce([l, r], st, &value/2)
    {cmp, st} = runtime(st, :compare, [inspect(Map.fetch!(@compare, op)), a, b])

    # Both sides non-empty (`empty?/1`: a field the user may not view is
    # empty too, WTF-500), and the ordering does not hold.
    {[ea, eb], st} = Enum.map_reduce([a, b], st, &runtime(&2, :empty?, [&1]))
    negated = ok(cmp, &"(not #{ea} and not #{eb} and not #{&1})")
    {all_ok({cmp, negated, [{l, a}, {r, b}]}, [a, b, cmp, ea, eb]), st}
  end

  defp atom_(%IR{op: :is_empty, args: [x]}, st) do
    {part, st} = value(x, st)
    {empty, st} = runtime(st, :empty?, [part])
    user = IR.node(:current_user, [], "user")
    {_, st} = if reads_actor?(x), do: value(user, st), else: {nil, st}
    logged_in = if reads_actor?(x), do: [{user, "current_user"}], else: []
    {all_ok({empty, ok(empty, &"not #{&1}"), logged_in}, [empty]), st}
  end

  defp atom_(%IR{op: :logged_in}, st) do
    st = bind(st, "current_user", :current_user, "user")
    {{"not is_nil(current_user)", "is_nil(current_user)", []}, st}
  end

  defp atom_(%IR{op: :member, args: [list, item]}, st) do
    cond do
      member_list?(list) ->
        {l, st} = list_ids(list, st)
        {i, st} = id_value(item, st)
        {items, st} = as_list(l, st)
        {items, i, st} = member_texts(list, items, i, st)
        member = "Enum.member?(#{items}, #{i})"
        {all_ok({member, "not #{member}", [{list, l}, {item, i}]}, [items, i]), st}

      # A list of records (an input's list, a query's records, list
      # algebra over them) contains a thing when one of its things is that
      # thing: compared by Bubble ID (the runtime's `id/1`, a record's or
      # an ID's own; a field the user may not view is no thing), so an
      # empty item is in no list (WTF-520).
      thing_list?(list.type) ->
        {l, st} = value(list, st)
        {i, st} = id_value(item, st)
        {items, st} = as_list(l, st)
        {id, st} = runtime(st, :id, ["&1"])
        member = "(not is_nil(#{i}) and Enum.member?(Enum.map(#{items}, &#{id}), #{i}))"
        {all_ok({member, "not #{member}", [{list, l}, {item, i}]}, [items, i]), st}

      true ->
        unsupported(st, {"contains on a list of records", nil})
    end
  end

  # `doesn't contain` with an empty part is false, as in the Ash filter
  # (`contains(t, NULL)` is NULL there): only a text that is not empty
  # can be missing from another.
  defp atom_(%IR{op: :text_contains, args: args}, st) do
    {[t, p], st} = Enum.map_reduce(args, st, &value/2)
    {found, st} = runtime(st, :text_contains?, [t, p])
    {empty, st} = runtime(st, :empty?, [p])
    absent = ok(found, &"(not #{empty} and not #{&1})")
    {all_ok({found, absent, Enum.zip(args, [t, p])}, [found, empty]), st}
  end

  defp atom_(%IR{op: :text_contains_words, args: args}, st) do
    {parts, st} = Enum.map_reduce(args, st, &value/2)
    {found, st} = runtime(st, :text_contains_words?, parts)
    {all_ok({found, ok(found, &"not #{&1}"), Enum.zip(args, parts)}, [found]), st}
  end

  # A yes/no value that may be empty: empty is not yes, the current
  # user's (or a logged-out visitor's) included: no guard (WTF-529).
  defp atom_(%IR{op: op} = ir, st) when op in @boolean_values do
    {part, st} = value(ir, st)
    {all_ok({"(#{part} == true)", "(#{part} != true)", []}, [part]), st}
  end

  # A yes/no folded from conditional states (an element's visibility read
  # by another, WTF-578; an input's initial content), or a yes/no
  # `formatted as` a yes/no (WTF-597): a yes/no value, an empty one
  # reading as no, as a stored one.
  defp atom_(%IR{op: op, type: "boolean"} = ir, st) when op in [:if, :format_boolean] do
    {part, st} = value(ir, st)
    {all_ok({"(#{part} == true)", "(#{part} != true)", []}, [part]), st}
  end

  defp atom_(%IR{op: op}, st), do: unsupported(st, {"#{op}", nil})

  # A list of texts and its item compare as `is` does (`unhidden/1`): a
  # case-insensitive text (the User's email) is its text (WTF-515).
  defp member_texts(%IR{type: "list.text"}, items, i, st)
       when is_binary(items) and is_binary(i) do
    {each, st} = runtime(st, :unhidden, ["&1"])
    {item, st} = runtime(st, :unhidden, [i])
    {"Enum.map(#{items}, &#{each})", item, st}
  end

  defp member_texts(_list, items, i, st), do: {items, i, st}

  # A literal that is neither empty nor text, or an option: compared with
  # `==` it already answers as Bubble for an empty, hidden or
  # case-insensitive other side.
  defp plain_literal?(%IR{op: :literal, args: [v]}), do: v not in [nil, []] and not is_binary(v)
  defp plain_literal?(%IR{op: :option}), do: true
  defp plain_literal?(_ir), do: false

  # A compared value as Bubble reads it (the runtime's `unhidden/1`): an
  # empty text is empty, as is a field the user may not view. Literals,
  # options and records' IDs need no call; an empty text literal is nil.
  defp unhidden({_ir, :error}, st), do: {:error, st}

  defp unhidden({%IR{op: :literal, args: [""]}, _part}, st), do: {"nil", st}

  defp unhidden({%IR{op: op} = ir, part}, st) do
    if op in [:literal, :empty, :option, :all_options] or record_type?(ir.type),
      do: {part, st},
      else: runtime(st, :unhidden, [part])
  end

  defp reads_actor?(%IR{op: op}) when op in [:current_user, :logged_in], do: true
  defp reads_actor?(%IR{args: args}), do: Enum.any?(args, &reads_actor?/1)
  defp reads_actor?(list) when is_list(list), do: Enum.any?(list, &reads_actor?/1)
  defp reads_actor?(_), do: false

  # Each item of `l` (`item`) that meets `pred`, `l` read as a list (the
  # runtime's `as_list/1`, never `|| []`: Elixir 1.20's type checker
  # rejects the dead branch on a set's options, and a hidden field is not
  # nil, WTF-500).
  defp item_filter(l, nil, st), do: as_list(l, st)

  defp item_filter(l, pred, st) do
    {l, st} = as_list(l, st)
    {c, inner} = cond(pred, %{st | item?: true}, true)

    {all_ok("Enum.filter(#{l}, fn item -> #{c} end)", [l, c]), %{inner | item?: st.item?}}
  end

  # A shown file or image value goes through `:file_url` (WTF-415).
  defp shown_file({:error, _} = result, _ir), do: result
  defp shown_file({_, %{file_url: nil}} = result, _ir), do: result

  defp shown_file({part, st}, %IR{type: type}) when type in ["file", "image"],
    do: {"#{st.file_url}(#{part})", st}

  defp shown_file({part, st}, %IR{type: type}) when type in ["list.file", "list.image"] do
    {l, st} = as_list(part, st)
    {"Enum.map(#{l}, &#{st.file_url}/1)", st}
  end

  defp shown_file(result, _ir), do: result

  defp text(:error, st), do: {:error, st}
  defp text(part, st), do: runtime(st, st.shown, [part])

  # A record compares by its ID: a field path reads its `_id` attribute;
  # any other record (an element's thing, a property, a custom state, a
  # search's first item) goes through the runtime's `id/1` (an ID stays
  # itself), so a record is never compared with an ID (always different)
  # or looked up in a list of IDs (never a member).
  defp id_value(%IR{type: type} = ir, st) do
    if record_type?(type) do
      case ir do
        %IR{op: op} when op in [:field, :this, :current_user, :fallback] ->
          path(ir, [], :id, st)

        # A thing literal is its Bubble ID.
        %IR{op: :literal} ->
          value(ir, st)

        _ ->
          {v, st} = value(ir, st)
          runtime(st, :id, [v])
      end
    else
      value(ir, st)
    end
  end

  # A list-of-things field as its things' IDs: each item's reference
  # attribute (no load), or a list stored as IDs as it is (WTF-520: also
  # through a list normalized to a join, read as records).
  defp list_ids(%IR{op: :field, type: type} = list, st) do
    if thing_list?(type), do: path(list, [], :id, st), else: id_value(list, st)
  end

  defp list_ids(list, st), do: id_value(list, st)

  # `source`, required to have every operand read from the current user
  # non-empty in Bubble's sense (the runtime's `empty?/1`: nil, `""`, `[]`,
  # or a field the user may not view, WTF-500; as the Ash backend).
  # `operands` are `{ir, source}` pairs.
  defp guard(:error, _operands, st), do: {:error, st}

  defp guard(source, operands, st) do
    case for({ir, part} <- operands, actor?(ir), uniq: true, do: part) do
      [] ->
        {source, st}

      parts ->
        {checks, st} =
          Enum.map_reduce(parts, st, fn part, st ->
            {empty, st} = runtime(st, :empty?, [part])
            {"not " <> empty, st}
          end)

        {"(" <> Enum.join(checks ++ [source], " and ") <> ")", st}
    end
  end

  # Whether `ir` is read from the current user (directly or through fields).
  defp actor?(%IR{op: :current_user}), do: true
  defp actor?(%IR{op: :field, args: [base | _]}), do: actor?(base)
  defp actor?(%IR{op: :fallback, args: args}), do: Enum.any?(args, &actor?/1)
  defp actor?(_ir), do: false

  # An option's lookup (`call` builds it from the option's variable)
  # applied to an option, or to each option of a list of them (an option's
  # label or attribute, of all of a set's options). The enum's lookups are
  # total: an empty or unknown option's label and attributes are empty
  # (WTF-500). A list attribute of each option of a list is one list of all
  # of their items (`list?`), as Bubble's `each item's`.
  defp each(:error, _call, _ir, _list?, st), do: {:error, st}

  defp each(part, call, %IR{type: type}, list?, st) do
    if match?(%Type{cardinality: :many}, classify(type)) do
      {l, st} = as_list(part, st)

      if list? do
        {item, st} = as_list(call.("option"), st)
        {"Enum.flat_map(#{l}, fn option -> #{item} end)", st}
      else
        {"Enum.map(#{l}, &#{call.("&1")})", st}
      end
    else
      {"then(#{part}, &#{call.("&1")})", st}
    end
  end

  # A value read as a list (WTF-500): empty (nil, `""`, a field the user
  # may not view) is `[]`, a list itself, any other value a list of it.
  # Never `x || []`: a hidden field (`%Ash.ForbiddenField{}`) or any other
  # value is truthy, and `Enum` raises on it.
  defp as_list(:error, st), do: {:error, st}
  defp as_list(part, st), do: runtime(st, :as_list, [part])

  defp record_type?(type), do: match?(%Type{kind: :ref, cardinality: :one}, classify(type))
  defp thing_list?(type), do: match?(%Type{kind: :ref, cardinality: :many}, classify(type))

  # A list whose items are values or Bubble IDs: a list-of-things field is
  # an array of IDs, other lists of records (inputs, searches) hold records.
  defp member_list?(%IR{op: :fallback, args: args}), do: Enum.all?(args, &member_list?/1)

  defp member_list?(%IR{op: op, type: type}) do
    case classify(type) do
      %Type{cardinality: :many, kind: :ref} -> op in [:field, :literal]
      %Type{cardinality: :many} -> true
      _ -> false
    end
  end

  # IR types are Bubble descriptors; the Model classifies them.
  defp classify(type) when is_binary(type), do: type |> Type.classify() |> elem(0)
  defp classify(_type), do: nil

  # --- API Connector values ------------------------------------------------------------

  # A field chain of an API Connector value (WTF-533: a call's result, as
  # the generated client decoded it), nil-safe: an API type with a typed
  # struct (one a data field stores) is read by its attributes, any other
  # (a call's own type) from the decoded map by Bubble field ID. Over a
  # list of API values, or through a list field, it is each item's field,
  # one list of their values (a list field's flattened), empty ones left
  # out, as a field of a list of things.
  defp external(%IR{op: :external_field, args: [base, ext, field], type: type}, fields, st),
    do: external(base, [{ext, field, type} | fields], st)

  defp external(%IR{type: type} = base, fields, st) do
    case external_keys(fields, st.lookup.externals) do
      {:ok, keys} ->
        {source, st} = value(base, st)
        list? = match?(%Type{cardinality: :many}, classify(type))
        segments = external_segments(Enum.zip(fields, keys))
        external_read(source, list?, segments, st)

      {:error, what} ->
        unsupported(st, what)
    end
  end

  # The chain in segments, each ending at a list field (or the chain's end).
  defp external_segments(steps) do
    {segments, last} =
      Enum.reduce(steps, {[], []}, fn {{_, _, type}, key}, {done, current} ->
        current = current ++ [key]

        if match?(%Type{cardinality: :many}, classify(type)),
          do: {done ++ [{current, true}], []},
          else: {done, current}
      end)

    if last == [], do: segments, else: segments ++ [{last, false}]
  end

  defp external_read(:error, _list?, _segments, st), do: {:error, st}
  defp external_read(source, _list?, [], st), do: {source, st}

  defp external_read(source, false, [{keys, list?} | rest], st),
    do: external_read("get_in(#{source}, [#{Enum.join(keys, ", ")}])", list?, rest, st)

  defp external_read(source, true, [{keys, list?} | rest], st) do
    {items, st} = as_list(source, st)
    get = "get_in(api_item, [#{Enum.join(keys, ", ")}])"

    read =
      if list?,
        do: "Enum.flat_map(#{items}, fn api_item -> List.wrap(#{get}) end)",
        else: "Enum.reject(Enum.map(#{items}, fn api_item -> #{get} end), &is_nil/1)"

    external_read(read, true, rest, st)
  end

  defp external_keys(fields, externals) do
    structs = Enum.map(fields, fn {ext, _, _} -> Map.has_key?(externals, ext) end)

    cond do
      Enum.all?(structs) ->
        Enum.reduce_while(fields, {:ok, []}, &struct_key(&1, &2, externals))

      not Enum.any?(structs) ->
        {:ok, Enum.map(fields, fn {_, field, _} -> "Access.key(#{lit(field)})" end)}

      true ->
        {:error, {"an API value mixing typed structs and maps", nil}}
    end
  end

  defp struct_key({ext, field, _type}, {:ok, acc}, externals) do
    case get_in(externals, [ext, field]) do
      %{name: name} -> {:cont, {:ok, acc ++ ["Access.key(#{atom(name)})"]}}
      nil -> {:halt, {:error, {"an API type field its typed struct lacks", ext}}}
    end
  end

  # --- field paths ----------------------------------------------------------------

  defp path(%IR{op: :field, args: [base, type, field]}, steps, mode, st),
    do: path(base, [{type, field} | steps], mode, st)

  defp path(%IR{op: :this, args: [:filter_item]} = base, steps, mode, %{item?: true} = st),
    do: access(base, "item", steps, mode, st)

  defp path(%IR{op: :this} = base, steps, mode, st), do: access(base, "this", steps, mode, st)

  defp path(%IR{op: :current_user} = base, steps, mode, st),
    do: access(base, "current_user", steps, mode, st)

  defp path(%IR{op: :input} = base, steps, mode, st) do
    {var, st} = value(base, st)
    access(base, var, steps, mode, st)
  end

  # A field chain over `x defaulting to d`: the chain over `x` unless `x`
  # is empty (a reference is its loaded record, nil when unset or gone),
  # else the chain over `d`.
  defp path(%IR{op: :fallback, args: [x, d]}, steps, mode, st) do
    {xv, st} = value(x, st)
    {empty, st} = runtime(st, :empty?, [xv])
    {[a, b], st} = Enum.map_reduce([x, d], st, &chain(&1, steps, mode, &2))
    {all_ok("(if #{empty}, do: #{b}, else: #{a})", [empty, a, b]), st}
  end

  # A field chain over `x :converted to list` is the chain over `x`,
  # converted: `(x :converted to list)'s a` is `(x's a) :converted to
  # list` (a thing's `a`, one item; a list's, each item's; empty, none).
  defp path(%IR{op: :as_list, args: [x]}, steps, mode, st) do
    {v, st} = chain(x, steps, mode, st)
    as_list(v, st)
  end

  defp path(%IR{op: op} = base, steps, mode, st) when op in @through_lists,
    do: through_list(base, steps, mode, st)

  defp path(%IR{op: op}, _steps, _mode, st), do: unsupported(st, {"a field of #{op}", nil})

  # `steps` (`{data_type, field}` from the base outwards) over `base`.
  defp chain(base, [], :id, st), do: id_value(base, st)
  defp chain(base, [], _mode, st), do: value(base, st)

  defp chain(base, steps, mode, st) do
    ir =
      Enum.reduce(steps, base, fn {type, field}, acc ->
        IR.node(:field, [acc, type, field], nil)
      end)

    path(ir, [], mode, st)
  end

  defp access(%IR{} = base, var, steps, mode, st) do
    {_, st} = if var in ["this", "current_user"], do: value(base, st), else: {var, st}
    read(base, var, steps, mode, st, &add_load(&1, var, &2))
  end

  # `steps` read from `source`, the Elixir of `base`'s value (a record, a
  # list of records, or nil); `load` adds the relationship paths the read
  # needs, relative to `base`'s things, to the variables they come from.
  defp read(%IR{} = base, source, steps, mode, st, load) do
    case keys(steps, type_id(base.type), mode, st) do
      {:ok, [[]], _loads, _list_id_key} ->
        {source, st}

      {:ok, segments, loads, list_id_key} ->
        st = if loads == [], do: st, else: load.(st, loads)

        # A field of a list of things (a search read first, an input's
        # list) is each item's (WTF-500), as Bubble's `each item's`: one
        # list of every item's values, empty ones dropped. `get_in/2` on
        # the list itself raises.
        if thing_list?(base.type) do
          {each, st} = segments_read("thing", segments, list_id_key, 1, st)
          {each, st} = as_list(each, st)
          {items, st} = as_list(source, st)
          # A thing given as its Bubble ID (a custom state's list) is no
          # record here: its fields read as empty, never a crash (WTF-500).
          {all_ok(
             "Enum.flat_map(#{items}, fn thing when is_map(thing) -> #{each}; _ -> [] end)",
             [each, items]
           ), st}
        else
          segments_read(source, segments, list_id_key, 1, st)
        end

      {:error, what} ->
        unsupported(st, what)
    end
  end

  # A chain read in segments, each ending at a list of things it reads
  # through (a list normalized to a join): each of its items' next
  # segment, flattened into one list as Bubble's `list's field` does
  # (WTF-520), empty values dropped.
  defp segments_read(source, [keys], list_id_key, _depth, st),
    do: field_value("get_in(#{source}, #{access_keys(keys)})", list_id_key, st)

  defp segments_read(source, [keys | rest], list_id_key, depth, st) do
    var = "each_#{depth}"
    {inner, st} = segments_read(var, rest, list_id_key, depth + 1, st)
    {inner, st} = as_list(inner, st)
    {items, st} = as_list("get_in(#{source}, #{access_keys(keys)})", st)

    {all_ok(
       "Enum.flat_map(#{items}, fn #{var} when is_map(#{var}) -> #{inner}; _ -> [] end)",
       [inner, items]
     ), st}
  end

  defp access_keys(keys), do: "[" <> Enum.map_join(keys, ", ", &"Access.key(#{atom(&1)})") <> "]"

  # A field chain over a list operator's result (WTF-520: `:first item`,
  # `:item #`, `:last item`, `:unique elements`, `:merged with`, ...) whose
  # things are records: the chain over that record (or each of those
  # records), its relationships loaded on the variables the records come
  # from (`origins/2`). Things stored as Bubble IDs (a list-of-things
  # field) are not records: their fields are not read here
  # (`BubbleEx.Target.Elixir.FrontendWorkflows.Lists` reads a page's as
  # records first).
  defp through_list(%IR{op: op} = base, steps, mode, st) do
    case origins(base, [], st) do
      {:ok, origins} ->
        {source, st} = value(base, st)

        {vars, st} =
          Enum.map_reduce(origins, st, fn {origin, prefix}, st ->
            {var, st} = value(origin, st)
            {{var, prefix}, st}
          end)

        load = &add_loads(&1, vars, &2)
        if source == :error, do: {:error, st}, else: read(base, source, steps, mode, st, load)

      :error ->
        unsupported(st, {"a field of #{op}", nil})
    end
  end

  # `loads` (relative to the things) on each variable they come from,
  # under its relationship path.
  defp add_loads(st, vars, loads) do
    Enum.reduce(vars, st, fn {var, prefix}, st ->
      add_load(st, var, Enum.map(loads, &(prefix ++ &1)))
    end)
  end

  # Where the things of a list operator's result come from: `{:ok, [{ir,
  # relationships}]}`, each a variable (a context input, a query's
  # records, `This`, the current user) and the relationship path from it
  # to the things; `:error` when they may be Bubble IDs (a list-of-things
  # field) or anything else.
  defp origins(%IR{op: :this, args: [:filter_item]}, _rels, %{item?: true}), do: :error

  defp origins(%IR{op: op, type: type} = ir, rels, _st)
       when op in [:this, :current_user] do
    if record_type?(type) or thing_list?(type), do: {:ok, [{ir, rels}]}, else: :error
  end

  defp origins(%IR{op: :input, args: [kind, ref], type: type} = ir, rels, _st) do
    if records?(kind, ref) and (record_type?(type) or thing_list?(type)),
      do: {:ok, [{ir, rels}]},
      else: :error
  end

  defp origins(%IR{op: :field} = ir, rels, st) do
    {base, steps} = unchain(ir, [])

    case relationship_path(steps, st) do
      {:ok, path} when base.op in [:input, :this, :current_user] ->
        origins(base, path ++ rels, st)

      _ ->
        :error
    end
  end

  defp origins(%IR{op: op, args: [list | _]}, rels, st)
       when op in [:first, :last, :item_at, :unique, :limit, :minus_list, :minus_item, :intersect],
       do: origins(list, rels, st)

  # The records the read returned; a thing carrying only its ID has no
  # relationship to load.
  defp origins(%IR{op: :picked, args: [read, _pick]}, rels, st), do: origins(read, rels, st)

  defp origins(%IR{op: op, args: [a, b]}, rels, st) when op in [:merge, :plus_item, :fallback] do
    with {:ok, x} <- origins(a, rels, st),
         {:ok, y} <- origins(b, rels, st),
         do: {:ok, x ++ y}
  end

  defp origins(_ir, _rels, _st), do: :error

  # The inputs whose things the page reads as records (through Ash, as
  # the user): a group's or a list's data (and a reusable element's
  # property, page data too), a cell's or the page's thing, a query's
  # records, a database trigger's thing. A custom state, a workflow's
  # parameter or a step's result may hold Bubble IDs: not an origin.
  defp records?(:element_state, %{"state" => state}) when is_binary(state),
    do: state in ["get_group_data", "get_list_data"] or String.starts_with?(state, "param_")

  defp records?(kind, _ref), do: kind in [:cell_thing, :page_thing, :query, :trigger_thing]

  defp unchain(%IR{op: :field, args: [base, type, field]}, steps),
    do: unchain(base, [{type, field} | steps])

  defp unchain(base, steps), do: {base, steps}

  # The relationships a chain whose every step is one reads, to records:
  # its last step not a list normalized to a join (read as its IDs).
  defp relationship_path(steps, st) do
    last = List.last(steps)

    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, rels} ->
      case relationship_step(step, step == last, st) do
        {:ok, rel} -> {:cont, {:ok, rels ++ [rel]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp relationship_step({type, field}, last?, st) do
    case field_info(type, field, st) do
      {:ok, %{list_id_key: _}} when last? -> :error
      {:ok, %{relationship: rel}} when is_binary(rel) -> {:ok, rel}
      _ -> :error
    end
  end

  # A field's value read by `path`: a list of things stored as their
  # records is its items' IDs (`list_id_key`).
  defp field_value(path, nil, st), do: {path, st}

  defp field_value(path, list_id_key, st) do
    {items, st} = as_list(path, st)
    {"Enum.map(#{items}, &Map.get(&1, #{atom(list_id_key)}))", st}
  end

  # Access keys for a field chain, in segments (see `segments_read/5`).
  # Relationship steps need loading; the last step is its attribute, or in
  # `:id` mode a reference's `_id` attribute (no load); in `:value` mode a
  # reference is its relationship. A list normalized to a join is its
  # relationship in either mode, read as its items' IDs (`list_id_key`).
  defp keys([], type, :id, st) do
    case st.lookup.types[type] do
      %{pk: pk} -> {:ok, [[pk]], [], nil}
      nil -> {:error, {"an unmapped data type", type}}
    end
  end

  defp keys([], _type, :value, _st), do: {:ok, [[]], [], nil}

  defp keys(steps, _type, mode, st) do
    {init, [{last_type, last_field}]} = Enum.split(steps, -1)

    with {:ok, segments, rels} <- relationships(init, st),
         {:ok, info} <- field_info(last_type, last_field, st) do
      list_id_key = info[:list_id_key]
      related? = (mode == :value or list_id_key != nil) and is_binary(info.relationship)
      last = if related?, do: info.relationship, else: info.attribute
      loads = if related?, do: rels ++ [last], else: rels
      segments = List.update_at(segments, -1, &(&1 ++ [last]))
      {:ok, segments, if(loads == [], do: [], else: [loads]), list_id_key}
    end
  end

  # The relationships of a chain's steps but the last, in segments: a list
  # normalized to a join (`list_id_key`) ends one, read through as a list.
  # A list of things stored as Bubble IDs, or any other value, has no
  # relationship to read through here.
  defp relationships(steps, st) do
    Enum.reduce_while(steps, {:ok, [[]], []}, fn {type, field}, {:ok, segments, rels} ->
      case field_info(type, field, st) do
        {:ok, %{relationship: rel, list_id_key: _}} when is_binary(rel) ->
          segments = List.update_at(segments, -1, &(&1 ++ [rel])) ++ [[]]
          {:cont, {:ok, segments, rels ++ [rel]}}

        {:ok, %{relationship: rel}} when is_binary(rel) ->
          {:cont, {:ok, List.update_at(segments, -1, &(&1 ++ [rel])), rels ++ [rel]}}

        {:ok, _} ->
          {:halt, {:error, {"a path through a list or value", "#{type}.#{field}"}}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp field_info(type, field, st) do
    case get_in(st.lookup, [:types, type, :fields, field]) do
      nil -> {:error, {"an unmapped field", "#{type}.#{field}"}}
      info -> {:ok, info}
    end
  end

  defp add_load(st, var, loads) do
    paths = Map.get(st.loads, var, MapSet.new())
    %{st | loads: Map.put(st.loads, var, Enum.into(loads, paths))}
  end

  defp type_id(type) do
    case classify(type) do
      %Type{kind: :ref, target: id} -> id
      _ -> nil
    end
  end

  # --- bindings and names ------------------------------------------------------------

  defp bind(st, var, input, type) do
    if Map.has_key?(st.bindings, var),
      do: st,
      else: %{st | bindings: Map.put(st.bindings, var, %{var: var, input: input, type: type})}
  end

  defp variable(kind, ref, bindings) do
    base =
      [
        Atom.to_string(kind)
        | for({_, v} <- Enum.sort(ref), is_binary(v) or is_number(v), do: to_string(v))
      ]
      |> Enum.join("_")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}_#{n}"
    end)
    |> Enum.find(&(not Map.has_key?(bindings, &1)))
  end

  defp atom(name) do
    if Regex.match?(~r/^[a-z_][A-Za-z0-9_]*[?!]?$/, name),
      do: ":" <> name,
      else: ":" <> inspect(name)
  end

  # --- results -------------------------------------------------------------------------

  defp runtime(st, fun, args) do
    if Enum.member?(args, :error) do
      {:error, st}
    else
      {"#{st.runtime}.#{fun}(#{Enum.join(args, ", ")})", %{st | used: MapSet.put(st.used, fun)}}
    end
  end

  # A condition's truth: a condition as compiled (an empty side never
  # holds), any other value only when it is yes.
  defp truth(%IR{op: op} = c, st) when op in @conditions, do: cond(c, st, true)

  defp truth(c, st) do
    {v, st} = value(c, st)
    {ok(v, &"(#{&1} == true)"), st}
  end

  defp ok(:error, _fun), do: :error
  defp ok(part, fun), do: fun.(part)

  defp all_ok(source, parts), do: if(Enum.member?(parts, :error), do: :error, else: source)

  # A construct is `{kind, at}`: `kind` holds no Bubble IDs (reports count
  # it); `at` names the Bubble IDs involved, or nil.
  defp unsupported(st, {_kind, _at} = what),
    do: {:error, %{st | unsupported: [what | st.unsupported]}}

  defp approximate(st, []), do: st
  defp approximate(st, constructs), do: %{st | approximated: constructs ++ st.approximated}

  # Formats compiled with parts the runtime only approximates: the
  # expression compiles, and the diagnostic reports what to check.
  defp approximations(%{approximated: []}, _opts), do: []

  defp approximations(st, opts) do
    constructs = st.approximated |> Enum.uniq() |> Enum.sort()

    [
      Diagnostic.new(
        :elixir_format_approximated,
        Keyword.get(opts, :path, ""),
        "#{Enum.join(constructs, ", ")} only approximated by the runtime; check the rendered text",
        target: :elixir,
        subject: Keyword.get(opts, :subject, %{}),
        details: %{constructs: constructs}
      )
    ]
  end

  defp describe({kind, nil}), do: kind
  defp describe({kind, at}), do: "#{kind} #{inspect(at)}"

  defp diagnostics(st, opts) do
    whats = st.unsupported |> Enum.uniq() |> Enum.sort()
    text = Enum.map_join(whats, "; ", &describe/1)

    [
      Diagnostic.new(
        :elixir_expr_unsupported,
        Keyword.get(opts, :path, ""),
        "#{text} has no Elixir mapping yet; the expression is not compiled",
        target: :elixir,
        subject: Keyword.get(opts, :subject, %{}),
        details: %{
          constructs: whats |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          at: for({_, at} <- whats, at != nil, do: at)
        }
      )
    ]
  end

  # Source of a literal, never truncated (`inspect/1` cuts long strings).
  defp lit(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)
end
