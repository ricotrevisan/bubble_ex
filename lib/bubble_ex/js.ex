defmodule BubbleEx.Js do
  @moduledoc """
  A conservative static check of an app author's JavaScript (WTF-608): does
  it only touch the page, so a generated client hook may run it as Bubble
  ran it, or does a developer have to port it?

      BubbleEx.Js.analyze("document.querySelector('#x').scrollTop = 0", params: [])
      #=> %BubbleEx.Js{verdict: :page_only, uses: ["document.querySelector"], ...}

  Stack-neutral: it reads the script's tokens (`BubbleEx.Js.Lexer`), never
  runs it, and says what it does, not how a target expresses it. The
  JavaScript is the app author's (Toolbox's "Run javascript" and
  "Javascript to Bubble", an HTML element's `<script>`); the values it gets
  are data, and data never becomes code: a script whose text Bubble builds
  from dynamic values is never page-only (the caller passes `dynamic:
  true`).

  ## Page-only

  A script is `:page_only` when every name in it is one of these, and
  nothing below rules it out:

    * a name the script declares itself (`var`, `let`, `const`, `function`,
      `class`, a parameter, a `catch` binding)
    * a JavaScript keyword or literal
    * a page-only global (`@globals`: `document`, `console`, `Math`, `JSON`,
      timers, `localStorage`, `sessionStorage`, observers, `navigator.clipboard`,
      `getComputedStyle`, …); `window.` only with a member of that list
    * `properties.paramN` / `properties.paramlistN` (Toolbox's inputs,
      `reads`)
    * `bubble_fn_<suffix>` (or `window.bubble_fn_<suffix>`): a "Javascript
      to Bubble" element's publish function, when `suffix` is one of the
      app's (`:publishes` option; `publishes`)
    * a member name (after `.`) that is not ruled out

  Ruled out (each a `reasons` entry `{kind, name}`):

    * `:network` - `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`,
      `sendBeacon`, workers, `Image`, `Audio` (they load a URL)
    * `:code` - `eval`, `Function`, `import`, `require`, `constructor`,
      `prototype`, `__proto__`, `Reflect`, `Proxy`, `globalThis`,
      `defaultView`, `view` (an event's window), property definitions,
      `this`, `arguments`, `with`, and the window's other names as names,
      even declared ones (`self`, `top`, `parent`, `frames`, `opener`); a
      timer (`setTimeout` / `setInterval`) given anything but a function
      expression, an arrow or a function the script declares by that name
      only and never assigns (`:timer_string`)
    * `:html` - `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `write`,
      `createContextualFragment`, `srcdoc`, `DOMParser`, `createElement`,
      `createElementNS`, `execCommand`, `implementation`, node cloning and
      importing
    * `:url` - `location`, `href`, `src`, `srcset`, `action`, `history`,
      `cookie`, `open`, `postMessage`, `indexedDB`, form submission, and
      styles (`style`, `cssText`, `insertRule`: a CSS `url()` loads it;
      `paintWorklet`, `addModule` load code)
    * `:attribute` - `setAttribute` of anything but `aria-*`, `role`,
      `title`, `tabindex` or `class` named by a literal (an `on…` or
      `phx-…` attribute runs code)
    * `:computed_member` - `x[…]` with any key but a number, and a
      computed key `{[…]: …}` (a name the check cannot see)
    * `Object.<name>` other than `keys`, `values`, `entries`, `freeze`,
      `isFrozen`, `hasOwn` (`:code`: `assign`, `fromEntries` write any name)
    * `:unknown_global` - a name it neither declares nor knows (a function
      a header script or another plugin defines, a third-party library)
    * `:global_write` - an assignment to a name it does not declare (a
      global in Bubble, an error in a module)
    * `:window_member` - `window.<name>` outside the list, or `window`
      used as a value
    * `:navigator_member` - `navigator.<name>` other than `clipboard`
    * `:property` - `properties.<name>` other than Toolbox's inputs, or
      `properties` used as a value
    * `:unresolved_publish` - a `bubble_fn_` function no element defines
    * `:unreadable` - the lexer refused it; `:too_long` - over
      #{100_000} bytes; `:dynamic` - its text is built from data

  Names ruled out are ruled out wherever they appear: as a member, an
  object key or a quoted text. Scopes are flat here: a name declared
  anywhere counts as declared everywhere, so the rules above never rely
  on a declaration to allow something dangerous.

  Also not page-only (`:unembeddable`): a text that would end or change the
  generated module or its script element (`</script`, `<!--`, `<%`,
  `\"""`, line separators and bidirectional controls, a text over several
  lines, which the module's indentation would change).
  """

  alias BubbleEx.Js.Lexer

  @max_bytes 100_000

  defstruct verdict: :owner, reads: [], publishes: [], uses: [], implicit: [], reasons: []

  @type reason_kind ::
          :network
          | :code
          | :html
          | :url
          | :attribute
          | :computed_member
          | :unknown_global
          | :global_write
          | :window_member
          | :navigator_member
          | :property
          | :unresolved_publish
          | :timer_string
          | :unreadable
          | :too_long
          | :dynamic
          | :unembeddable
          | :markup
          | :no_script

  @type t :: %__MODULE__{
          verdict: :page_only | :owner,
          reads: [String.t()],
          publishes: [String.t()],
          uses: [String.t()],
          implicit: [String.t()],
          reasons: [{reason_kind(), String.t()}]
        }

  @ruled_out %{
    network:
      ~w(fetch XMLHttpRequest WebSocket EventSource sendBeacon RTCPeerConnection Worker SharedWorker
         serviceWorker importScripts Image Audio Request),
    code: ~w(eval Function import require execScript constructor __proto__ prototype Reflect Proxy
         globalThis defaultView contentWindow contentDocument view defineProperty
         defineProperties setPrototypeOf getPrototypeOf getOwnPropertyDescriptor
         getOwnPropertyDescriptors __defineGetter__ __defineSetter__ __lookupGetter__
         __lookupSetter__ this arguments with export),
    html: ~w(innerHTML outerHTML insertAdjacentHTML write writeln createContextualFragment srcdoc
         DOMParser createElement createElementNS setHTMLUnsafe parseHTMLUnsafe execCommand
         implementation cloneNode importNode adoptNode createAttribute createAttributeNS
         setAttributeNode setAttributeNodeNS setNamedItem setNamedItemNS attributes content scripts
         head nodeValue outerText insertAdjacentText append prepend before after replaceWith
         replaceChildren appendChild insertBefore replaceChild createTextNode insertNode
         surroundContents appendData insertData replaceData splitText),
    url: ~w(location href src srcset action formAction history cookie domain open postMessage
         indexedDB caches submit requestSubmit style cssText insertRule paintWorklet addModule
         assign poster data ping styleSheets adoptedStyleSheets replaceSync formMethod
         formTarget attributeStyleMap computedStyleMap)
  }

  @ruled_out_kind for {kind, names} <- @ruled_out, name <- names, into: %{}, do: {name, kind}

  # Other names of the window: ruled out as globals (as members they are a
  # rectangle's `top` or a node's `parent`; `window.top` is not a listed
  # window member).
  @window_aliases ~w(self top parent frames opener)

  @keywords ~w(true false null undefined NaN Infinity new typeof instanceof in of return if else for
               while do switch case default break continue try catch finally throw async await
               yield delete void function var let const class extends static get set debugger)

  @globals ~w(document window console Math JSON Date Number String Array Object Boolean parseInt
              parseFloat isNaN isFinite encodeURIComponent decodeURIComponent setTimeout
              clearTimeout setInterval clearInterval requestAnimationFrame cancelAnimationFrame
              localStorage sessionStorage ResizeObserver MutationObserver IntersectionObserver
              WeakSet WeakMap Map Set Promise getComputedStyle Error TypeError RangeError Intl
              structuredClone alert confirm getSelection CustomEvent Event KeyboardEvent MouseEvent
              HTMLElement Element Node NodeFilter navigator properties URLSearchParams performance)

  # `Object.<name>`: the members that only read (no assign, no property
  # definitions, no prototypes).
  @object_members ~w(keys freeze isFrozen hasOwn)

  # Text an element takes: on a `<script>` or `<style>` the page has, a
  # value would be code or CSS that loads a URL. Only a literal is
  # written.
  @text_members ~w(text textContent innerText)

  @window_members ~w(innerWidth innerHeight scrollX scrollY pageXOffset pageYOffset scrollTo
                     scrollBy scroll addEventListener removeEventListener getComputedStyle
                     getSelection matchMedia localStorage sessionStorage requestAnimationFrame
                     cancelAnimationFrame setTimeout clearTimeout setInterval clearInterval
                     devicePixelRatio dispatchEvent console)

  @navigator_members ~w(clipboard)
  @timers ~w(setTimeout setInterval)
  @attribute_setters ~w(setAttribute setAttributeNS toggleAttribute)
  @attributes ~r/\A(aria-[a-z-]+|role|title|tabindex|class)\z/
  @params ~w(param1 param2 param3 param4 param5 paramlist1 paramlist2 paramlist3 paramlist4 paramlist5)
  @declarers ~w(var let const)

  @doc "Toolbox's inputs, as `properties.<name>`."
  @spec params() :: [String.t()]
  def params, do: @params

  @doc """
  The analysis of `source`.

  ## Options

    * `:publishes` - the suffixes of the app's "Javascript to Bubble"
      elements (`bubble_fn_<suffix>`); default none
    * `:dynamic` - true when Bubble builds the script's text from dynamic
      values: never page-only
  """
  @spec analyze(String.t(), keyword()) :: t()
  def analyze(source, opts \\ []) when is_binary(source) do
    publishable = MapSet.new(Keyword.get(opts, :publishes, []))

    cond do
      Keyword.get(opts, :dynamic, false) ->
        owner([{:dynamic, "script"}])

      byte_size(source) > @max_bytes ->
        owner([{:too_long, "script"}])

      (embed = unembeddable(source)) != nil ->
        owner([{:unembeddable, embed}])

      true ->
        case Lexer.tokens(source) do
          {:ok, tokens} -> tokens |> flatten() |> check(publishable) |> parsed(tokens)
          {:error, why} -> owner([{:unreadable, why}])
        end
    end
  end

  # A text that would end or change the element a page embeds the script
  # in (an HTML `<script>`, a HEEx template).
  defp unembeddable(source) do
    lower = String.downcase(source)

    cond do
      s = Enum.find(["</script", "<script", "<!--", "<%", ~s(""")], &String.contains?(lower, &1)) ->
        s

      # Line and paragraph separators and bidirectional controls: legal in
      # JavaScript, refused in Elixir source.
      Regex.match?(~r/[\x{2028}\x{2029}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u, source) ->
        "a line separator or bidirectional control character"

      true ->
        nil
    end
  end

  # A script the parser refuses is never page-only: a syntax error would
  # stop every script of the page.
  defp parsed(%__MODULE__{} = analysis, tokens) do
    case BubbleEx.Js.Parser.check(tokens) do
      :ok ->
        analysis

      {:error, why} ->
        %{analysis | verdict: :owner, reasons: Enum.sort([{:unreadable, why} | analysis.reasons])}
    end
  end

  @doc """
  The globals some script reads without declaring them (its
  `:unknown_global` and `:window_member` reasons), for `isolate/2`.
  """
  @spec shared([t()]) :: MapSet.t()
  def shared(analyses) do
    for %__MODULE__{reasons: reasons} <- analyses,
        {kind, name} <- reasons,
        kind in [:unknown_global, :window_member],
        into: MapSet.new(),
        do: String.replace_prefix(name, "window.", "")
  end

  @doc """
  A page-only analysis whose implicit globals (`implicit`, names it
  assigns without declaring them, before reading them) another script
  reads (`shared/1`) is not page-only: the generated hook declares them
  locally, so the other script would not see them.
  """
  @spec isolate(t(), MapSet.t()) :: t()
  def isolate(%__MODULE__{implicit: implicit} = analysis, shared) do
    case Enum.filter(implicit, &MapSet.member?(shared, &1)) do
      [] ->
        analysis

      names ->
        reasons = Enum.sort(analysis.reasons ++ Enum.map(names, &{:global_write, &1}))
        %{analysis | verdict: :owner, reasons: reasons}
    end
  end

  defp owner(reasons), do: %__MODULE__{verdict: :owner, reasons: reasons}

  # Template literals become a text token followed by their parts in
  # parentheses, so every name in them is checked like any other.
  defp flatten(tokens) do
    Enum.flat_map(tokens, fn
      {:template, parts, meta} ->
        [
          {:string, template_text(parts), meta}
          | Enum.flat_map(parts, fn
              {:expr, inner} -> [{:punct, "(", meta}] ++ flatten(inner) ++ [{:punct, ")", meta}]
              {:text, _} -> []
            end)
        ]

      token ->
        [token]
    end)
  end

  defp template_text(parts),
    do:
      Enum.map_join(parts, fn
        {:text, t} -> t
        _ -> ""
      end)

  # --- the check ------------------------------------------------------------

  defp check(list, publishable) do
    t = List.to_tuple(list)
    {declared, functions} = declared(t)

    ctx = %{
      t: t,
      n: tuple_size(t),
      declared: declared,
      functions: functions,
      publishable: publishable
    }

    facts =
      Enum.reduce(
        0..(ctx.n - 1)//1,
        %{reads: [], publishes: [], uses: [], implicit: [], reasons: []},
        fn i, acc -> token(elem(t, i), i, ctx, acc) end
      )

    reasons = facts.reasons |> Enum.uniq() |> Enum.sort()

    %__MODULE__{
      verdict: if(reasons == [], do: :page_only, else: :owner),
      reads: facts.reads |> Enum.uniq() |> Enum.sort(),
      publishes: facts.publishes |> Enum.uniq() |> Enum.sort(),
      uses: facts.uses |> Enum.uniq() |> Enum.sort(),
      implicit: facts.implicit |> Enum.uniq() |> Enum.sort(),
      reasons: reasons
    }
  end

  defp add(acc, key, value), do: Map.update!(acc, key, &[value | &1])

  defp token({:string, raw, _}, _i, _ctx, acc) do
    cond do
      kind = @ruled_out_kind[raw] ->
        add(acc, :reasons, {kind, raw})

      # A text naming a script or a stylesheet (a selector, CSS that
      # loads a URL): the script would reach what runs or loads.
      Regex.match?(~r/script|style|@import|url\s*\(/i, raw) ->
        add(acc, :reasons, {:url, "a text naming a script or a stylesheet"})

      # A template literal over several lines, or a string continued on
      # the next: the generated module's indentation would change it.
      String.contains?(raw, ["\n", "\r"]) ->
        add(acc, :reasons, {:unembeddable, "a text over several lines"})

      true ->
        acc
    end
  end

  defp token({:punct, "[", _}, i, ctx, acc), do: computed(i, ctx, acc)
  defp token({:ident, name, _}, i, ctx, acc), do: ident(name, i, ctx, acc)
  defp token(_token, _i, _ctx, acc), do: acc

  defp ident(name, i, ctx, acc) do
    cond do
      kind = @ruled_out_kind[name] -> add(acc, :reasons, {kind, name})
      member?(at(ctx, i - 1)) -> member(name, i, ctx, acc)
      key?(i, ctx) -> acc
      true -> reference(name, i, ctx, acc)
    end
  end

  # A name read or written (not a member, not a key).
  defp reference(name, i, ctx, acc) do
    declared? = MapSet.member?(ctx.declared, name)

    cond do
      # Even as a parameter's name: the scope is flat here.
      name in @window_aliases ->
        add(acc, :reasons, {:code, name})

      name in @keywords or declared? ->
        acc

      String.starts_with?(name, "bubble_fn_") ->
        publish(String.replace_prefix(name, "bubble_fn_", ""), acc, ctx)

      name in @globals ->
        global(name, i, ctx, acc)

      true ->
        undeclared(name, i, ctx, acc)
    end
  end

  defp undeclared(name, i, ctx, acc) do
    cond do
      name in acc.implicit ->
        acc

      # Its first use assigns it: a global in Bubble (sloppy mode), a
      # local of the generated function (`implicit`).
      punct?(at(ctx, i + 1), "=") ->
        add(acc, :implicit, name)

      true ->
        add(acc, :reasons, {:unknown_global, name})
    end
  end

  defp publish(suffix, acc, ctx) do
    if MapSet.member?(ctx.publishable, suffix),
      do: add(acc, :publishes, suffix),
      else: add(acc, :reasons, {:unresolved_publish, "bubble_fn_" <> suffix})
  end

  # A member name: `object.name`. What it is a member of matters only for
  # `window`, `navigator` and `properties` directly.
  defp member(name, i, ctx, acc) do
    object = at(ctx, i - 2)

    acc =
      if name in @text_members and not literal_write?(i, ctx),
        do: add(acc, :reasons, {:html, name <> " set from a value"}),
        else: acc

    acc =
      if name in @attribute_setters and punct?(at(ctx, i + 1), "("),
        do: attribute(name, i, ctx, acc),
        else: acc

    if member_of_member?(ctx, i), do: acc, else: global_member(object, name, i, ctx, acc)
  end

  defp global_member({:ident, "window", _}, name, i, ctx, acc),
    do: window_member(name, i, acc, ctx)

  defp global_member({:ident, "navigator", _}, name, _i, _ctx, acc),
    do: navigator_member(name, acc)

  defp global_member({:ident, "properties", _}, name, _i, _ctx, acc), do: property(name, acc)

  defp global_member({:ident, "document", _}, name, _i, _ctx, acc),
    do: add(acc, :uses, "document." <> name)

  defp global_member({:ident, "Object", _}, name, _i, _ctx, acc), do: object_member(name, acc)
  defp global_member(_object, _name, _i, _ctx, acc), do: acc

  # Whether `object` (at i - 2) is itself a member (`a.window.x`): then it
  # is not the global.
  defp member_of_member?(ctx, i), do: member?(at(ctx, i - 3))

  defp window_member(name, i, acc, ctx) do
    cond do
      String.starts_with?(name, "bubble_fn_") ->
        publish(String.replace_prefix(name, "bubble_fn_", ""), acc, ctx)

      name in @timers and not timer_function?(i, ctx) ->
        add(acc, :reasons, {:timer_string, "window." <> name})

      name in @window_members ->
        add(acc, :uses, "window." <> name)

      true ->
        add(acc, :reasons, {:window_member, "window." <> name})
    end
  end

  # A read, or `= <string or number>` ending the statement. Any other
  # assignment (`+=`, `||=`, …) or a for-in/of target is a write of a value.
  defp literal_write?(i, ctx) do
    case at(ctx, i + 1) do
      {:punct, "=", _} ->
        match?({kind, _, _} when kind in [:string, :number], at(ctx, i + 2)) and
          statement_end?(at(ctx, i + 3))

      {:punct, op, _} ->
        not assignment_after?({:punct, op, nil})

      {:ident, w, _} when w in ["of", "in"] ->
        false

      _ ->
        true
    end
  end

  # The statement ends here: `;`, `}`, the end, or a line break before a
  # name that cannot continue the expression.
  defp statement_end?(nil), do: true
  defp statement_end?({:punct, p, _}) when p in [";", "}"], do: true

  defp statement_end?({:ident, w, %{nl: true}}),
    do: w not in ~w(in instanceof of)

  defp statement_end?(_), do: false

  defp object_member(name, acc) do
    if name in @object_members,
      do: add(acc, :uses, "Object." <> name),
      else: add(acc, :reasons, {:code, "Object." <> name})
  end

  defp navigator_member(name, acc) do
    if name in @navigator_members,
      do: add(acc, :uses, "navigator." <> name),
      else: add(acc, :reasons, {:navigator_member, "navigator." <> name})
  end

  defp property(name, acc) do
    if name in @params,
      do: add(acc, :reads, name),
      else: add(acc, :reasons, {:property, "properties." <> name})
  end

  @value_globals %{
    "window" => :window_member,
    "navigator" => :navigator_member,
    "properties" => :property
  }

  defp global(name, i, ctx, acc) do
    cond do
      Map.has_key?(@value_globals, name) and not member?(at(ctx, i + 1)) ->
        add(acc, :reasons, {@value_globals[name], name})

      name in @timers and not timer_function?(i, ctx) ->
        add(acc, :reasons, {:timer_string, name})

      name in ["window", "navigator", "properties", "document", "Object"] ->
        acc

      true ->
        add(acc, :uses, name)
    end
  end

  # `setTimeout(fn, …)`: the first argument is a function expression, an
  # arrow or a function the script declares; anything else may be a text
  # the timer evaluates.
  defp timer_function?(i, ctx) do
    case {at(ctx, i + 1), at(ctx, i + 2), at(ctx, i + 3)} do
      {open, {:ident, "function", _}, _} when elem(open, 1) == "(" ->
        true

      {open, {:ident, "async", _}, next} when elem(open, 1) == "(" ->
        async_function?(next, i + 3, ctx)

      {open, {:punct, "(", _}, _} when elem(open, 1) == "(" ->
        arrow_after?(i + 2, ctx)

      {open, {:ident, name, _}, next} when elem(open, 1) == "(" ->
        punct?(next, "=>") or
          (MapSet.member?(ctx.functions, name) and (punct?(next, ",") or punct?(next, ")")))

      _ ->
        false
    end
  end

  # `async function`, `async (…) =>`, `async x =>`; a bare `async` is a
  # name like any other.
  defp async_function?({:ident, "function", _}, _at, _ctx), do: true
  defp async_function?({:punct, "(", _}, at, ctx), do: arrow_after?(at, ctx)
  defp async_function?({:ident, _, _}, at, ctx), do: punct?(at(ctx, at + 1), "=>")
  defp async_function?(_next, _at, _ctx), do: false

  # Whether the parenthesis at `open` closes into an arrow (`(…) =>`).
  defp arrow_after?(open, ctx) do
    case close_of(ctx.t, open) do
      nil -> false
      close -> punct?(at(ctx, close + 1), "=>")
    end
  end

  # `el.setAttribute("aria-label", …)`: only a literal attribute name the
  # browser never runs.
  defp attribute(name, i, ctx, acc) do
    case at(ctx, i + 2) do
      {:string, attr, _} ->
        if Regex.match?(@attributes, String.downcase(attr)),
          do: acc,
          else: add(acc, :reasons, {:attribute, attr})

      _ ->
        add(acc, :reasons, {:attribute, name})
    end
  end

  # `x[…]`, a member read by a computed key (not an array literal): the
  # key holds no text, and the member is neither called nor indexed again.
  defp computed(i, ctx, acc) do
    close = close_of(ctx.t, i)

    cond do
      close == nil ->
        add(acc, :reasons, {:computed_member, "[…]"})

      computed_member?(at(ctx, i - 1)) and not number_key?(i, close, ctx) ->
        add(acc, :reasons, {:computed_member, "[…]"})

      computed_key?(i, close, ctx) ->
        add(acc, :reasons, {:computed_member, "{[…]: …}"})

      true ->
        acc
    end
  end

  defp key_start?({:punct, p, _}), do: p in ["{", ","]
  defp key_start?({:ident, w, _}), do: w in ~w(get set async static)
  defp key_start?(_), do: false

  # `x[0]`: the only computed member the check can read.
  defp number_key?(i, close, ctx),
    do: close == i + 2 and match?({:number, _, _}, at(ctx, i + 1))

  # `{[k]: v}`, `{[k]() {}}`: a computed key of an object literal or
  # pattern.
  defp computed_key?(i, close, ctx) do
    key_start?(at(ctx, i - 1)) and
      match?({:punct, p, _} when p in [":", "("], at(ctx, close + 1))
  end

  defp computed_member?({:ident, name, _}), do: name not in @keywords or name in ~w(this)
  defp computed_member?({:punct, p, _}), do: p in [")", "]", "?."]
  defp computed_member?({:string, _, _}), do: true
  defp computed_member?(_), do: false

  # --- names the script declares --------------------------------------------

  # The names the script declares, and the functions a timer may take by
  # name: declared only by `function <name>` (no parameter, variable or
  # other binding shares the name, the scope being flat here) and never
  # assigned.
  defp declared(t) do
    {names, fns} =
      Enum.reduce(0..(tuple_size(t) - 1)//1, {MapSet.new(), []}, fn i, {names, fns} ->
        {new, fname} = declares(elem(t, i), t, i)
        {MapSet.union(names, new), if(fname, do: [fname | fns], else: fns)}
      end)

    others =
      for i <- 0..(tuple_size(t) - 1)//1,
          {new, _} = declares(elem(t, i), t, i),
          name <- MapSet.to_list(new),
          name not in fns or not function_name_at?(t, i, name),
          into: MapSet.new(),
          do: name

    once = fns |> Enum.frequencies() |> Enum.filter(&(elem(&1, 1) == 1)) |> Enum.map(&elem(&1, 0))
    {names, MapSet.new(once) |> MapSet.difference(others) |> MapSet.difference(assigned(t))}
  end

  # Whether `name` is the name of the function declared at `i`.
  defp function_name_at?(t, i, name) do
    match?({:ident, "function", _}, at_t(t, i)) and elem(function_head(t, i + 1), 0) == name and
      not MapSet.member?(params(t, elem(function_head(t, i + 1), 1)), name)
  end

  # The names an assignment (`=`, `+=`, …, `++`, `--`) targets.
  defp assigned(t) do
    for i <- 0..(tuple_size(t) - 1)//1,
        {:ident, name, _} <- [elem(t, i)],
        not member?(at_t(t, i - 1)),
        assignment_after?(at_t(t, i + 1)) or
          match?({:punct, p, _} when p in ["++", "--"], at_t(t, i - 1)),
        into: MapSet.new(),
        do: name
  end

  defp assignment_after?({:punct, p, _}),
    do: p in ~w(= += -= *= /= %= **= <<= >>= >>>= &= |= ^= &&= ||= ??= ++ --)

  defp assignment_after?(_), do: false

  # The names the token at `i` declares, and the function it names.
  defp declares({:ident, d, _}, t, i) when d in @declarers, do: {declaration(t, i + 1), nil}

  defp declares({:ident, "function", _}, t, i) do
    {fname, params_at} = function_head(t, i + 1)
    names = params(t, params_at)
    {if(fname, do: MapSet.put(names, fname), else: names), fname}
  end

  defp declares({:ident, "class", _}, t, i) do
    case at_t(t, i + 1) do
      {:ident, cname, _} -> {MapSet.new([cname]), nil}
      _ -> {MapSet.new(), nil}
    end
  end

  defp declares({:ident, "catch", _}, t, i), do: {params(t, i + 1), nil}
  defp declares({:punct, "=>", _}, t, i), do: {arrow_params(t, i - 1), nil}
  defp declares({:punct, "(", _}, t, i), do: {method_params(t, i), nil}
  defp declares(_token, _t, _i), do: {MapSet.new(), nil}

  # `var a = 1, {b, c: d} = x, e;`: the names after the keyword and after
  # each comma at the declaration's depth.
  defp declaration(t, i), do: declaration(t, i, 0, :name, MapSet.new())

  defp declaration(t, i, depth, want, acc) do
    case declaration_step(at_t(t, i), t, i, depth, want, acc) do
      {:cont, i, depth, want, acc} -> declaration(t, i, depth, want, acc)
      {:done, acc} -> acc
    end
  end

  defp declaration_step(nil, _t, _i, _depth, _want, acc), do: {:done, acc}

  defp declaration_step(token, t, i, 0, want, acc), do: top_step(token, t, i, want, acc)

  defp declaration_step({:punct, p, _}, _t, i, depth, want, acc) when p in ["(", "[", "{"],
    do: {:cont, i + 1, depth + 1, want, acc}

  defp declaration_step({:punct, p, _}, _t, i, depth, want, acc) when p in [")", "]", "}"],
    do: {:cont, i + 1, depth - 1, want, acc}

  defp declaration_step(_token, _t, i, depth, want, acc), do: {:cont, i + 1, depth, want, acc}

  # At the declaration's own depth.
  defp top_step({:ident, name, _}, _t, i, :name, acc),
    do: {:cont, i + 1, 0, :init, MapSet.put(acc, name)}

  defp top_step({:punct, p, _}, t, i, :name, acc) when p in ["{", "["] do
    case close_of(t, i) do
      nil -> {:done, acc}
      close -> {:cont, close + 1, 0, :init, MapSet.union(acc, pattern(t, i, close))}
    end
  end

  defp top_step({:punct, p, _}, _t, i, want, acc) when p in ["(", "[", "{"],
    do: {:cont, i + 1, 1, want, acc}

  defp top_step({:punct, p, _}, _t, _i, _want, acc) when p in [")", "]", "}", ";"],
    do: {:done, acc}

  defp top_step({:punct, ",", _}, _t, i, _want, acc), do: {:cont, i + 1, 0, :name, acc}
  defp top_step({:ident, kw, _}, _t, _i, _want, acc) when kw in ["of", "in"], do: {:done, acc}

  defp top_step({_, _, %{nl: true}} = token, t, i, :init, acc) do
    if continues?(at_t(t, i - 1), token),
      do: {:cont, i + 1, 0, :init, acc},
      else: {:done, acc}
  end

  defp top_step(_token, _t, i, want, acc), do: {:cont, i + 1, 0, want, acc}

  # Whether a line break inside a declaration continues it: the line ends
  # with an operator or a comma, or the next starts with one.
  defp continues?(prev, token) do
    operator?(prev) or
      match?({:punct, p, _} when p not in ["(", "[", "{", "!", "~", "++", "--"], token)
  end

  defp operator?({:punct, p, _}), do: p not in [")", "]", "}"]
  defp operator?(_), do: false

  # The names a destructuring pattern binds (between `open` and `close`):
  # the names that are not followed by `:` (a renamed key) nor a member.
  defp pattern(t, open, close) do
    for j <- (open + 1)..(close - 1)//1,
        {:ident, name, _} <- [elem(t, j)],
        name not in @keywords,
        not member?(at_t(t, j - 1)),
        not member?(at_t(t, j + 1)),
        not punct?(at_t(t, j + 1), ":"),
        not after_default?(t, open, j),
        into: MapSet.new(),
        do: name
  end

  # Whether the name at `j` is in a default value (after `=` at the
  # pattern's own depth, before the next comma): a reference, not a name.
  defp after_default?(t, open, j) do
    Enum.reduce_while((j - 1)..(open + 1)//-1, false, fn k, _ ->
      case elem(t, k) do
        {:punct, "=", _} -> {:halt, true}
        {:punct, p, _} when p in [",", "{", "["] -> {:halt, false}
        _ -> {:cont, false}
      end
    end)
  end

  defp function_head(t, i) do
    i = if punct?(at_t(t, i), "*"), do: i + 1, else: i

    case at_t(t, i) do
      {:ident, name, _} -> {name, i + 1}
      _ -> {nil, i}
    end
  end

  # The parameters of the parenthesized list at `i`.
  defp params(t, i) do
    with {:punct, "(", _} <- at_t(t, i),
         close when is_integer(close) <- close_of(t, i) do
      pattern(t, i, close)
    else
      _ -> MapSet.new()
    end
  end

  defp arrow_params(t, i) do
    case at_t(t, i) do
      {:ident, name, _} ->
        MapSet.new([name])

      {:punct, ")", _} ->
        case open_of(t, i) do
          nil -> MapSet.new()
          open -> pattern(t, open, i)
        end

      _ ->
        MapSet.new()
    end
  end

  # A method `name(…) {` in an object or class body (after `{`, `,`, `;`,
  # `}`, or `get` / `set` / `static` / `async`): its parameters.
  defp method_params(t, open) do
    with {:ident, name, _} when name not in @keywords or name in ~w(get set static async) <-
           at_t(t, open - 1),
         true <- method_start?(at_t(t, open - 2)),
         close when is_integer(close) <- close_of(t, open),
         true <- punct?(at_t(t, close + 1), "{") do
      pattern(t, open, close)
    else
      _ -> MapSet.new()
    end
  end

  defp method_start?({:punct, p, _}), do: p in ["{", ",", ";", "}"]
  defp method_start?({:ident, kw, _}), do: kw in ~w(get set static async)
  defp method_start?(_), do: false

  # --- tokens ---------------------------------------------------------------

  defp at(ctx, i), do: at_t(ctx.t, i)

  defp at_t(_t, i) when i < 0, do: nil
  defp at_t(t, i) when i >= tuple_size(t), do: nil
  defp at_t(t, i), do: elem(t, i)

  defp punct?({:punct, p, _}, p), do: true
  defp punct?(_, _), do: false

  defp member?({:punct, p, _}), do: p in [".", "?."]
  defp member?(_), do: false

  # An object key: `{name: …` or `, name: …` (not a ternary's branch).
  defp key?(i, ctx) do
    punct?(at(ctx, i + 1), ":") and match?({:punct, p, _} when p in ["{", ","], at(ctx, i - 1))
  end

  @pairs %{"(" => ")", "[" => "]", "{" => "}"}

  defp close_of(t, open) do
    {:punct, o, _} = elem(t, open)
    c = Map.fetch!(@pairs, o)

    Enum.reduce_while((open + 1)..(tuple_size(t) - 1)//1, 0, fn j, depth ->
      case elem(t, j) do
        {:punct, ^o, _} -> {:cont, depth + 1}
        {:punct, ^c, _} when depth == 0 -> {:halt, {:at, j}}
        {:punct, ^c, _} -> {:cont, depth - 1}
        _ -> {:cont, depth}
      end
    end)
    |> at_result()
  end

  defp at_result({:at, j}), do: j
  defp at_result(_), do: nil

  defp open_of(t, close) do
    Enum.reduce_while((close - 1)..0//-1, 0, fn j, depth ->
      case elem(t, j) do
        {:punct, ")", _} -> {:cont, depth + 1}
        {:punct, "(", _} when depth == 0 -> {:halt, {:at, j}}
        {:punct, "(", _} -> {:cont, depth - 1}
        _ -> {:cont, depth}
      end
    end)
    |> case do
      {:at, j} -> j
      _ -> nil
    end
  end
end
