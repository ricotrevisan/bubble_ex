defmodule BubbleEx.Target.Phoenix.Structural.Bypasses do
  @moduledoc """
  The authorization-bypass inventory of Elixir source (WTF-386,
  `bypass_inventory`), read from the parsed code
  (`Code.string_to_quoted_with_comments/2`), not by grepping text.

  ## Sites

  Every node of the AST is visited; a site's line is the line of the
  nearest enclosing node that has one, and two sites on one line stay two
  sites.

  | kind | what |
  |------|------|
  | `:authorize_false` | the pair `authorize?: false` anywhere (a keyword list, a map, a struct, a module attribute, a function body), the arguments `:authorize?, false` side by side (`Keyword.put/3`), or the DSL call `authorize? false` |
  | `:authorize_unverifiable` | the same with any value but the literal `true`: a variable, `@attr`, `!true`, a function call. It may be `false` at runtime |
  | `:runtime_start` | a generated workflow body's `Runtime.start(input, context, "<workflow id>", false)` (`BubbleEx.Target.Ash.Workflows`: the workflow ignores privacy rules in Bubble) |
  | `:runtime_unverifiable` | `Runtime.start/4` whose last argument is not `true`, `false` or `:inherit`, or whose workflow is not a literal |
  | `:policy_bypass` | a `bypass ...` policy |
  | `:authorize_mode` | `authorize` with anything but `:by_default` or `:always` (`:never`, `:when_requested`, a variable) |
  | `:no_authorizers` | `authorizers: []` |
  | `:repo_call` | a call on a `*.Repo` module or `Ecto.Adapters.SQL`: data access that no Ash policy sees |

  ## Markers

  A site is accounted for by a `# bubble:ignores_privacy <token>` comment
  on its line or the line above:

    * `scaffold:<purpose>` - written by the generator, from the closed
      vocabulary `scaffold_purposes/0`, each covering one site kind
      (`purpose_kind/1`); the rendered `.wtf/bypasses.json` (generated, so
      hash-checked) lists how many sites of each purpose each file has in
      each enclosing function, and no function may have more
    * `workflow:<id>` (or a bare `<id>`) - a workflow that ignores privacy
      rules in Bubble, and only inside that workflow's generated body
      (after its `# bubble:workflow <id>` comment and before the next one)
    * `decision:<key>` - an owner's decision, which the caller must have
      resolved as active and authored by the owner (`:decisions`)

  A `:runtime_start` needs no marker: its workflow must be in the bypass
  list and it must sit in that workflow's body. Anything else is
  `:unlisted`: a structural failure.

  ## Not seen

  A bypass that names no literal `authorize?` key (options built with
  `Keyword.merge/2` from a variable, `put_in/2` with runtime keys,
  `apply/3`); a Repo reached through an alias, an import, `apply/3` or a
  variable; `Runtime.start/4` through an alias; a `policy always()` whose
  check is `authorize_if always()`, or an owned resource with no
  authorizer at all; queries through Postgrex or another library; files
  outside `lib/` (tests). A hand-written `# bubble:workflow` comment in
  owned code passes for a workflow body, and a `decision:<key>` marker
  accepts any active owner decision (WTF-424). It is an inventory, not a
  proof.
  """

  @marker ~r/#\s*bubble:ignores_privacy\s+(\S+)/
  @workflow_marker ~r/#\s*bubble:workflow\s+(\S+)/

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
    * `:decisions` - keys of the owner's active decisions a marker may cite

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
      decisions: opts |> Keyword.get(:decisions, []) |> MapSet.new()
    }

    {sites, unparsable} =
      files
      |> Enum.filter(fn {path, _} -> Path.extname(path) in [".ex", ".exs"] end)
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn {path, source}, {sites, bad} ->
        case sites(source) do
          {:ok, found} -> {[classify_file(path, found, ctx) | sites], bad}
          :error -> {sites, [path | bad]}
        end
      end)

    %{sites: sites |> Enum.reverse() |> Enum.concat(), unparsable: Enum.reverse(unparsable)}
  end

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
        site = Map.put(site, :path, path)
        {class, detail, used} = classify(site, ctx, used)
        {Map.merge(site, %{class: class, detail: detail}), used}
      end)

    sites
  end

  defp classify(%{kind: :runtime_start, workflow: w} = site, ctx, used) do
    cond do
      not MapSet.member?(ctx.workflows, w) ->
        {:unlisted, "the workflow does not ignore privacy rules in Bubble", used}

      site.in_workflow != w ->
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

  defp classify(%{marker: {:decision, key}}, ctx, used) do
    if MapSet.member?(ctx.decisions, key),
      do: {:marked, nil, used},
      else: {:unlisted, "the decision is not an active owner decision here", used}
  end

  defp classify(_site, _ctx, used), do: {:unlisted, nil, used}

  # --- the AST ------------------------------------------------------------------------

  @doc """
  The sites of one source text, each with the marker on or above its line
  and the workflow body it is in; `:error` when it does not parse.
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

        bodies =
          for %{line: line, text: text} <- comments,
              [_, id] <- [Regex.run(@workflow_marker, text)],
              do: {line, id}

        {:ok,
         ast
         |> walk({nil, nil}, [])
         |> Enum.reverse()
         |> Enum.sort_by(&(&1.line || 0))
         |> Enum.map(&annotate(&1, markers, bodies))}

      {:error, _} ->
        :error
    end
  end

  defp marker("scaffold:" <> purpose), do: {:scaffold, purpose}
  defp marker("decision:" <> key), do: {:decision, key}
  defp marker("workflow:" <> id), do: {:workflow, id}
  defp marker(id), do: {:workflow, id}

  defp annotate(%{line: line} = site, markers, bodies) do
    marker = line && (markers[line] || markers[line - 1])

    body =
      bodies
      |> Enum.filter(fn {l, _} -> line && l < line end)
      |> Enum.max_by(&elem(&1, 0), fn -> {nil, nil} end)
      |> elem(1)

    Map.merge(site, %{marker: marker, in_workflow: body})
  end

  # `line` is `{line, function}`: the nearest line and the enclosing
  # function (`name/arity`, nil outside one).
  defp walk({form, meta, args} = node, {line, fun}, acc) when is_list(meta) do
    line = {Keyword.get(meta, :line, line), def_name(node) || fun}
    acc = node_sites(node, line, acc)
    acc = walk(form, line, acc)
    if is_list(args), do: Enum.reduce(args, acc, &walk(&1, line, &2)), else: acc
  end

  defp walk({left, right}, line, acc) do
    acc = pair_site(left, right, line, acc)
    walk(right, line, walk(left, line, acc))
  end

  defp walk(list, line, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, line, &2))
  defp walk(_other, _line, acc), do: acc

  defp def_name({kind, _, [head | _]}) when kind in [:def, :defp, :defmacro, :defmacrop],
    do: head_name(head)

  defp def_name(_node), do: nil

  defp head_name({:when, _, [head | _]}), do: head_name(head)

  defp head_name({name, _, args}) when is_atom(name),
    do: "#{name}/#{if is_list(args), do: length(args), else: 0}"

  defp head_name(_), do: nil

  defp pair_site(:authorize?, value, line, acc), do: authorize_site(value, line, acc)
  defp pair_site(:authorizers, [], line, acc), do: [site(:no_authorizers, line) | acc]
  defp pair_site(_left, _right, _line, acc), do: acc

  defp authorize_site(true, _line, acc), do: acc
  defp authorize_site(false, line, acc), do: [site(:authorize_false, line) | acc]
  defp authorize_site(_value, line, acc), do: [site(:authorize_unverifiable, line) | acc]

  # Runtime.start(input, context, "<id>", false)
  defp node_sites({{:., _, [{:__aliases__, _, aliases}, :start]}, _, [_, _, id, last]}, line, acc)
       when is_list(aliases) do
    cond do
      List.last(aliases) != :Runtime ->
        acc

      last in [true, :inherit] ->
        acc

      last == false and is_binary(id) ->
        [Map.put(site(:runtime_start, line), :workflow, id) | acc]

      true ->
        [site(:runtime_unverifiable, line) | acc]
    end
  end

  # Repo.all(...), Ecto.Adapters.SQL.query(...)
  defp node_sites({{:., _, [{:__aliases__, _, aliases}, _fun]}, _, args}, line, acc)
       when is_list(aliases) and is_list(args) do
    acc =
      if List.last(aliases) == :Repo or Enum.take(aliases, 3) == [:Ecto, :Adapters, :SQL],
        do: [site(:repo_call, line) | acc],
        else: acc

    argument_sites(args, line, acc)
  end

  # The DSL: `authorize? false`, `bypass ...`, `authorize :never`.
  defp node_sites({:authorize?, _, [value]}, line, acc), do: authorize_site(value, line, acc)
  defp node_sites({:bypass, _, [_ | _]}, line, acc), do: [site(:policy_bypass, line) | acc]

  defp node_sites({:authorize, _, [mode]}, line, acc) when mode not in [:by_default, :always],
    do: [site(:authorize_mode, line) | acc]

  defp node_sites({_form, _, args}, line, acc) when is_list(args),
    do: argument_sites(args, line, acc)

  defp node_sites(_node, _line, acc), do: acc

  # `Keyword.put(opts, :authorize?, value)`: the key and value side by side.
  defp argument_sites(args, line, acc) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(acc, fn
      [:authorize?, value], acc -> authorize_site(value, line, acc)
      _, acc -> acc
    end)
  end

  defp site(kind, {line, fun}), do: %{kind: kind, line: line, function: fun, workflow: nil}
end
