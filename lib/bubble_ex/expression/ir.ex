defmodule BubbleEx.Expression.IR do
  @moduledoc """
  The stack-neutral compiled form of a Bubble expression: what target
  backends (`BubbleEx.Target.Ash.Expressions`, `BubbleEx.Target.Elixir`)
  consume. It is built from a typed AST by `BubbleEx.Expression.Compiler`
  and states Bubble semantics in a small, closed vocabulary, with every
  node's Bubble type (`type`, a descriptor such as `"text"`,
  `"custom.task"`, `"list.user"`, `"option.status"`, or nil when unknown).

      {:ok, %{ir: ir, diagnostics: []}} = BubbleEx.Expression.Compiler.compile(ast, env)

  A node is `%IR{op: op, args: args, type: type}`:

  | `op` | `args` | Bubble |
  |------|--------|--------|
  | `:literal` | `[value]` | a text, number or yes/no |
  | `:empty` | `[]` | an empty value |
  | `:option` | `[option_set, value, key]` | one option: `value` as the expression names it, `key` its stable stored key (`db_value`) from the Model, nil if the Model lacks it |
  | `:all_options` | `[option_set]` | every option of a set |
  | `:current_user` | `[]` | the session's user |
  | `:this` | `[binder]` | `This Thing`: `:rule_record`, `:filter_item` or `:context` (see `Ast.ThisThing`) |
  | `:input` | `[kind, ref]` | a value supplied by context: `:element_state`, `:cell_thing`, `:cell_index`, `:page_thing`, `:parameter`, `:step_result`, `:trigger_thing`, `:page_data` or `:url_parameter`; `ref` holds Bubble IDs with string keys |
  | `:field` | `[record, data_type, field]` | a data-type field (built-in ones by their Bubble names, e.g. `"Created By"`); over a list of records it maps, and `type` is a list |
  | `:option_attribute` | `[option, option_set, attribute]` | an option-set attribute; attribute `"display"` is the option's label |
  | `:external_field` | `[value, external_type, field]` | a field of an API Connector type |
  | `:eq`, `:neq` | `[left, right]` | `is`, `is not`. Bubble semantics: an empty value equals an empty value |
  | `:gt`, `:lt`, `:gte`, `:lte` | `[left, right]` | ordering comparisons |
  | `:and`, `:or` | `[a, b, …]` | flattened; Bubble groups left to right |
  | `:not` | `[x]` | negation |
  | `:is_empty` | `[x]` | empty: no value, an empty text or an empty list |
  | `:logged_in` | `[]` | the current user is logged in |
  | `:member` | `[list, item]` | `list contains item` |
  | `:contains_all` | `[list, list]` | `contains list` |
  | `:count`, `:first`, `:last`, `:unique`, `:as_list` | `[list]` | list operators |
  | `:item_at`, `:limit` | `[list, n]` | `item #`, `items until #` |
  | `:merge`, `:minus_list`, `:intersect`, `:plus_item`, `:minus_item` | `[list, other]` | list algebra |
  | `:sort` | `[list, field, descending?]` | `:sorted` / a search's sort by one field |
  | `:add`, `:sub`, `:mul`, `:div`, `:mod` | `[left, right]` | arithmetic |
  | `:concat` | `[part, …]` | dynamic text: parts in order, each shown as text |
  | `:fallback` | `[x, default]` | `x defaulting to default` |
  | `:lowercase`, `:uppercase`, `:trim`, `:capitalize_words`, `:text_length`, `:json_encode`, `:url_encode`, `:is_email`, `:abs`, `:round`, `:to_text` | `[x]` | text and number operators |
  | `:to_number`, `:format_date` | `[x]` / `[date, format]` | `converted to number`; `formatted as` a date (`format` is Bubble's format text, nil for the default) |
  | `:format_number` | `[number, options]` | `formatted as` a number; `options` are Bubble's settings verbatim |
  | `:format_boolean` | `[x, yes_text, no_text]` | a yes/no `formatted as` text |
  | `:truncate` | `[text, n]` | `truncated to` |
  | `:replace` | `[text, find, replace, regex?]` | `find & replace` |
  | `:split` | `[text, separator]` | `split by` |
  | `:date_add` | `[date, amount, unit]` | `+(seconds)` … `+(years)`; `unit` is `:second`, `:minute`, `:hour`, `:day`, `:month` or `:year` |
  | `:date_floor`, `:date_part` | `[date, unit]` | `rounded down to`, `extract`; `unit` is Bubble's component name |
  | `:text_contains` | `[text, text]` | `text contains string` (substring) |
  | `:text_contains_words` | `[text, text]` | `text contains` (Bubble's keyword match) |
  | `:search` | `[data_type, predicate \\| nil]` | `Do a search for`; the predicate is over `{:this, [:filter_item]}` |
  | `:filter` | `[list, predicate]` | `:filtered` |

  The IR has no target-language names: fields and types are Bubble IDs,
  options carry their stable keys. It is plain data, deterministic and
  JSON-encodable through `to_map/1`.
  """

  @enforce_keys [:op]
  defstruct [:op, args: [], type: nil]

  @type t :: %__MODULE__{op: atom(), args: [term()], type: String.t() | nil}

  @doc "Builds a node."
  @spec node(atom(), [term()], String.t() | nil) :: t()
  def node(op, args \\ [], type \\ nil), do: %__MODULE__{op: op, args: args, type: type}

  @doc "JSON form: `%{\"op\" => …, \"args\" => […], \"type\" => …}` with nested nodes as maps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ir),
    do: %{"op" => Atom.to_string(ir.op), "args" => Enum.map(ir.args, &json/1), "type" => ir.type}

  defp json(%__MODULE__{} = ir), do: to_map(ir)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)
  defp json(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp json(value), do: value

  @doc """
  Every op in `ir`, depth first (for coverage counts). Nested predicates
  and list operands are included.
  """
  @spec ops(t()) :: [atom()]
  def ops(%__MODULE__{op: op, args: args}), do: [op | Enum.flat_map(args, &nested_ops/1)]

  defp nested_ops(%__MODULE__{} = ir), do: ops(ir)
  defp nested_ops(list) when is_list(list), do: Enum.flat_map(list, &nested_ops/1)
  defp nested_ops(_), do: []
end
