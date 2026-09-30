defmodule BubbleEx.Target.Phoenix.Structural.Bypasses do
  @moduledoc """
  The authorization-bypass inventory of Elixir source (WTF-386,
  `bypass_inventory`), read from the parsed code
  (`Code.string_to_quoted_with_comments/2`), not by grepping text.

  ## Sites

  Every node of the AST is visited, after pipes are rewritten as plain
  calls (`a |> f(b)` is `f(a, b)`); a site's line is the line of the
  nearest enclosing node that has one, and two sites on one line stay two
  sites. A call's module is read from an alias (resolved through the
  `alias`es and `require ..., as:` in scope, with any options, scoped as
  Elixir scopes them: to the rest of their block), an `:"Elixir.Mod"`
  atom, `__MODULE__`, or a module attribute holding a module
  (`@repo Acme.Repo`, from its definition on); any other module
  expression (a variable, an unknown attribute, `Module.concat/1`) cannot
  be read. A `defmodule` name is resolved the way Elixir does (an aliased
  head through its alias, an unaliased nested one under its parent).

  | kind | what |
  |------|------|
  | `:authorize_false` | the pair `authorize?: false` anywhere (a keyword list, a map, a struct, a module attribute, a function body), the arguments `:authorize?, false` side by side (`Keyword.put/3`), the DSL call `authorize? false`, or `put_in/2,3` of an `:authorize?` path to `false` |
  | `:authorize_unverifiable` | the same with any value but the literal `true` (a variable, `@attr`, `!true`, a function call; `update_in/2,3` of an `:authorize?` path): it may be `false` at runtime. Also `false` under a key that is not a literal: `put_in(opts[key], false)`, `put_in(opts, keys, false)`, `Keyword.put(opts, key, false)`, `Map.put/3`, `*.put_new/3`, and a literal `[{key, false}]` or `%{key => false}` anywhere (merged, `Enum.into/2`, passed as options); clause patterns excepted |
  | `:runtime_start` | a generated workflow body's `Runtime.start(input, context, "<workflow id>", false)` (`BubbleEx.Target.Ash.Workflows`: the workflow ignores privacy rules in Bubble), also through an alias or an attribute |
  | `:runtime_unverifiable` | `Runtime.start/4` whose last argument is not `true`, `false` or `:inherit`, or whose workflow is not a literal; `start/4` on a module that cannot be read; `apply/3` of `Runtime.start`; `import` of a `*.Runtime`; in a `quote`, an `alias`, `require ..., as:` or `use` of one |
  | `:policy_bypass` | a `bypass ...` policy, or a `field_policy_bypass ...` field policy |
  | `:policy_always` | a policy whose condition is always true (`always()`, `Builtins.always()` qualified, `expr(true)`, or a list of them) with an `authorize_if` of the same: a bypass under another name |
  | `:authorize_mode` | `authorize` with anything but `:by_default` or `:always` (`:never`, `:when_requested`, a variable) |
  | `:no_authorizers` | `authorizers: []` |
  | `:unauthorized_resource` | `use Ash.Resource` without `Ash.Policy.Authorizer` in a literal `authorizers:` (embedded resources excepted; in a `quote` whose options are `unquote`d, a `__using__` wrapper, its callers are the ones to check). Generated resources are hash-checked, and with `privacy: :omit` have none by design: `inventory/2`'s `:generated` skips them |
  | `:repo_call` | a call on a Repo (a `*.Repo` module, `Ecto.Adapters.SQL`, or any module the files define with `use Ecto.Repo` / `use AshPostgres.Repo`, whatever its name), also through `apply/3`, `:erlang.apply/3`, `Kernel.apply/3`, `Function.capture/3`, `defdelegate ..., to:`; an `import` of one; every `use Ecto.Repo` / `use AshPostgres.Repo` but the generated app's Repo (`:app_repo`, by its exact name, outside a `quote`); a quoted one (a `__using__` defining Repos, whose users are Repos too) and a `use` of such a wrapper; and in a `quote`, an `alias`, `require ..., as:` or `use` of a Repo (injected into every module using it): data access that no Ash policy sees |
  | `:repo_unverifiable` | a call of an `Ecto.Repo` function on a module that cannot be read (`repo.all(q)`, `@unknown.all(q)`, `Module.concat(...).all(q)`, `apply(repo, :all, [q])`): it may reach a Repo |
  | `:data_layer_call` | in a `quote`, an `alias`, `require ..., as:` or `use` of `Ash.Seed` or a data layer module; `Ash.Seed`, and `run_query/2` (and the other reads and writes) of `Ash.DataLayer` or `AshPostgres.DataLayer`: no action, no policy |
  | `:code_eval` | `Code.eval_*`, `Code.compile_*`, `Code.require_file/1`, `Module.eval_quoted/2,3`, `EEx.eval_*`, `EEx.compile_*`: code no one can read here |
  | `:nested_alias` | an `alias` or `require ..., as:` that is not a statement of a block whose scope is known (inside an expression such as `x = (alias A, as: B)` or `f(alias(A))`, or in another macro's `do` block): it still binds for the statements after it, as in Elixir, but where it applies is not certain here |
  | `:body_module` | a `defmodule` of a workflow body module (`bodies/3`) in any other file than the body's scaffolded one |

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
      the generated name map binds it to (`bodies/3`: `<Module>.Workflows.
      <Folder>.Bodies.<action>/2` and its `<action>__step/2` and
      `<action>__condition/1`, in the body's scaffolded file). A
      `# bubble:workflow` comment is a reading aid, never a body
    * `decision:<key>` - an owner's privacy exception (`:decisions`): the
      caller passes only the active ones a trusted owner accepted
      (`BubbleEx.Target.Phoenix.Structural.project/2`'s `:owners`), each
      with the module or function it allows; a site outside that scope
      is unlisted. Any other decision (a finding, a rename, the owner's
      drop of a symbol) authorizes no bypass

  Code inside a `quote` runs where it is injected: it is in no function
  and no scope here, so no workflow body or decision covers it. A
  `:runtime_start` needs no marker: its workflow must be in the bypass
  list and it must sit in that workflow's body entry function. Anything
  else is `:unlisted`: a structural failure.

  ## Not seen

  Options merged from a variable (`Keyword.merge(opts, extra)`,
  `Enum.into(runtime, opts)`) or built by another function; a local call
  after an `import` (the import is a site); `apply/2,3` or
  `:erlang.apply/2` whose module and function both cannot be read, or a
  function capture held in a variable; policies that authorize
  everything under other conditions or checks (`Ash.Policy.Check.Static`,
  a custom check); authorizers added by a Spark fragment; a `__using__`
  wrapper's callers' options; Repo calls in `~H` sigils and `.heex`
  templates (not Elixir code here); queries through Postgrex or another
  library; files outside `lib/` (tests); aliases a dependency's macro
  injects, and a wrapper of a wrapper of a Repo. It is an inventory, not
  a proof.
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
    "private_file_holders" =>
      "a private file's request finds the records holding it (IDs only); who may open it is checked with the actor (Uploads, privacy: :enforced)",
    "ash_authentication" =>
      "AshAuthentication's own interactions with the User (sign-in, tokens) bypass its policies and field policies (privacy: :enforced)",
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
                 |> Map.put("ash_authentication", :policy_bypass)
                 |> Map.put("private_file_holders", :authorize_false)

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
    * `:bodies` - the workflow bodies, `bodies/3` of the generated name
      map: where a workflow's `Runtime.start/4` and markers may be
    * `:decisions` - `%{key => scope}`: the decisions a `decision:<key>`
      marker may cite and the module (`"Acme.Owned"`) or function
      (`"Acme.Owned.run/2"`) each allows (`decision_scope/1`); a list of
      keys allows nothing
    * `:generated` - paths of generated (hash-checked) files: their
      `:unauthorized_resource` sites are skipped
    * `:app_repo` - the generated app's Repo module (`"Acme.Repo"`): the
      only `use Ecto.Repo` / `use AshPostgres.Repo` module that is not a
      site. Every such module in `files` is a Repo: calls on it are
      `:repo_call` sites, whatever its name

  Returns the sites and the paths that do not parse (reported, never
  skipped silently).
  """
  @spec inventory(%{String.t() => binary()}, keyword()) :: %{
          sites: [site()],
          unparsable: [String.t()]
        }
  def inventory(files, opts) do
    files =
      files
      |> Enum.filter(fn {path, _} -> Path.extname(path) in [".ex", ".exs"] end)
      |> Enum.sort()

    scan_opts =
      [app_repo: Keyword.get(opts, :app_repo)] ++ repo_context(Map.values(Map.new(files)))

    ctx = %{
      workflows: opts |> Keyword.get(:workflows, []) |> MapSet.new(),
      scaffold: Keyword.get(opts, :scaffold, %{}),
      bodies: Keyword.get(opts, :bodies, %{}),
      decisions: decision_scopes(Keyword.get(opts, :decisions, %{})),
      generated: opts |> Keyword.get(:generated, []) |> MapSet.new()
    }

    {sites, unparsable} =
      Enum.reduce(files, {[], []}, fn {path, source}, {sites, bad} ->
        case scan(source, scan_opts) do
          {:ok, found} ->
            {[classify_file(path, owned_sites(found, path, ctx), ctx) | sites], bad}

          :error ->
            {sites, [path | bad]}
        end
      end)

    %{sites: sites |> Enum.reverse() |> Enum.concat(), unparsable: Enum.reverse(unparsable)}
  end

  # The Repo modules of `sources`: those defined with `use Ecto.Repo` /
  # `use AshPostgres.Repo`, and those that `use` a wrapper module whose
  # quoted code (`__using__`) does (`:repo_wrappers`).
  defp repo_context(sources) do
    wrappers = collect(sources, [], :repo_wrapper)
    repos = collect(sources, [repo_wrappers: wrappers], :defines_repo)
    [repos: repos, repo_wrappers: wrappers]
  end

  defp collect(sources, opts, kind) do
    for source <- sources,
        {:ok, found} <- [scan(source, opts)],
        %{kind: ^kind, module: m} when is_binary(m) <- found,
        into: MapSet.new(),
        do: m
  end

  # A generated resource is hash-checked: its missing authorizer is the
  # generator's (`privacy: :omit`), not a bypass of the owner's. A module
  # definition is a site only when it defines a workflow body module
  # outside that body's scaffolded file.
  defp owned_sites(found, path, ctx) do
    body_paths = for {_, {_, _, p, m}} <- ctx.bodies, into: %{}, do: {m, p}

    found
    |> Enum.reject(
      &(&1.kind in [:defines_repo, :repo_wrapper] or
          (&1.kind == :unauthorized_resource and MapSet.member?(ctx.generated, path)))
    )
    |> Enum.flat_map(fn
      %{kind: :defines, module: m} = site ->
        if Map.has_key?(body_paths, m) and body_paths[m] != path,
          do: [%{site | kind: :body_module}],
          else: []

      site ->
        [site]
    end)
  end

  @doc """
  The workflow bodies of a generated name map (`.wtf/workflows.json`'s
  `names`, `BubbleEx.Target.Ash.Workflows.Spec`'s `names`) under the root
  module `namespace` and the OTP app `app`: `%{{module, function} =>
  {workflow id, :entry | :helper, path, module}}`. The entry is
  `<action>/2` of `<namespace>.Workflows.<resource>.Bodies`, scaffolded
  at `lib/<app>/workflows/<resource, underscored>/bodies.ex`; its helpers
  are `<action>__step/2` and `<action>__condition/1`. A body counts only
  in that file, and another file defining the module is a site.
  """
  @spec bodies(map() | nil, String.t() | nil, String.t() | nil) :: %{
          {String.t(), String.t()} => {String.t(), :entry | :helper, String.t(), String.t()}
        }
  def bodies(%{"actions" => actions}, namespace, app)
      when is_map(actions) and is_binary(namespace) and is_binary(app) do
    for {id, %{"resource" => r, "action" => a}} <- actions,
        is_binary(id) and is_binary(r) and is_binary(a),
        module = "#{namespace}.Workflows.#{r}.Bodies",
        path = "lib/#{app}/workflows/#{Macro.underscore(r)}/bodies.ex",
        {fun, role} <- [
          {"#{a}/2", :entry},
          {"#{a}__step/2", :helper},
          {"#{a}__condition/1", :helper}
        ],
        into: %{},
        do: {{module, fun}, {id, role, path, module}}
  end

  def bodies(_names, _namespace, _app), do: %{}

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
        body =
          case Map.get(ctx.bodies, {site.module, site.function}) do
            {id, role, ^path, _module} when not site.quoted? -> {id, role}
            _ -> nil
          end

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

  defp classify(%{kind: :body_module}, _ctx, used),
    do: {:unlisted, "defines a workflow body module outside its scaffolded file", used}

  # Code in a `quote` runs where it is injected, not in the module or
  # function it is written in.
  defp classify(%{quoted?: true, marker: {kind, _}}, _ctx, used)
       when kind in [:workflow, :decision],
       do: {:unlisted, "inside a quote: it runs where it is injected", used}

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

  defp in_scope?(_scope, %{quoted?: true}), do: false
  defp in_scope?({:module, module}, site), do: site.module == module

  defp in_scope?({:function, module, fun}, site),
    do: site.module == module and site.function == fun

  # --- the AST ------------------------------------------------------------------------

  # Functions of `Ecto.Repo` and `Ecto.Adapters.SQL`: a call of one of
  # them on a module that cannot be read (a variable, an attribute, an
  # expression, `apply/3`) may reach a Repo.
  @repo_functions ~w(aggregate all all_by checkout delete delete! delete_all exists?
                     get get! get_by get_by! insert insert! insert_all insert_or_update
                     insert_or_update! one one! preload query query! query_many
                     query_many! reload reload! stream transact transaction update
                     update! update_all)a

  # `Ash.DataLayer` functions that read or write without actions or policies.
  @data_layer_functions ~w(run_query run_aggregate_query run_query_with_lateral_join
                           create update destroy upsert bulk_create update_query
                           destroy_query)a

  # `Code`, `Module.eval_quoted/2,3` and `EEx`: code evaluated at runtime.
  # Entries `scan/2` records for the passes, never sites.
  @internal_kinds [:defines, :defines_repo, :repo_wrapper]

  # Forms whose blocks scope aliases (Elixir): an alias in their `do`,
  # `else`, ... or a clause does not reach the code after them.
  @scoping [
    :defmodule,
    :def,
    :defp,
    :defmacro,
    :defmacrop,
    :quote,
    :if,
    :unless,
    :case,
    :cond,
    :for,
    :with,
    :try,
    :receive,
    :fn
  ]

  @data_layer_modules [[:Ash, :Seed], [:Ash, :DataLayer], [:AshPostgres, :DataLayer]]

  @eval_functions ~w(eval_string eval_quoted eval_quoted_with_env eval_file compile_string
                     compile_quoted compile_file require_file)a

  @doc """
  The sites of one source text, each with the marker on or above its line,
  its enclosing module and function; `:error` when it does not parse.
  Options: `:app_repo` (see `inventory/2`); the Repo modules are those the
  source defines.
  """
  @spec sites(String.t(), keyword()) :: {:ok, [site()]} | :error
  def sites(source, opts \\ []) do
    with {:ok, found} <- scan(source, opts ++ repo_context([source])),
         do: {:ok, Enum.reject(found, &(&1.kind in @internal_kinds))}
  end

  # The sites plus a `:defines` entry per module definition and a
  # `:defines_repo` entry per Repo module. Options: `:repos` (module
  # names), `:app_repo`.
  defp scan(source, opts) do
    case Code.string_to_quoted_with_comments(source, emit_warnings: false) do
      {:ok, ast, comments} ->
        markers =
          for %{line: line, text: text} <- comments,
              [_, token] <- [Regex.run(@marker, text)],
              into: %{},
              do: {line, marker(token)}

        ctx = %{
          line: nil,
          fun: nil,
          module: nil,
          quoted?: false,
          aliases: %{},
          attributes: %{},
          repos: Keyword.get(opts, :repos, MapSet.new()),
          repo_wrappers: Keyword.get(opts, :repo_wrappers, MapSet.new()),
          app_repo: Keyword.get(opts, :app_repo),
          stmt: nil,
          scope_known?: true,
          parent: nil
        }

        ast = unpipe(ast)
        ctx = %{ctx | stmt: ast}

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

  # `a |> f(b)` as `f(a, b)`, so a piped call is matched like any other.
  defp unpipe(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [left, {_, _, args} = right]} = node when is_list(args) ->
        try do
          Macro.pipe(left, right, 0)
        rescue
          _ -> node
        end

      node ->
        node
    end)
  end

  # Aliases and module attributes are lexical, as in Elixir: `alias`,
  # `require ..., as:` and `@attr Module` bind for the statements after
  # them in the same block (and what those contain), never outside it: an
  # alias in one module does not reach a sibling module, nor one in an
  # `if` or `case` clause the code after it. A nested `defmodule Inner`
  # aliases `Inner` for the rest of its parent's body.
  defp bind({:alias, _, [target | rest]}, ctx),
    do: %{ctx | aliases: add_alias(target, rest, ctx)}

  defp bind({:require, _, [target, opts]}, ctx) when is_list(opts) do
    if Keyword.has_key?(opts, :as),
      do: %{ctx | aliases: add_alias(target, [opts], ctx)},
      else: ctx
  end

  defp bind({:@, _, [{name, _, [value]}]}, ctx) when is_atom(name) do
    case module_of(value, ctx) do
      {:known, parts} -> %{ctx | attributes: Map.put(ctx.attributes, name, parts)}
      _ -> %{ctx | attributes: Map.delete(ctx.attributes, name)}
    end
  end

  defp bind({:defmodule, _, [{:__aliases__, _, [head]} | _]}, %{module: module} = ctx)
       when is_atom(head) and is_binary(module) do
    if Map.has_key?(ctx.aliases, head),
      do: ctx,
      else: %{ctx | aliases: Map.put(ctx.aliases, head, module_parts(module) ++ [head])}
  end

  # An alias nested in an expression (`x = (alias A, as: B)`,
  # `f(alias(A))`) binds after the statement too, unless it is in a form
  # that scopes it.
  defp bind(expr, ctx) do
    expr
    |> nested_aliases()
    |> Enum.reduce(ctx, fn node, ctx -> bind(node, ctx) end)
  end

  defp nested_aliases(expr) do
    {_, found} =
      Macro.prewalk(expr, [], fn
        # replaced by an atom: its children are not visited
        {form, _, _}, acc when form in @scoping or form == :-> ->
          {:scoped, acc}

        {:alias, _, [_ | _]} = node, acc ->
          {node, [node | acc]}

        {:require, _, [_, opts]} = node, acc when is_list(opts) ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp add_alias({:__aliases__, _, _} = target, rest, ctx) do
    short =
      case rest do
        [opts] when is_list(opts) -> Keyword.get(opts, :as)
        _ -> nil
      end

    case {module_of(target, ctx), short} do
      {{:known, parts}, {:__aliases__, _, [name]}} when is_atom(name) ->
        Map.put(ctx.aliases, name, parts)

      {{:known, parts}, nil} ->
        Map.put(ctx.aliases, target |> elem(2) |> List.last() |> alias_head(parts), parts)

      _ ->
        ctx.aliases
    end
  end

  defp add_alias({{:., _, [base, :{}]}, _, children}, _rest, ctx) do
    case module_of(base, ctx) do
      {:known, base} ->
        for {:__aliases__, _, parts} <- children,
            is_list(parts) and Enum.all?(parts, &is_atom/1),
            into: ctx.aliases,
            do: {List.last(parts), base ++ parts}

      _ ->
        ctx.aliases
    end
  end

  defp add_alias(_target, _rest, ctx), do: ctx.aliases

  # `alias __MODULE__` aliases the module's last segment.
  defp alias_head(last, _parts) when is_atom(last), do: last
  defp alias_head(_last, parts), do: List.last(parts)

  defp resolve([head | rest] = parts, aliases) when is_atom(head) do
    case Map.fetch(aliases, head) do
      {:ok, full} when full != [head] -> full ++ rest
      _ -> parts
    end
  end

  defp resolve(parts, _aliases), do: parts

  defp elixir_module(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> name -> name |> String.split(".") |> Enum.map(&String.to_atom/1)
      _ -> nil
    end
  end

  defp module_name(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp module_parts(nil), do: nil
  defp module_parts(name), do: name |> String.split(".") |> Enum.map(&String.to_atom/1)

  # What a call's module expression is: `{:known, parts}` (an alias, an
  # `Elixir.` atom, `__MODULE__`, an attribute holding a module),
  # `{:erlang, atom}`, or `:dynamic` (a variable, an unknown attribute, an
  # expression such as `Module.concat/1`).
  defp module_of({:__aliases__, _, [{:__MODULE__, _, c} | rest]}, ctx) when is_atom(c) do
    case module_parts(ctx.module) do
      nil -> :dynamic
      parts -> {:known, parts ++ rest}
    end
  end

  defp module_of({:__aliases__, _, parts}, ctx) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: {:known, resolve(parts, ctx.aliases)}, else: :dynamic
  end

  defp module_of({:__MODULE__, _, c}, ctx) when is_atom(c) do
    case module_parts(ctx.module) do
      nil -> :dynamic
      parts -> {:known, parts}
    end
  end

  defp module_of({:@, _, [{name, _, c}]}, ctx) when is_atom(name) and is_atom(c) do
    case Map.fetch(ctx.attributes, name) do
      {:ok, parts} -> {:known, parts}
      :error -> :dynamic
    end
  end

  defp module_of(atom, _ctx) when is_atom(atom) do
    case elixir_module(atom) do
      nil -> {:erlang, atom}
      parts -> {:known, parts}
    end
  end

  defp module_of(_expr, _ctx), do: :dynamic

  # A `*.Repo`, `Ecto.Adapters.SQL`, or any module the files define with
  # `use Ecto.Repo` / `use AshPostgres.Repo`.
  defp repo?(parts, ctx),
    do:
      List.last(parts) == :Repo or Enum.take(parts, 3) == [:Ecto, :Adapters, :SQL] or
        MapSet.member?(ctx.repos, module_name(parts))

  defp runtime?(parts), do: List.last(parts) == :Runtime

  # `ctx`: the nearest line, the enclosing function (`name/arity`, nil
  # outside one), the enclosing module, whether inside a `quote`, the
  # file's aliases and module attributes.
  defp walk({:defmodule, meta, [{:__aliases__, _, parts} | rest]} = node, ctx, acc)
       when is_list(meta) and is_list(parts) do
    ctx = %{ctx | line: Keyword.get(meta, :line, ctx.line)}
    name = defined_module(parts, ctx)
    ctx = %{ctx | module: name, parent: :defmodule}
    acc = [%{site(:defines, ctx) | module: name} | acc]
    acc = node_sites(node, ctx, acc)
    walk(rest, ctx, acc)
  end

  # A block's statements in order: each sees the aliases and attributes
  # the statements before it bound.
  defp walk({:__block__, meta, exprs} = node, ctx, acc) when is_list(meta) and is_list(exprs) do
    # Its statements are statements only when it is one itself (not a
    # parenthesized block inside an expression) in a block whose scope
    # is known.
    statements? = node == ctx.stmt and ctx.scope_known?
    ctx = %{ctx | line: Keyword.get(meta, :line, ctx.line)}
    acc = node_sites(node, ctx, acc)

    {acc, _ctx} =
      Enum.reduce(exprs, {acc, ctx}, fn expr, {acc, ctx} ->
        {walk(expr, %{ctx | stmt: if(statements?, do: expr)}, acc), bind(expr, ctx)}
      end)

    acc
  end

  # A clause's patterns are not values: `{key, false} -> ...` sets nothing.
  defp walk({:->, meta, [patterns, body]}, ctx, acc) when is_list(meta) and is_list(patterns) do
    ctx = %{ctx | line: Keyword.get(meta, :line, ctx.line)}
    acc = Enum.reduce(patterns, acc, &walk(&1, ctx, &2))
    walk(body, %{ctx | stmt: body, scope_known?: true}, acc)
  end

  # Code in a quote belongs to no function here.
  defp walk({:quote, meta, args}, ctx, acc) when is_list(meta) do
    ctx = %{
      ctx
      | line: Keyword.get(meta, :line, ctx.line),
        fun: nil,
        quoted?: true,
        parent: :quote
    }

    walk(args, ctx, acc)
  end

  defp walk({form, meta, args} = node, ctx, acc) when is_list(meta) do
    fun = if ctx.quoted?, do: nil, else: def_name(node) || ctx.fun
    ctx = %{ctx | line: Keyword.get(meta, :line, ctx.line), fun: fun}
    acc = node_sites(node, ctx, acc)
    ctx = %{ctx | parent: form}
    acc = walk(form, ctx, acc)
    if is_list(args), do: Enum.reduce(args, acc, &walk(&1, ctx, &2)), else: acc
  end

  # A `do`/`else`/... block: its body is a statement; its scope is known
  # for the forms Elixir scopes (`@scoping`), not for another macro's.
  defp walk({left, right}, ctx, acc) when left in [:do, :else, :after, :rescue, :catch] do
    walk(right, %{ctx | stmt: right, scope_known?: ctx.parent in @scoping}, acc)
  end

  defp walk({left, right}, ctx, acc) do
    acc = pair_site(left, right, ctx, acc)
    walk(right, ctx, walk(left, ctx, acc))
  end

  defp walk(list, ctx, acc) when is_list(list) do
    acc = list_site(list, ctx, acc)
    Enum.reduce(list, acc, &walk(&1, ctx, &2))
  end

  defp walk(_other, _ctx, acc), do: acc

  # The module a `defmodule` defines, as Elixir names it: an aliased head
  # expands through the alias; an unaliased one nested in a module is
  # prefixed by it; `__MODULE__.Inner` is the enclosing module's.
  defp defined_module([{:__MODULE__, _, _} | rest], ctx),
    do: Enum.join([ctx.module || "__MODULE__" | Enum.map(rest, &part/1)], ".")

  defp defined_module([head | _] = parts, ctx) when is_atom(head) do
    resolved = resolve(parts, ctx.aliases)

    cond do
      resolved != parts -> module_name(resolved)
      ctx.module -> ctx.module <> "." <> Enum.map_join(parts, ".", &part/1)
      true -> Enum.map_join(parts, ".", &part/1)
    end
  end

  defp defined_module(parts, _ctx), do: Enum.map_join(parts, ".", &part/1)

  defp part(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp part(_), do: "?"

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

  # `[{key, false}]`, `%{key => false}` with a key that is not a literal: a
  # runtime key that may be `:authorize?` (in a keyword list, a map, a
  # `Keyword.merge/2` or `Enum.into/2`).
  defp list_site(list, ctx, acc) do
    if Enum.any?(list, &(match?({key, false} when not is_atom(key), &1) and runtime_pair?(&1))),
      do: runtime_key(ctx, acc),
      else: acc
  end

  defp runtime_pair?({key, false}), do: not literal_key?(key)

  defp authorize_site(true, _ctx, acc), do: acc
  defp authorize_site(false, ctx, acc), do: [site(:authorize_false, ctx) | acc]
  defp authorize_site(_value, ctx, acc), do: [site(:authorize_unverifiable, ctx) | acc]

  # A remote call: `Mod.fun(...)`, `@attr.fun(...)`, `var.fun(...)`,
  # `:"Elixir.Mod".fun(...)`, `:erlang.apply(...)`.
  defp node_sites({{:., _, [module, fun]}, meta, args}, ctx, acc)
       when is_atom(fun) and is_list(args) do
    acc =
      case module_of(module, ctx) do
        {:known, parts} -> known_call(parts, fun, args, ctx, acc)
        {:erlang, :erlang} when fun == :apply -> apply_args(args, ctx, acc)
        {:erlang, _} -> acc
        # `map.field` is not a call
        :dynamic -> if meta[:no_parens], do: acc, else: dynamic_call(fun, args, ctx, acc)
      end

    argument_sites(args, ctx, acc)
  end

  # `apply(module, fun, args)`.
  defp node_sites({:apply, _, [module, fun, _args] = args}, ctx, acc) do
    acc = apply_site(module, fun, ctx, acc)
    argument_sites(args, ctx, acc)
  end

  # `import Acme.Repo`, `import Ecto.Adapters.SQL`: every local call may be
  # a Repo call; `import ...Runtime`: `start/4` unseen.
  defp node_sites({:import, _, [module | _]}, ctx, acc) do
    case module_of(module, ctx) do
      {:known, parts} ->
        cond do
          repo?(parts, ctx) -> [site(:repo_call, ctx) | acc]
          runtime?(parts) -> [site(:runtime_unverifiable, ctx) | acc]
          true -> acc
        end

      _ ->
        acc
    end
  end

  # `defdelegate all(q), to: Acme.Repo`.
  defp node_sites({:defdelegate, _, [head, opts]}, ctx, acc) when is_list(opts) do
    name = Keyword.get(opts, :as) || elem(head, 0)

    case module_of(Keyword.get(opts, :to), ctx) do
      {:known, parts} -> known_call(parts, name, delegate_args(head), ctx, acc)
      :dynamic -> dynamic_call(name, delegate_args(head), ctx, acc)
      _ -> acc
    end
  end

  # An `alias` or `require ..., as:` that is not a statement of a known
  # scope (inside an expression, or a macro's block): where it applies is
  # not read. In a `quote`, one of a Repo, a Runtime or a data layer
  # module is injected into every module that uses it.
  defp node_sites({:alias, _, [target | _]} = node, ctx, acc),
    do: alias_sites(node, target, ctx, acc)

  defp node_sites({:require, _, [target, opts]} = node, ctx, acc) when is_list(opts) do
    if Keyword.has_key?(opts, :as),
      do: alias_sites(node, target, ctx, acc),
      else: acc
  end

  # `use Ash.Resource` without `Ash.Policy.Authorizer` (embedded resources
  # are read through their parent; a `__using__` wrapper passing its
  # options on is its callers' to check); `use Ecto.Repo` in any module
  # but the generated app's Repo (`:app_repo`): a second Repo.
  defp node_sites({:use, _, [module | opts]}, ctx, acc) do
    case module_of(module, ctx) do
      {:known, [:Ash, :Resource]} ->
        if authorized?(opts, ctx) or (ctx.quoted? and unquotes?(opts)),
          do: acc,
          else: [site(:unauthorized_resource, ctx) | acc]

      {:known, parts} when parts in [[:Ecto, :Repo], [:AshPostgres, :Repo]] ->
        repo_definition(ctx, acc)

      {:known, parts} ->
        used_sites(parts, ctx, acc)

      _ ->
        acc
    end
  end

  # `put_in/2,3`, `update_in/2,3`, `get_and_update_in/2,3`.
  defp node_sites({op, _, args}, ctx, acc)
       when op in [:put_in, :update_in, :get_and_update_in] and is_list(args) do
    acc = path_site(op, args, ctx, acc)
    argument_sites(args, ctx, acc)
  end

  # The DSL: `authorize? false`, `bypass ...`, `authorize :never`,
  # `policy always() do authorize_if always() end` (and its spellings).
  defp node_sites({:authorize?, _, [value]}, ctx, acc), do: authorize_site(value, ctx, acc)
  defp node_sites({:bypass, _, [_ | _]}, ctx, acc), do: [site(:policy_bypass, ctx) | acc]

  defp node_sites({:field_policy_bypass, _, [_ | _]}, ctx, acc),
    do: [site(:policy_bypass, ctx) | acc]

  defp node_sites({:authorize, _, [mode]}, ctx, acc) when mode not in [:by_default, :always],
    do: [site(:authorize_mode, ctx) | acc]

  defp node_sites({:policy, _, [condition | rest]} = node, ctx, acc) do
    acc =
      if always_condition?(condition, ctx) and authorizes_always?(rest, ctx),
        do: [site(:policy_always, ctx) | acc],
        else: acc

    node |> elem(2) |> argument_sites(ctx, acc)
  end

  defp node_sites({:%{}, _, pairs}, ctx, acc) when is_list(pairs), do: list_site(pairs, ctx, acc)

  defp node_sites({_form, _, args}, ctx, acc) when is_list(args),
    do: argument_sites(args, ctx, acc)

  defp node_sites(_node, _ctx, acc), do: acc

  # In a quote (a `__using__`): every module using the wrapper is a Repo,
  # and the quoted `use` is a site, the app's Repo included. Outside one:
  # a Repo module, a site unless it is the app's Repo.
  defp repo_definition(%{quoted?: true} = ctx, acc),
    do: [site(:repo_call, ctx), %{site(:repo_wrapper, ctx) | module: ctx.module} | acc]

  defp repo_definition(ctx, acc) do
    acc = [%{site(:defines_repo, ctx) | module: ctx.module} | acc]

    if ctx.module != nil and ctx.module == ctx.app_repo,
      do: acc,
      else: [site(:repo_call, ctx) | acc]
  end

  # `use Wrapper` of a module whose `__using__` defines a Repo: a Repo; a
  # quoted `use` of a Repo, Runtime or data layer module: injected.
  defp used_sites(parts, ctx, acc) do
    cond do
      MapSet.member?(ctx.repo_wrappers, module_name(parts)) and not ctx.quoted? ->
        [site(:repo_call, ctx), %{site(:defines_repo, ctx) | module: ctx.module} | acc]

      ctx.quoted? ->
        injected_site(parts, ctx, acc)

      true ->
        acc
    end
  end

  defp alias_sites(node, target, ctx, acc) do
    acc =
      if node == ctx.stmt and ctx.scope_known?,
        do: acc,
        else: [site(:nested_alias, ctx) | acc]

    with true <- ctx.quoted?,
         {:known, parts} <- module_of(alias_target(target), ctx) do
      injected_site(parts, ctx, acc)
    else
      _ -> acc
    end
  end

  # `alias A.{B, C}`: the base (a Repo's parent is not a Repo).
  defp alias_target({{:., _, [base, :{}]}, _, _}), do: base
  defp alias_target(target), do: target

  defp injected_site(parts, ctx, acc) do
    cond do
      repo?(parts, ctx) -> [site(:repo_call, ctx) | acc]
      runtime?(parts) -> [site(:runtime_unverifiable, ctx) | acc]
      parts in @data_layer_modules -> [site(:data_layer_call, ctx) | acc]
      true -> acc
    end
  end

  defp delegate_args({_name, _, args}) when is_list(args), do: args
  defp delegate_args(_head), do: []

  defp unquotes?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:unquote, _, _} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  # A call on a module that can be read.
  defp known_call([:Kernel], :apply, [module, fun, _], ctx, acc),
    do: apply_site(module, fun, ctx, acc)

  defp known_call([:Function], :capture, [module, fun, _], ctx, acc),
    do: apply_site(module, fun, ctx, acc)

  defp known_call(parts, fun, args, ctx, acc) do
    if runtime?(parts) and fun == :start and length(args) == 4 do
      runtime_site(args, ctx, acc)
    else
      case call_kind(parts, fun, ctx) do
        nil -> access_sites(parts, fun, args, ctx, acc)
        kind -> [site(kind, ctx) | acc]
      end
    end
  end

  # The site kind of a call on a known module (`fun` nil when unknown, as
  # in `apply/3` of a variable function), or nil.
  defp call_kind([:Ash, :Seed], _fun, _ctx), do: :data_layer_call

  defp call_kind(parts, fun, _ctx)
       when parts in [[:Ash, :DataLayer], [:AshPostgres, :DataLayer]] and
              (fun in @data_layer_functions or fun == nil),
       do: :data_layer_call

  defp call_kind([mod], fun, _ctx)
       when mod in [:Code, :Module, :EEx] and (fun in @eval_functions or fun == nil),
       do: :code_eval

  defp call_kind(parts, _fun, ctx), do: if(repo?(parts, ctx), do: :repo_call)

  # A call on a module that cannot be read.
  defp dynamic_call(fun, args, ctx, acc) do
    cond do
      fun == :start and length(args) == 4 -> [site(:runtime_unverifiable, ctx) | acc]
      fun in @repo_functions -> [site(:repo_unverifiable, ctx) | acc]
      true -> acc
    end
  end

  defp apply_args([module, fun, _], ctx, acc), do: apply_site(module, fun, ctx, acc)
  defp apply_args(_args, _ctx, acc), do: acc

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

  # `apply(module, fun, args)`, `Function.capture(module, fun, arity)`.
  defp apply_site(module, fun, ctx, acc) do
    fun = if is_atom(fun), do: fun, else: nil

    kind =
      case module_of(module, ctx) do
        {:known, parts} -> applied_kind(parts, fun, ctx)
        :dynamic when fun in @repo_functions or fun == :start -> :repo_unverifiable
        _ -> nil
      end

    if kind, do: [site(kind, ctx) | acc], else: acc
  end

  defp applied_kind(parts, fun, ctx) do
    if runtime?(parts) and fun in [:start, nil],
      do: :runtime_unverifiable,
      else: call_kind(parts, fun, ctx)
  end

  # `Keyword.put(opts, key, false)`, `Map.put/3`, `*.put_new/3` with a key
  # that is not a literal: a runtime key that may be `:authorize?`.
  defp access_sites([mod], fun, [_, key, false], ctx, acc)
       when mod in [:Keyword, :Map] and fun in [:put, :put_new] do
    if literal_key?(key), do: acc, else: runtime_key(ctx, acc)
  end

  defp access_sites(_parts, _fun, _args, _ctx, acc), do: acc

  defp runtime_key(ctx, acc), do: [site(:authorize_unverifiable, ctx) | acc]

  # A key written out in full (`:k`, `"k"`, `{"a", "b"}`): not `:authorize?`
  # at runtime unless it is `:authorize?`.
  defp literal_key?(key), do: Macro.quoted_literal?(key)

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

  # `always()`, `Builtins.always()` (qualified), `expr(true)`, and a list of
  # them.
  defp always?({:always, _, []}, _ctx), do: true
  defp always?({:expr, _, [true]}, _ctx), do: true

  defp always?({{:., _, [module, :always]}, _, []}, ctx) do
    case module_of(module, ctx) do
      {:known, parts} -> List.last(parts) == :Builtins
      _ -> false
    end
  end

  defp always?(_node, _ctx), do: false

  defp always_condition?([_ | _] = conditions, ctx), do: Enum.all?(conditions, &always?(&1, ctx))
  defp always_condition?(condition, ctx), do: always?(condition, ctx)

  defp authorizes_always?(rest, ctx) do
    {_, found} =
      Macro.prewalk(rest, false, fn
        {:authorize_if, _, [check | _]} = node, found -> {node, found or always?(check, ctx)}
        node, found -> {node, found}
      end)

    found
  end

  defp authorized?([opts], ctx) when is_list(opts) do
    case Keyword.fetch(opts, :authorizers) do
      {:ok, list} when is_list(list) ->
        # `authorizers: []` is its own site (`:no_authorizers`).
        list == [] or
          Enum.any?(list, &(module_of(&1, ctx) == {:known, [:Ash, :Policy, :Authorizer]}))

      {:ok, _other} ->
        false

      :error ->
        Keyword.get(opts, :data_layer) == :embedded
    end
  end

  defp authorized?(_opts, _ctx), do: false

  defp site(kind, ctx),
    do: %{
      kind: kind,
      line: ctx.line,
      function: ctx.fun,
      module: ctx.module,
      quoted?: ctx.quoted?,
      workflow: nil
    }
end
