defmodule BubbleEx.Js.Lexer do
  @moduledoc """
  Splits an app author's JavaScript into tokens for `BubbleEx.Js` (WTF-608).
  A reader for a conservative static check, not a parser: it knows
  comments, strings, template literals (their `${…}` parts are tokens
  too), regular expression literals, numbers, identifiers and punctuators,
  and refuses anything it cannot read for sure.

  A token is `{kind, value, meta}`:

    * `:ident` - an identifier or keyword (`value` its name); a private
      name keeps its `#`
    * `:punct` - a punctuator (`value` its text)
    * `:string` - a quoted string (`value` its raw text between the quotes)
    * `:template` - a template literal (`value` a list of `{:text, raw}` and
      `{:expr, tokens}`)
    * `:number`, `:regex` - `value` the raw text

  `meta` is `%{nl: boolean}`: whether a line break comes before the token.

  Refused (`{:error, reason}`): an unterminated comment, string, template
  or regular expression, a backslash outside a string (an escaped
  identifier hides its name), and any character it does not know.
  """

  @type token :: {:ident | :punct | :string | :template | :number | :regex, term(), map()}

  @puncts ~w(>>>= ... === !== **= <<= >>= >>> &&= ||= ??= => == != <= >= && || ?? ?. ++ -- += -=
             *= /= %= &= |= ^= ** << >>) ++
            Enum.map(~c"{}()[];,<>+-*/%&|^!~?:=.@", &<<&1>>)

  # A `/` after these starts a regular expression, not a division.
  @regex_after_idents ~w(return typeof instanceof in of new delete void throw case do else yield await)

  @spaces [?\s, ?\t, ?\v, ?\f, 0xA0, 0xFEFF]
  @breaks [?\n, ?\r, 0x2028, 0x2029]

  @doc "The tokens of `source`, or why it cannot be read."
  @spec tokens(String.t()) :: {:ok, [token()]} | {:error, String.t()}
  def tokens(source) when is_binary(source) do
    if String.valid?(source) do
      case lex(source, [], false, :top) do
        {:ok, tokens, ""} -> {:ok, tokens}
        {:ok, _tokens, _rest} -> {:error, "an unmatched }"}
        {:error, _} = error -> error
      end
    else
      {:error, "not UTF-8"}
    end
  end

  # `mode` :top reads to the end; :template reads a `${…}` part to its
  # closing brace (depth counts the braces opened inside it).
  defp lex(src, acc, nl, mode, depth \\ 0)

  defp lex("", acc, _nl, :top, _depth), do: {:ok, Enum.reverse(acc), ""}
  defp lex("", _acc, _nl, :template, _depth), do: {:error, "an unterminated template literal"}

  defp lex(<<c::utf8, rest::binary>>, acc, nl, mode, depth) when c in @spaces,
    do: lex(rest, acc, nl, mode, depth)

  defp lex(<<c::utf8, rest::binary>>, acc, _nl, mode, depth) when c in @breaks,
    do: lex(rest, acc, true, mode, depth)

  defp lex("//" <> rest, acc, nl, mode, depth) do
    case :binary.match(rest, ["\n", "\r", "\u2028", "\u2029"]) do
      {at, _} -> lex(binary_part(rest, at, byte_size(rest) - at), acc, nl, mode, depth)
      :nomatch -> lex("", acc, nl, mode, depth)
    end
  end

  defp lex("/*" <> rest, acc, nl, mode, depth) do
    case :binary.split(rest, "*/") do
      [comment, after_comment] ->
        nl = nl or String.contains?(comment, ["\n", "\r", "\u2028", "\u2029"])
        lex(after_comment, acc, nl, mode, depth)

      [_] ->
        {:error, "an unterminated comment"}
    end
  end

  defp lex("}" <> rest, acc, _nl, :template, 0), do: {:ok, Enum.reverse(acc), rest}

  defp lex(<<q, rest::binary>>, acc, nl, mode, depth) when q in [?", ?'] do
    with {:ok, raw, rest} <- string(rest, q, []),
         do: lex(rest, [{:string, raw, %{nl: nl}} | acc], false, mode, depth)
  end

  defp lex("`" <> rest, acc, nl, mode, depth) do
    with {:ok, parts, rest} <- template(rest, [], []),
         do: lex(rest, [{:template, parts, %{nl: nl}} | acc], false, mode, depth)
  end

  defp lex("/" <> rest = src, acc, nl, mode, depth) do
    if regex_allowed?(acc) do
      with {:ok, raw, rest} <- regex(rest, false, ["/"]),
           do: lex(rest, [{:regex, raw, %{nl: nl}} | acc], false, mode, depth)
    else
      punct(src, acc, nl, mode, depth)
    end
  end

  defp lex(<<c::utf8, _::binary>> = src, acc, nl, mode, depth) when c in ?0..?9,
    do: number(src, acc, nl, mode, depth)

  defp lex(<<?., c, _::binary>> = src, acc, nl, mode, depth) when c in ?0..?9,
    do: number(src, acc, nl, mode, depth)

  defp lex("\\" <> _, _acc, _nl, _mode, _depth),
    do: {:error, "a backslash outside a string (an escaped name)"}

  defp lex(<<c::utf8, _::binary>> = src, acc, nl, mode, depth)
       when c in ?a..?z or c in ?A..?Z or c in [?_, ?$, ?#] or c > 127 do
    case Regex.run(
           ~r/\A#?[\p{L}\p{Nl}_$][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}_$\x{200C}\x{200D}]*/u,
           src
         ) do
      [name] ->
        rest = binary_part(src, byte_size(name), byte_size(src) - byte_size(name))

        if String.starts_with?(rest, "\\"),
          do: {:error, "a backslash outside a string (an escaped name)"},
          else: lex(rest, [{:ident, name, %{nl: nl}} | acc], false, mode, depth)

      nil ->
        {:error, "an unknown character (U+#{Integer.to_string(c, 16)})"}
    end
  end

  defp lex(src, acc, nl, mode, depth), do: punct(src, acc, nl, mode, depth)

  defp punct(src, acc, nl, mode, depth) do
    case Enum.find(@puncts, &String.starts_with?(src, &1)) do
      nil ->
        <<c::utf8, _::binary>> = src
        {:error, "an unknown character (U+#{Integer.to_string(c, 16)})"}

      p ->
        rest = binary_part(src, byte_size(p), byte_size(src) - byte_size(p))

        depth =
          case p do
            "{" -> depth + 1
            "}" -> depth - 1
            _ -> depth
          end

        lex(rest, [{:punct, p, %{nl: nl}} | acc], false, mode, depth)
    end
  end

  @bigint ~r/\A(?:0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*|0[oO][0-7](?:_?[0-7])*|0[bB][01](?:_?[01])*|[0-9](?:_?[0-9])*)n/
  @decimal ~r/\A(?:0[xX][0-9a-fA-F](?:_?[0-9a-fA-F])*|0[oO][0-7](?:_?[0-7])*|0[bB][01](?:_?[01])*|(?:[0-9](?:_?[0-9])*(?:\.(?:[0-9](?:_?[0-9])*)?)?|\.[0-9](?:_?[0-9])*)(?:[eE][+-]?[0-9](?:_?[0-9])*)?)/

  # A number: separators only between digits, a BigInt only of an integer,
  # no legacy octal (`010`, `0_1`), and nothing name-like right after it.
  defp number(src, acc, nl, mode, depth) do
    [raw] = Regex.run(@bigint, src) || Regex.run(@decimal, src)
    rest = binary_part(src, byte_size(raw), byte_size(src) - byte_size(raw))

    cond do
      Regex.match?(~r/\A0[0-9_]/, raw) ->
        {:error, "a legacy octal number"}

      Regex.match?(~r/\A[\p{L}\p{N}_$\\]/u, rest) ->
        {:error, "a malformed number"}

      true ->
        lex(rest, [{:number, raw, %{nl: nl}} | acc], false, mode, depth)
    end
  end

  # An escape: `\x` takes two hex digits, `\u` four or a code point in
  # braces.
  defp escape("x" <> rest) do
    case rest do
      <<a, b, rest::binary>> when a in ?0..?9 or a in ?a..?f or a in ?A..?F ->
        if hex?(b), do: {:ok, <<"x", a, b>>, rest}, else: {:error, "a malformed escape"}

      _ ->
        {:error, "a malformed escape"}
    end
  end

  defp escape("u{" <> rest) do
    case Regex.run(~r/\A([0-9a-fA-F]{1,6})\}/, rest) do
      [whole, hex] ->
        if String.to_integer(hex, 16) <= 0x10FFFF,
          do:
            {:ok, "u{" <> whole,
             binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))},
          else: {:error, "a malformed escape"}

      _ ->
        {:error, "a malformed escape"}
    end
  end

  defp escape("u" <> rest) do
    case Regex.run(~r/\A[0-9a-fA-F]{4}/, rest) do
      [hex] -> {:ok, "u" <> hex, binary_part(rest, 4, byte_size(rest) - 4)}
      _ -> {:error, "a malformed escape"}
    end
  end

  defp escape(<<c::utf8, rest::binary>>), do: {:ok, <<c::utf8>>, rest}
  defp escape(_), do: {:error, "an unterminated string"}

  defp hex?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  defp string(<<q, rest::binary>>, q, acc),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp string(<<?\\, rest::binary>>, q, acc) do
    with {:ok, escaped, rest} <- escape(rest), do: string(rest, q, [escaped, "\\" | acc])
  end

  defp string(<<c::utf8, _::binary>>, _q, _acc) when c in [?\n, ?\r],
    do: {:error, "an unterminated string"}

  defp string(<<c::utf8, rest::binary>>, q, acc), do: string(rest, q, [<<c::utf8>> | acc])
  defp string(_, _q, _acc), do: {:error, "an unterminated string"}

  # A template literal's parts, to its closing backquote.
  defp template("`" <> rest, text, parts), do: {:ok, close_text(text, parts), rest}

  defp template(<<?\\, rest::binary>>, text, parts) do
    with {:ok, escaped, rest} <- escape(rest), do: template(rest, [escaped, "\\" | text], parts)
  end

  defp template("${" <> rest, text, parts) do
    with {:ok, tokens, rest} <- lex(rest, [], false, :template, 0) do
      parts = close_text(text, parts) |> Enum.reverse()
      template(rest, [], Enum.reverse([{:expr, tokens} | parts]))
    end
  end

  defp template(<<c::utf8, rest::binary>>, text, parts),
    do: template(rest, [<<c::utf8>> | text], parts)

  defp template(_, _text, _parts), do: {:error, "an unterminated template literal"}

  defp close_text([], parts), do: parts
  defp close_text(text, parts), do: parts ++ [{:text, IO.iodata_to_binary(Enum.reverse(text))}]

  # A regular expression literal: its body (a `/` inside a class does not
  # close it) and flags.
  defp regex(<<?\\, c::utf8, rest::binary>>, class?, acc),
    do: regex(rest, class?, [<<c::utf8>>, "\\" | acc])

  defp regex("[" <> rest, _class?, acc), do: regex(rest, true, ["[" | acc])
  defp regex("]" <> rest, true, acc), do: regex(rest, false, ["]" | acc])

  defp regex("/" <> rest, false, acc) do
    [flags] = Regex.run(~r/\A[a-z]*/, rest)
    rest = binary_part(rest, byte_size(flags), byte_size(rest) - byte_size(flags))
    {:ok, IO.iodata_to_binary(Enum.reverse([flags, "/" | acc])), rest}
  end

  defp regex(<<c::utf8, _::binary>>, _class?, _acc) when c in @breaks,
    do: {:error, "an unterminated regular expression"}

  defp regex(<<c::utf8, rest::binary>>, class?, acc), do: regex(rest, class?, [<<c::utf8>> | acc])
  defp regex(_, _class?, _acc), do: {:error, "an unterminated regular expression"}

  defp regex_allowed?([]), do: true
  defp regex_allowed?([{:punct, p, _} | _]), do: p not in [")", "]", "++", "--"]
  defp regex_allowed?([{:ident, name, _} | _]), do: name in @regex_after_idents
  defp regex_allowed?(_), do: false
end
