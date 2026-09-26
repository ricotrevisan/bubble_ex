defmodule BubbleEx.Db.Encoder.Literal do
  @moduledoc """
  Quoting for names that encoders write into their target syntax (WTF-408).
  Bubble names are arbitrary text: quotes, backslashes, `--`, `*/` and line
  breaks (CR, LF, VT, FF, NEL, LS, PS) all occur, and none may end a literal
  or comment early, nor start a line a batch tool reads as a command (T-SQL's
  `GO`). Each function follows its format's grammar, and the
  generated-schema syntax check (`test/support/syntax_check`) parses the
  output of the `hostile_names` fixture with the real parsers.
  """

  # Line terminators some tool splits on, besides CR and LF.
  @line_breaks ["\v", "\f", "\u0085", "\u2028", "\u2029"]

  # C0 controls, DEL, and the Unicode line/paragraph separators.
  @escaped ~r/[\x{00}-\x{1F}\x{7F}\x{85}\x{2028}\x{2029}]/u

  @doc """
  A DBML double-quoted identifier (`"..."`): backslash and `"` are
  backslash-escaped, and control characters and line separators become
  `\\n`, `\\r`, `\\t` or `\\uXXXX` escapes (DBML rejects a raw line break
  inside a quoted identifier).
  """
  @spec dbml_quoted(String.t()) :: String.t()
  def dbml_quoted(name) do
    escaped =
      name
      |> String.replace("\\", "\\\\")
      |> String.replace(~s("), ~s(\\"))
      |> escape_controls()

    ~s("#{escaped}")
  end

  @doc """
  A JavaScript/TypeScript single-quoted string literal (`'...'`): backslash
  and `'` are backslash-escaped, and control characters and line separators
  become `\\n`, `\\r`, `\\t` or `\\uXXXX` escapes. The literal stays on one
  line and reads back as `name` exactly.
  """
  @spec js_single_quoted(String.t()) :: String.t()
  def js_single_quoted(name) do
    escaped =
      name
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")
      |> escape_controls()

    "'" <> escaped <> "'"
  end

  @doc """
  A T-SQL bracket-quoted identifier (`[...]`) that stays on one line, with
  embedded `]` doubled. T-SQL allows raw line breaks inside brackets, but
  sqlcmd and SSMS split batches on any line that is only `GO` (or `GO n`)
  before the server parses anything, so a name holding such a line would cut
  the script in two (WTF-409). A name with control characters or line
  separators therefore has each of them replaced by a space and gets a
  suffix of `_` and the first 8 hex digits of the SHA-256 of the original
  name, so it stays deterministic and cannot collide with the name that
  already had spaces. Every other name is kept verbatim.
  """
  @spec tsql_bracketed(String.t()) :: String.t()
  def tsql_bracketed(name) do
    "[" <> String.replace(single_line(name), "]", "]]") <> "]"
  end

  defp single_line(name) do
    if name =~ @escaped do
      suffix = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      Regex.replace(@escaped, name, " ") <> "_" <> suffix
    else
      name
    end
  end

  @doc """
  Text safe inside a line comment (`--` in SQL, `//` in JavaScript):
  backslashes are doubled first, so the escapes stay unambiguous, then CR,
  LF and the other line terminators (VT, FF, NEL, LS, PS) become `\\r`,
  `\\n`, `\\v`, `\\f` and `\\uXXXX`, so the text cannot end the comment and
  run as code.
  """
  @spec line_comment(String.t()) :: String.t()
  def line_comment(text) do
    Enum.reduce(
      [{"\\", "\\\\"}, {"\r", "\\r"}, {"\n", "\\n"} | Enum.map(@line_breaks, &{&1, escape(&1)})],
      text,
      fn {char, escape}, acc -> String.replace(acc, char, escape) end
    )
  end

  defp escape_controls(text), do: Regex.replace(@escaped, text, &escape/1)

  defp escape("\n"), do: "\\n"
  defp escape("\r"), do: "\\r"
  defp escape("\t"), do: "\\t"
  defp escape("\v"), do: "\\v"
  defp escape("\f"), do: "\\f"

  defp escape(<<codepoint::utf8>>),
    do: "\\u" <> String.pad_leading(Integer.to_string(codepoint, 16), 4, "0")
end
