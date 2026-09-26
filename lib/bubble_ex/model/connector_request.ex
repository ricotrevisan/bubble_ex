defmodule BubbleEx.Model.ConnectorRequest do
  @moduledoc """
  The request a `BubbleEx.Model.ConnectorCall` sends, as a **leak-safe
  template** (WTF-374): enough for a target to generate a client, never a
  credential.

  API Connector calls hold credentials in their URLs, bodies and parameter
  values, private or not. The template keeps only:

    * **structure**: the URL's scheme, port, path segments and query-string
      names, the body's JSON structure (object keys, arrays), the body type
      and the response type
    * **placeholders**: a `[name]` in the URL or `<name>` in the body that
      names one of the call's parameters becomes a reference to that
      parameter by Bubble ID (`%{kind: :parameter, id: id}`); the value is
      never read. A placeholder naming no parameter while the call has
      private parameters whose key the payload stripped becomes
      `%{kind: :secret, name: name}` (a private value, read from the
      environment by a target)
    * **safe literals**: a literal (path segment, query value, body text or
      number) is kept (`%{kind: :literal, text: text}`, or `%{kind: :json,
      value: value}` for a number, boolean or null) only when it cannot hold a
      credential: it is made of plain words (lower/Title/camel case words up
      to 24 letters with vowels, short acronyms, numbers up to six digits,
      `v1`-style versions, `4o`/`gpt4`-style tokens), matches no
      `BubbleEx.Secrets.Native.Detectors` pattern and holds no `Bearer`
      credential, and is not the value of a member or query parameter named
      like a credential (`token`, `key`, `secret`, `password`, `auth`,
      `signature`, …). Every other literal becomes `%{kind: :redacted,
      index: i}` (the call's `i`th redacted literal, from 1, in template
      order): a target reads it from the environment too. The check errs
      towards redacting: a redacted literal costs an environment variable,
      a kept credential a leak
    * **defaults are not read**: a non-private parameter's value is only the
      value Bubble initialized the call with; every call site supplies its
      own

  Fields:

    * `scheme` - `"https"` or `"http"`, lowercase; nil when unknown
    * `host` - the host as parts (literals and URL parameters); nil when the
      call has no plain host (`BubbleEx.Model.ConnectorReader.host/1`)
    * `port` - the URL's explicit port, or nil
    * `path` - the path's segments (after the host, split at `/`), each a
      list of parts; a trailing `/` gives a last empty segment
    * `query` - the URL's own query string: `%{name, value}` entries in URL
      order, `value` a list of parts (names and literals percent-decoded)
    * `body_type` - `:none`, `:json` (`body` is a JSON template), `:form`
      (Bubble's form data: the `:param` parameters are form fields) or
      `:raw` (a body that is not a JSON template; unsupported)
    * `body` - the JSON template: a node, one of `%{kind: :object, members:
      [%{key, value}]}`, `%{kind: :array, items}`, `%{kind: :text, parts}`
      (a string), `%{kind: :json, value}`, an unquoted placeholder
      (`:parameter` or `:secret`: a JSON value) or `:redacted` (a JSON
      value read from the environment); nil unless `body_type` is `:json`
    * `parameters_in` - where the call's `:param` parameters go: `:query`
      (a GET, or a call with a JSON body) or `:form`
    * `response` - `:json`, `:text` or `:empty` (Bubble's `data_type`), or
      `:unsupported`
    * `list` - Bubble's `is_list`: the response is a list
    * `redacted` - how many literals were redacted
    * `unsupported` - why the template does not describe the request
      completely, sorted: `:no_url`, `:no_host` (no plain host: a whole-URL
      parameter, user info, …), `:scheme`, `:dynamic_port`,
      `:unmatched_placeholder`, `:query` (a query-string name that is not
      a plain name), `:raw_body`, `:body_key` (a body key that is a
      placeholder or looks like a credential), `:body_and_parameters`
      (form parameters next to a JSON body), `:file_parameter` and
      `:response_type`
  """

  @enforce_keys [:body_type]
  defstruct [
    :scheme,
    :host,
    :port,
    :body,
    :body_type,
    :parameters_in,
    response: :json,
    list: false,
    path: [],
    query: [],
    redacted: 0,
    unsupported: []
  ]

  @type part ::
          %{kind: :literal, text: String.t()}
          | %{kind: :parameter, id: String.t()}
          | %{kind: :secret, name: String.t()}
          | %{kind: :redacted, index: pos_integer()}

  @type node_template :: map()

  @type t :: %__MODULE__{
          scheme: String.t() | nil,
          host: [part()] | nil,
          port: non_neg_integer() | nil,
          path: [[part()]],
          query: [%{name: String.t(), value: [part()]}],
          body_type: :none | :json | :form | :raw,
          body: node_template() | nil,
          parameters_in: :query | :form,
          response: :json | :text | :empty | :unsupported,
          list: boolean(),
          redacted: non_neg_integer(),
          unsupported: [atom()]
        }
