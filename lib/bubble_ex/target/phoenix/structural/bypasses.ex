defmodule BubbleEx.Target.Phoenix.Structural.Bypasses do
  @moduledoc """
  The authorization-bypass inventory of Elixir source (WTF-386,
  `bypass_inventory`), read from the parsed code
  (`Code.string_to_quoted_with_comments/2`), not by grepping text.

  ## Sites

  Every node of the AST is visited; a site's line is the line of the
  nearest enclosing node that has one, and two sites on one line stay two
  sites. Module names are resolved through the file's `alias`es (read for
  the whole file, not per lexical scope).

  | kind | what |
  |------|------|
  | `:authorize_false` | the pair `authorize?: false` anywhere (a keyword list, a map, a struct, a module attribute, a function body), the arguments `:authorize?, false` side by side (`Keyword.put/3`), the DSL call `authorize? false`, or `put_in/2,3` of an `:authorize?` path to `false` |
  | `:authorize_unverifiable` | the same with any value but the literal `true` (a variable, `@attr`, `!true`, a function call; `update_in/2,3` of an `:authorize?` path): it may be `false` at runtime. Also `false` put under a key that is not a literal (`put_in(opts[key], false)`, `put_in(opts, keys, false)`, `Keyword.put(opts, key, false)`, `Map.put/3`, `*.put_new/3`, `Keyword.merge/2` / `Map.merge/2` of a literal holding `{key, false}`) |
  | `:runtime_start` | a generated workflow body's `Runtime.start(input, context, "<workflow id>", false)` (`BubbleEx.Target.Ash.Workflows`: the workflow ignores privacy rules in Bubble), also through an alias |
  | `:runtime_unverifiable` | `Runtime.start/4` whose last argument is not `true`, `false` or `:inherit`, or whose workflow is not a literal; `apply/3` of `Runtime.start`; `import` of a `*.Runtime` |
  | `:policy_bypass` | a `bypass ...` policy |
  | `:policy_always` | a `policy always()` (or `[always()]`) with an `authorize_if always()`: a bypass under another name |
  | `:authorize_mode` | `authorize` with anything but `:by_default` or `:always` (`:never`, `:when_requested`, a variable) |
  | `:no_authorizers` | `authorizers: []` |
  | `:unauthorized_resource` | `use Ash.Resource` without `Ash.Policy.Authorizer` in a literal `authorizers:` (embedded resources excepted). Generated resources are hash-checked, and with `privacy: :omit` have none by design: `inventory/2`'s `:generated` skips them |
  | `:repo_call` | a call on a `*.Repo` module or `Ecto.Adapters.SQL` (also through an alias or `apply/3`), or an `import` of one: data access that no Ash policy sees |
  | `:repo_unverifiable` | a call of an `Ecto.Repo` function on a module held in a variable (`repo.all(q)`, `apply(repo, :all, [q])`): it may reach a Repo |

  ## Markers

  A site is accounted for by a `# bubble:ignores_privacy <token>` comment
  on its line or the line above:

    * `scaffold:<purpose>` - written by the generator, from the closed
      vocabulary `scaffold_purposes/0`, each covering one site kind
      (`purpose_kind/1`); the rendered `.wtf/bypasses.json` (generated, so
      hash-checked) lists how many sites of each purpose each file has in
      each enclosing function, and no function may have more
    * `workflow:<id>` (or a bare `<id>`) - a workflow that ignores privacy
      rules in Bubble, and only inside that workflow's body: the function
      the generated name map binds it to (`bodies/2`: `<Module>.Workflows.
      <Folder>.Bodies.<action>/2` and its `<action>__step/2` and
      `<action>__condition/1`). A `# bubble:workflow` comment is a
      reading aid, never a body
    * `decision:<key>` - an owner's privacy exception (`:decisions`): the
      caller passes only the active ones a trusted owner accepted
      (`BubbleEx.Target.Phoenix.Structural.project/2`'s `:owners`), each
      with the module or function it allows; a site outside that scope
      is unlisted. Any other decision (a finding, a rename, the owner's
      drop of a symbol) authorizes no bypass

  A `:runtime_start` needs no marker: its workflow must be in the bypass
  list and it must sit in that workflow's body entry function. Anything
  else is `:unlisted`: a structural failure.

  ## Not seen

  Options merged from a variable (`Keyword.merge(opts, extra)`) or built
  by another function; a Repo reached through a module computed at
  runtime (`Module.concat/1`), a local call after `import`, `apply/3`
  with neither a literal module nor a literal Repo function, or a
  function capture held in a variable; `Runtime.start/4` called locally after an
  import, or through a variable module; policies that authorize everything
  under a condition other than `always()`; authorizers added by a Spark
  fragment; queries through Postgrex or another library; files outside
  `lib/` (tests). It is an inventory, not a proof.
  """

  @marker ~r/#\s*bubble:ignores_privacy\s+(\S+)/
  @scope ~r/\A((?:[A-Z][A-Za-z0-9_]*)(?:\.[A-Z][A-Za-z0-9_]*)*)(?:\.([a-z_][A-Za-z0-9_]*[?!]?)\/(\d+))?\z/
  @scaffold_purposes %{
    "confirm_email" =>
      "the magic-link sign-in sets the signed-in user's confirmed_at (AuthController)",
    "job_actor" => "a scheduled job loads the user who scheduled it (Workflows.Runtime)",
    "workflow_authorize" =>
      "the workflow runtime passes each workflow's own authorize? setting on (Workflows.Runtime)",
    "load_actor" => "the privacy module loads the actor with its privacy loads (Privacy)",
    "derived_count" =>
      "a count aggregate an owner's derive_count decision generates (not authorized, as the list it replaces)"
  }

  @type site :: %{
          required(:kind) => atom(),
          required(:line) => pos_integer() | nil,
          optional(:path) => String.t(),
          optional(:workflow) => String.t() | nil,
          optional(:function) => String.t() | nil,
          optional(:module) => String.t() | nil,
          optional(:marker) => {:scaffold | :workflow | :decision, String.t()} | nil,
          optional(:in_workflow) => String.t() | nil,
          optional(:class) => :listed | :marked | :scaffold | :unlisted,
          optional(:detail) => String.t() | nil
        }

  # Where the generator writes each fixed scaffold purpose: the file
  # (path suffix under lib/<app>), the one site kind the purpose covers,
  # and how many sites in which function (a generator change that adds or
  # moves one fails run/2).
  @expected_sites %{
    "confirm_email" =>
      {"_web/controllers/auth_controller.ex", :authorize_false, %{"confirm_email/2" => 1}},
    "job_actor" => {"/workflows/runtime.ex", :authorize_false, %{"job_actor/1" => 1}},
    "workflow_authorize" =>
      {"/workflows/runtime.ex", :authorize_unverifiable,
       %{
         "run/3" => 1,
         "start/4" => 1,
         "get/3" => 1,
         "load/3" => 2,
         "options/2" => 1,
         "call_run/6" => 1
       }},
    "load_actor" => {"/privacy.ex", :authorize_false, %{"load_actor/1" => 1}}
  }

  # The site kind each purpose covers (`derived_count`: the aggregate's
  # `authorize?: false`, in the resource body, no function).
  @purpose_kinds Map.new(@expected_sites, fn {p, {_, kind, _}} -> {p, kind} end)
                 |> Map.put("derived_count", :authorize_false)

  @doc """
  The fixed scaffold sites the generator writes: purpose => `{path suffix
  under lib/<app>, site kind, %{function => count}}`. `derived_count` is
  per Project aggregate.
  """
  @spec expected_sites() :: %{String.t() => {String.t(), atom(), %{String.t() => pos_integer()}}}
  def expected_sites, do: @expected_sites

  @doc "The site kind a scaffold purpose covers, or nil for an unknown purpose."
  @spec purpose_kind(String.t()) :: atom() | nil
  def purpose_kind(purpose), do: Map.get(@purpose_kinds, purpose)

  @doc "The allowlist's path in the project."
  @spec path() :: String.t()
  def path, do: ".wtf/bypasses.json"

  @doc "The scaffold purposes the generator may write, with what each is for."
  @spec scaffold_purposes() :: %{String.t() => String.t()}
  def scaffold_purposes, do: @scaffold_purposes

  @doc """
  The sites of every `.ex`/`.exs` file in `files` (path => content), sorted
  by path and line, classified. Options:

    * `:workflows` - Bubble IDs of the workflows allowed to bypass
    * `:scaffold` - `%{{path, purpose, function} => count}`: the scaffold
      sites allowed per file and enclosing function (`.wtf/bypasses.json`)
    * `:bodies` - the workflow bodies, `bodies/2` of the generated name
      map: where a workflow's `Runtime.start/4` and markers may be
    * `:decisions` - `%{key => scope}`: the decisions a `decision:<key>`
      marker may cite and the module (`"Acme.Owned"`) or function
      (`"Acme.Owned.run/2"`) each allows (`decision_scope/1`); a list of
      keys allows nothing
    * `:generated` - paths of generated (hash-checked) files: their
      `:unauthorized_resource` sites are skipped

  Returns the sites and the paths that do not parse (reported, never
  skipped silently).
  """
  @spec inventory(%{String.t() => binary()}, keyword()) :: %{
          sites: [site()],
          unparsable: [String.t()]
        }
  def inventory(files, opts) do
    ctx = %{
      workflows: opts |> Keyword.get(:workflows, []) |> MapSet.new(),
      scaffold: Keyword.get(opts, :scaffold, %{}),
      bodies: Keyword.get(opts, :bodies, %{}),
      decisions: decision_scopes(Keyword.get(opts, :decisions, %{})),
      generated: opts |> Keyword.get(:generated, []) |> MapSet.new()
    }

    {sites, unparsable} =
      files
      |> Enum.filter(fn {path, _} -> Path.extname(path) in [".ex", ".exs"] end)
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn {path, source}, {sites, bad} ->
        case sites(source) do
          {:ok, found} ->
            {[classify_file(path, owned_sites(found, path, ctx), ctx) | sites], bad}

          :error ->
            {sites, [path | bad]}
        end
      end)

    %{sites: sites |> Enum.reverse() |> Enum.concat(), unparsable: Enum.reverse(unparsable)}
  end

  # A generated resource is hash-checked: its missing authorizer is the
  # generator's (`privacy: :omit`), not a bypass of the owner's.
  defp owned_sites(found, path, ctx) do
    if MapSet.member?(ctx.generated, path),
      do: Enum.reject(found, &(&1.kind == :unauthorized_resource)),
      else: found
  end

  @doc """
  The workflow bodies of a generated name map (`.wtf/workflows.json`'s
  `names`, `BubbleEx.Target.Ash.Workflows.Spec`'s `names`) under the root
  module `namespace`: `%{{module, function} => {workflow id, :entry |
  :helper}}`. The entry is `<action>/2` of `<namespace>.Workflows.
  <resource>.Bodies`; its helpers are `<action>__step/2` and
  `<action>__condition/1`.
  """
  @spec bodies(map() | nil, String.t() | nil) :: %{
          {String.t(), String.t()} => {String.t(), :entry | :helper}
        }
  def bodies(%{"actions" => actions}, namespace) when is_map(actions) and is_binary(namespace) do
    for {id, %{"resource" => r, "action" => a}} <- actions,
        is_binary(id) and is_binary(r) and is_binary(a),
        module = "#{namespace}.Workflows.#{r}.Bodies",
        {fun, role} <- [
          {"#{a}/2", :entry},
          {"#{a}__step/2", :helper},
          {"#{a}__condition/1", :helper}
        ],
        into: %{},
        do: {{module, fun}, {id, role}}
  end

  def bodies(_names, _namespace), do: %{}

  @doc """
  The module or function a privacy decision's scope names: `{:module,
  "Acme.Owned"}`, `{:function, "Acme.Owned", "run/2"}`, or `:error`.
  """
  @spec decision_scope(term()) ::
          {:module, String.t()} | {:function, String.t(), String.t()} | :error
  def decision_scope(scope) when is_binary(scope) do
    case Regex.run(@scope, scope) do
      [_, module] -> {:module, module}
      [_, module, fun, arity] -> {:function, module, "#{fun}/#{arity}"}
      _ -> :error
    end
  end

  def decision_scope(_scope), do: :error

  defp decision_scopes(decisions) when is_map(decisions) do
    for {key, scope} <- decisions,
        parsed = decision_scope(scope),
        parsed != :error,
        into: %{},
        do: {key, parsed}
  end

  defp decision_scopes(_keys), do: %{}

  @doc """
  The scaffold sites of `files` as `.wtf/bypasses.json` content: per file,
  purpose and enclosing function (`name/arity`, nil in a module body), the
  count of `scaffold:<purpose>` markers on a site of the purpose's kind.
  """
  @spec scaffold_counts(%{String.t() => binary()}) :: %{
          {String.t(), String.t(), String.t() | nil} => pos_integer()
        }
  def scaffold_counts(files) do
    for {path, source} <- files,
        Path.extname(path) in [".ex", ".exs"],
        {:ok, found} <- [sites(source)],
        %{marker: {:scaffold, purpose}, kind: kind, function: fun} <- found,
        purpose_kind(purpose) == kind,
        reduce: %{} do
      acc -> Map.update(acc, {path, purpose, fun}, 1, &(&1 + 1))
    end
  end

  @doc "`scaffold_counts/1` as the canonical JSON of `.wtf/bypasses.json`."
  @spec allowlist_json(%{String.t() => binary()}) :: String.t()
  def allowlist_json(files) do
    entries =
      files
      |> scaffold_counts()
      |> Enum.sort()
      |> Enum.map(fn {{path, purpose, fun}, n} ->
        %{
          "path" => path,
          "purpose" => purpose,
          "kind" => Atom.to_string(purpose_kind(purpose)),
          "function" => fun,
          "count" => n
        }
      end)

    %{"version" => 2, "scaffold" => entries}
    |> BubbleEx.CanonicalJson.ordered()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc "Reads `.wtf/bypasses.json` into `%{{path, purpose, function} => count}`."
  @spec decode_allowlist(String.t() | nil) :: {:ok, map()} | :error
  def decode_allowlist(nil), do: {:ok, %{}}

  def decode_allowlist(json) do
    with {:ok, %{"version" => 2, "scaffold" => entries}} when is_list(entries) <-
           Jason.decode(json),
         true <- Enum.all?(entries, &allow_entry?/1) do
      {:ok, Map.new(entries, &{{&1["path"], &1["purpose"], &1["function"]}, &1["count"]})}
    else
      _ -> :error
    end
  end

  defp allow_entry?(%{"path" => p, "purpose" => u, "function" => f, "count" => n} = e),
    do:
      is_binary(p) and is_binary(u) and (is_binary(f) or is_nil(f)) and is_integer(n) and n > 0 and
        e["kind"] == Atom.to_string(purpose_kind(u) || :none)

  defp allow_entry?(_), do: false

  # --- classification ----------------------------------------------------------------

  # Scaffold allowances are counted per file and purpose: the first
  # `count` sites marked with a purpose are scaffold, the rest unlisted.
  defp classify_file(path, found, ctx) do
    {sites, _used} =
      Enum.map_reduce(found, %{}, fn site, used ->
        body = Map.get(ctx.bodies, {site.module, site.function})

        site =
          Map.merge(site, %{
            path: path,
            in_workflow: body && elem(body, 0),
            body_entry?: match?({_, :entry}, body)
          })

        {class, detail, used} = classify(site, ctx, used)
        {Map.merge(site, %{class: class, detail: detail}), used}
      end)

    sites
  end

  defp classify(%{kind: :runtime_start, workflow: w} = site, ctx, used) do
    cond do
      not MapSet.member?(ctx.workflows, w) ->
        {:unlisted, "the workflow does not ignore privacy rules in Bubble", used}

      site.in_workflow != w or not site.body_entry? ->
        {:unlisted, "not in the workflow's own body", used}

      true ->
        {:listed, nil, used}
    end
  end

  defp classify(%{kind: :runtime_unverifiable}, _ctx, used),
    do: {:unlisted, "Runtime.start/4 with a value that cannot be read", used}

  defp classify(%{marker: {:scaffold, purpose}, path: path} = site, ctx, used) do
    slot = {path, purpose, site.function}
    allowed = Map.get(ctx.scaffold, slot, 0)
    n = Map.get(used, slot, 0)

    cond do
      purpose_kind(purpose) == nil ->
        {:unlisted, "unknown scaffold purpose", used}

      purpose_kind(purpose) != site.kind ->
        {:unlisted, "scaffold:#{purpose} covers #{purpose_kind(purpose)} sites only", used}

      n >= allowed ->
        {:unlisted,
         "more scaffold:#{purpose} sites in #{site.function || "the module body"} than the generator wrote",
         used}

      true ->
        {:scaffold, nil, Map.put(used, slot, n + 1)}
    end
  end

  defp classify(%{marker: {:workflow, w}} = site, ctx, used) do
    cond do
      not MapSet.member?(ctx.workflows, w) ->
        {:unlisted, "the marked workflow does not ignore privacy rules in Bubble", used}

      site.in_workflow != w ->
        {:unlisted, "the workflow marker is outside that workflow's body", used}

      true ->
        {:marked, nil, used}
    end
  end

  defp classify(%{marker: {:decision, key}} = site, ctx, used) do
    case Map.fetch(ctx.decisions, key) do
      :error ->
        {:unlisted, "the decision is not an active privacy exception of a trusted owner here",
         used}

      {:ok, scope} ->
        if in_scope?(scope, site),
          do: {:marked, nil, used},
          else: {:unlisted, "outside the decision's scope", used}
    end
  end

  defp classify(_site, _ctx, used), do: {:unlisted, nil, used}

  defp in_scope?({:module, module}, site), do: site.module == module

  defp in_scope?({:function, module, fun}, site),
    do: site.module == module and site.function == fun

  # --- the AST ------------------------------------------------------------------------

  # Functions of `Ecto.Repo` and `Ecto.Adapters.SQL`: a call of one of
  # them on a module held in a variable (or through `apply/3`) may reach a
  # Repo.
  @repo_functions ~w(aggregate all all_by checkout delete delete! delete_all exists?
                     get get! get_by get_by! insert insert! insert_all insert_or_update
                     insert_or_update! one one! preload query query! query_many
                     query_many! reload reload! stream transact transaction update
                     update! update_all)a

  @doc """
  The sites of one source text, each with the marker on or above its line,
  its enclosing module and function; `:error` when it does not parse.
  """
  @spec sites(String.t()) :: {:ok, [site()]} | :error
  def sites(source) do
    case Code.string_to_quoted_with_comments(source, emit_warnings: false) do
      {:ok, ast, comments} ->
        markers =
          for %{line: line, text: text} <- comments,
              [_, token] <- [Regex.run(@marker, text)],
              into: %{},
              do: {line, marker(token)}

        ctx = %{line: nil, fun: nil, module: nil, aliases: aliases(ast)}

        {:ok,
         ast
         |> walk(ctx, [])
         |> Enum.reverse()
         |> Enum.sort_by(&(&1.line || 0))
         |> Enum.map(&annotate(&1, markers))}

      {:error, _} ->
        :error
    end
  end

  defp marker("scaffold:" <> purpose), do: {:scaffold, purpose}
  defp marker("decision:" <> key), do: {:decision, key}
  defp marker("workflow:" <> id), do: {:workflow, id}
  defp marker(id), do: {:workflow, id}

  defp annotate(%{line: line} = site, markers),
    do: Map.put(site, :marker, line && (markers[line] || markers[line - 1]))

  # The file's aliases (`alias A.B`, `alias A.B, as: C`, `alias A.{B, C}`),
  # short name => full parts. Read for the whole file, not per lexical
  # scope: an alias that resolves somewhere resolves everywhere, so a
  # site is found more often, never less.
  defp aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [target | rest]} = node, acc -> {node, add_alias(target, rest, acc)}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp add_alias({:__aliases__, _, parts}, [[as: {:__aliases__, _, [short]}]], acc)
       when is_list(parts),
       do: Map.put(acc, short, resolve(parts, acc))

  defp add_alias({:__aliases__, _, parts}, [], acc) when is_list(parts),
    do: Map.put(acc, List.last(parts), resolve(parts, acc))

  defp add_alias({{:., _, [{:__aliases__, _, base}, :{}]}, _, children}, [], acc)
       when is_list(base) do
    Enum.reduce(children, acc, fn
      {:__aliases__, _, parts}, acc when is_list(parts) ->
        Map.put(acc, List.last(parts), resolve(base ++ parts, acc))

      _, acc ->
        acc
    end)
  end

  defp add_alias(_target, _rest, acc), do: acc

  defp resolve([head | rest] = parts, aliases) when is_atom(head) do
    case Map.fetch(aliases, head) do
      {:ok, full} when full != [head] -> full ++ rest
      _ -> parts
    end
  end

  defp resolve(parts, _aliases), do: parts

  defp repo?(parts),
    do: List.last(parts) == :Repo or Enum.take(parts, 3) == [:Ecto, :Adapters, :SQL]

  defp runtime?(parts), do: List.last(parts) == :Runtime

  # `ctx`: the nearest line, the enclosing function (`name/arity`, nil
  # outside one), the enclosing module and the file's aliases.
  defp walk({:defmodule, meta, [{:__aliases__, _, parts} | rest]} = node, ctx, acc)
       when is_list(meta) and is_list(parts) do
    name = Enum.map_join(parts, ".", &module_part(&1, ctx))
    ctx = %{ctx | line: Keyword.get(meta, :line, ctx.line)}
    # A nested `defmodule Inner` is `Outer.Inner`; `__MODULE__.Inner` is
    # already full.
    nested? = ctx.module != nil and is_atom(hd(parts))
    ctx = %{ctx | module: if(nested?, do: ctx.module <> "." <> name, else: name)}
    acc = node_sites(node, ctx, acc)
    walk(rest, ctx, acc)
  end

  defp walk({form, meta, args} = node, ctx, acc) when is_list(meta) do
    ctx = %{ctx | line: Keyword.get(meta, :line, ctx.line), fun: def_name(node) || ctx.fun}
    acc = node_sites(node, ctx, acc)
    acc = walk(form, ctx, acc)
    if is_list(args), do: Enum.reduce(args, acc, &walk(&1, ctx, &2)), else: acc
  end

  defp walk({left, right}, ctx, acc) do
    acc = pair_site(left, right, ctx, acc)
    walk(right, ctx, walk(left, ctx, acc))
  end

  defp walk(list, ctx, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, ctx, &2))
  defp walk(_other, _ctx, acc), do: acc

  # `defmodule __MODULE__.Inner`: the enclosing module.
  defp module_part(part, _ctx) when is_atom(part), do: Atom.to_string(part)
  defp module_part({:__MODULE__, _, _}, ctx), do: ctx.module || "__MODULE__"
  defp module_part(_part, _ctx), do: "?"

  defp def_name({kind, _, [head | _]}) when kind in [:def, :defp, :defmacro, :defmacrop],
    do: head_name(head)

  defp def_name(_node), do: nil

  defp head_name({:when, _, [head | _]}), do: head_name(head)

  defp head_name({name, _, args}) when is_atom(name),
    do: "#{name}/#{if is_list(args), do: length(args), else: 0}"

  defp head_name(_), do: nil

  defp pair_site(:authorize?, value, ctx, acc), do: authorize_site(value, ctx, acc)
  defp pair_site(:authorizers, [], ctx, acc), do: [site(:no_authorizers, ctx) | acc]
  defp pair_site(_left, _right, _ctx, acc), do: acc

  defp authorize_site(true, _ctx, acc), do: acc
  defp authorize_site(false, ctx, acc), do: [site(:authorize_false, ctx) | acc]
  defp authorize_site(_value, ctx, acc), do: [site(:authorize_unverifiable, ctx) | acc]

  # A remote call on a module alias: Runtime.start/4, a Repo, or neither.
  defp node_sites({{:., _, [{:__aliases__, _, parts}, fun]}, _, args}, ctx, acc)
       when is_list(parts) and is_list(args) do
    parts = resolve(parts, ctx.aliases)

    acc =
      case {parts, fun, args} do
        {[:Kernel], :apply, [module, f, _]} ->
          apply_site(module, f, ctx, acc)

        _ ->
          cond do
            runtime?(parts) and fun == :start and length(args) == 4 ->
              runtime_site(args, ctx, acc)

            repo?(parts) ->
              [site(:repo_call, ctx) | acc]

            true ->
              access_sites(parts, fun, args, ctx, acc)
          end
      end

    argument_sites(args, ctx, acc)
  end

  # A call on a module held in a variable: `repo.all(q)`.
  defp node_sites({{:., _, [{var, _, c}, fun]}, meta, args}, ctx, acc)
       when is_atom(var) and var != :__MODULE__ and is_atom(c) and is_list(args) do
    acc =
      if not Keyword.get(meta, :no_parens, false) and fun in @repo_functions,
        do: [site(:repo_unverifiable, ctx) | acc],
        else: acc

    argument_sites(args, ctx, acc)
  end

  # `apply(module, fun, args)` (`Kernel.apply/3` above).
  defp node_sites({:apply, _, [module, fun, _args] = args}, ctx, acc) do
    acc = apply_site(module, fun, ctx, acc)
    argument_sites(args, ctx, acc)
  end

  # `import Acme.Repo`, `import Ecto.Adapters.SQL`: every local call may be
  # a Repo call; `import ...Workflows.Runtime`: `start/4` unseen.
  defp node_sites({:import, _, [{:__aliases__, _, parts} | _]}, ctx, acc) when is_list(parts) do
    parts = resolve(parts, ctx.aliases)

    cond do
      repo?(parts) -> [site(:repo_call, ctx) | acc]
      runtime?(parts) -> [site(:runtime_unverifiable, ctx) | acc]
      true -> acc
    end
  end

  # `use Ash.Resource` without `Ash.Policy.Authorizer` (embedded resources
  # are read through their parent).
  defp node_sites({:use, _, [{:__aliases__, _, parts} | opts]}, ctx, acc) when is_list(parts) do
    if resolve(parts, ctx.aliases) == [:Ash, :Resource] and not authorized?(opts, ctx),
      do: [site(:unauthorized_resource, ctx) | acc],
      else: acc
  end

  # `put_in/2,3`, `update_in/2,3`, `get_and_update_in/2,3`.
  defp node_sites({op, _, args}, ctx, acc)
       when op in [:put_in, :update_in, :get_and_update_in] and is_list(args) do
    acc = path_site(op, args, ctx, acc)
    argument_sites(args, ctx, acc)
  end

  # The DSL: `authorize? false`, `bypass ...`, `authorize :never`,
  # `policy always() do authorize_if always() end`.
  defp node_sites({:authorize?, _, [value]}, ctx, acc), do: authorize_site(value, ctx, acc)
  defp node_sites({:bypass, _, [_ | _]}, ctx, acc), do: [site(:policy_bypass, ctx) | acc]

  defp node_sites({:authorize, _, [mode]}, ctx, acc) when mode not in [:by_default, :always],
    do: [site(:authorize_mode, ctx) | acc]

  defp node_sites({:policy, _, [condition | rest]} = node, ctx, acc) do
    acc =
      if always?(condition) and authorizes_always?(rest),
        do: [site(:policy_always, ctx) | acc],
        else: acc

    node |> elem(2) |> argument_sites(ctx, acc)
  end

  defp node_sites({_form, _, args}, ctx, acc) when is_list(args),
    do: argument_sites(args, ctx, acc)

  defp node_sites(_node, _ctx, acc), do: acc

  # `Keyword.put(opts, :authorize?, value)`: the key and value side by side.
  defp argument_sites(args, ctx, acc) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(acc, fn
      [:authorize?, value], acc -> authorize_site(value, ctx, acc)
      _, acc -> acc
    end)
  end

  # Runtime.start(input, context, "<id>", false)
  defp runtime_site([_, _, id, last], ctx, acc) do
    cond do
      last in [true, :inherit] -> acc
      last == false and is_binary(id) -> [Map.put(site(:runtime_start, ctx), :workflow, id) | acc]
      true -> [site(:runtime_unverifiable, ctx) | acc]
    end
  end

  defp apply_site({:__aliases__, _, parts}, fun, ctx, acc) when is_list(parts) do
    parts = resolve(parts, ctx.aliases)

    cond do
      repo?(parts) -> [site(:repo_call, ctx) | acc]
      runtime?(parts) and fun == :start -> [site(:runtime_unverifiable, ctx) | acc]
      runtime?(parts) and not is_atom(fun) -> [site(:runtime_unverifiable, ctx) | acc]
      true -> acc
    end
  end

  defp apply_site({:__MODULE__, _, c}, _fun, _ctx, acc) when is_atom(c), do: acc

  defp apply_site(module, fun, ctx, acc) when not is_atom(module) do
    if fun in @repo_functions, do: [site(:repo_unverifiable, ctx) | acc], else: acc
  end

  defp apply_site(_module, _fun, _ctx, acc), do: acc

  # `Keyword.put(opts, key, false)`, `Map.put/3`, `*.put_new/3` with a key
  # that is not a literal, and `Keyword.merge/2` / `Map.merge/2` of a
  # literal holding `{key, false}` / `%{key => false}`: a runtime key that
  # may be `:authorize?`.
  defp access_sites([mod], fun, [_, key, false], ctx, acc)
       when mod in [:Keyword, :Map] and fun in [:put, :put_new] do
    if literal_key?(key), do: acc, else: runtime_key(ctx, acc)
  end

  defp access_sites([mod], :merge, [_, extra | _], ctx, acc) when mod in [:Keyword, :Map] do
    if Enum.any?(runtime_false_pairs(extra)), do: runtime_key(ctx, acc), else: acc
  end

  defp access_sites(_parts, _fun, _args, _ctx, acc), do: acc

  defp runtime_false_pairs(list) when is_list(list),
    do: Enum.map(list, &match?({key, false} when not is_atom(key) and not is_binary(key), &1))

  defp runtime_false_pairs({:%{}, _, pairs}) when is_list(pairs), do: runtime_false_pairs(pairs)
  defp runtime_false_pairs(_), do: []

  defp runtime_key(ctx, acc), do: [site(:authorize_unverifiable, ctx) | acc]

  defp literal_key?(key), do: is_atom(key) or is_binary(key) or is_number(key)

  # `put_in(opts[:authorize?], v)`, `put_in(opts, [:authorize?], v)`: the
  # key named (the value is checked); `put_in(opts[key], false)`,
  # `put_in(opts, keys, false)`: a runtime key set to false.
  defp path_site(op, args, ctx, acc) do
    {keys, value} = path_keys(args)
    value = if op == :put_in, do: value, else: :unverifiable

    cond do
      :authorize? in keys -> authorize_site(value, ctx, acc)
      value == false and not Enum.all?(keys, &literal_key?/1) -> runtime_key(ctx, acc)
      true -> acc
    end
  end

  defp path_keys([path, value]), do: {access_keys(path), value}
  defp path_keys([_data, keys, value]) when is_list(keys), do: {keys, value}
  defp path_keys([_data, _keys, value]), do: {[{:runtime, [], nil}], value}
  defp path_keys(_args), do: {[], nil}

  defp access_keys({{:., _, [Access, :get]}, _, [inner, key]}), do: access_keys(inner) ++ [key]

  defp access_keys({{:., _, [inner, key]}, meta, []}) when is_atom(key) do
    if meta[:no_parens], do: access_keys(inner) ++ [key], else: []
  end

  defp access_keys(_root), do: []

  defp always?({:always, _, []}), do: true
  defp always?([condition]), do: always?(condition)
  defp always?(_), do: false

  defp authorizes_always?(rest) do
    {_, found} =
      Macro.prewalk(rest, false, fn
        {:authorize_if, _, [{:always, _, []}]} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  defp authorized?([opts], ctx) when is_list(opts) do
    case Keyword.fetch(opts, :authorizers) do
      {:ok, list} when is_list(list) ->
        # `authorizers: []` is its own site (`:no_authorizers`).
        list == [] or
          Enum.any?(list, fn
            {:__aliases__, _, parts} ->
              resolve(parts, ctx.aliases) == [:Ash, :Policy, :Authorizer]

            _ ->
              false
          end)

      {:ok, _other} ->
        false

      :error ->
        Keyword.get(opts, :data_layer) == :embedded
    end
  end

  defp authorized?(_opts, _ctx), do: false

  defp site(kind, ctx),
    do: %{kind: kind, line: ctx.line, function: ctx.fun, module: ctx.module, workflow: nil}
end
