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
  `get_in(x, [Access.key(:a), Access.key(:b)])`. Records are compared by
  Bubble ID. Empty values follow `BubbleEx.Target.Ash.Expressions`: a
  comparison with a value read from the current user is false when that
  value is empty, in either polarity (negation is pushed down to the
  comparisons); between other values empty equals empty (not verified
  against Bubble), and an empty text (`""`) is empty, so `"" is nil`
  (WTF-514; Bubble has no empty text apart from empty, inferred, not
  replayed; the generated privacy policies keep `""` and nil apart, the
  stricter reading); an empty list contains nothing; `not` of an empty yes/no
  is true; `x is not y` between yes/no values (not conditions), one at
  least stored, reads an empty one as no, as Bubble does (`x is not no` needs a stored yes,
  WTF-471), while `x is y` keeps empty equal only to empty; a comparison
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
  | `format_date(x, format[, zone])`, `format_number(x, options)`, `date_floor(x, unit[, zone])`, `date_part(x, unit[, zone])`, `date_add(x, n, unit)` | Bubble's date and number formats and calendar operators (`BubbleEx.Target.Elixir.Formats`); `zone` only when the expression names one |
  | `format_boolean(x, yes, no)`, `truncate(x, n)`, `replace(x, find, replace, regex?)`, `split(x, sep)`, `text_contains?(a, b)`, `text_contains_words?(a, b)` | the other formatting and text operators |

  List algebra (`:merged with`, `:unique elements`, `:minus list`,
  `:intersect with`, `:plus item`, `:minus item`, `:items until #`, `:item
  #`, `:converted to list`, WTF-495) calls the runtime (`merge/2`, …),
  which compares things by Bubble ID, records and IDs alike; `:filtered`
  over options, texts, numbers or dates is `Enum.filter/2` with the
  constraints per item (`item`); `:sorted` on texts, numbers or dates is
  `sort_values(list, descending?)`. An option's label or attribute of a list
  of options maps over it (a list attribute of each is one list of their
  items).

  Data shapes never raise (WTF-500): every list read (`count`, `:first
  item`, `contains`, `:filtered`, a list of options or files) goes through
  the runtime's `as_list/1`, so an empty value or a field the user may not
  view (`%Ash.ForbiddenField{}`, `empty?/1`) is an empty list, and the
  current user's operands are checked with `empty?/1`; a field of a list of
  things (a search read first) is each item's, one list of their values.

  Not compiled yet (diagnosed with `:elixir_expr_unsupported`, stage
  `{:target, :elixir}`): searches, and `:filtered` or sorting of a list of
  things (these become Ash queries, `FrontendWorkflows.Lists`), other
  sorting by a field, API type fields, fields of the items of a list-of-things field
  (stored as a list of IDs).

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
  alias BubbleEx.Target.Elixir.Formats

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
                    is_email abs round to_text to_number)a
  @arithmetic ~w(add sub mul div mod)a
  @list_ops ~w(as_list unique merge minus_list intersect plus_item minus_item limit item_at)a
  @conditions ~w(eq neq gt lt gte lte and or not is_empty logged_in member text_contains
                 text_contains_words)a
  @boolean_values [:field, :input, :fallback, :option_attribute, :option_label]
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

    {source, st} = ir |> value(st) |> shown_file(ir)

    if source == :error or st.unsupported != [] do
      %{source: nil, bindings: [], loads: %{}, runtime: [], diagnostics: diagnostics(st, opts)}
    else
      formatted = source |> Code.format_string!() |> IO.iodata_to_binary()

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
    %{types: types, enums: enums}
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

  # A condition used as a value: strictly true or false, never nil (WTF-471).
  defp value(%IR{op: op} = ir, st) when op in @conditions do
    {c, st} = cond(ir, st, true)
    {ok(c, &"(#{&1} == true)"), st}
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

  defp value(%IR{op: op, args: [l, r]}, st) when op in @arithmetic do
    {[a, b], st} = Enum.map_reduce([l, r], st, &value/2)
    runtime(st, op, [a, b])
  end

  defp value(%IR{op: :concat, args: parts}, st) do
    {texts, st} =
      Enum.map_reduce(parts, st, fn
        %IR{op: :literal, args: [text]}, st when is_binary(text) -> {lit(text), st}
        part, st -> part |> value(st) |> shown_file(part) |> then(fn {p, st} -> text(p, st) end)
      end)

    {all_ok("(" <> Enum.join(texts, " <> ") <> ")", texts), st}
  end

  defp value(%IR{op: :fallback, args: [x, d]}, st) do
    {[a, b], st} = Enum.map_reduce([x, d], st, &value/2)
    runtime(st, :default, [a, b])
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

  defp yes_no_neq(%IR{op: :literal, args: [false]}, _r, _a, b), do: "(#{b} == true)"
  defp yes_no_neq(_l, %IR{op: :literal, args: [false]}, a, _b), do: "(#{a} == true)"
  defp yes_no_neq(%IR{op: :literal}, _r, a, b), do: "(#{a} != #{b})"
  defp yes_no_neq(_l, %IR{op: :literal}, a, b), do: "(#{a} != #{b})"
  defp yes_no_neq(_l, _r, a, b), do: "((#{a} == true) != (#{b} == true))"

  defp yes_no_pair?(l, r),
    do: (stored_yes_no?(l) or stored_yes_no?(r)) and yes_no_side?(l) and yes_no_side?(r)

  defp stored_yes_no?(%IR{op: op, type: "boolean"}), do: op in @boolean_values
  defp stored_yes_no?(_ir), do: false

  defp yes_no_side?(%IR{op: :literal, args: [b]}), do: is_boolean(b)
  defp yes_no_side?(ir), do: stored_yes_no?(ir)

  # Two yes/no sides, one a condition: expanded so that each side keeps its
  # own polarities and guards (a stored yes/no side is `== true` / `==
  # false`: empty is neither). A condition's negation is not always its
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

    eq = "(#{a} == #{b})"

    # WTF-471: between yes/no values with a stored side, `is not` reads an
    # empty one as no, as Bubble does (`x is not no` needs a stored yes);
    # `is` keeps empty equal only to empty (stricter against no).
    neq = if yes_no_pair?(l, r), do: yes_no_neq(l, r, a, b), else: "(#{a} != #{b})"

    {pos, neg} = if op == :eq, do: {eq, neq}, else: {neq, eq}
    {all_ok({pos, neg, [{l, a}, {r, b}]}, [a, b]), st}
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
    if member_list?(list) do
      {[l, i], st} = Enum.map_reduce([list, item], st, &id_value/2)
      {items, st} = as_list(l, st)
      member = "Enum.member?(#{items}, #{i})"
      {all_ok({member, "not #{member}", [{list, l}, {item, i}]}, [items, i]), st}
    else
      unsupported(st, {"contains on a list of records", nil})
    end
  end

  defp atom_(%IR{op: op, args: args}, st) when op in [:text_contains, :text_contains_words] do
    {parts, st} = Enum.map_reduce(args, st, &value/2)
    {found, st} = runtime(st, :"#{op}?", parts)
    {all_ok({found, ok(found, &"not #{&1}"), Enum.zip(args, parts)}, [found]), st}
  end

  # A yes/no value that may be empty: empty is not yes.
  defp atom_(%IR{op: op} = ir, st) when op in @boolean_values do
    {part, st} = value(ir, st)
    {all_ok({"(#{part} == true)", "(#{part} != true)", [{ir, part}]}, [part]), st}
  end

  defp atom_(%IR{op: op}, st), do: unsupported(st, {"#{op}", nil})

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
    base_type = type_id(base.type)

    case keys(steps, base_type, mode, st) do
      {:ok, [], _loads, _list_id_key} ->
        {var, st}

      {:ok, keys, loads, list_id_key} ->
        st = if loads == [], do: st, else: add_load(st, var, loads)
        access = "[" <> Enum.map_join(keys, ", ", &"Access.key(#{atom(&1)})") <> "]"

        # A field of a list of things (a search read first, an input's
        # list) is each item's (WTF-500), as Bubble's `each item's`: one
        # list of every item's values, empty ones dropped. `get_in/2` on
        # the list itself raises.
        {read, st} =
          if thing_list?(base.type) do
            {each, st} = field_value("get_in(thing, #{access})", list_id_key, st)
            {each, st} = as_list(each, st)
            {items, st} = as_list(var, st)
            {"Enum.flat_map(#{items}, fn thing -> #{each} end)", st}
          else
            field_value("get_in(#{var}, #{access})", list_id_key, st)
          end

        {read, st}

      {:error, what} ->
        unsupported(st, what)
    end
  end

  # A field's value read by `path`: a list of things stored as their
  # records is its items' IDs (`list_id_key`).
  defp field_value(path, nil, st), do: {path, st}

  defp field_value(path, list_id_key, st) do
    {items, st} = as_list(path, st)
    {"Enum.map(#{items}, &Map.get(&1, #{atom(list_id_key)}))", st}
  end

  # Access keys for a field chain. Relationship steps need loading; the
  # last step is its attribute, or in `:id` mode a reference's `_id`
  # attribute (no load); in `:value` mode a reference is its relationship.
  defp keys([], type, :id, st) do
    case st.lookup.types[type] do
      %{pk: pk} -> {:ok, [pk], [], nil}
      nil -> {:error, {"an unmapped data type", type}}
    end
  end

  defp keys([], _type, :value, _st), do: {:ok, [], [], nil}

  defp keys(steps, _type, mode, st) do
    {init, [{last_type, last_field}]} = Enum.split(steps, -1)

    with {:ok, rels} <- relationships(init, st),
         {:ok, info} <- field_info(last_type, last_field, st) do
      last =
        if mode == :value and info.relationship,
          do: info.relationship,
          else: info.attribute

      loads = if mode == :value and info.relationship, do: rels ++ [last], else: rels

      {:ok, rels ++ [last], if(loads == [], do: [], else: [loads]),
       if(mode == :value, do: info[:list_id_key])}
    end
  end

  defp relationships(steps, st) do
    Enum.reduce_while(steps, {:ok, []}, fn {type, field}, {:ok, rels} ->
      case field_info(type, field, st) do
        {:ok, %{relationship: rel, list_id_key: _}} when is_binary(rel) ->
          {:halt, {:error, {"a path through a list or value", "#{type}.#{field}"}}}

        {:ok, %{relationship: rel}} when is_binary(rel) ->
          {:cont, {:ok, rels ++ [rel]}}

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
