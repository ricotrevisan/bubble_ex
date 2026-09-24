defmodule BubbleEx.Expression.Vocabulary do
  @moduledoc false

  # The Bubble operator, source and constraint names the AST models. Anything
  # outside these tables is preserved as a raw node with a diagnostic, so the
  # tables are the single statement of what the AST claims to understand.

  @compare %{
    "equals" => :equals,
    "not_equals" => :not_equals,
    "greater_than" => :greater_than,
    "less_than" => :less_than,
    "greater_or_equal_than" => :greater_or_equal,
    "less_or_equal_than" => :less_or_equal
  }
  @logical %{"and_" => :and, "or_" => :or}
  @arithmetic %{
    "plus" => :plus,
    "minus" => :minus,
    "times" => :times,
    "divide" => :divided_by,
    "modulo" => :modulo
  }
  @check %{
    "is_empty" => :is_empty,
    "is_not_empty" => :is_not_empty,
    "is_true" => :is_true,
    "is_false" => :is_false,
    "logged_in" => :logged_in,
    "not_logged_in" => :logged_out
  }
  # List operators and the operand each takes: none, one expression argument,
  # or sort options held in `properties`.
  @list %{
    "count" => {:count, :none},
    "first_element" => {:first_item, :none},
    "last_element" => {:last_item, :none},
    "unique" => {:unique, :none},
    "convert_to_list" => {:as_list, :none},
    "contains" => {:contains, :arg},
    "not_contains" => {:not_contains, :arg},
    "contains_list" => {:contains_list, :arg},
    "is_contained_by_list" => {:is_contained_by, :arg},
    "is_not_contained_by_list" => {:is_not_contained_by, :arg},
    "specific_item" => {:item_number, :arg},
    "limit_to" => {:limit_to, :arg},
    "merged_with" => {:merged_with, :arg},
    "minus_list" => {:minus_list, :arg},
    "intersect_with" => {:intersect_with, :arg},
    "plus_element" => {:plus_item, :arg},
    "minus_element" => {:minus_item, :arg},
    "sorted" => {:sorted, :options}
  }

  # Sources whose value is fixed by page, element, workflow or API context.
  # Their identifying properties are retained verbatim as the scope reference.
  @scopes %{
    "CurrentPageItem" => :current_page_thing,
    "CurrentWorkflowItem" => :workflow_parameter,
    "APIEventParameter" => :api_parameter,
    "CurrentDataItem" => :current_cell_thing,
    "OldDataItem" => :thing_before_change,
    "CurrentCellsIndex" => :current_cell_index,
    "GetElement" => :element,
    "ElementParent" => :parent_group,
    "ElementAncestor" => :ancestor_group,
    "ThisElement" => :this_element,
    "PreviousStep" => :previous_step,
    "PageData" => :page_data,
    "GetParamFromUrl" => :url_parameter,
    "Breakpoint" => :breakpoint
  }

  @builtin_fields %{
    "Created By" => {:created_by, "user"},
    "Created Date" => {:created_date, "date"},
    "Modified Date" => {:modified_date, "date"},
    "Slug" => {:slug, "text"},
    "_id" => {:unique_id, "text"}
  }

  @constraint_ops %{
    "equals" => :equals,
    "not equal" => :not_equals,
    "is_empty" => :is_empty,
    "empty" => :is_empty,
    "is_not_empty" => :is_not_empty,
    "not empty" => :is_not_empty,
    "greater than" => :greater_than,
    "less than" => :less_than,
    "gte" => :greater_or_equal,
    "lte" => :less_or_equal,
    "in" => :in,
    "not in" => :not_in,
    "contains" => :contains,
    "not contains" => :not_contains,
    "text contains" => :text_contains,
    "not text contains" => :not_text_contains,
    "text contains string" => :text_contains_string,
    "email_equals" => :email_equals
  }

  # Editor bookkeeping carried on expression objects (plus `*_friendly`
  # captions). Retained for round-trip fidelity but carries no expression
  # semantics, so it is not diagnosed.
  @metadata ~w(is_slidable said moved_to_top)

  @type operator ::
          {:compare, atom()}
          | {:logical, atom()}
          | {:arithmetic, atom()}
          | {:check, atom()}
          | {:list, atom(), :none | :arg | :options}
          | :filtered
          | :fallback
          | nil

  @spec operator(String.t()) :: operator()
  def operator(name) do
    cond do
      op = @compare[name] -> {:compare, op}
      op = @logical[name] -> {:logical, op}
      op = @arithmetic[name] -> {:arithmetic, op}
      op = @check[name] -> {:check, op}
      spec = @list[name] -> Tuple.insert_at(spec, 0, :list)
      name == "filtered" -> :filtered
      name == "defaulting_to" -> :fallback
      true -> nil
    end
  end

  @doc "Bubble operator name for an AST operator of the given class."
  @spec operator_name(atom(), atom()) :: String.t()
  def operator_name(:compare, op), do: name_for(@compare, op)
  def operator_name(:logical, op), do: name_for(@logical, op)
  def operator_name(:arithmetic, op), do: name_for(@arithmetic, op)
  def operator_name(:check, op), do: name_for(@check, op)

  def operator_name(:list, op),
    do: Enum.find_value(@list, fn {name, {o, _}} -> if o == op, do: name end)

  @spec scope(String.t()) :: atom() | nil
  def scope(type), do: @scopes[type]

  @spec builtin_field(String.t()) :: {atom(), String.t()} | nil
  def builtin_field(name), do: @builtin_fields[name]

  @spec constraint_op(String.t()) :: atom() | nil
  def constraint_op(name), do: @constraint_ops[name]

  @spec constraint_name(atom()) :: String.t() | nil
  def constraint_name(op), do: name_for(@constraint_ops, op)

  @spec metadata_key?(String.t()) :: boolean()
  def metadata_key?(key), do: key in @metadata or String.ends_with?(key, "_friendly")

  # Several Bubble spellings can share one operator; prefer the most explicit.
  defp name_for(table, op) do
    table
    |> Enum.filter(fn {_, o} -> o == op end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort_by(&{String.length(&1), &1})
    |> List.last()
  end
end
