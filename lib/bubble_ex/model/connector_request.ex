defmodule BubbleEx.Model.ConnectorRequest do
  @moduledoc """
  The request a `BubbleEx.Model.ConnectorCall` sends, as a **leak-safe
  template** (WTF-374): enough for a target to generate a client, never a
  credential.

  API Connector calls hold credentials in their URLs, bodies and parameter
  values, private or not. The template keeps only:

    * **hosts**: a host's literal labels are kept when they are plain
      names; a chunk with any other label (an account-specific subdomain,
      a number) is redacted, so the client reads it from the environment
    * **structure**: the URL's scheme, port and path segments, the body's
      JSON structure (object keys, arrays), the body type and the response
      type. Query-string names and body keys are kept only when they are
      plain names (`Reader.safe_name?/1`: dictionary words, abbreviations
      and English-like words, short numbers; UUIDs, hex runs and detector
      matches refused; random tokens refused with high probability, not
      certainty); a query entry or body key that is not is dropped and the
      call marked unsupported. Header and parameter names get the same
      check (`BubbleEx.Model.ConnectorParameter`)
    * **placeholders**: a `[name]` in the URL or `<name>` in the body that
      names one of the call's parameters becomes a reference to that
      parameter by Bubble ID (`%{kind: :parameter, id: id}`); the value is
      never read. A placeholder with a plain name naming no parameter while
      the call has private parameters whose key the payload stripped
      becomes `%{kind: :secret, name: name}` (a private value, read from
      the environment by a target)
    * **default-deny literals**: the only literals kept
      (`%{kind: :literal, text: text}`) are path segments that are API
      versions (`v1`, `2023-01-01`) or words of a fixed dictionary of API
      path words (`users`, `orders`, `messages`, `search`, …), up to the
      first segment named like a credential (`token`, `key`, `auth`, …:
      every literal segment after it is redacted), a shared `Content-Type`
      or `Accept` header's media type, JSON booleans and null, and empty
      text. **Every other literal** (query values, body strings and
      numbers, header values, other path segments) becomes
      `%{kind: :redacted, index: i}` (the call's `i`th redacted literal,
      from 1, in template order), which a target reads from the
      environment. This costs environment variables, never a leak
    * **defaults are not read**: a non-private parameter's value is only the
      value Bubble initialized the call with; every call site supplies its
      own

  Fields:

    * `scheme` - `"https"` or `"http"`, lowercase; nil when unknown
    * `host` - the host as parts (literals, URL parameters and redacted
      account-specific labels); nil when the call has no plain host
      (`BubbleEx.Model.ConnectorReader.host/1`)
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
  # values it looks at are the URL, the body text and a group's shared
  # values; only structure (`structural?/1`, `safe_name?/1`) is kept, every
  # other literal is redacted and every value a placeholder stands for is
  # never read.

  alias BubbleEx.Model.{ConnectorParameter, ConnectorRequest}
  alias BubbleEx.Model.ConnectorRequest.English
  alias BubbleEx.Secrets.Native.Detectors

  @url ~r{\A\s*([A-Za-z][A-Za-z0-9+.\-]*)://([^/?#\\]*)([^?#\\]*)(?:\?([^#\\]*))?(?:#.*)?\s*\z}s
  @url_placeholder ~r/\[([^\[\]]{1,128})\]/
  @body_placeholder ~r/<[^<>\r\n]{1,128}>/
  # A placeholder name that may be the stripped key of a private parameter
  # (not an HTML tag name: bodies hold HTML too).
  @secret_name ~r/\A(?!(?:a|b|i|p|s|u|br|hr|em|h[1-6]|li|ol|ul|tr|td|th|div|span|strong|small|code|pre|img|table|tbody|thead|html|head|body|style|script|sub|sup)\z)[A-Za-z_][A-Za-z0-9_\-.]{0,63}\z/i
  # Characters a URL path or query literal may hold verbatim.
  @url_safe ~r/\A[A-Za-z0-9\-._~%!$&'()*+,;=:@]*\z/
  # Any name containing one of these (case-insensitive) names a credential.
  @credential ~r/token|secret|key|pass|auth|pwd|pin|otp|signature|cred|session|cookie|bearer|salt|hmac|nonce/i

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

        {parts, state} = shared_literal(p, text || "", state)
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

        {port, state} = port(host_port, state)
        {host_parts, state} = host(host, named, state)
        {segments, state} = path(path, named, state)

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

  defp port(host_port, state) do
    case Regex.run(~r/:([^:\]]*)\z/, host_port) do
      [_, digits] when digits != "" -> port_number(digits, state)
      _ -> {nil, state}
    end
  end

  defp port_number(digits, state) do
    case Integer.parse(digits) do
      {port, ""} when port in 0..65_535 -> {port, state}
      _ -> {nil, unsupported(state, :dynamic_port)}
    end
  end

  # The host as parts. A literal chunk with a label that is not a plain
  # name (an account-specific subdomain such as `eo1a2b3c.m.example.net`,
  # a number) is redacted, so it is configured from the environment;
  # placeholders stay parameters.
  defp host(host, named, state) do
    {parts, state} = url_parts(host, named, state, :host)

    Enum.flat_map_reduce(parts, state, fn
      %{kind: :literal, text: text} = part, state ->
        labels = String.split(text, ".", trim: true)
        if Enum.all?(labels, &safe_name?/1), do: {[part], state}, else: redact(state)

      part, state ->
        {[part], state}
    end)
  end

  # Path segments; every literal segment after one named like a credential
  # is redacted.
  defp path(path, named, state) do
    {segments, {state, _after_key?}} =
      path
      |> String.split("/")
      |> Enum.drop(1)
      |> Enum.map_reduce({state, false}, fn segment, {state, after_key?} ->
        context = if after_key?, do: :after_key, else: :path
        {parts, state} = url_parts(segment, named, state, context)
        {parts, {state, after_key? or credential?(decode(segment) || segment)}}
      end)

    {segments, state}
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
        literal_url(chunk, context, state)
    end)
  end

  # What a placeholder names: a parameter, a private parameter whose key was
  # stripped, or nothing.
  defp placeholder(name, named) do
    case Map.fetch(named.names, name) do
      {:ok, id} ->
        %{kind: :parameter, id: id}

      :error ->
        if named.unnamed_private > 0 and Regex.match?(@secret_name, name) and safe_name?(name),
          do: %{kind: :secret, name: name}
    end
  end

  # A path literal is kept only when it is structure: an API version or
  # words of the path dictionary, and no segment before it names a
  # credential.
  defp literal_url(chunk, context, state) do
    if context == :path and Regex.match?(@url_safe, chunk) and path_word?(decode(chunk)),
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

      if is_binary(decoded) and plain_name?(decoded) and safe_name?(decoded) do
        {parts, state} = query_value(List.first(value) || "", decoded, named, state)
        {[%{name: decoded, value: parts}], state}
      else
        {[], unsupported(state, :query)}
      end
    end)
    |> then(fn {entries, state} -> {List.flatten(entries), state} end)
  end

  # A query value's literals are always redacted.
  defp query_value(text, _name, named, state) do
    text
    |> split_captures(@url_placeholder)
    |> Enum.flat_map_reduce(state, fn
      {:capture, whole}, state -> url_parts(whole, named, state, :path)
      {:text, ""}, state -> {[], state}
      {:text, _chunk}, state -> redact(state)
    end)
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
          {node, state} = json_node(term, table, state)
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

  defp json_node(%Jason.OrderedObject{values: members}, table, state) do
    {members, state} =
      Enum.flat_map_reduce(members, state, fn {key, value}, state ->
        state =
          if String.contains?(key, [@open, @close, @raw]) or not safe_key?(key),
            do: unsupported(state, :body_key),
            else: state

        if safe_key?(key) do
          {value, state} = json_node(value, table, state)
          {[%{key: key, value: value}], state}
        else
          {[], state}
        end
      end)

    {%{kind: :object, members: members}, state}
  end

  defp json_node(list, table, state) when is_list(list) do
    {items, state} = Enum.map_reduce(list, state, &json_node(&1, table, &2))
    {%{kind: :array, items: items}, state}
  end

  defp json_node(text, table, state) when is_binary(text) do
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

            {:text, _chunk}, state ->
              redact(state)
          end)

        {%{kind: :text, parts: parts}, state}
    end
  end

  # Numbers are values: redacted like text.
  defp json_node(number, _table, state) when is_number(number),
    do: redact_value(state)

  defp json_node(value, _table, state), do: {%{kind: :json, value: value}, state}

  defp redact_value(state) do
    state = %{state | redacted: state.redacted + 1}
    {%{kind: :redacted, index: state.redacted}, state}
  end

  # A shared header's value is kept only when it is a media type of a
  # `Content-Type` or `Accept` header; an empty value is empty.
  defp shared_literal(_p, "", state), do: {[], state}

  defp shared_literal(%ConnectorParameter{in: :header, name: name}, text, state)
       when is_binary(name) do
    if String.downcase(name) in ["content-type", "accept"] and media_type?(text),
      do: {[%{kind: :literal, text: text}], state},
      else: redact(state)
  end

  defp shared_literal(_p, _text, state), do: redact(state)

  defp redact(state) do
    state = %{state | redacted: state.redacted + 1}
    {[%{kind: :redacted, index: state.redacted}], state}
  end

  # --- structure that is kept ---------------------------------------------------------

  # Words of API paths kept verbatim; any other path literal is redacted.
  @path_words ~w(
    api apis rest v public private internal admin
    users user me people person profile profiles members member accounts account
    teams team orgs org organizations organization workspaces workspace groups group
    orders order items item products product prices price customers customer
    charges charge payments payment invoices invoice refunds refund subscriptions subscription
    plans plan checkout carts cart coupons coupon discounts balance transactions transaction
    messages message chat chats conversations conversation threads thread replies reply
    completions completion embeddings embedding models model images image audio speech
    transcriptions transcription translations moderations assistants assistant runs run
    steps step responses response files file uploads upload attachments attachment media
    documents document folders folder records record objects object entries entry rows row
    tables table sheets sheet values spreadsheets databases database collections collection
    calendars calendar events event lists list contacts contact companies company deals deal
    leads lead tickets ticket tasks task projects project issues issue comments comment notes note
    labels label tags tag categories category channels channel posts post pages page blocks block
    search query find lookup filter batch bulk sync export import
    create update delete remove get set send add edit patch upsert start stop cancel close open
    status health ping info version versions config settings meta metadata stats analytics
    reports report logs log metrics usage limits
    email emails mail mails sms notifications notification templates template
    webhooks webhook hooks hook callbacks callback
    json xml csv html pdf txt graphql rpc data
    by id ids all new latest current next previous count
  )

  # Media types kept verbatim; any other is redacted.
  @media_types ~w(
    application/json application/x-www-form-urlencoded multipart/form-data text/plain
    text/html text/csv text/xml application/xml application/octet-stream application/pdf
    application/javascript application/graphql application/x-ndjson application/ld+json
    application/problem+json application/merge-patch+json application/json-patch+json
    application/vnd.api+json application/hal+json image/png image/jpeg image/gif image/webp
    image/svg+xml audio/mpeg audio/wav video/mp4 */*
  )

  @doc """
  Whether a path literal is kept: an API version (`v1`, `v2.1`,
  `2023-01-01`) or words of the path dictionary joined by `-`, `_` or
  `.` (`users`, `sign-in`, `users.json`). Nothing else is.
  """
  @spec path_word?(term()) :: boolean()
  def path_word?(text) when is_binary(text) do
    version?(text) or
      (text != "" and
         text
         |> String.split(["-", "_", "."])
         |> Enum.all?(&(String.downcase(&1) in @path_words or version?(&1))))
  end

  def path_word?(_), do: false

  defp version?(text),
    do:
      Regex.match?(
        ~r/\A(?:v\d{1,3}(?:\.\d{1,3}){0,2}(?:beta|alpha)?\d?|\d{4}-\d{2}(?:-\d{2})?)\z/i,
        text
      )

  @doc "Whether a text is an allowlisted media type (`application/json`), with an optional UTF-8 charset."
  @spec media_type?(term()) :: boolean()
  def media_type?(text) when is_binary(text) do
    case Regex.run(~r{\A\s*([^;\s]+)\s*(?:;\s*charset=([A-Za-z0-9\-]+))?\s*\z}, text) do
      [_, type] ->
        String.downcase(type) in @media_types

      [_, type, charset] ->
        String.downcase(type) in @media_types and String.downcase(charset) in ["utf-8", "utf8"]

      nil ->
        false
    end
  end

  def media_type?(_), do: false

  @doc """
  Whether a literal is kept anywhere in a template: an empty text, a path
  word or version, or a media type. Everything else is redacted.
  """
  @spec structural?(term()) :: boolean()
  def structural?(text), do: text == "" or path_word?(text) or media_type?(text)

  # Short words and abbreviations (up to three letters), and common API
  # words the letter model scores low, that are names.
  @short_words ~w(
    a i x id ids db url uri api key to cc bcc at by of on in is it as or and an be do so if
    no up us we he me my go you our ips pin who how two see low the for new get set put add all any max min sum avg num qty ref src
    dst utc gmt tz ip os ui ux sdk app web dev log msg sms mms pdf csv tsv xml css js ts png jpg
    gif svg cdn dns ssl tls jwt ttl crm cms seo raw bin hex top end day hr sec ms eu gb kb mb
    tag via per pre sub pub now old out off yes ok row col tab pos neg dir doc img vid bot ai
    gpt llm org acc amt bal btn cfg cmd ctx env err evt exp ext fmt idx inc len lst obj opt pct
    pkg pwd req res ret rev seq sig sql std str sys tmp txt val var ver win zip eq ne lt gt lte
    gte not has few job due did use run fix hq uid gid svc www com net io co ai mtg utm iso ftp
    ssh vpn gcal http html json uuid ascii yaml toml grpc cors csrf oidc saml ldap smtp imap
    input output subject keywords workflow emoji enum skip view webhook oauth employee
  )

  @hex_run ~r/[0-9a-f]{8,}/i
  @uuid ~r/[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}/i

  @doc """
  Whether a name (a header, parameter or query-string name, a body key, a
  placeholder, a host label) is kept: an identifier (up to 64 characters,
  optionally with `[segment]` suffixes)
  of segments (split at `_`, `-`, `.`, camel case and digits) that are
  each a known short word or abbreviation, a three-letter word with a
  vowel scoring at least -2.6, or an English-like word (four
  to twenty letters scoring at least -3.2, or -3.0 from seven letters, under an English letter-pair
  model, with vowels and no five-consonant run); at most one other single
  letter and
  at most two numbers of up to four digits. UUIDs, runs of eight or more
  hex digits, digits between lowercase letters (`ab12cd`) and
  secret-detector matches are refused. This is a
  heuristic: random tokens are refused with high probability, not
  certainty (measured under 0.5% for random 16-character lowercase
  alphanumerics, UUIDs, 16-character hex and 32-character mixed-case
  alphanumerics; see the test).
  """
  @spec safe_name?(term()) :: boolean()
  def safe_name?(name) when is_binary(name) do
    String.length(name) in 1..64 and
      Regex.match?(~r/\A[$@]?[A-Za-z_][A-Za-z0-9_.\-]*(?:\[[A-Za-z0-9_.\-]*\])*\z/, name) and
      not Regex.match?(@hex_run, name) and not Regex.match?(@uuid, name) and
      not Regex.match?(~r/[A-Za-z][0-9]+[a-z]/, name) and
      not looks_like_credential?(name) and
      name |> segments() |> plain_segments?()
  end

  def safe_name?(_), do: false

  # A body key: a safe name, or plain words separated by spaces.
  defp safe_key?(key),
    do: key != "" and key |> String.split(" ", trim: true) |> Enum.all?(&safe_name?/1)

  defp segments(name) do
    name
    |> String.replace(~r/[$@\[\]]/, " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1 \\2")
    |> String.replace(~r/([A-Za-z])([0-9])/, "\\1 \\2")
    |> String.replace(~r/([0-9])([A-Za-z])/, "\\1 \\2")
    |> String.split(~r/[\s_.\-]+/, trim: true)
  end

  defp plain_segments?(segments) do
    {numbers, words} = Enum.split_with(segments, &Regex.match?(~r/\A\d+\z/, &1))
    words = Enum.map(words, &String.downcase/1)

    words != [] and length(numbers) <= 2 and
      Enum.all?(numbers, &(String.length(&1) <= 4)) and
      Enum.count(words, &(String.length(&1) == 1 and &1 not in ["a", "i", "x"])) <= 1 and
      Enum.all?(words, &word?/1)
  end

  defp word?(word) do
    cond do
      not Regex.match?(~r/\A[a-z]+\z/, word) -> false
      String.length(word) == 1 -> true
      word in @short_words or word in @path_words -> true
      String.length(word) == 2 -> false
      String.length(word) == 3 -> Regex.match?(~r/[aeiouy]/, word) and English.score(word) >= -2.6
      true -> english_like?(word)
    end
  end

  # At least as English-like as -3.2 (-3.0 from seven letters; mean
  # letter-pair log-probability, `English.score/1`), with vowels and no
  # five-consonant run.
  defp english_like?(word) do
    length = String.length(word)
    vowels = word |> String.graphemes() |> Enum.count(&(&1 in ~w(a e i o u y)))

    length <= 20 and vowels / length >= 0.15 and vowels / length <= 0.7 and
      not Regex.match?(~r/[bcdfghjklmnpqrstvwxz]{5,}/, word) and
      English.score(word) >= if(length >= 7, do: -3.0, else: -3.2)
  end

  defp looks_like_credential?(text) do
    Regex.match?(~r/bearer\s+\S{8,}|basic\s+[A-Za-z0-9+\/=]{8,}/i, text) or
      Detectors.scan_value(text) != []
  end

  @doc "Whether a member or parameter name names a credential."
  @spec credential?(term()) :: boolean()
  def credential?(name) when is_binary(name), do: Regex.match?(@credential, name)

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
