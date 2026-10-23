defmodule BubbleEx.Js.Parser do
  @moduledoc """
  Checks that an app author's script is valid JavaScript as the body of a
  function in a strict-mode module (WTF-608): a generated hook embeds it,
  and one syntax error would stop every script of the page (the module
  would not load). A validator for a subset, not a full parser: what it
  accepts is valid JavaScript; much valid JavaScript it refuses, and the
  script then goes to a developer.

  The subset: `var` / `let` / `const` (with object and array patterns),
  function declarations and expressions, arrows, `async` / `await`, `if`,
  `for` (with `in` / `of`), `while`, `do`, `switch`, `try`, `return`,
  `break`, `continue`, `throw`, expressions with every operator, object
  and array literals (methods, getters, setters, computed keys, spread),
  template literals, optional chaining, automatic semicolon insertion.

  Refused: classes, generators, labels, regular expression literals,
  `import` / `export`, `new.target`, `super`, destructuring assignment
  (outside declarations), legacy octal numbers and escapes, non-ASCII
  names, strict-mode reserved words as names, `eval` / `arguments` as
  bindings, `delete` of a name, duplicate parameters, duplicate or
  clashing block-scoped declarations, `const` without a value, `break` /
  `continue` outside a loop or switch, `await` outside an async function.
  """

  alias BubbleEx.Js.Lexer

  # Words a strict-mode module never takes as a name.
  @reserved ~w(break case catch class const continue debugger default delete do else enum export
               extends false finally for function if import in instanceof new null return super
               switch this throw true try typeof var void while with implements interface let
               package private protected public static yield await)

  @assign_ops ~w(= += -= *= /= %= **= <<= >>= >>>= &= |= ^= &&= ||= ??=)

  @binary [
    {["??"], 1},
    {["||"], 2},
    {["&&"], 3},
    {["|"], 4},
    {["^"], 5},
    {["&"], 6},
    {["==", "!=", "===", "!=="], 7},
    {["<", ">", "<=", ">=", "instanceof", "in"], 8},
    {["<<", ">>", ">>>"], 9},
    {["+", "-"], 10},
    {["*", "/", "%"], 11},
    {["**"], 12}
  ]

  @precedence for {ops, p} <- @binary, op <- ops, into: %{}, do: {op, p}

  @doc """
  `:ok` when `tokens` (`BubbleEx.Js.Lexer.tokens/1`) are a valid body of a
  plain (not async) function in strict mode, within the subset.
  """
  @spec check([Lexer.token()]) :: :ok | {:error, String.t()}
  def check(tokens) when is_list(tokens) do
    st = %{
      t: List.to_tuple(tokens),
      async: false,
      loops: 0,
      switches: 0,
      # The generated function takes `properties` (Toolbox's inputs): a
      # `let` or `const` of that name would clash with it.
      scopes: [new_scope(true, ["properties"])]
    }

    {_i, _st} = statements(st, 0, :eof)
    :ok
  catch
    {:js, why} -> {:error, why}
  end

  defp fail(why), do: throw({:js, why})

  # --- statements -------------------------------------------------------------

  defp statements(st, i, until) do
    case peek(st, i) do
      nil when until == :eof ->
        {i, st}

      {:punct, "}", _} when until == :block ->
        {i, st}

      nil ->
        fail("an unclosed block")

      _ ->
        {i, st} = statement(st, i)
        statements(st, i, until)
    end
  end

  defp statement(st, i), do: statement(peek(st, i), st, i)

  defp statement({:punct, "{", _}, st, i), do: block(st, i)
  defp statement({:punct, ";", _}, st, i), do: {i + 1, st}

  defp statement({:ident, kw, _}, st, i) when kw in ["var", "let", "const"] do
    {i, st} = declaration(st, i + 1, kw, :statement)
    {semicolon(st, i), st}
  end

  defp statement({:ident, "function", _}, st, i), do: function(st, i + 1, false, :declaration)

  defp statement({:ident, "async", _}, st, i) do
    if ident?(peek(st, i + 1), "function") and not nl?(peek(st, i + 1)),
      do: function(st, i + 2, true, :declaration),
      else: expression_statement(st, i)
  end

  defp statement({:ident, "if", _}, st, i) do
    {i, st} = parenthesized(st, i + 1)
    {i, st} = sub_statement(st, i)
    if ident?(peek(st, i), "else"), do: sub_statement(st, i + 1), else: {i, st}
  end

  defp statement({:ident, "for", _}, st, i), do: for_statement(st, i + 1)

  defp statement({:ident, "while", _}, st, i) do
    {i, st} = parenthesized(st, i + 1)
    loop_body(st, i)
  end

  defp statement({:ident, "do", _}, st, i) do
    {i, st} = loop_body(st, i + 1)
    {i, st} = parenthesized(st, expect_ident(st, i, "while"))
    {if(punct?(peek(st, i), ";"), do: i + 1, else: i), st}
  end

  defp statement({:ident, "return", _}, st, i) do
    if ends_statement?(st, i + 1) do
      {semicolon(st, i + 1), st}
    else
      {i, st} = expression(st, i + 1)
      {semicolon(st, i), st}
    end
  end

  defp statement({:ident, kw, _}, st, i) when kw in ["break", "continue"] do
    cond do
      kw == "break" and st.loops == 0 and st.switches == 0 -> fail("a break outside a loop")
      kw == "continue" and st.loops == 0 -> fail("a continue outside a loop")
      match?({:ident, _, %{nl: false}}, peek(st, i + 1)) -> fail("a label")
      true -> {semicolon(st, i + 1), st}
    end
  end

  defp statement({:ident, "throw", _}, st, i) do
    if nl?(peek(st, i + 1)), do: fail("a line break after throw")
    {i, st} = expression(st, i + 1)
    {semicolon(st, i), st}
  end

  defp statement({:ident, "try", _}, st, i), do: try_statement(st, i + 1)
  defp statement({:ident, "switch", _}, st, i), do: switch_statement(st, i + 1)

  defp statement({:ident, kw, _}, _st, _i)
       when kw in ["class", "import", "export", "with", "debugger"],
       do: fail("#{kw}")

  defp statement({:ident, _name, _}, st, i) do
    if punct?(peek(st, i + 1), ":"), do: fail("a label"), else: expression_statement(st, i)
  end

  defp statement(_token, st, i), do: expression_statement(st, i)

  # `( expression )`.
  defp parenthesized(st, i) do
    {i, st} = expression(st, expect(st, i, "("))
    {expect(st, i, ")"), st}
  end

  # The statement of an `if` / `else`: a declaration there is not allowed.
  defp sub_statement(st, i) do
    case peek(st, i) do
      {:ident, kw, _} when kw in ["let", "const", "function", "class"] ->
        fail("a declaration as the body of if")

      _ ->
        statement(st, i)
    end
  end

  defp loop_body(st, i) do
    {i, st2} = sub_statement(%{st | loops: st.loops + 1}, i)
    {i, %{st2 | loops: st.loops}}
  end

  defp block(st, i) do
    i = expect(st, i, "{")
    st = push_scope(st, false)
    {i, st} = statements(st, i, :block)
    {expect(st, i, "}"), pop_scope(st)}
  end

  defp expression_statement(st, i) do
    {i, st} = expression(st, i)
    {semicolon(st, i), st}
  end

  # Automatic semicolon insertion: a `;`, or a `}`, the end, or a line
  # break before the next token.
  defp semicolon(st, i) do
    case peek(st, i) do
      {:punct, ";", _} -> i + 1
      nil -> i
      {:punct, "}", _} -> i
      {_, _, %{nl: true}} -> i
      other -> fail("an unexpected #{describe(other)}")
    end
  end

  defp ends_statement?(st, i) do
    case peek(st, i) do
      nil -> true
      {:punct, p, _} when p in [";", "}"] -> true
      {_, _, %{nl: true}} -> true
      _ -> false
    end
  end

  defp for_statement(st, i) do
    i = expect(st, i, "(")
    st = push_scope(st, false)

    {i, st} =
      case peek(st, i) do
        {:punct, ";", _} ->
          for_rest(st, i + 1)

        {:ident, kw, _} when kw in ["var", "let", "const"] ->
          {j, st, kind} = for_declaration(st, i + 1, kw)
          if kind == :each, do: for_each(st, j), else: for_rest(st, expect(st, j, ";"))

        _ ->
          {j, st, target?} = expression_no_in(st, i)
          for_expression_rest(st, j, target?)
      end

    {i, st} = loop_body(st, expect(st, i, ")"))
    {i, pop_scope(st)}
  end

  defp for_expression_rest(st, j, target?) do
    case peek(st, j) do
      {:ident, kw, _} when kw in ["of", "in"] ->
        unless target?, do: fail("an invalid for-in target")
        for_each(st, j)

      _ ->
        for_rest(st, expect(st, j, ";"))
    end
  end

  # `for (let x of …)` or `for (let i = 0; …`.
  defp for_declaration(st, i, kw) do
    {j, st, names} = binding(st, i)

    case peek(st, j) do
      {:ident, each, _} when each in ["of", "in"] ->
        {j, declare(st, kw, names), :each}

      _ ->
        {j, st} = declarator_rest(st, j, kw, names, :for)
        {j, st} = more_declarators(st, j, kw, :for)
        {j, st, :plain}
    end
  end

  defp for_each(st, i) do
    case peek(st, i) do
      {:ident, "of", _} -> assignment(st, i + 1)
      {:ident, "in", _} -> expression(st, i + 1)
    end
  end

  defp for_rest(st, i) do
    {i, st} = if punct?(peek(st, i), ";"), do: {i, st}, else: expression(st, i)
    i = expect(st, i, ";")
    if punct?(peek(st, i), ")"), do: {i, st}, else: expression(st, i)
  end

  defp try_statement(st, i) do
    {i, st} = block(st, i)

    {i, st, caught?} =
      if ident?(peek(st, i), "catch") do
        i = i + 1

        if punct?(peek(st, i), "(") do
          st = push_scope(st, false)
          {j, st, names} = binding(st, i + 1)
          st = declare(st, "let", names)
          j = expect(st, j, ")")
          {j, st} = function_body_block(st, j)
          {j, pop_scope(st), true}
        else
          {j, st} = block(st, i)
          {j, st, true}
        end
      else
        {i, st, false}
      end

    cond do
      ident?(peek(st, i), "finally") -> block(st, i + 1)
      caught? -> {i, st}
      true -> fail("a try without catch or finally")
    end
  end

  # A catch's block shares the catch binding's scope for clashes.
  defp function_body_block(st, i) do
    i = expect(st, i, "{")
    {i, st} = statements(st, i, :block)
    {expect(st, i, "}"), st}
  end

  defp switch_statement(st, i) do
    i = expect(st, i, "(")
    {i, st} = expression(st, i)
    i = expect(st, i, ")")
    i = expect(st, i, "{")
    st = push_scope(%{st | switches: st.switches + 1}, false)
    {i, st} = cases(st, i, false)
    st = pop_scope(st)
    {expect(st, i, "}"), %{st | switches: st.switches - 1}}
  end

  defp cases(st, i, default?) do
    case peek(st, i) do
      {:punct, "}", _} ->
        {i, st}

      {:ident, "case", _} ->
        {i, st} = expression(st, i + 1)
        {i, st} = case_body(st, expect(st, i, ":"))
        cases(st, i, default?)

      {:ident, "default", _} ->
        if default?, do: fail("two defaults in a switch")
        {i, st} = case_body(st, expect(st, i + 1, ":"))
        cases(st, i, true)

      other ->
        fail("an unexpected #{describe(other)} in a switch")
    end
  end

  defp case_body(st, i) do
    case peek(st, i) do
      {:punct, "}", _} ->
        {i, st}

      {:ident, kw, _} when kw in ["case", "default"] ->
        {i, st}

      nil ->
        fail("an unclosed switch")

      _ ->
        {i, st} = statement(st, i)
        case_body(st, i)
    end
  end

  # --- declarations -------------------------------------------------------------

  defp declaration(st, i, kw, where) do
    {j, st, names} = binding(st, i)
    {j, st} = declarator_rest(st, j, kw, names, where)
    more_declarators(st, j, kw, where)
  end

  defp more_declarators(st, i, kw, where) do
    if punct?(peek(st, i), ","), do: declaration(st, i + 1, kw, where), else: {i, st}
  end

  defp declarator_rest(st, i, kw, names, where) do
    st = declare(st, kw, names)

    if punct?(peek(st, i), "=") do
      if where == :for, do: assignment_no_in(st, i + 1), else: assignment(st, i + 1)
    else
      if kw == "const", do: fail("a const without a value")
      if names.pattern?, do: fail("a pattern without a value")
      {i, st}
    end
  end

  # A binding: a name or an object / array pattern. Returns the names.
  defp binding(st, i) do
    case peek(st, i) do
      {:ident, name, _} ->
        binding_name(name)
        {i + 1, st, %{names: [name], pattern?: false}}

      {:punct, "{", _} ->
        {j, st, names} = object_pattern(st, i + 1, [])
        {j, st, %{names: names, pattern?: true}}

      {:punct, "[", _} ->
        {j, st, names} = array_pattern(st, i + 1, [])
        {j, st, %{names: names, pattern?: true}}

      other ->
        fail("an unexpected #{describe(other)} where a name belongs")
    end
  end

  defp binding_name(name) do
    cond do
      name in @reserved -> fail("the reserved word #{name} as a name")
      name in ["eval", "arguments"] -> fail("#{name} as a name")
      not ascii_name?(name) -> fail("a non-ASCII name")
      true -> :ok
    end
  end

  defp object_pattern(st, i, acc) do
    case peek(st, i) do
      {:punct, "}", _} ->
        {i + 1, st, acc}

      {:punct, "...", _} ->
        {j, st, %{names: names}} = binding(st, i + 1)
        {expect(st, j, "}"), st, acc ++ names}

      _ ->
        {j, st, key_name} = property_key(st, i)
        {j, st, names} = pattern_binding(st, j, key_name)

        {j, st} = if punct?(peek(st, j), "="), do: assignment(st, j + 1), else: {j, st}
        pattern_next(st, j, "}", acc ++ names, &object_pattern/3)
    end
  end

  # A property of an object pattern: `key: binding`, or a shorthand.
  defp pattern_binding(st, j, key_name) do
    cond do
      punct?(peek(st, j), ":") ->
        {j, st, %{names: names}} = binding(st, j + 1)
        {j, st, names}

      key_name == nil ->
        fail("a computed key without a binding")

      true ->
        binding_name(key_name)
        {j, st, [key_name]}
    end
  end

  defp array_pattern(st, i, acc) do
    case peek(st, i) do
      {:punct, "]", _} ->
        {i + 1, st, acc}

      {:punct, ",", _} ->
        array_pattern(st, i + 1, acc)

      {:punct, "...", _} ->
        {j, st, %{names: names}} = binding(st, i + 1)
        {expect(st, j, "]"), st, acc ++ names}

      _ ->
        {j, st, %{names: names}} = binding(st, i)
        {j, st} = if punct?(peek(st, j), "="), do: assignment(st, j + 1), else: {j, st}
        pattern_next(st, j, "]", acc ++ names, &array_pattern/3)
    end
  end

  defp pattern_next(st, j, close, acc, next) do
    case peek(st, j) do
      {:punct, ^close, _} -> {j + 1, st, acc}
      {:punct, ",", _} -> next.(st, j + 1, acc)
      other -> fail("an unexpected #{describe(other)} in a pattern")
    end
  end

  # --- functions ----------------------------------------------------------------

  # After `function` (and `async`): a name (a declaration needs one), its
  # parameters and body.
  defp function(st, i, async?, kind) do
    if punct?(peek(st, i), "*"), do: fail("a generator")

    {i, st} =
      case peek(st, i) do
        {:ident, name, _} ->
          binding_name(name)
          st = if kind == :declaration, do: declare(st, "function", [name]), else: st
          {i + 1, st}

        _ ->
          if kind == :declaration, do: fail("a function without a name")
          {i, st}
      end

    function_rest(st, i, async?)
  end

  # Parameters `(…)` and a body `{…}`.
  defp function_rest(st, i, async?) do
    i = expect(st, i, "(")
    {i, st, names} = parameters(st, i, [])
    i = expect(st, i, "{")
    function_body(st, i, async?, names)
  end

  defp parameters(st, i, acc) do
    case peek(st, i) do
      {:punct, ")", _} ->
        {i + 1, st, acc}

      {:punct, "...", _} ->
        {j, st, %{names: names}} = binding(st, i + 1)
        {expect(st, j, ")"), st, acc ++ names}

      _ ->
        {j, st, %{names: names}} = binding(st, i)
        {j, st} = if punct?(peek(st, j), "="), do: assignment(st, j + 1), else: {j, st}

        case peek(st, j) do
          {:punct, ")", _} -> {j + 1, st, acc ++ names}
          {:punct, ",", _} -> parameters(st, j + 1, acc ++ names)
          other -> fail("an unexpected #{describe(other)} in parameters")
        end
    end
  end

  # A function's body (after its `{`): a scope of its own, its
  # parameters declared, no loop or switch around it.
  defp function_body(st, i, async?, params) do
    if length(Enum.uniq(params)) != length(params), do: fail("a duplicate parameter")

    inner = %{
      st
      | async: async?,
        loops: 0,
        switches: 0,
        scopes: [new_scope(true, params) | st.scopes]
    }

    {i, inner} = statements(inner, i, :block)
    i = expect(inner, i, "}")
    {i, %{st | scopes: st.scopes}}
  end

  # --- expressions ----------------------------------------------------------------

  defp expression(st, i) do
    {i, st} = assignment(st, i)
    if punct?(peek(st, i), ","), do: expression(st, i + 1), else: {i, st}
  end

  # A for statement's first part: no `in` operator; whether it is a
  # simple target (for-in / for-of).
  defp expression_no_in(st, i) do
    {j, st, kind} = assign_expr(st, i, false)

    if punct?(peek(st, j), ",") do
      {j, st} = expression(%{st | scopes: st.scopes}, j + 1)
      {j, st, false}
    else
      {j, st, kind == :target}
    end
  end

  defp assignment(st, i) do
    {i, st, _kind} = assign_expr(st, i, true)
    {i, st}
  end

  defp assignment_no_in(st, i) do
    {i, st, _kind} = assign_expr(st, i, false)
    {i, st}
  end

  # Returns the kind of what it read: `:target` (a name or a member) or
  # `:value`.
  defp assign_expr(st, i, in?) do
    if arrow?(st, i) do
      {j, st} = arrow(st, i)
      {j, st, :value}
    else
      {j, st, kind} = conditional(st, i, in?)
      assign_rest(st, j, kind, in?)
    end
  end

  defp assign_rest(st, j, kind, in?) do
    case peek(st, j) do
      {:punct, op, _} when op in @assign_ops ->
        unless kind == :target, do: fail("an invalid assignment target")
        {j, st} = if in?, do: assignment(st, j + 1), else: assignment_no_in(st, j + 1)
        {j, st, :value}

      _ ->
        {j, st, kind}
    end
  end

  # `x =>`, `(…) =>`, `async x =>`, `async (…) =>` (no line break before
  # the arrow).
  defp arrow?(st, i) do
    case peek(st, i) do
      {:ident, "async", _} ->
        not nl?(peek(st, i + 1)) and arrow_head?(st, i + 1)

      _ ->
        arrow_head?(st, i)
    end
  end

  defp arrow_head?(st, i) do
    case peek(st, i) do
      {:ident, name, _} when name not in @reserved ->
        arrow_token?(peek(st, i + 1))

      {:punct, "(", _} ->
        case close_paren(st, i) do
          nil -> false
          close -> arrow_token?(peek(st, close + 1))
        end

      _ ->
        false
    end
  end

  defp arrow_token?({:punct, "=>", %{nl: false}}), do: true
  defp arrow_token?(_), do: false

  defp arrow(st, i) do
    {async?, i} = if ident?(peek(st, i), "async"), do: {true, i + 1}, else: {false, i}

    {i, st, params} =
      case peek(st, i) do
        {:ident, name, _} ->
          binding_name(name)
          {i + 1, st, [name]}

        {:punct, "(", _} ->
          parameters(st, i + 1, [])
      end

    i = expect(st, i, "=>")

    if punct?(peek(st, i), "{") do
      function_body(st, i + 1, async?, params)
    else
      if length(Enum.uniq(params)) != length(params), do: fail("a duplicate parameter")

      inner = %{st | async: async?, scopes: [new_scope(true, params) | st.scopes]}
      {j, _inner} = assignment(inner, i)
      {j, st}
    end
  end

  defp conditional(st, i, in?) do
    {j, st, kind} = binary(st, i, 0, in?)

    if punct?(peek(st, j), "?") do
      {j, st} = assignment(st, j + 1)
      j = expect(st, j, ":")
      {j, st} = if in?, do: assignment(st, j), else: assignment_no_in(st, j)
      {j, st, :value}
    else
      {j, st, kind}
    end
  end

  # Precedence climbing over the binary operators.
  defp binary(st, i, min, in?) do
    {i, st, kind} = unary(st, i)
    binary_rest(st, i, min, in?, kind)
  end

  defp binary_rest(st, i, min, in?, kind) do
    op = binary_op(peek(st, i))
    p = op && @precedence[op]

    cond do
      p == nil or p <= min or (op == "in" and not in?) ->
        {i, st, kind}

      op == "**" ->
        # Right-associative.
        {j, st, _} = binary(st, i + 1, p - 1, in?)
        binary_rest(st, j, min, in?, {:op, op})

      true ->
        {j, st, right} = binary(st, i + 1, p, in?)
        mixed_coalesce(op, kind, right)
        binary_rest(st, j, min, in?, {:op, op})
    end
  end

  defp binary_op({:punct, p, _}), do: p
  defp binary_op({:ident, w, _}) when w in ["instanceof", "in"], do: w
  defp binary_op(_token), do: nil

  # `a ?? b || c` (and `a || b ?? c`) without parentheses is a syntax error.
  defp mixed_coalesce(op, left, right) do
    others = if op == "??", do: ["||", "&&"], else: ["??"]

    if op in ["??", "||", "&&"] and
         Enum.any?([left, right], fn
           {:op, o} -> o in others
           _ -> false
         end),
       do: fail("?? mixed with || or && without parentheses")
  end

  defp unary(st, i), do: unary(peek(st, i), st, i)

  defp unary({:punct, p, _}, st, i) when p in ["++", "--"] do
    {j, st, kind} = unary(st, i + 1)
    unless kind == :target, do: fail("an invalid #{p} target")
    {j, st, :value}
  end

  defp unary(token, st, i) do
    if prefix?(token, st, i) do
      {j, st, _} = unary(st, i + 1)
      no_exponent(st, j)
    else
      postfix(st, i)
    end
  end

  # A prefix operator (`!`, `-`, `typeof`, `await`, …), checked.
  defp prefix?({:punct, p, _}, _st, _i), do: p in ["!", "~", "+", "-"]

  defp prefix?({:ident, "delete", _}, st, i) do
    unless match?({:ident, _, _}, peek(st, i + 1)) and member_follows?(st, i + 2),
      do: fail("delete of anything but a member")

    true
  end

  defp prefix?({:ident, "await", _}, st, _i) do
    unless st.async, do: fail("await outside an async function")
    true
  end

  defp prefix?({:ident, w, _}, _st, _i), do: w in ["typeof", "void"]
  defp prefix?(_token, _st, _i), do: false

  # `-a ** b` is a syntax error.
  defp no_exponent(st, j) do
    if punct?(peek(st, j), "**"), do: fail("a unary operator before **"), else: {j, st, :value}
  end

  defp member_follows?(st, i), do: match?({:punct, p, _} when p in [".", "[", "?."], peek(st, i))

  defp postfix(st, i) do
    {j, st, kind} = left_hand(st, i)

    case peek(st, j) do
      {:punct, p, %{nl: false}} when p in ["++", "--"] ->
        unless kind == :target, do: fail("an invalid #{p} target")
        {j + 1, st, :value}

      _ ->
        {j, st, kind}
    end
  end

  # A primary expression and its members, calls and tagged templates.
  defp left_hand(st, i) do
    {i, st, kind} =
      case peek(st, i) do
        {:ident, "new", _} -> new_expression(st, i + 1)
        _ -> primary(st, i)
      end

    members(st, i, kind, false)
  end

  defp new_expression(st, i) do
    if punct?(peek(st, i), "."), do: fail("new.target")

    {i, st, _} =
      case peek(st, i) do
        {:ident, "new", _} -> new_expression(st, i + 1)
        _ -> primary(st, i)
      end

    {i, st} = callee_members(st, i)

    if punct?(peek(st, i), "("),
      do: (fn {j, st} -> {j, st, :value} end).(arguments(st, i + 1)),
      else: {i, st, :value}
  end

  # The members of a `new` callee (no calls, no optional chain).
  defp callee_members(st, i) do
    case peek(st, i) do
      {:punct, ".", _} ->
        callee_members(st, member_name(st, i + 1))

      {:punct, "[", _} ->
        {j, st} = expression(st, i + 1)
        callee_members(st, expect(st, j, "]"))

      {:punct, "?.", _} ->
        fail("an optional chain after new")

      _ ->
        {i, st}
    end
  end

  defp members(st, i, kind, optional?), do: members(peek(st, i), st, i, kind, optional?)

  defp members({:punct, ".", _}, st, i, _kind, optional?),
    do: members(st, member_name(st, i + 1), member_kind(optional?), optional?)

  defp members({:punct, "?.", _}, st, i, _kind, _optional?) do
    case peek(st, i + 1) do
      {:punct, "(", _} ->
        {j, st} = arguments(st, i + 2)
        members(st, j, :value, true)

      {:punct, "[", _} ->
        {j, st} = expression(st, i + 2)
        members(st, expect(st, j, "]"), :value, true)

      _ ->
        members(st, member_name(st, i + 1), :value, true)
    end
  end

  defp members({:punct, "[", _}, st, i, _kind, optional?) do
    {j, st} = expression(st, i + 1)
    members(st, expect(st, j, "]"), member_kind(optional?), optional?)
  end

  defp members({:punct, "(", _}, st, i, _kind, optional?) do
    {j, st} = arguments(st, i + 1)
    members(st, j, :value, optional?)
  end

  defp members({:template, _, _} = t, st, i, _kind, optional?) do
    if optional?, do: fail("a tagged template in an optional chain")
    {st, _} = template(st, t)
    members(st, i + 1, :value, optional?)
  end

  defp members(_token, st, i, kind, _optional?), do: {i, st, kind}

  # An optional chain is never an assignment target.
  defp member_kind(true), do: :value
  defp member_kind(false), do: :target

  defp member_name(st, i) do
    case peek(st, i) do
      {:ident, "#" <> _, _} -> fail("a private name")
      {:ident, name, _} -> if ascii_name?(name), do: i + 1, else: fail("a non-ASCII name")
      other -> fail("an unexpected #{describe(other)} after .")
    end
  end

  defp arguments(st, i) do
    case peek(st, i) do
      {:punct, ")", _} ->
        {i + 1, st}

      _ ->
        i = if punct?(peek(st, i), "..."), do: i + 1, else: i
        {j, st} = assignment(st, i)
        arguments_next(st, j)
    end
  end

  defp arguments_next(st, j) do
    case {peek(st, j), peek(st, j + 1)} do
      {{:punct, ")", _}, _} -> {j + 1, st}
      {{:punct, ",", _}, {:punct, ")", _}} -> {j + 2, st}
      {{:punct, ",", _}, _} -> arguments(st, j + 1)
      {other, _} -> fail("an unexpected #{describe(other)} in arguments")
    end
  end

  defp primary(st, i), do: primary(peek(st, i), st, i)

  defp primary({:ident, "function", _}, st, i) do
    {j, st} = function(st, i + 1, false, :expression)
    {j, st, :value}
  end

  defp primary({:ident, "async", _}, st, i) do
    if ident?(peek(st, i + 1), "function") and not nl?(peek(st, i + 1)) do
      {j, st} = function(st, i + 2, true, :expression)
      {j, st, :value}
    else
      {i + 1, st, :target}
    end
  end

  defp primary({:ident, w, _}, st, i) when w in ["true", "false", "null", "this"],
    do: {i + 1, st, :value}

  defp primary({:ident, w, _}, _st, _i) when w in ["class", "super", "import"], do: fail(w)

  defp primary({:ident, name, _}, st, i) do
    cond do
      name in @reserved -> fail("an unexpected #{name}")
      not ascii_name?(name) -> fail("a non-ASCII name")
      name in ["eval", "arguments"] -> {i + 1, st, :value}
      true -> {i + 1, st, :target}
    end
  end

  defp primary({:number, raw, _}, st, i) do
    if Regex.match?(~r/\A0\d/, raw), do: fail("a legacy octal number")
    {i + 1, st, :value}
  end

  defp primary({:string, raw, _}, st, i) do
    no_octal_escape(raw)
    {i + 1, st, :value}
  end

  defp primary({:template, _, _} = t, st, i) do
    {st, _} = template(st, t)
    {i + 1, st, :value}
  end

  defp primary({:regex, _, _}, _st, _i), do: fail("a regular expression literal")

  defp primary({:punct, "(", _}, st, i) do
    {j, st} = expression(st, i + 1)
    {expect(st, j, ")"), st, :value}
  end

  defp primary({:punct, "[", _}, st, i), do: array_literal(st, i + 1)
  defp primary({:punct, "{", _}, st, i), do: object_literal(st, i + 1)
  defp primary(other, _st, _i), do: fail("an unexpected #{describe(other)}")

  defp no_octal_escape(raw) do
    if Regex.match?(~r/(?<!\\)(?:\\\\)*\\(?:[1-9]|0[0-9])/, raw),
      do: fail("a legacy octal escape")
  end

  defp template(st, {:template, parts, _}) do
    st =
      Enum.reduce(parts, st, fn
        {:text, raw}, st ->
          no_octal_escape(raw)
          st

        {:expr, tokens}, st ->
          inner = %{st | t: List.to_tuple(tokens)}
          {j, _} = expression(inner, 0)
          if j != tuple_size(inner.t), do: fail("an unexpected token in a template")
          st
      end)

    {st, :ok}
  end

  defp array_literal(st, i) do
    case peek(st, i) do
      {:punct, "]", _} ->
        {i + 1, st, :value}

      {:punct, ",", _} ->
        array_literal(st, i + 1)

      _ ->
        i = if punct?(peek(st, i), "..."), do: i + 1, else: i
        {j, st} = assignment(st, i)

        case peek(st, j) do
          {:punct, "]", _} -> {j + 1, st, :value}
          {:punct, ",", _} -> array_literal(st, j + 1)
          other -> fail("an unexpected #{describe(other)} in an array")
        end
    end
  end

  defp object_literal(st, i) do
    case peek(st, i) do
      {:punct, "}", _} ->
        {i + 1, st, :value}

      _ ->
        {j, st} = property(st, i)

        case peek(st, j) do
          {:punct, "}", _} -> {j + 1, st, :value}
          {:punct, ",", _} -> object_literal(st, j + 1)
          other -> fail("an unexpected #{describe(other)} in an object")
        end
    end
  end

  defp property(st, i) do
    case {peek(st, i), peek(st, i + 1)} do
      {{:punct, "...", _}, _} ->
        assignment(st, i + 1)

      {{:ident, acc, _}, next} when acc in ["get", "set", "async"] ->
        if punct?(next, ":") or punct?(next, "(") or punct?(next, ",") or punct?(next, "}"),
          do: plain_property(st, i),
          else: accessor(st, i + 1, acc)

      _ ->
        plain_property(st, i)
    end
  end

  defp accessor(st, i, kind) do
    if kind == "async" and nl?(peek(st, i)), do: fail("a line break after async")
    if punct?(peek(st, i), "*"), do: fail("a generator")
    {j, st, _} = property_key(st, i)
    function_rest(st, j, kind == "async")
  end

  defp plain_property(st, i) do
    {j, st, key_name} = property_key(st, i)

    case peek(st, j) do
      {:punct, ":", _} ->
        assignment(st, j + 1)

      {:punct, "(", _} ->
        function_rest(st, j, false)

      {:punct, p, _} when p in [",", "}"] ->
        cond do
          key_name == nil -> fail("a computed key without a value")
          key_name in @reserved -> fail("the reserved word #{key_name} as a shorthand")
          true -> {j, st}
        end

      other ->
        fail("an unexpected #{describe(other)} in an object")
    end
  end

  # A property key: a name (any word), a string, a number or `[expr]`.
  # Returns the name of a plain word key (for shorthands), else nil.
  defp property_key(st, i) do
    case peek(st, i) do
      {:ident, "#" <> _, _} ->
        fail("a private name")

      {:ident, name, _} ->
        if ascii_name?(name), do: {i + 1, st, name}, else: fail("a non-ASCII name")

      {:string, raw, _} ->
        no_octal_escape(raw)
        {i + 1, st, nil}

      {:number, raw, _} ->
        if Regex.match?(~r/\A0\d/, raw), do: fail("a legacy octal number")
        {i + 1, st, nil}

      {:punct, "[", _} ->
        {j, st} = assignment(st, i + 1)
        {expect(st, j, "]"), st, nil}

      other ->
        fail("an unexpected #{describe(other)} as a key")
    end
  end

  # --- scopes ---------------------------------------------------------------------

  # A scope: its block-scoped names, the `var` names declared in it or
  # below, and whether it is a function's (vars stop there). A function's
  # parameters are `params`: a `let` of the same name clashes, a `var`
  # does not.
  defp new_scope(function?, params \\ []),
    do: %{function?: function?, lexical: MapSet.new(), vars: MapSet.new(params), params: params}

  defp push_scope(st, function?), do: %{st | scopes: [new_scope(function?) | st.scopes]}
  defp pop_scope(%{scopes: [_ | rest]} = st), do: %{st | scopes: rest}

  defp declare(st, kw, %{names: names}), do: declare(st, kw, names)

  defp declare(st, kw, names) when is_list(names) do
    Enum.reduce(names, st, fn name, st -> declare_one(st, kw, name) end)
  end

  # A function declaration at a function's top level is var-like; in a
  # block it is block-scoped.
  defp declare_one(%{scopes: [scope | rest]} = st, "function", name) do
    if scope.function?,
      do: declare_one(st, "var", name),
      else: %{st | scopes: [lexical(scope, name) | rest]}
  end

  defp declare_one(%{scopes: scopes} = st, "var", name) do
    {inner, outer} = Enum.split_while(scopes, &(not &1.function?))

    inner =
      Enum.map(inner, fn scope ->
        if MapSet.member?(scope.lexical, name), do: fail("a var clashing with #{name}")
        %{scope | vars: MapSet.put(scope.vars, name)}
      end)

    outer =
      case outer do
        [fun | rest] ->
          if MapSet.member?(fun.lexical, name), do: fail("a var clashing with #{name}")
          [%{fun | vars: MapSet.put(fun.vars, name)} | rest]

        [] ->
          []
      end

    %{st | scopes: inner ++ outer}
  end

  defp declare_one(%{scopes: [scope | rest]} = st, _let_or_const, name) do
    %{st | scopes: [lexical(scope, name) | rest]}
  end

  defp lexical(scope, name) do
    if MapSet.member?(scope.lexical, name) or MapSet.member?(scope.vars, name),
      do: fail("a duplicate declaration of #{name}")

    %{scope | lexical: MapSet.put(scope.lexical, name)}
  end

  # --- tokens ---------------------------------------------------------------------

  defp peek(st, i) when i < tuple_size(st.t), do: elem(st.t, i)
  defp peek(_st, _i), do: nil

  defp expect(st, i, p) do
    case peek(st, i) do
      {:punct, ^p, _} -> i + 1
      other -> fail("an unexpected #{describe(other)} where #{p} belongs")
    end
  end

  defp expect_ident(st, i, word) do
    if ident?(peek(st, i), word), do: i + 1, else: fail("a missing #{word}")
  end

  defp punct?({:punct, p, _}, p), do: true
  defp punct?(_, _), do: false

  defp ident?({:ident, w, _}, w), do: true
  defp ident?(_, _), do: false

  defp nl?({_, _, %{nl: nl}}), do: nl
  defp nl?(_), do: false

  defp ascii_name?(name), do: Regex.match?(~r/\A[A-Za-z_$][A-Za-z0-9_$]*\z/, name)

  defp close_paren(st, open) do
    Enum.reduce_while((open + 1)..(tuple_size(st.t) - 1)//1, 0, fn j, depth ->
      case elem(st.t, j) do
        {:punct, p, _} when p in ["(", "[", "{"] -> {:cont, depth + 1}
        {:punct, p, _} when p in [")", "]", "}"] and depth == 0 -> {:halt, {:at, j, p}}
        {:punct, p, _} when p in [")", "]", "}"] -> {:cont, depth - 1}
        _ -> {:cont, depth}
      end
    end)
    |> case do
      {:at, j, ")"} -> j
      _ -> nil
    end
  end

  defp describe(nil), do: "end"
  defp describe({:punct, p, _}), do: p
  defp describe({:ident, w, _}), do: w
  defp describe({kind, _, _}), do: Atom.to_string(kind)
end
