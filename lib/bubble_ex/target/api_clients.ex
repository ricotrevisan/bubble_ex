defmodule BubbleEx.Target.ApiClients do
  @moduledoc """
  Maps a `BubbleEx.Model`'s API Connector groups and calls to a
  `BubbleEx.Target.ApiClients.Spec` (WTF-374): one client module per group,
  one function per call, for `BubbleEx.Target.Phoenix` to print as `Req`
  clients with generated `Req.Test` request-shape tests.

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, project} = BubbleEx.Target.Ash.map(model)
      {:ok, clients} = BubbleEx.Target.ApiClients.map(model)
      {:ok, files} = BubbleEx.Target.Phoenix.render(project, api_clients: clients)

  It reads each call's leak-safe request template
  (`BubbleEx.Model.ConnectorRequest`), so the Spec holds no value that could
  be a credential.

  ## Arguments and the environment

  A call's non-private parameters are its function's arguments (`params`,
  keys from Bubble's keys in snake case): each Bubble call site supplies its
  own values. Bubble's private values are never read; they, and literals of
  the request that could be credentials, are read from environment
  variables at call time. The names are deterministic, from the group's
  module (`PAYMENTS`) and the call's function (`CREATE_CHARGE`):

  | What | Variable |
  |---|---|
  | `private_key_header` / `private_key_url` key | `<GROUP>_API_KEY` |
  | `basic_auth` | `<GROUP>_USERNAME`, `<GROUP>_PASSWORD` |
  | private shared header or parameter `name` | `<GROUP>_<NAME>` |
  | private shared one whose name Bubble stripped | `<GROUP>_HEADER_<ID>` / `<GROUP>_PARAM_<ID>` holding `Name: value` / `name=value` |
  | redacted shared value | `<GROUP>_SHARED_<N>` |
  | private call parameter `name` (also a stripped key's `[name]`/`<name>` placeholder) | `<GROUP>_<CALL>_<NAME>` |
  | private call header or parameter whose name Bubble stripped | `<GROUP>_<CALL>_HEADER_<ID>` / `<GROUP>_<CALL>_PARAM_<ID>`, holding `Name: value` / `name=value` |
  | redacted literal `N` of the call's URL or body | `<GROUP>_<CALL>_LITERAL_<N>` |

  Names are upper case, with runs of other characters as `_`; a name
  already taken gets `_2`, `_3`, …

  ## Authentication

  `none` (or none given), `private_key_header` (the key in the header
  Bubble names, `token_param_name`, else `Authorization`),
  `private_key_url` (the key in the query parameter Bubble names; when the
  payload has no name, `<GROUP>_API_KEY_PARAM` holds `name=value`) and
  `basic_auth`. Other kinds (OAuth, JWT, custom token) are residue.

  ## Residue

  A call is not generated, and is listed in `residue` with its reasons,
  when it is not an object (`:malformed_call`), its method is unknown
  (`:method`), its group's authentication is unsupported
  (`:unsupported_auth`), a non-private header or query
  parameter has no usable name (`:unnamed_parameter`), or its request
  template is incomplete (the reasons of
  `BubbleEx.Model.ConnectorRequest`'s `unsupported`).

  ## Responses

  Bubble's `data_type` gives the decoding: JSON (default), text or empty.
  A call returning an API Connector type the Model resolves
  (`BubbleEx.Model.ExternalType.known?/1`) records it in `response.type`,
  with the response paths of that type and the types it nests in `types`;
  the renderer decodes into the Project's typed struct for it when there
  is one, else the response stays a map.
  """

  alias BubbleEx.{Error, Model}
  alias BubbleEx.Model.{Connector, ConnectorCall, ConnectorParameter, ExternalType, Type}
  alias BubbleEx.Model.ConnectorRequest.Reader
  alias BubbleEx.Target.Ash.Naming
  alias BubbleEx.Target.ApiClients.{Call, Group, Spec}

  @methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete
  }

  @auth_supported [nil, "none", "private_key_header", "private_key_url", "basic_auth"]

  # Function names a client module must not define: Kernel's (imported
  # everywhere) and the module's own helpers.
  @reserved_functions Enum.uniq(
                        Enum.map(Kernel.__info__(:functions) ++ Kernel.__info__(:macros), fn {n,
                                                                                              _} ->
                          Atom.to_string(n)
                        end) ++
                          ~w(module_info __info__ do end fn nil true false when and or not in)
                      )

  # Module segments taken by the renderer's own modules.
  @reserved_modules ~w(Decode)

  @doc """
  The Spec of `model`'s API Connector calls. Deterministic: the same Model
  gives the same Spec.
  """
  @spec map(Model.t(), keyword()) :: {:ok, Spec.t()} | {:error, Error.t()}
  def map(model, opts \\ [])

  def map(%Model{} = model, _opts) do
    state = %{modules: MapSet.new(@reserved_modules), env: %{}, residue: []}

    {groups, state} = Enum.map_reduce(model.connectors, state, &group(&1, model, &2))

    groups = Enum.reject(groups, &(&1.calls == []))
    types = types(model, groups)
    used = for g <- groups, c <- g.calls, name <- c.env, into: MapSet.new(), do: name

    {:ok,
     %Spec{
       groups: groups,
       env:
         state.env
         |> Map.values()
         |> Enum.filter(&MapSet.member?(used, &1.name))
         |> Enum.map(&Map.delete(&1, :key))
         |> Enum.sort_by(& &1.name),
       types: types,
       residue: Enum.reverse(state.residue)
     }}
  end

  def map(_model, _opts),
    do: {:error, Error.new(:invalid_input, "expected a BubbleEx.Model")}

  # --- groups --------------------------------------------------------------------------

  defp group(%Connector{} = group, model, state) do
    base = Naming.base(:pascal, group.name, group.id, "Api")
    {module, modules} = Naming.claim(base, state.modules, :pascal, :none)
    state = %{state | modules: modules}
    prefix = env_part(Macro.underscore(module))

    {shared, group_reasons, state} = shared(group, prefix, state)

    {calls, {_functions, state}} =
      Enum.flat_map_reduce(group.calls, {MapSet.new(), state}, fn call, {functions, state} ->
        case call(call, group, shared, group_reasons, prefix, functions, model, state) do
          {:ok, call, functions, state} ->
            {[call], {functions, state}}

          {:residue, reasons, state} ->
            entry = %{group: group.id, call: call.id, name: call.name, reasons: reasons}
            {[], {functions, %{state | residue: [entry | state.residue]}}}
        end
      end)

    {%Group{id: group.id, bubble_name: group.name, module: module, calls: calls}, state}
  end

  # The group's authentication and shared parameters: header, query and
  # other (`:param`) entries every call gets, and reasons no call can be
  # generated.
  defp shared(%Connector{} = group, prefix, state) do
    values = Map.new(group.shared_values, &{&1.parameter, &1.parts})
    {auth, reasons, state} = auth(group, prefix, state)

    {entries, {reasons, state}} =
      Enum.map_reduce(group.parameters, {reasons, state}, fn p, {reasons, state} ->
        case shared_entry(p, values, group, prefix, state) do
          {:unnamed, state} -> {nil, {[:unnamed_parameter | reasons], state}}
          {entry, state} -> {{p.in, entry}, {reasons, state}}
        end
      end)

    entries = Enum.reject(entries, &is_nil/1)

    shared = %{
      headers: Map.get(auth, :headers, []) ++ for({:header, e} <- entries, do: e),
      query: Map.get(auth, :query, []) ++ for({:query, e} <- entries, do: e),
      param: for({:param, e} <- entries, do: e),
      auth: Map.get(auth, :auth)
    }

    {shared, reasons, state}
  end

  defp auth(%Connector{auth: "private_key_header"} = group, prefix, state) do
    {name, state} =
      env(state, prefix <> "_API_KEY", :auth, subject(group), "API key (private key in header)")

    header = if header_name?(group.key_name), do: group.key_name, else: "authorization"
    {%{headers: [%{name: header, value: [{:env, name}]}]}, [], state}
  end

  defp auth(%Connector{auth: "private_key_url", key_name: key} = group, prefix, state)
       when is_binary(key) do
    {name, state} =
      env(state, prefix <> "_API_KEY", :auth, subject(group), "API key (private key in URL)")

    {%{query: [%{name: key, value: [{:env, name}]}]}, [], state}
  end

  defp auth(%Connector{auth: "private_key_url"} = group, prefix, state) do
    {name, state} =
      env(
        state,
        prefix <> "_API_KEY_PARAM",
        :auth,
        subject(group),
        "API key (private key in URL) whose parameter name Bubble does not send (`name=value`)"
      )

    {%{query: [%{name: nil, value: [{:env_line, name}]}]}, [], state}
  end

  defp auth(%Connector{auth: "basic_auth"} = group, prefix, state) do
    {user, state} = env(state, prefix <> "_USERNAME", :auth, subject(group), "basic auth user")

    {password, state} =
      env(state, prefix <> "_PASSWORD", :auth, subject(group), "basic auth password")

    {%{auth: {:basic, user, password}}, [], state}
  end

  defp auth(%Connector{auth: auth}, _prefix, state) when auth in @auth_supported,
    do: {%{}, [], state}

  defp auth(_group, _prefix, state), do: {%{}, [:unsupported_auth], state}

  defp subject(%Connector{id: id}), do: %{group: id, call: nil}

  # A shared parameter as an entry: a private value from the environment,
  # or the value Bubble sends (a safe literal, else from the environment).
  defp shared_entry(%ConnectorParameter{private: true} = p, _values, group, prefix, state) do
    {value, state} =
      private_env(p, prefix, %{group: group.id, call: nil}, "private shared", state)

    {entry(p, value), state}
  end

  defp shared_entry(%ConnectorParameter{name: nil}, _values, _group, _prefix, state),
    do: {:unnamed, state}

  defp shared_entry(%ConnectorParameter{} = p, values, group, prefix, state) do
    case Map.get(values, p.id, []) do
      [] ->
        {%{name: p.name, value: [{:literal, ""}]}, state}

      [%{kind: :literal, text: text}] ->
        {%{name: p.name, value: [{:literal, text}]}, state}

      [%{kind: :redacted, index: i}] ->
        {name, state} =
          env(
            state,
            "#{prefix}_SHARED_#{i}",
            :literal,
            %{group: group.id, call: nil, parameter: p.id},
            describe(p, "shared") <> ": Bubble's value, which may be a credential"
          )

        {%{name: p.name, value: [{:env, name}]}, state}
    end
  end

  defp entry(%ConnectorParameter{}, {:env_line, _} = value), do: %{name: nil, value: [value]}
  defp entry(%ConnectorParameter{name: name}, value), do: %{name: name, value: [value]}

  # A private parameter's variable: its value, or (when Bubble stripped its
  # name) its `Name: value` / `name=value` line.
  defp private_env(%ConnectorParameter{name: name} = p, prefix, subject, adjective, state)
       when is_binary(name) do
    subject = Map.put(subject, :parameter, p.id)

    {var, state} =
      env(state, prefix <> "_" <> env_part(name), :private, subject, describe(p, adjective))

    {{:env, var}, state}
  end

  defp private_env(%ConnectorParameter{} = p, prefix, subject, adjective, state) do
    {var, state} =
      env(
        state,
        prefix <> "_" <> line_word(p) <> "_" <> env_part(p.id),
        :private_line,
        Map.put(subject, :parameter, p.id),
        describe(p, adjective) <> " whose name Bubble does not send (#{line_format(p)})"
      )

    {{:env_line, var}, state}
  end

  # --- calls ---------------------------------------------------------------------------

  defp call(%ConnectorCall{raw: raw}, _group, _shared, _reasons, _prefix, _fns, _model, state)
       when raw != nil,
       do: {:residue, [:malformed_call], state}

  defp call(
         %ConnectorCall{} = call,
         group,
         shared,
         group_reasons,
         prefix,
         functions,
         model,
         state
       ) do
    method = Map.get(@methods, Reader.method(call.method))
    request = call.request

    unnamed =
      Enum.any?(
        call.parameters,
        &(not &1.private and is_nil(&1.name) and &1.in in [:header, :query, :param])
      )

    reasons =
      (group_reasons ++
         request.unsupported ++
         if(method, do: [], else: [:method]) ++
         if(unnamed, do: [:unnamed_parameter], else: []))
      |> Enum.uniq()
      |> Enum.sort()

    if reasons != [] do
      {:residue, reasons, state}
    else
      base = Naming.base(:snake, call.name, call.id, "call")
      base = if base in @reserved_functions, do: base <> "_call", else: base
      {function, functions} = Naming.claim(base, functions, :snake, :none)
      {call, state} = build(call, group, shared, method, prefix, function, model, state)
      {:ok, call, functions, state}
    end
  end

  defp build(call, group, shared, method, prefix, function, model, state) do
    request = call.request
    cprefix = prefix <> "_" <> env_part(function)
    by_id = Map.new(call.parameters, &{&1.id, &1})
    args = args(call.parameters, referenced(request))

    arg_of = Map.new(args, &{&1.parameter, &1.key})
    ctx = %{call: call, group: group, cprefix: cprefix, by_id: by_id, arg_of: arg_of}

    # Private parameters' variables, then the template's.
    {private, state} =
      call.parameters
      |> Enum.filter(& &1.private)
      |> Enum.map_reduce(state, fn p, state ->
        {value, state} =
          private_env(p, cprefix, %{group: group.id, call: call.id}, "private", state)

        {{p.id, value}, state}
      end)

    ctx = Map.put(ctx, :private, Map.new(private))

    {host, state} = values(request.host, ctx, state)
    {path, state} = Enum.map_reduce(request.path, state, &values(&1, ctx, &2))

    {url_query, state} =
      Enum.map_reduce(request.query, state, fn %{name: name, value: parts}, state ->
        {value, state} = values(parts, ctx, state)
        {%{name: name, value: value}, state}
      end)

    located = fn location ->
      for p <- call.parameters, p.in == location, entry = parameter_entry(p, ctx), do: entry
    end

    params = located.(:param)

    {query_params, form} =
      if request.parameters_in == :form,
        do: {[], shared.param ++ params},
        else: {shared.param ++ params, []}

    {json, state} =
      if request.body_type == :json, do: template(request.body, ctx, state), else: {nil, state}

    built = %Call{
      id: call.id,
      bubble_name: call.name,
      function: function,
      method: method,
      publish_as: call.publish_as,
      base: %{scheme: request.scheme, host: host, port: request.port},
      path: path,
      query: shared.query ++ url_query ++ located.(:query) ++ query_params,
      headers: shared.headers ++ located.(:header),
      form: form,
      json: json,
      auth: shared.auth,
      args: args,
      env: [],
      response: response(call, model)
    }

    {%{built | env: call_env(built)}, state}
  end

  # Arguments: non-private named parameters sent in headers and the query
  # string or as form fields, and those the URL and body placeholders name.
  defp args(parameters, referenced) do
    parameters
    |> Enum.filter(fn p ->
      not p.private and is_binary(p.name) and
        (p.in in [:header, :query, :param] or MapSet.member?(referenced, p.id))
    end)
    |> Enum.map_reduce(MapSet.new(), fn p, used ->
      {key, used} = Naming.claim(Naming.base(:snake, p.name, p.id, "param"), used, :snake, :none)
      {%{key: key, parameter: p.id, in: p.in, name: p.name}, used}
    end)
    |> elem(0)
  end

  defp response(%ConnectorCall{request: request, returns: returns}, model) do
    {type, list?} =
      case returns(returns) do
        {id, list?} -> {if(known?(model, id), do: id), list?}
        nil -> {nil, false}
      end

    %{kind: request.response, list: request.list or list?, type: type}
  end

  # The variables a call reads.
  defp call_env(%Call{} = call) do
    values =
      call.base.host ++
        List.flatten(call.path) ++
        Enum.flat_map(call.query ++ call.headers ++ call.form, & &1.value) ++
        json_env(call.json)

    auth =
      case call.auth do
        {:basic, user, password} -> [user, password]
        nil -> []
      end

    (for({kind, name} <- values, kind in [:env, :env_line], do: name) ++ auth)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp json_env(nil), do: []
  defp json_env({:object, members}), do: Enum.flat_map(members, &json_env(elem(&1, 1)))
  defp json_env({:array, items}), do: Enum.flat_map(items, &json_env/1)
  defp json_env({:text, values}), do: values
  defp json_env({:env_json, name}), do: [{:env, name}]
  defp json_env(_), do: []

  # A header, query or other parameter as an entry: an argument, or a
  # private value from the environment.
  defp parameter_entry(%ConnectorParameter{} = p, ctx) do
    case {Map.fetch(ctx.private, p.id), Map.fetch(ctx.arg_of, p.id)} do
      {{:ok, {:env_line, name}}, _} -> %{name: nil, value: [{:env_line, name}]}
      {{:ok, value}, _} -> %{name: p.name, value: [value]}
      {_, {:ok, key}} -> %{name: p.name, value: [{:arg, key}]}
      _ -> nil
    end
  end

  # Template parts as values.
  defp values(nil, _ctx, state), do: {[], state}

  defp values(parts, ctx, state), do: Enum.map_reduce(parts, state, &value(&1, ctx, &2))

  defp value(%{kind: :literal, text: text}, _ctx, state), do: {{:literal, text}, state}

  defp value(%{kind: :parameter, id: id}, ctx, state) do
    case Map.fetch(ctx.private, id) do
      {:ok, {:env, name}} -> {{:env, name}, state}
      {:ok, {:env_line, name}} -> {{:env, name}, state}
      :error -> {{:arg, Map.fetch!(ctx.arg_of, id)}, state}
    end
  end

  defp value(%{kind: :secret, name: secret}, ctx, state) do
    subject = %{group: ctx.group.id, call: ctx.call.id, parameter: nil}

    {name, state} =
      env(
        state,
        ctx.cprefix <> "_" <> env_part(secret),
        :private,
        subject,
        "private parameter `#{secret}` (a placeholder whose parameter Bubble does not send)"
      )

    {{:env, name}, state}
  end

  defp value(%{kind: :redacted, index: i}, ctx, state) do
    subject = %{group: ctx.group.id, call: ctx.call.id, parameter: nil}

    {name, state} =
      env(
        state,
        "#{ctx.cprefix}_LITERAL_#{i}",
        :literal,
        subject,
        "literal #{i} of the request: Bubble's value, which may be a credential"
      )

    {{:env, name}, state}
  end

  defp template(%{kind: :object, members: members}, ctx, state) do
    # A repeated key keeps its last value, as JSON decoders do.
    members = members |> Enum.reverse() |> Enum.uniq_by(& &1.key) |> Enum.reverse()

    {members, state} =
      Enum.map_reduce(members, state, fn %{key: key, value: value}, state ->
        {node, state} = template(value, ctx, state)
        {{key, node}, state}
      end)

    {{:object, members}, state}
  end

  defp template(%{kind: :array, items: items}, ctx, state) do
    {items, state} = Enum.map_reduce(items, state, &template(&1, ctx, &2))
    {{:array, items}, state}
  end

  defp template(%{kind: :text, parts: parts}, ctx, state) do
    {values, state} = values(parts, ctx, state)
    {{:text, values}, state}
  end

  defp template(%{kind: :json, value: value}, _ctx, state), do: {{:json, value}, state}

  defp template(part, ctx, state) do
    case value(part, ctx, state) do
      {{:arg, key}, state} -> {{:arg, key}, state}
      {{:env, name}, state} -> {{:env_json, name}, state}
    end
  end

  defp referenced(request) do
    parts =
      (request.host || []) ++
        List.flatten(request.path) ++
        Enum.flat_map(request.query, & &1.value) ++ template_parts(request.body)

    for %{kind: :parameter, id: id} <- parts, into: MapSet.new(), do: id
  end

  defp template_parts(nil), do: []

  defp template_parts(%{kind: :object, members: m}),
    do: Enum.flat_map(m, &template_parts(&1.value))

  defp template_parts(%{kind: :array, items: items}), do: Enum.flat_map(items, &template_parts/1)
  defp template_parts(%{kind: :text, parts: parts}), do: parts
  defp template_parts(%{kind: :json}), do: []
  defp template_parts(part), do: [part]

  # --- responses -------------------------------------------------------------------------

  # The external type a call returns (its `ret_value`, classified by the
  # Model) and whether it is a list.
  defp returns(descriptor) when is_binary(descriptor) do
    case Type.classify(descriptor) do
      {%Type{kind: :external, target: id, cardinality: cardinality}, nil} ->
        {id, cardinality == :many}

      _ ->
        nil
    end
  end

  defp returns(_), do: nil

  defp known?(model, id) do
    case Model.external_type(model, id) do
      %ExternalType{} = type -> ExternalType.known?(type)
      nil -> false
    end
  end

  # Response paths of the types the calls return and the known types they
  # nest (not through cycle edges).
  defp types(model, groups) do
    roots = for g <- groups, c <- g.calls, id = c.response.type, id != nil, uniq: true, do: id
    roots |> Enum.sort() |> Enum.reduce(%{}, &visit(model, &1, &2))
  end

  defp visit(model, id, acc) do
    if Map.has_key?(acc, id) or not known?(model, id) do
      acc
    else
      type = Model.external_type(model, id)
      paths = Map.new(type.fields, &{&1.id, response_path(&1.response_path, &1.id)})
      acc = Map.put(acc, id, paths)

      type.fields
      |> Enum.filter(&(&1.type.kind == :external and not &1.cycle))
      |> Enum.reduce(acc, &visit(model, &1.type.target, &2))
    end
  end

  defp response_path(path, id) when is_list(path) and path != [] do
    if Enum.all?(path, &(is_binary(&1) or is_integer(&1))), do: path, else: [id]
  end

  defp response_path(_path, id), do: [id]

  # --- environment variables ----------------------------------------------------------------

  # Registers a variable: a new name for a new subject (`_2`, … when taken),
  # the same name for a subject already registered.
  defp env(state, base, kind, subject, description) do
    key = {subject[:group], subject[:call], subject[:parameter], kind, description}

    case Enum.find(Map.values(state.env), &(&1.key == key)) do
      %{name: name} ->
        {name, state}

      nil ->
        name = free_env(state.env, base)

        entry = %{
          name: name,
          kind: kind,
          group: subject[:group],
          call: subject[:call],
          parameter: subject[:parameter],
          description: description,
          key: key
        }

        {name, %{state | env: Map.put(state.env, name, entry)}}
    end
  end

  defp free_env(env, base) do
    if Map.has_key?(env, base),
      do:
        Enum.find_value(
          2..(map_size(env) + 2),
          &if(Map.has_key?(env, "#{base}_#{&1}"), do: nil, else: "#{base}_#{&1}")
        ),
      else: base
  end

  @doc false
  # An environment variable name part: upper case, other runs as `_`.
  @spec env_part(String.t()) :: String.t()
  def env_part(text) do
    part =
      text
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]+/, "_")
      |> String.trim("_")

    if part == "", do: "X", else: part
  end

  defp header_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z\-]{1,128}\z/, name)

  defp header_name?(_), do: false

  defp line_word(%ConnectorParameter{in: :header}), do: "HEADER"
  defp line_word(_), do: "PARAM"

  defp line_format(%ConnectorParameter{in: :header}), do: "`Name: value`"
  defp line_format(_), do: "`name=value`"

  defp describe(%ConnectorParameter{} = p, adjective) do
    where =
      case p.in do
        :header -> "header"
        :url -> "URL parameter"
        :body -> "body parameter"
        :query -> "query parameter"
        :param -> "parameter"
      end

    if is_binary(p.name),
      do: "#{adjective} #{where} `#{p.name}`",
      else: "#{adjective} #{where} #{p.id}"
  end
end
