defmodule BubbleEx.Target.Phoenix.ApiClients do
  @moduledoc false

  # Prints a `BubbleEx.Target.ApiClients.Spec` as the generated API client
  # files of a `BubbleEx.Target.Phoenix` app (WTF-374):
  #
  #   * lib/<app>/api_clients.ex - the runtime (`<Module>.ApiClients`)
  #   * lib/<app>/api_clients/<group>.ex - one module per group, one
  #     function per call
  #   * lib/<app>/api_clients/decode.ex - decoding into the Project's typed
  #     structs, when a call returns one
  #   * test/<app>/api_clients/<group>_test.exs - a `Req.Test` request-shape
  #     test per call: method, URL, query, header names and values, body,
  #     and response decoding, with stubbed arguments and environment
  #   * test/<app>/api_clients_test.exs - the runtime's behaviour
  #   * lib/mix/tasks/bubble.api_env.ex - `mix bubble.api_env`: the
  #     environment variables that are not set (names only, WTF-533)
  #   * .env.example - every variable's name, no value
  #   * .wtf/api_clients.json - environment variables, residue and names
  #
  # It prints only: every decision is in the Spec and the Project. Stub
  # values are derived from names (`stub-<key>`, `env-<name>`), never from
  # Bubble values.

  alias BubbleEx.CanonicalJson
  alias BubbleEx.Target.Ash.{Project, TypedStruct}
  alias BubbleEx.Target.ApiClients.{Call, Group, Spec}
  alias BubbleEx.Target.Phoenix.Templates

  @receive_timeout 30_000
  @connect_timeout 10_000
  @max_retries 2
  @max_body_bytes 10_000_000
  @deadline 30_000
  @max_retry_delay 5_000

  @json_path ".wtf/api_clients.json"

  @doc false
  @spec json_path() :: String.t()
  def json_path, do: @json_path

  @doc false
  @spec files(Spec.t() | nil, Project.t(), map()) :: %{String.t() => String.t()}
  def files(nil, _project, _ctx), do: %{}

  def files(%Spec{} = spec, %Project{} = project, ctx) do
    lib = "lib/#{ctx.app}/"
    test = "test/#{ctx.app}/"
    structs = structs(project, spec)

    ctx =
      Map.merge(ctx, %{
        structs: structs,
        maps: map_names(spec, structs),
        spec: spec,
        root: ctx.module <> ".ApiClients"
      })

    runtime =
      Templates.render(
        "lib/app/api_clients.ex",
        Map.merge(ctx, %{
          env_doc: env_doc(spec),
          env_names: code(Enum.map(spec.env, & &1.name)),
          receive_timeout: format_int(@receive_timeout),
          connect_timeout: format_int(@connect_timeout),
          max_retries: @max_retries,
          max_body_bytes: format_int(@max_body_bytes),
          max_body_bytes_text: "10 MB",
          deadline: format_int(@deadline),
          deadline_text: format_int(@deadline),
          max_retry_delay: format_int(@max_retry_delay),
          max_retry_delay_text: format_int(@max_retry_delay)
        })
      )

    groups =
      for %Group{} = group <- spec.groups, into: %{} do
        {lib <> "api_clients/#{Macro.underscore(group.module)}.ex",
         format(group_source(group, ctx))}
      end

    tests =
      for %Group{} = group <- spec.groups, into: %{} do
        {test <> "api_clients/#{Macro.underscore(group.module)}_test.exs",
         format(group_test(group, ctx))}
      end

    decode =
      case decode_source(ctx) do
        nil -> %{}
        source -> %{(lib <> "api_clients/decode.ex") => format(source)}
      end

    groups
    |> Map.merge(tests)
    |> Map.merge(decode)
    |> Map.merge(%{
      (lib <> "api_clients.ex") => format(runtime),
      (test <> "api_clients_test.exs") => format(runtime_test(ctx)),
      "lib/mix/tasks/bubble.api_env.ex" => format(env_task(ctx)),
      ".env.example" => env_example(spec),
      @json_path => json_document(spec)
    })
  end

  @doc false
  # The `config/runtime.exs` block that reads the clients' variables
  # (names only): the one place their values come from.
  @spec runtime_config(Spec.t() | nil, map()) :: String.t()
  def runtime_config(nil, _ctx), do: ""
  def runtime_config(%Spec{env: []}, _ctx), do: ""

  def runtime_config(%Spec{env: env}, ctx) do
    names = Enum.map_join(env, "\n", &("        " <> &1.name))

    """

    # API Connector secrets (keys, tokens, private headers and parameters):
    # read from the environment, never copied from the Bubble export. A call
    # whose variables are not set (or empty) is refused before anything is
    # sent. `mix bubble.api_env` lists the missing ones; .env.example names
    # them all.
    config :#{ctx.app}, #{ctx.module}.ApiClients,
      env:
        Map.new(
          ~w(
    #{names}
          ),
          &{&1, System.get_env(&1)}
        )
    """
  end

  defp env_task(ctx) do
    """
    defmodule Mix.Tasks.Bubble.ApiEnv do
      @shortdoc "Lists the API Connector environment variables that are not set"
      @moduledoc \"\"\"
      Lists the environment variables the generated API Connector clients
      (`#{ctx.root}`) need that are not set (or are empty), by name: never a
      value. Exits with status 1 when any is missing, so a deploy can run it
      as a boot check:

          mix bubble.api_env

      `config/runtime.exs` reads them; `.env.example` names them all. A call
      whose variables are missing is refused (`#{ctx.root}.MissingEnvError`).
      \"\"\"
      use Mix.Task

      @requirements ["app.config"]

      @impl Mix.Task
      def run(_args) do
        names = #{ctx.root}.env_names()

        case #{ctx.root}.missing_env() do
          [] ->
            Mix.shell().info("All \#{length(names)} API Connector environment variables are set.")

          missing ->
            Mix.shell().error(
              "\#{length(missing)} of \#{length(names)} API Connector environment variables are not set:"
            )

            Enum.each(missing, &Mix.shell().error("  " <> &1 <> was(&1)))
            exit({:shutdown, 1})
        end
      end

      # Before bubble_ex WTF-533 the same variable had no BUBBLE_API_ prefix.
      defp was("BUBBLE_API_" <> old), do: " (was " <> old <> ")"
      defp was(_name), do: ""
    end
    """
  end

  defp env_example(%Spec{env: env}) do
    header = """
    # The environment variables the API Connector clients read (generated by
    # bubble_ex). Names only: set the values where the app runs, never in a
    # committed file. `mix bubble.api_env` lists the missing ones.
    """

    header <> Enum.map_join(env, "", &(&1.name <> "=\n"))
  end

  # Terms as code: never truncated (inspect's default limits print `...`).
  defp code(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp format(source), do: IO.iodata_to_binary([Code.format_string!(source), "\n"])

  defp format_int(n),
    do:
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join("_", &Enum.join/1)
      |> String.reverse()

  # --- typed structs ------------------------------------------------------------------

  # External type ID => %{module, fun, struct} for the Project's typed structs
  # of the types the Spec has response paths for.
  defp structs(%Project{typed_structs: structs}, %Spec{types: types}) do
    for %TypedStruct{source: %{external_type: id}} = struct <- structs,
        Map.has_key?(types, id),
        into: %{} do
      fun =
        struct.module
        |> String.replace_prefix("External.", "")
        |> Macro.underscore()
        |> String.replace("/", "_")

      {id, %{module: struct.module, fun: fun, struct: struct}}
    end
  end

  defp typed(%Call{response: %{type: type}}, ctx) when is_binary(type),
    do: Map.get(ctx.structs, type)

  defp typed(_call, _ctx), do: nil

  # A call's own API type without a typed struct (WTF-533): decoded into a
  # typed map (`map_<n>` in the Decode module).
  defp map_typed(%Call{response: %{kind: :json, type: type}} = call, ctx) when is_binary(type) do
    if typed(call, ctx) == nil, do: Map.get(ctx.maps, type)
  end

  defp map_typed(_call, _ctx), do: nil

  # External type ID => decoder name for the types decoded into maps: every
  # type with shapes and no typed struct, numbered in ID order.
  defp map_names(%Spec{shapes: shapes}, structs) do
    shapes
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(structs, &1))
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Map.new(fn {id, n} -> {id, "map_#{n}"} end)
  end

  # --- group modules ------------------------------------------------------------------

  defp group_source(%Group{} = group, ctx) do
    residue = Enum.filter(ctx.spec.residue, &(&1.group == group.id))

    residue_doc =
      case residue do
        [] ->
          ""

        entries ->
          "\n\nNot generated (see `.wtf/api_clients.json`):\n\n" <>
            Enum.map_join(entries, "\n", fn r ->
              "  * #{quote_name(r.name)} (`#{r.call}`): " <>
                Enum.map_join(r.reasons, ", ", &"`#{&1}`")
            end)
      end

    doc =
      "Client of the Bubble API Connector group #{quote_name(group.bubble_name)} " <>
        "(`#{group.id}`): one function per call. See `#{ctx.root}` for the " <>
        "options, results and environment variables." <> residue_doc

    """
    defmodule #{ctx.root}.#{group.module} do
      @moduledoc #{heredoc(doc)}

      alias #{ctx.root}

      #{Enum.map_join(group.calls, "\n\n", &call_source(&1, ctx))}
    end
    """
  end

  defp call_source(%Call{} = call, ctx) do
    keys = Enum.map_join(call.args, ", ", &":#{&1.key}")
    p = if uses?(call, :arg), do: "p", else: "_p"

    steps =
      ["{:ok, #{p}} <- ApiClients.params(params, [#{keys}])"] ++
        if call.env == [],
          do: [],
          else: [env_step(call, ctx)]

    """
    @doc #{heredoc(call_doc(call))}
    @spec #{call.function}(map() | keyword(), keyword()) :: {:ok, term()} | {:error, term()}
    def #{call.function}(params \\\\ %{}, opts \\\\ []) do
      with #{Enum.join(steps, ",\n")} do
        ApiClients.request(__MODULE__, opts, %{
          method: #{code(call.method)},
          base: #{base_expr(call)},
          path: #{path_expr(call)},
          query: #{entries_expr(call.query, :param)},
          headers: #{entries_expr(call.headers, :header)},
          body: #{body_expr(call)},
          auth: #{auth_expr(call)},
          response: #{response_expr(call, ctx)}#{wrap_expr(call)}
        })
      end
    end
    """
  end

  # The variables a call reads; its host variables are not needed when a
  # base URL is configured.
  defp env_step(%Call{env: env}, ctx) do
    hosts = for %{kind: :host, name: name} <- ctx.spec.env, name in env, do: name

    case hosts do
      [] ->
        "{:ok, env} <- ApiClients.env(opts, #{code(env)})"

      hosts ->
        "{:ok, env} <- ApiClients.env(opts, #{code(env -- hosts)}, __MODULE__, #{code(hosts)})"
    end
  end

  defp call_doc(%Call{} = call) do
    params =
      case call.args do
        [] ->
          ""

        args ->
          "\n\nParameters:\n\n" <>
            Enum.map_join(args, "\n", fn a ->
              "  * `:#{a.key}` - #{location(a.in)} `#{a.name}` (`#{a.parameter}`)"
            end)
      end

    env =
      case call.env do
        [] -> ""
        names -> "\n\nEnvironment: " <> Enum.map_join(names, ", ", &"`#{&1}`") <> "."
      end

    "#{quote_name(call.bubble_name)} (Bubble call `#{call.id}`, " <>
      "#{if call.publish_as, do: "used as #{call.publish_as}", else: "API call"}): " <>
      "`#{call.method |> Atom.to_string() |> String.upcase()} #{url_sketch(call)}`." <>
      params <> env
  end

  defp location(:header), do: "header"
  defp location(:url), do: "URL parameter"
  defp location(:body), do: "body parameter"
  defp location(:query), do: "query parameter"
  defp location(:param), do: "parameter"

  defp quote_name(nil), do: "(unnamed)"
  defp quote_name(name), do: code(name)

  # The URL with placeholders: `{key}` for an argument, `{NAME}` for a
  # variable.
  defp url_sketch(%Call{} = call) do
    sketch = fn values ->
      Enum.map_join(values, fn
        {:literal, text} -> text
        {:arg, key} -> "{#{key}}"
        {kind, name} when kind in [:env, :env_line] -> "{#{name}}"
      end)
    end

    port = if call.base.port, do: ":#{call.base.port}", else: ""

    "#{call.base.scheme}://#{sketch.(call.base.host)}#{port}" <>
      Enum.map_join(call.path, &("/" <> sketch.(&1)))
  end

  defp uses?(%Call{} = call, kind) do
    values =
      call.base.host ++
        List.flatten(call.path) ++
        Enum.flat_map(call.query ++ call.headers ++ call.form, & &1.value) ++
        template_values(call.json)

    Enum.any?(values, &match?({^kind, _}, &1))
  end

  defp template_values(nil), do: []

  defp template_values({:object, members}),
    do: Enum.flat_map(members, &template_values(elem(&1, 1)))

  defp template_values({:array, items}), do: Enum.flat_map(items, &template_values/1)
  defp template_values({:text, values}), do: values
  defp template_values({:json, _}), do: []
  defp template_values({:env_json, name}), do: [{:env, name}]
  defp template_values({:arg, key}), do: [{:arg, key}]

  # Code for a value.
  defp expr({:literal, text}), do: inspect(text, printable_limit: :infinity)
  defp expr({:arg, key}), do: "p[:#{key}]"
  defp expr({:env, name}), do: "env[#{code(name)}]"

  # Literal and code pieces joined with `<>`, adjacent literals merged.
  defp concat_expr(pieces) do
    pieces
    |> Enum.chunk_while(
      nil,
      fn
        {:lit, text}, {:lit, acc} -> {:cont, {:lit, acc <> text}}
        piece, nil -> {:cont, piece}
        piece, acc -> {:cont, acc, piece}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.reject(&(&1 == {:lit, ""}))
    |> case do
      [] ->
        ~s("")

      pieces ->
        Enum.map_join(pieces, " <> ", fn
          {:lit, text} -> inspect(text, printable_limit: :infinity)
          {:code, code} -> code
        end)
    end
  end

  defp base_expr(%Call{base: base}) do
    host =
      Enum.map(base.host, fn
        {:literal, text} -> {:lit, text}
        value -> {:code, "ApiClients.host(#{expr(value)})"}
      end)

    port = if base.port, do: [{:lit, ":#{base.port}"}], else: []
    concat_expr([{:lit, base.scheme <> "://"}] ++ host ++ port)
  end

  # An empty path is `/`: the same request.
  defp path_expr(%Call{path: []}), do: ~s("/")

  defp path_expr(%Call{path: path}) do
    path
    |> Enum.flat_map(fn segment ->
      [{:lit, "/"}] ++
        Enum.map(segment, fn
          {:literal, text} -> {:lit, text}
          value -> {:code, "ApiClients.segment(#{expr(value)})"}
        end)
    end)
    |> concat_expr()
  end

  defp entries_expr(entries, kind) do
    items =
      Enum.map(entries, fn
        %{name: nil, value: [{:env_line, name}]} ->
          line = if kind == :header, do: "header_line", else: "param_line"
          "ApiClients.#{line}(env[#{code(name)}])"

        %{name: name, value: values} ->
          "{#{code(name)}, #{value_expr(values)}}"
      end)

    "[" <> Enum.join(items, ", ") <> "]"
  end

  # A header, query or form value: text, nil when its only value is missing.
  defp value_expr(values) do
    if Enum.all?(values, &match?({:literal, _}, &1)),
      do: inspect(Enum.map_join(values, &elem(&1, 1)), printable_limit: :infinity),
      else:
        (case values do
           [{:env, _} = value] -> expr(value)
           [value] -> "ApiClients.text(#{expr(value)})"
           values -> "ApiClients.concat([#{Enum.map_join(values, ", ", &expr/1)}])"
         end)
  end

  defp body_expr(%Call{json: nil, form: []}), do: "nil"
  defp body_expr(%Call{json: nil, form: form}), do: "{:form, #{entries_expr(form, :param)}}"
  defp body_expr(%Call{json: json}), do: "{:json, #{template_expr(json)}}"

  defp template_expr({:object, members}) do
    "%{" <>
      Enum.map_join(members, ", ", fn {key, node} ->
        "#{inspect(key, printable_limit: :infinity)} => #{template_expr(node)}"
      end) <> "}"
  end

  defp template_expr({:array, items}),
    do: "[" <> Enum.map_join(items, ", ", &template_expr/1) <> "]"

  defp template_expr({:text, values}) do
    if Enum.all?(values, &match?({:literal, _}, &1)),
      do: inspect(Enum.map_join(values, &elem(&1, 1)), printable_limit: :infinity),
      else: "ApiClients.string([#{Enum.map_join(values, ", ", &expr/1)}])"
  end

  defp template_expr({:json, value}), do: code(value)
  defp template_expr({:arg, key}), do: "ApiClients.json_arg(p[:#{key}])"
  defp template_expr({:env_json, name}), do: "ApiClients.json_value(env[#{code(name)}])"

  defp auth_expr(%Call{auth: nil}), do: "nil"

  defp auth_expr(%Call{auth: {:basic, user, password}}),
    do: "{:basic, env[#{code(user)}], env[#{code(password)}]}"

  defp wrap_expr(%Call{} = call) do
    wrap = if call.wrap_errors, do: ",\n      wrap_errors: true", else: ""
    # Only a GET Bubble uses as data may be retried (WTF-533).
    retry =
      if call.publish_as == "data" and call.method == :get, do: ",\n      retry: true", else: ""

    wrap <> retry
  end

  defp response_expr(%Call{} = call, ctx) do
    case {call.response.kind, typed(call, ctx), map_typed(call, ctx)} do
      {:json, %{fun: fun}, _} ->
        "{:json, &#{ctx.root}.Decode.#{fun}/1, #{call.response.list}}"

      {:json, nil, fun} when is_binary(fun) ->
        "{:json, &#{ctx.root}.Decode.#{fun}/1, #{call.response.list}}"

      {kind, _, _} ->
        code(kind)
    end
  end

  # --- decoding -----------------------------------------------------------------------------

  defp decode_source(ctx) do
    roots =
      for g <- ctx.spec.groups,
          c <- g.calls,
          c.response.kind == :json,
          %{} = s <- [typed(c, ctx)],
          uniq: true,
          do: s

    map_roots =
      for g <- ctx.spec.groups,
          c <- g.calls,
          fun = map_typed(c, ctx),
          is_binary(fun),
          uniq: true,
          do: c.response.type

    case {roots, map_roots} do
      {[], []} ->
        nil

      {roots, map_roots} ->
        all = roots |> Enum.flat_map(&reachable(&1, ctx, [])) |> Enum.uniq_by(& &1.fun)
        casts = Enum.map_join(Enum.sort_by(roots, & &1.fun), "\n\n", &cast_source(&1, ctx))
        fields = Enum.map_join(Enum.sort_by(all, & &1.fun), "\n\n", &fields_source(&1, ctx))

        maps =
          map_roots
          |> Enum.flat_map(&map_reachable(&1, ctx, []))
          |> Enum.uniq()
          |> Enum.sort_by(&ctx.maps[&1])
          |> Enum.map_join("\n\n", &map_source(&1, MapSet.new(map_roots), ctx))

        """
        defmodule #{ctx.root}.Decode do
          @moduledoc \"\"\"
          Decodes API Connector responses into the generated external types,
          following Bubble's response paths: a typed struct when a data
          field stores the type, else a typed map (Bubble field ID => the
          value at its response path, cast to the field's type).
          \"\"\"

          alias #{ctx.root}

          #{casts}

          #{fields}

          #{maps}
        end
        """
    end
  end

  # The map types a map type nests (not through cycles), itself first.
  defp map_reachable(id, ctx, seen) do
    if id in seen or not Map.has_key?(ctx.maps, id) do
      []
    else
      nested =
        for %{type: {:external, n}} <- Map.get(ctx.spec.shapes, id, []), do: n

      [id | Enum.flat_map(nested, &map_reachable(&1, ctx, [id | seen]))]
    end
  end

  defp map_source(id, roots, ctx) do
    fun = ctx.maps[id]

    members =
      ctx.spec.shapes
      |> Map.get(id, [])
      |> Enum.map_join(",\n", fn f ->
        at = "ApiClients.at(value, #{code(f.path)})"
        "#{inspect(f.id, printable_limit: :infinity)} => #{map_value(f, at, ctx)}"
      end)

    root =
      if MapSet.member?(roots, id),
        do: """
        @doc false
        def #{fun}(value) when is_map(value), do: {:ok, #{fun}_fields(value)}
        def #{fun}(_value), do: {:error, {:decode, :not_an_object}}

        """,
        else: ""

    """
    #{root}@doc false
    def #{fun}_fields(value) when is_map(value) do
      %{#{members}}
    end

    def #{fun}_fields(_value), do: nil
    """
  end

  defp map_value(%{type: {:external, n}, list: list?}, at, ctx) do
    case Map.fetch(ctx.maps, n) do
      {:ok, fun} when list? -> "ApiClients.map_list(#{at}, &#{fun}_fields/1)"
      {:ok, fun} -> "#{fun}_fields(#{at})"
      # A type with a typed struct, nested in a map: as the response has it.
      :error -> at
    end
  end

  defp map_value(%{type: type, list: list?}, at, _ctx) when is_atom(type),
    do: "ApiClients.cast_value(#{at}, #{code(if list?, do: {:list, type}, else: type)})"

  # The struct and the external structs its fields nest.
  defp reachable(%{} = s, ctx, seen) do
    if s.fun in seen do
      []
    else
      nested =
        for attribute <- s.struct.fields,
            %{} = n <- [nested_struct(attribute.type, ctx)],
            do: n

      [s | Enum.flat_map(nested, &reachable(&1, ctx, [s.fun | seen]))]
    end
  end

  defp nested_struct({:array, type}, ctx), do: nested_struct(type, ctx)

  defp nested_struct({:module, module}, ctx),
    do: Enum.find_value(ctx.structs, fn {_id, s} -> if s.module == module, do: s end)

  defp nested_struct(_type, _ctx), do: nil

  defp cast_source(s, ctx) do
    """
    @doc false
    def #{s.fun}(value), do: ApiClients.cast(#{ctx.module}.#{s.module}, #{s.fun}_fields(value))
    """
  end

  defp fields_source(s, ctx) do
    id = s.struct.source.external_type
    paths = Map.get(ctx.spec.types, id, %{})

    members =
      Enum.map_join(s.struct.fields, ",\n", fn attribute ->
        field = attribute.source[:field]
        path = code(Map.get(paths, field, [field]))
        at = "ApiClients.at(value, #{path})"

        value = field_expr(attribute.type, at, ctx)

        "#{attribute.name}: #{value}"
      end)

    """
    @doc false
    def #{s.fun}_fields(value) when is_map(value) do
      %{#{members}}
    end

    def #{s.fun}_fields(value), do: value
    """
  end

  defp field_expr({:array, inner}, at, ctx) do
    case nested_struct(inner, ctx) do
      %{fun: fun} -> "ApiClients.map_list(#{at}, &#{fun}_fields/1)"
      nil -> at
    end
  end

  defp field_expr(type, at, ctx) do
    case nested_struct(type, ctx) do
      %{fun: fun} -> "#{fun}_fields(#{at})"
      nil -> at
    end
  end

  # --- tests -----------------------------------------------------------------------------------

  defp group_test(%Group{} = group, ctx) do
    """
    defmodule #{ctx.root}Test.#{group.module} do
      # Request-shape tests (WTF-374): each call is made against a Req.Test
      # stub with stubbed arguments and environment, never the network.
      # Each is tagged with its call's Bubble ID (`bubble:`), which the
      # plan's request_shape check binds to.
      use ExUnit.Case, async: true

      alias #{ctx.root}.#{group.module}

      defp capture(respond) do
        test = self()

        Req.Test.stub(__MODULE__, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:request, conn, body})
          respond.(conn)
        end)

        [plug: {Req.Test, __MODULE__}, retry: false]
      end

      #{Enum.map_join(group.calls, "\n\n", &call_test(&1, group, ctx))}
    end
    """
  end

  defp call_test(%Call{} = call, group, ctx) do
    args =
      "%{" <> Enum.map_join(call.args, ", ", &"#{&1.key}: #{code(arg_stub(&1.key))}") <> "}"

    {respond, {expected, decoded_assert}} = response_test(call, ctx)
    port = call.base.port || if(call.base.scheme == "https", do: 443, else: 80)
    query = Enum.map(call.query, &eval_entry(&1, :param))

    """
    @tag bubble: #{code(call.subject)}
    test #{code("#{call.function} sends its request shape (#{short_id(call.id)})")} do
      opts = capture(#{respond})

      assert #{expected} =
               #{group.module}.#{call.function}(#{args}, [env: #{env_stubs(call)}] ++ opts)

      #{decoded_assert}
      assert_received {:request, conn, body}
      assert conn.method == #{code(call.method |> Atom.to_string() |> String.upcase())}
      assert conn.scheme == #{code(String.to_atom(call.base.scheme))}
      assert conn.host == #{inspect(eval_host(call), printable_limit: :infinity)}
      assert conn.port == #{port}
      assert conn.request_path == #{inspect(eval_path(call), printable_limit: :infinity)}
      assert conn.query_string |> URI.query_decoder() |> Enum.to_list() == #{literal(query)}
      #{header_asserts(call)}
      #{body_assert(call)}
    end
    """
  end

  # A call ID short enough for a test name (ExUnit caps names at 255
  # characters): as is up to 24 characters, else a hash.
  defp short_id(id) when byte_size(id) <= 24 and id != "", do: id

  defp short_id(id),
    do:
      "call " <>
        (:sha256 |> :crypto.hash(id) |> Base.encode16(case: :lower) |> binary_part(0, 12))

  defp literal(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  # The stubbed environment: a line for a header or parameter whose name
  # Bubble strips, else a value.
  defp env_stubs(%Call{} = call) do
    lines =
      for {entries, kind} <- [{call.headers, :header}, {call.query ++ call.form, :param}],
          %{name: nil, value: [{:env_line, name}]} <- entries,
          into: %{},
          do: {name, line_stub(name, kind)}

    "%{" <>
      Enum.map_join(call.env, ", ", fn name ->
        "#{code(name)} => #{code(Map.get_lazy(lines, name, fn -> env_stub(name) end))}"
      end) <> "}"
  end

  defp header_asserts(%Call{} = call) do
    basic =
      case call.auth do
        {:basic, user, password} ->
          [
            {"authorization",
             "Basic " <> Base.encode64(env_stub(user) <> ":" <> env_stub(password))}
          ]

        nil ->
          []
      end

    call.headers
    |> Enum.map(fn entry ->
      {name, value} = eval_entry(entry, :header)
      {String.downcase(name), value}
    end)
    |> Kernel.++(basic)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.map_join("\n", fn {name, values} ->
      "assert Plug.Conn.get_req_header(conn, #{code(name)}) == #{literal(values)}"
    end)
  end

  defp body_assert(%Call{json: json}) when json != nil,
    do: "assert Jason.decode!(body) == #{literal(eval_template(json))}"

  defp body_assert(%Call{form: [_ | _] = form}) do
    form = Enum.map(form, &eval_entry(&1, :param))
    "assert body |> URI.query_decoder() |> Enum.to_list() == #{literal(form)}"
  end

  defp body_assert(%Call{}), do: ~s(assert body == "")

  defp response_test(%Call{response: %{kind: :text}}, _ctx),
    do: {"&Req.Test.text(&1, \"stub\")", {~s({:ok, "stub"}), ""}}

  defp response_test(%Call{response: %{kind: :empty}}, _ctx),
    do: {"&Plug.Conn.send_resp(&1, 204, \"\")", {"{:ok, nil}", ""}}

  defp response_test(%Call{} = call, ctx) do
    case typed(call, ctx) do
      %{} = s ->
        sample = sample_object(s, ctx, [])
        module = "#{ctx.module}.#{s.module}"
        body = if call.response.list, do: [sample], else: sample
        pattern = "%#{module}{} = decoded"
        pattern = if call.response.list, do: "[#{pattern}]", else: pattern

        {"&Req.Test.json(&1, #{inspect(body, limit: :infinity, printable_limit: :infinity)})",
         {"{:ok, #{pattern}}", decoded_assert(s, ctx)}}

      nil ->
        map_response_test(call, map_typed(call, ctx), ctx)
    end
  end

  defp map_response_test(call, fun, ctx) when is_binary(fun) do
    sample = map_sample(call.response.type, ctx, [])
    body = if call.response.list, do: [sample], else: sample
    pattern = if call.response.list, do: "[%{} = decoded]", else: "%{} = decoded"

    {"&Req.Test.json(&1, #{inspect(body, limit: :infinity, printable_limit: :infinity)})",
     {"{:ok, #{pattern}}", map_assert(call.response.type, ctx)}}
  end

  defp map_response_test(_call, nil, _ctx),
    do: {~s[&Req.Test.json(&1, %{"stub" => true})], {~s[{:ok, %{"stub" => true}}], ""}}

  # A response object with a sample value at each text field's response
  # path (a map type's).
  defp map_sample(id, ctx, seen) do
    ctx.spec.shapes
    |> Map.get(id, [])
    |> Enum.filter(&Enum.all?(&1.path, fn k -> is_binary(k) end))
    |> Enum.reduce(%{}, &put_sample(&2, &1, map_sample_value(&1.type, id, ctx, seen)))
  end

  defp put_sample(acc, _field, nil), do: acc
  defp put_sample(acc, %{list: true} = f, value), do: deep_put(acc, f.path, [value])
  defp put_sample(acc, f, value), do: deep_put(acc, f.path, value)

  defp map_sample_value(:text, _id, _ctx, _seen), do: "stub"
  defp map_sample_value(:number, _id, _ctx, _seen), do: 1
  defp map_sample_value(:boolean, _id, _ctx, _seen), do: true

  defp map_sample_value({:external, n}, id, ctx, seen),
    do: if(n in seen, do: nil, else: map_sample(n, ctx, [id | seen]))

  defp map_sample_value(_type, _id, _ctx, _seen), do: nil

  # Checks a text field of a map type was read from its response path.
  defp map_assert(id, ctx) do
    ctx.spec.shapes
    |> Map.get(id, [])
    |> Enum.filter(
      &(&1.type == :text and not &1.list and Enum.all?(&1.path, fn k -> is_binary(k) end))
    )
    |> Enum.max_by(&{length(&1.path), &1.id}, fn -> nil end)
    |> case do
      nil -> "assert is_map(decoded)"
      f -> "assert decoded[#{inspect(f.id, printable_limit: :infinity)}] == \"stub\""
    end
  end

  # Checks the text field with the longest response path was read from it
  # (every field is checked by the cast; this checks the paths).
  defp decoded_assert(s, ctx) do
    paths = Map.get(ctx.spec.types, s.struct.source.external_type, %{})

    s.struct.fields
    |> Enum.filter(&(&1.type in [:string, :ci_string]))
    |> Enum.map(&{&1.name, Map.get(paths, &1.source[:field], [&1.source[:field]])})
    |> Enum.filter(fn {_name, path} -> Enum.all?(path, &is_binary/1) end)
    |> Enum.max_by(fn {name, path} -> {length(path), name} end, fn -> nil end)
    |> case do
      nil -> "assert decoded"
      {name, _path} -> ~s(assert decoded.#{name} == "stub")
    end
  end

  # A response object with a sample value at each field's response path.
  defp sample_object(s, ctx, seen) do
    paths = Map.get(ctx.spec.types, s.struct.source.external_type, %{})

    Enum.reduce(s.struct.fields, %{}, fn attribute, acc ->
      field = attribute.source[:field]
      path = Map.get(paths, field, [field])

      if Enum.all?(path, &is_binary/1),
        do: deep_put(acc, path, sample(attribute.type, ctx, [s.fun | seen])),
        else: acc
    end)
  end

  defp deep_put(map, [key], value), do: Map.put(map, key, value)

  defp deep_put(map, [key | rest], value) do
    inner = if is_map(map[key]), do: map[key], else: %{}
    Map.put(map, key, deep_put(inner, rest, value))
  end

  defp sample(type, _ctx, _seen) when type in [:string, :ci_string], do: "stub"
  defp sample(:integer, _ctx, _seen), do: 1
  defp sample(:float, _ctx, _seen), do: 1.5
  defp sample(:boolean, _ctx, _seen), do: true

  defp sample(type, _ctx, _seen)
       when type in [:utc_datetime, :utc_datetime_usec, :naive_datetime],
       do: "2026-01-01T00:00:00Z"

  defp sample(:date, _ctx, _seen), do: "2026-01-01"

  defp sample({:array, inner}, ctx, seen) do
    case sample(inner, ctx, seen) do
      nil -> []
      value -> [value]
    end
  end

  defp sample({:module, _} = type, ctx, seen) do
    case nested_struct(type, ctx) do
      %{fun: fun} = s -> if fun in seen, do: nil, else: sample_object(s, ctx, seen)
      nil -> nil
    end
  end

  defp sample(_type, _ctx, _seen), do: nil

  # --- stubbed evaluation ------------------------------------------------------------------------

  defp arg_stub(key), do: "stub-" <> String.replace(key, "_", "-")
  defp env_stub(name), do: "env-" <> (name |> String.downcase() |> String.replace("_", "-"))

  defp line_stub(name, :header),
    do:
      "x-stub-" <>
        (name |> String.downcase() |> String.replace("_", "-")) <> ": " <> env_stub(name)

  defp line_stub(name, :param), do: "stub_" <> String.downcase(name) <> "=" <> env_stub(name)

  defp stub({:literal, text}), do: text
  defp stub({:arg, key}), do: arg_stub(key)
  defp stub({:env, name}), do: env_stub(name)

  defp eval_entry(%{name: nil, value: [{:env_line, name}]}, kind) do
    [n, v] =
      String.split(line_stub(name, kind), if(kind == :header, do: ": ", else: "="), parts: 2)

    {n, v}
  end

  defp eval_entry(%{name: name, value: values}, _kind), do: {name, Enum.map_join(values, &stub/1)}

  defp eval_host(%Call{base: base}), do: Enum.map_join(base.host, &stub/1)

  defp eval_path(%Call{path: []}), do: "/"

  defp eval_path(%Call{path: path}),
    do: Enum.map_join(path, &("/" <> Enum.map_join(&1, fn v -> stub(v) end)))

  defp eval_template({:object, members}),
    do: Map.new(members, fn {key, node} -> {key, eval_template(node)} end)

  defp eval_template({:array, items}), do: Enum.map(items, &eval_template/1)
  defp eval_template({:text, values}), do: Enum.map_join(values, &stub/1)
  defp eval_template({:json, value}), do: value
  defp eval_template({:arg, key}), do: arg_stub(key)
  defp eval_template({:env_json, name}), do: env_stub(name)

  # --- runtime test --------------------------------------------------------------------------------

  defp runtime_test(ctx) do
    """
    defmodule #{ctx.root}Test do
      # The runtime of the generated API clients (WTF-374), against a
      # Req.Test stub: never the network.
      use ExUnit.Case, async: true

      alias #{ctx.root}

      defp request(respond, fields \\\\ %{}, opts \\\\ []) do
        Req.Test.stub(__MODULE__, respond)

        # `retry: nil` leaves the runtime's own retry decision.
        base = Keyword.merge([plug: {Req.Test, __MODULE__}, retry: false], opts)
        base = if base[:retry] == nil, do: Keyword.delete(base, :retry), else: base

        ApiClients.request(
          __MODULE__,
          base,
          Map.merge(
            %{
              method: :get,
              base: "https://api.example.com",
              path: "/x",
              query: [],
              headers: [],
              body: nil,
              auth: nil,
              response: :json
            },
            fields
          )
        )
      end

      test "a 2xx JSON response is decoded" do
        assert {:ok, %{"ok" => true}} = request(&Req.Test.json(&1, %{"ok" => true}))
      end

      test "a non-2xx response is an error with its status and body" do
        assert {:error, {:status, 500, "boom"}} =
                 request(&Plug.Conn.send_resp(&1, 500, "boom"))
      end

      test "a body that is not JSON is a decode error" do
        assert {:error, {:decode, %Jason.DecodeError{}}} =
                 request(&Plug.Conn.send_resp(&1, 200, "not json"))
      end

      test "text and empty responses" do
        assert {:ok, "plain"} = request(&Req.Test.text(&1, "plain"), %{response: :text})
        assert {:ok, nil} = request(&Plug.Conn.send_resp(&1, 204, ""), %{response: :empty})
      end

      test "a missing parameter is not sent" do
        test = self()

        request(
          fn conn ->
            send(test, {:request, conn})
            Req.Test.json(conn, %{})
          end,
          %{query: [{"a", "1"}, {"b", nil}], headers: [{"x-a", "1"}, {"x-b", nil}]}
        )

        assert_received {:request, conn}
        assert conn.query_string == "a=1"
        assert Plug.Conn.get_req_header(conn, "x-a") == ["1"]
        assert Plug.Conn.get_req_header(conn, "x-b") == []
      end

      test "environment variables come from :env, then the configuration; missing ones are an error" do
        assert {:ok, %{"A" => "1"}} = ApiClients.env([env: %{"A" => "1"}], ["A"])

        assert {:error, %ApiClients.MissingEnvError{names: ["BUBBLE_EX_UNSET_VARIABLE"]} = error} =
                 ApiClients.env([], ["BUBBLE_EX_UNSET_VARIABLE"])

        assert Exception.message(error) =~ "BUBBLE_EX_UNSET_VARIABLE"

        # An empty value is not set.
        assert {:error, %ApiClients.MissingEnvError{names: ["A"]}} =
                 ApiClients.env([env: %{"A" => ""}], ["A"])

        # A host variable is needed only without a base URL.
        assert {:error, %ApiClients.MissingEnvError{names: ["BUBBLE_EX_UNSET_HOST"]}} =
                 ApiClients.env([], [], nil, ["BUBBLE_EX_UNSET_HOST"])

        assert {:ok, %{}} =
                 ApiClients.env([base_url: "https://api.example.com"], [], nil, ["BUBBLE_EX_UNSET_HOST"])
      end

      test "configured variables come from the application environment, never the system's" do
        name = "BUBBLE_EX_SYSTEM_ONLY_VARIABLE"
        System.put_env(name, "from-system")
        on_exit(fn -> System.delete_env(name) end)

        assert {:error, %ApiClients.MissingEnvError{names: [^name]}} = ApiClients.env([], [name])
        assert ApiClients.missing_env() == ApiClients.missing_env() -- [name]
        assert is_list(ApiClients.env_names())
      end

      test "with errors included in the response, a non-2xx response is the result" do
        assert {:ok, %{"returned_an_error" => true, "error" => error}} =
                 request(&Plug.Conn.send_resp(&1, 404, "nope"), %{wrap_errors: true})

        assert error == %{"status_code" => 404, "status_message" => "Not Found", "body" => "nope"}

        assert {:ok, %{"ok" => true, "returned_an_error" => false}} =
                 request(&Req.Test.json(&1, %{"ok" => true}), %{wrap_errors: true})
      end

      test "a transport error is an error even with errors included in the response" do
        assert {:error, %Req.TransportError{reason: :timeout}} =
                 request(&Req.Test.transport_error(&1, :timeout), %{wrap_errors: true})
      end

      test "an address the owner did not configure must not be private", %{} do
        guard = %{trusted: nil, allow?: false}

        for url <- ~w(http://127.0.0.1/x http://localhost/x http://169.254.169.254/latest
                      http://10.0.0.1/ http://192.168.1.1/ http://[::1]/ http://[fd00:ec2::254]/
                      http://[::ffff:127.0.0.1]/ http://0.0.0.0/) do
          assert {:error, {:blocked_address, _}} = ApiClients.check_address(url, guard), url
        end

        assert :ok = ApiClients.check_address("https://93.184.216.34/x", guard)
        # The owner's base URL, or the owner's opt-in.
        trusted = %{guard | trusted: {"http", "127.0.0.1", 4001}}
        assert :ok = ApiClients.check_address("http://127.0.0.1:4001/x", trusted)
        assert {:error, _} = ApiClients.check_address("http://127.0.0.1:4002/x", trusted)
        assert :ok = ApiClients.check_address("http://127.0.0.1/x", %{guard | allow?: true})
      end

      test "a private address is refused before connecting; the owner's base URL is not" do
        request = %{
          method: :get,
          base: "http://127.0.0.1:9",
          path: "/x",
          query: [],
          headers: [{"x-api-key", "secret"}],
          body: nil,
          auth: nil,
          response: :json
        }

        assert {:error, {:blocked_address, :private}} =
                 ApiClients.request(__MODULE__, [retry: false], request)

        # Configured by the owner: it connects (port 9 on localhost refuses).
        assert {:error, %Req.TransportError{}} =
                 ApiClients.request(__MODULE__, [retry: false, base_url: "http://127.0.0.1:9"], request)
      end

      test "a body is read up to :max_body_bytes, decompressed included" do
        assert {:error, {:body_too_large, 10}} =
                 request(&Req.Test.text(&1, String.duplicate("a", 11)), %{}, max_body_bytes: 10)

        bomb = :zlib.gzip(:binary.copy(<<0>>, 5_000_000))

        assert {:error, {:body_too_large, 1_000}} =
                 request(
                   fn conn ->
                     conn
                     |> Plug.Conn.put_resp_header("content-encoding", "gzip")
                     |> Plug.Conn.send_resp(200, bomb)
                   end,
                   %{response: :text},
                   max_body_bytes: 1_000
                 )

        assert {:ok, %{"ok" => true}} =
                 request(fn conn ->
                   conn
                   |> Plug.Conn.put_resp_header("content-encoding", "gzip")
                   |> Plug.Conn.send_resp(200, :zlib.gzip(~s({"ok":true})))
                 end)
      end

      test "the whole call has a deadline" do
        assert {:error, :deadline_exceeded} =
                 request(
                   fn conn ->
                     Process.sleep(300)
                     Req.Test.json(conn, %{})
                   end,
                   %{},
                   deadline: 50
                 )
      end

      test "only data GETs retry, on 429/503, waiting at most :max_retry_delay" do
        test = self()

        respond = fn conn ->
          send(test, :attempt)

          conn
          |> Plug.Conn.put_resp_header("retry-after", "3600")
          |> Plug.Conn.send_resp(503, "busy")
        end

        started = System.monotonic_time(:millisecond)

        assert {:error, {:status, 503, "busy"}} =
                 request(respond, %{retry: true}, retry: nil, max_retry_delay: 10)

        assert System.monotonic_time(:millisecond) - started < 2_000
        assert_received :attempt
        assert_received :attempt
        assert_received :attempt

        # An action (no `retry:`) is never retried.
        assert {:error, {:status, 503, _}} = request(respond, %{}, retry: nil)
        assert_received :attempt
        refute_received :attempt
      end

      test "unknown parameters are refused" do
        assert {:ok, %{a: 1}} = ApiClients.params([a: 1], [:a, :b])
        assert {:error, {:unknown_parameters, [:c]}} = ApiClients.params(%{c: 1}, [:a])
      end

      defp redirecting(location, status \\\\ 302) do
        test = self()

        fn conn ->
          send(test, {:request, conn.scheme, conn.host, conn.request_path, conn.req_headers})

          if conn.request_path == "/x",
            do:
              conn
              |> Plug.Conn.put_resp_header("location", location)
              |> Plug.Conn.send_resp(status, ""),
            else: Req.Test.json(conn, %{"ok" => true})
        end
      end

      defp secret_request(respond, opts) do
        Req.Test.stub(__MODULE__, respond)

        ApiClients.request(
          __MODULE__,
          [plug: {Req.Test, __MODULE__}, retry: false] ++ opts,
          %{
            method: :post,
            base: "https://api.example.com",
            path: "/x",
            query: [],
            headers: [{"x-api-key", "secret"}],
            body: {:json, %{"a" => 1}},
            auth: {:basic, "user", "password"},
            response: :json
          }
        )
      end

      test "redirects are not followed by default" do
        assert {:error, {:status, 302, _}} =
                 secret_request(redirecting("https://api.example.com/y"), [])
      end

      test "a followed same-origin redirect keeps the headers" do
        assert {:ok, %{"ok" => true}} =
                 secret_request(redirecting("/y"), follow_redirects: true)

        assert_received {:request, :https, "api.example.com", "/x", _}
        assert_received {:request, :https, "api.example.com", "/y", headers}
        assert {"x-api-key", "secret"} in headers
      end

      test "a cross-origin or downgrading redirect drops every header and the auth" do
        for location <- ["https://evil.example.com/y", "http://api.example.com/y"] do
          assert {:ok, %{"ok" => true}} =
                   secret_request(redirecting(location), follow_redirects: true)

          assert_received {:request, _, _, "/x", _}
          assert_received {:request, _, _, "/y", headers}
          refute Enum.any?(headers, fn {name, _} -> name in ["x-api-key", "authorization"] end)
        end
      end

      test "a 307 redirect to another origin is refused" do
        assert {:error, {:redirect_refused, 307, "https://evil.example.com/y"}} =
                 secret_request(redirecting("https://evil.example.com/y", 307),
                   follow_redirects: true
                 )
      end

      test "header and parameter lines, path segments and response paths" do
        assert ApiClients.header_line("X-Key: abc") == {"X-Key", "abc"}
        assert ApiClients.param_line("key=a=b") == {"key", "a=b"}
        assert ApiClients.segment("a b/c") == "a%20b%2Fc"
        # A dot segment never moves up the path.
        assert ApiClients.segment(".") == "%2E"
        assert ApiClients.segment("..") == "%2E%2E"
        assert ApiClients.at(%{"a" => [%{"b" => 1}]}, ["a", 0, "b"]) == 1
        assert ApiClients.at(%{"a" => 1}, ["a", "b"]) == nil
        assert ApiClients.json_value("[1]") == [1]
        assert ApiClients.json_value("text") == "text"
        # A text pasted into a JSON body outside quotes, as Bubble does.
        assert ApiClients.json_arg("3") == 3
        assert ApiClients.json_arg("null") == nil
        assert ApiClients.json_arg("hi") == "hi"
        assert ApiClients.json_arg(true) == true
        # Only scalars: an object or array typed as text stays text.
        assert ApiClients.json_arg(~s({"$ne":null})) == ~s({"$ne":null})
        assert ApiClients.json_arg("[1]") == "[1]"
        assert ApiClients.json_arg([1]) == [1]
      end
    end
    """
  end

  # --- documentation and the JSON document -----------------------------------------------------

  defp env_doc(%Spec{env: []}), do: "  No environment variables: no call reads a secret."

  # Printed into the runtime's @moduledoc heredoc: every piece that comes
  # from the app (IDs, descriptions holding names) is escaped.
  defp env_doc(%Spec{env: env}) do
    env
    |> Enum.map_join("\n", fn e ->
      where = if e.call, do: "call `#{e.call}` of group `#{e.group}`", else: "group `#{e.group}`"
      "    * `#{e.name}` - #{e.description} (#{where})"
    end)
    |> escape_doc()
  end

  defp json_document(%Spec{} = spec) do
    names =
      for g <- spec.groups, into: %{} do
        {g.id,
         %{
           "module" => g.module,
           "functions" => Map.new(g.calls, &{&1.id, &1.function})
         }}
      end

    document = %{
      # 2: every variable is under BUBBLE_API_ (WTF-533).
      "version" => 2,
      "spec_sha256" => Spec.sha256(spec),
      "summary" => Spec.summary(spec),
      "names" => names,
      "env" =>
        Enum.map(spec.env, fn e ->
          %{
            "name" => e.name,
            "kind" => Atom.to_string(e.kind),
            "group" => e.group,
            "call" => e.call,
            "parameter" => e.parameter,
            "description" => e.description
          }
        end),
      "residue" =>
        Enum.map(spec.residue, fn r ->
          %{
            "group" => r.group,
            "call" => r.call,
            "name" => r.name,
            "reasons" => Enum.map(r.reasons, &Atom.to_string/1)
          }
        end)
    }

    (document |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"
  end

  # --- text ---------------------------------------------------------------------------------------

  # Text for a heredoc: backslashes, interpolation and every double quote
  # (so no `"""` can close it) escaped.
  defp escape_doc(text),
    do:
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\#{", "\\\#{")
      |> String.replace(~s("), ~s(\\"))

  defp heredoc(text) do
    body =
      text
      |> escape_doc()
      |> String.split("\n")
      |> Enum.map_join("\n", &String.trim_trailing/1)

    ~s("""\n) <> body <> ~s(\n""")
  end
end