end

defmodule BubbleEx.Model.ConnectorRequest.Reader do
  @moduledoc false

  # Reads a call's `BubbleEx.Model.ConnectorRequest` template. The only raw
  # values it looks at are the URL, the body text and literal values it
  # classifies (`safe_text?/1`); only safe literals are kept, every value a
  # placeholder stands for is never read.

  alias BubbleEx.Model.{ConnectorParameter, ConnectorRequest}
  alias BubbleEx.Secrets.Native.Detectors

  @url ~r{\A\s*([A-Za-z][A-Za-z0-9+.\-]*)://([^/?#\\]*)([^?#\\]*)(?:\?([^#\\]*))?(?:#.*)?\s*\z}s
  @url_placeholder ~r/\[([^\[\]]{1,128})\]/
  @body_placeholder ~r/<[^<>\r\n]{1,128}>/
  # A placeholder name that may be the stripped key of a private parameter
  # (not an HTML tag name: bodies hold HTML too).
  @secret_name ~r/\A(?!(?:a|b|i|p|s|u|br|hr|em|h[1-6]|li|ol|ul|tr|td|th|div|span|strong|small|code|pre|img|table|tbody|thead|html|head|body|style|script|sub|sup)\z)[A-Za-z_][A-Za-z0-9_\-.]{0,63}\z/i
  # Characters a URL path or query literal may hold verbatim.
  @url_safe ~r/\A[A-Za-z0-9\-._~%!$&'()*+,;=:@]*\z/
  @credential ~r/(?:^|[^a-z])(?:token|secret|password|passwd|pwd|pass|auth|authorization|bearer|key|apikey|signature|sig|session|cookie|credential|credentials|otp|pin|salt|hmac|nonce)(?:$|[^a-z])/i

  # Private-use sentinels marking placeholders in the body before JSON
  # parsing: `@open n @close` inside a string, `"@raw n @close"` outside.
  @open "\u{E000}"
  @close "\u{E001}"
  @raw "\u{E002}"

  @doc false
  @spec read(map(), [ConnectorParameter.t()]) :: ConnectorRequest.t()
  def read(call, parameters) do
    {url_fields, state} = url(Map.get(call, "url"), by_location(parameters, :url), new_state())
    method = call |> Map.get("method") |> method()
    {body_type, body, state} = body(call, parameters, method, state)
    parameters_in = if method != "get" and body_type == :form, do: :form, else: :query
    response = response(Map.get(call, "data_type"))

    state =
      state
      |> unsupported_if(
        body_type == :json and method != "get" and Enum.any?(parameters, &(&1.in == :param)),
        :body_and_parameters
      )
      |> unsupported_if(file_parameter?(call), :file_parameter)
      |> unsupported_if(response == :unsupported, :response_type)

    struct!(
      ConnectorRequest,
      Map.merge(url_fields, %{
        body_type: body_type,
        body: body,
        parameters_in: parameters_in,
        response: response,
        list: Map.get(call, "is_list") == true,
        redacted: state.redacted,
        unsupported: state.unsupported |> MapSet.to_list() |> Enum.sort()
      })
    )
  end

  # Form data (Bubble's `body_type`), a JSON template from the body text, or
  # none; a call with parameters and no body sends them as a form unless
  # it is a GET or DELETE.
  defp body(call, parameters, method, state) do
    cond do
      Map.get(call, "body_type") == "form_data" -> {:form, nil, state}
      text = body_text(call) -> json_body(text, by_location(parameters, :body), state)
      method in ["get", "delete"] -> {:none, nil, state}
      Enum.any?(parameters, &(&1.in == :param)) -> {:form, nil, state}
      true -> {:none, nil, state}
    end
  end

  defp body_text(call) do
    Enum.find_value(["body", "%b3"], fn key ->
      text = Map.get(call, key)
      if is_binary(text) and String.trim(text) != "", do: text
    end)
  end

  defp response(nil), do: :json
  defp response("JSON"), do: :json
  defp response("text"), do: :text
  defp response("empty"), do: :empty
  defp response(_), do: :unsupported

  defp unsupported_if(state, true, reason), do: unsupported(state, reason)
  defp unsupported_if(state, false, _reason), do: state

  @doc """
  The values of a group's non-private shared parameters (`shared_headers`,
  `shared_params`): Bubble sends them as supplied, so each is a single safe
  literal or redacted: `%{parameter, parts}` in parameter order.
  """
  @spec shared_values(map(), [ConnectorParameter.t()]) :: [map()]
  def shared_values(group, parameters) do
    {values, _state} =
      parameters
      |> Enum.reject(& &1.private)
      |> Enum.map_reduce(new_state(), fn p, state ->
        raw =
          Enum.find_value(["shared_headers", "shared_params"], fn member ->
            get_in(group, [Access.key(member, %{}), Access.key(p.id, %{})])
          end)

        text =
          case raw do
            %{} -> Enum.find_value(["value", "%v"], &text(Map.get(raw, &1)))
            _ -> nil
          end

        {parts, state} = literal(text || "", credential?(p.name), state)
        {%{parameter: p.id, parts: parts}, state}
      end)

    values
  end

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value), do: to_string(value)
  defp text(_), do: nil

  @doc "The HTTP method, lowercase, `delete_method` read as `delete`."
  @spec method(term()) :: String.t() | nil
  def method(method) when is_binary(method) do
    case String.downcase(method) do
      "delete_method" -> "delete"
      other -> other
    end
  end

  def method(_), do: nil

  # --- the URL ---------------------------------------------------------------------

  defp url(url, named, state) when is_binary(url) do
    host = BubbleEx.Model.ConnectorReader.host(url)

    case {host, Regex.run(@url, url)} do
      {host, [_, scheme, host_port, path | rest]} when is_binary(host) ->
        scheme = String.downcase(scheme)
        state = if scheme in ["http", "https"], do: state, else: unsupported(state, :scheme)

        {port, state} =
          case Regex.run(~r/:([^:\]]*)\z/, host_port) do
            [_, ""] -> {nil, state}
            [_, digits] -> port(digits, state)
            nil -> {nil, state}
          end

        {host_parts, state} = url_parts(host, named, state, :host)

        {segments, state} =
          path
          |> String.split("/")
          |> Enum.drop(1)
          |> Enum.map_reduce(state, &url_parts(&1, named, &2, :path))

        {query, state} = query(List.first(rest) || "", named, state)
        state = check_secrets(state, named, :url)

        {%{
           scheme: if(scheme in ["http", "https"], do: scheme),
           host: host_parts,
           port: port,
           path: segments,
           query: query
         }, state}

      _ ->
        {%{}, unsupported(state, :no_host)}
    end
  end

  defp url(_url, _named, state), do: {%{}, unsupported(state, :no_url)}

  defp port(digits, state) do
    case Integer.parse(digits) do
      {port, ""} when port in 0..65_535 -> {port, state}
      _ -> {nil, unsupported(state, :dynamic_port)}
    end
  end

  # A URL text as parts: `[name]` placeholders and literal chunks. A host
  # keeps its literal labels (the Model's host is public already); path
  # and query literals must be safe.
  defp url_parts(text, named, state, context) do
    text
    |> split_captures(@url_placeholder)
    |> Enum.flat_map_reduce(state, fn
      {:capture, whole}, state ->
        case placeholder(String.slice(whole, 1..-2//1), named) do
          nil -> {[], unsupported(state, :unmatched_placeholder)}
          %{kind: :secret} = part -> {[part], add_secret(state, :url, part.name)}
          part -> {[part], state}
        end

      {:text, ""}, state ->
        {[], state}

      {:text, chunk}, state when context == :host ->
        {[%{kind: :literal, text: chunk}], state}

      {:text, chunk}, state ->
        literal_url(chunk, false, state)
    end)
  end

  # What a placeholder names: a parameter, a private parameter whose key was
  # stripped, or nothing.
  defp placeholder(name, named) do
    case Map.fetch(named.names, name) do
      {:ok, id} ->
        %{kind: :parameter, id: id}

      :error ->
        if named.unnamed_private > 0 and Regex.match?(@secret_name, name),
          do: %{kind: :secret, name: name}
    end
  end

  defp literal_url(chunk, credential?, state) do
    if Regex.match?(@url_safe, chunk) and not credential? and safe_text?(decode(chunk)),
      do: {[%{kind: :literal, text: chunk}], state},
      else: redact(state)
  end

  defp query("", _named, state), do: {[], state}

  defp query(text, named, state) do
    text
    |> String.split("&", trim: true)
    |> Enum.map_reduce(state, fn entry, state ->
      [name | value] = String.split(entry, "=", parts: 2)
      decoded = decode(name)

      if is_binary(decoded) and plain_name?(decoded) do
        {parts, state} = query_value(List.first(value) || "", decoded, named, state)
        {[%{name: decoded, value: parts}], state}
      else
        {[], unsupported(state, :query)}
      end
    end)
    |> then(fn {entries, state} -> {List.flatten(entries), state} end)
  end

  defp query_value(text, name, named, state) do
    credential? = credential?(name)

    text
    |> split_captures(@url_placeholder)
    |> Enum.flat_map_reduce(state, fn
      {:capture, whole}, state -> url_parts(whole, named, state, :path)
      {:text, ""}, state -> {[], state}
      {:text, chunk}, state -> query_literal(chunk, credential?, state)
    end)
  end

  defp query_literal(chunk, credential?, state) do
    decoded = decode(chunk)

    if is_binary(decoded) and Regex.match?(@url_safe, chunk) and not credential? and
         safe_text?(decoded),
       do: {[%{kind: :literal, text: decoded}], state},
       else: redact(state)
  end

  defp decode(text) do
    URI.decode_www_form(text)
  rescue
    ArgumentError -> nil
  end

  defp plain_name?(name),
    do: String.length(name) in 1..128 and not String.match?(name, ~r/[=:\s\x00-\x1f\x7f\[\]]/u)

  # --- the body ----------------------------------------------------------------------

  defp json_body(text, named, state) do
    if String.contains?(text, [@open, @close, @raw]) do
      {:raw, nil, unsupported(state, :raw_body)}
    else
      {marked, table, state} = mark(text, named, state)

      case Jason.decode(marked, objects: :ordered_objects) do
        {:ok, term} ->
          {node, state} = json_node(term, table, false, state)
          {:json, node, check_secrets(state, named, :body)}

        {:error, _} ->
          {:raw, nil, unsupported(state, :raw_body)}
      end
    end
  end

  # Replaces every `<name>` naming a body parameter (or, when the call has
  # unnamed private body parameters, any plain name) with a sentinel: one
  # inside a JSON string, or a quoted one standing for a JSON value. The
  # table maps sentinel numbers to parts.
  defp mark(text, named, state) do
    {pieces, {_in_string, table, state}} =
      text
      |> split_captures(@body_placeholder)
      |> Enum.map_reduce({false, %{}, state}, fn
        {:capture, whole}, acc ->
          mark_placeholder(whole, named, acc)

        {:text, chunk}, {in_string, table, state} ->
          {chunk, {scan(chunk, in_string), table, state}}
      end)

    {IO.iodata_to_binary(pieces), table, state}
  end

  defp mark_placeholder(whole, named, {in_string, table, state}) do
    case placeholder(String.slice(whole, 1..-2//1), named) do
      nil ->
        {whole, {scan(whole, in_string), table, state}}

      part ->
        n = map_size(table)
        state = if part.kind == :secret, do: add_secret(state, :body, part.name), else: state

        marker =
          if in_string,
            do: @open <> Integer.to_string(n) <> @close,
            else: ~s(") <> @raw <> Integer.to_string(n) <> @close <> ~s(")

        {marker, {in_string, Map.put(table, n, part), state}}
    end
  end

  # Whether the JSON text is inside a string after `chunk`.
  defp scan(chunk, in_string), do: scan_chars(chunk, in_string, false)

  defp scan_chars(<<>>, in_string, _escaped), do: in_string
  defp scan_chars(<<_, rest::binary>>, true, true), do: scan_chars(rest, true, false)
  defp scan_chars(<<?\\, rest::binary>>, true, false), do: scan_chars(rest, true, true)

  defp scan_chars(<<?", rest::binary>>, in_string, false),
    do: scan_chars(rest, not in_string, false)

  defp scan_chars(<<_, rest::binary>>, in_string, false), do: scan_chars(rest, in_string, false)

  defp json_node(%Jason.OrderedObject{values: members}, table, _credential?, state) do
    {members, state} =
      Enum.map_reduce(members, state, fn {key, value}, state ->
        state =
          if String.contains?(key, [@open, @close, @raw]) or looks_like_credential?(key),
            do: unsupported(state, :body_key),
            else: state

        {value, state} = json_node(value, table, credential?(key), state)
        {%{key: key, value: value}, state}
      end)

    {%{kind: :object, members: members}, state}
  end

  defp json_node(list, table, credential?, state) when is_list(list) do
    {items, state} = Enum.map_reduce(list, state, &json_node(&1, table, credential?, &2))
    {%{kind: :array, items: items}, state}
  end

  defp json_node(text, table, credential?, state) when is_binary(text) do
    case Regex.run(~r/\A#{@raw}(\d+)#{@close}\z/u, text) do
      [_, n] ->
        {Map.fetch!(table, String.to_integer(n)), state}

      nil ->
        {parts, state} =
          text
          |> split_captures(~r/#{@open}\d+#{@close}/u)
          |> Enum.flat_map_reduce(state, fn
            {:capture, marker}, state ->
              n = marker |> String.slice(1..-2//1) |> String.to_integer()
              {[Map.fetch!(table, n)], state}

            {:text, ""}, state ->
              {[], state}

            {:text, chunk}, state ->
              literal(chunk, credential?, state)
          end)

        {%{kind: :text, parts: parts}, state}
    end
  end

  defp json_node(number, _table, credential?, state) when is_number(number) do
    if credential? or (is_integer(number) and abs(number) >= 10_000_000),
      do: redact_value(state),
      else: {%{kind: :json, value: number}, state}
  end

  defp json_node(value, _table, _credential?, state), do: {%{kind: :json, value: value}, state}

  defp redact_value(state) do
    state = %{state | redacted: state.redacted + 1}
    {%{kind: :redacted, index: state.redacted}, state}
  end

  defp literal(text, credential?, state) do
    if not credential? and safe_text?(text),
      do: {if(text == "", do: [], else: [%{kind: :literal, text: text}]), state},
      else: redact(state)
  end

  defp redact(state) do
    state = %{state | redacted: state.redacted + 1}
    {[%{kind: :redacted, index: state.redacted}], state}
  end

  # --- safe literals -----------------------------------------------------------------

  @word ~r/\A(?:\p{Ll}{1,24}|\p{Lu}\p{Ll}{1,23}|\p{Ll}{1,24}(?:\p{Lu}\p{Ll}{1,23}){1,4}|\p{Lu}{1,5}s?|v\d{1,3}|\d{1,6}|\d{1,4}\p{Ll}{1,3}|\p{Ll}{1,12}\d{1,3})\z/u
  @separators ~r/[\s\-_.\/:,;!?()\[\]{}"'@#&=+*%<>|~`$^\\…–—«»“”‘’]+/u

  @doc """
  Whether a literal cannot hold a credential: it matches no secret detector
  or `Bearer` credential and every word is a plain word (see the module
  documentation of `BubbleEx.Model.ConnectorRequest`).
  """
  @spec safe_text?(String.t()) :: boolean()
  def safe_text?(text) when is_binary(text) do
    String.length(text) <= 10_000 and String.valid?(text) and
      not looks_like_credential?(text) and
      text |> String.split(@separators, trim: true) |> Enum.all?(&word?/1)
  end

  def safe_text?(_), do: false

  defp word?(token) do
    Regex.match?(@word, token) and not gibberish?(token)
  end

  # A long run of letters with few vowels or a long consonant run is more
  # likely a random string than a word.
  defp gibberish?(token) do
    letters = String.downcase(token)
    length = String.length(letters)

    length >= 10 and
      (count_vowels(letters) / length < 0.2 or
         Regex.match?(~r/[bcdfghjklmnpqrstvwxz]{6,}/, letters))
  end

  defp count_vowels(text), do: text |> String.graphemes() |> Enum.count(&(&1 in ~w(a e i o u y)))

  defp looks_like_credential?(text) do
    Regex.match?(~r/bearer\s+\S{8,}|basic\s+[A-Za-z0-9+\/=]{8,}/i, text) or
      Detectors.scan_value(text) != []
  end

  @doc "Whether a member or parameter name names a credential."
  @spec credential?(term()) :: boolean()
  def credential?(name) when is_binary(name) do
    name
    |> String.replace(~r/([a-z])([A-Z])/, "\\1_\\2")
    |> then(&Regex.match?(@credential, &1))
  end

  def credential?(_), do: false

  # --- helpers --------------------------------------------------------------------------

  defp by_location(parameters, location) do
    located = Enum.filter(parameters, &(&1.in == location))

    %{
      names:
        located
        |> Enum.filter(& &1.name)
        |> Enum.reduce(%{}, fn p, acc -> Map.put_new(acc, p.name, p.id) end),
      unnamed_private: Enum.count(located, &(&1.private and is_nil(&1.name)))
    }
  end

  defp new_state,
    do: %{
      redacted: 0,
      unsupported: MapSet.new(),
      secrets: %{url: MapSet.new(), body: MapSet.new()}
    }

  defp add_secret(state, location, name),
    do: update_in(state, [:secrets, location], &MapSet.put(&1, name))

  # More distinct secret placeholders than unnamed private parameters: some
  # placeholder names nothing.
  defp check_secrets(state, named, location) do
    if MapSet.size(state.secrets[location]) > named.unnamed_private,
      do: unsupported(state, :unmatched_placeholder),
      else: state
  end

  defp unsupported(state, reason),
    do: %{state | unsupported: MapSet.put(state.unsupported, reason)}

  defp file_parameter?(call) do
    params =
      for member <- ["params", "body_params"],
          %{} = collection <- [Map.get(call, member)],
          {_, %{} = param} <- collection,
          do: param

    Enum.any?(params, &(&1["binary_file"] == true))
  end

  # `text` split around `regex` matches: `{:text, chunk}` and `{:capture,
  # match}` pieces in order.
  defp split_captures(text, regex) do
    regex
    |> Regex.split(text, include_captures: true)
    |> Enum.with_index()
    |> Enum.map(fn {piece, i} ->
      if rem(i, 2) == 0, do: {:text, piece}, else: {:capture, piece}
    end)
  end
end
