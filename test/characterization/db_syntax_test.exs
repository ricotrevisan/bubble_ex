defmodule BubbleEx.Characterization.DbSyntaxTest do
  # The generated DBML, Zod and Convex schemas must parse, whatever the
  # Bubble names hold (WTF-408: DBML once wrote `"` unescaped inside quoted
  # identifiers, Zod a raw line break inside a quoted object key).
  #
  # The `:syntax_check` tests parse every schema fixture's output, in both
  # namings and in the legacy and preserved external-type modes, with real
  # parsers: @dbml/core for DBML and the TypeScript compiler's parser for Zod
  # and Convex (`test/support/syntax_check/check.mjs`, pinned in its
  # package-lock). They need Node.js and the pinned packages, so they are
  # excluded by default; CI runs them in the fidelity job, which has Node:
  #
  #     npm ci --ignore-scripts --prefix test/support/syntax_check
  #     mix test --only syntax_check
  #
  # The untagged tests are a structural check that always runs: over the
  # hostile_names fixture, no line terminator but LF appears and no line ends
  # inside a string literal (a small tokenizer, not a parser); for T-SQL, no
  # line but the encoder's own `GO` is one sqlcmd would act on (WTF-409).
  use ExUnit.Case, async: true

  alias BubbleEx.Db.{Encoder, Reader}

  @hostile_fixture "test/support/db/fixtures/hostile_names.json"

  @formats [dbml: "dbml", zod: "ts", convex: "ts"]

  defp db(fixture) do
    {:ok, db} = fixture |> File.read!() |> Jason.decode!() |> Reader.parse()
    db
  end

  defp render(db, format) do
    {:ok, result} = Encoder.render(format, db)
    result.content
  end

  describe "structural check over hostile_names" do
    for {format, _ext} <- @formats do
      @format format
      test "#{format} keeps every literal and comment on its line" do
        content = @hostile_fixture |> db() |> render(@format)

        refute content =~ ~r/[\x{0B}-\x{0D}\x{85}\x{2028}\x{2029}]/u

        content
        |> String.split("\n")
        |> skip_dbml_project(@format)
        |> Enum.each(fn line ->
          assert closed?(line),
                 "#{@format}: a string literal runs past the line: #{inspect(line)}"
        end)
      end
    end

    test "the structural check rejects a line ending inside a literal" do
      refute closed?(~S|  'a\': z.string(),|)
      refute closed?(~S|Table custom."a"b" {|)
      assert closed?(~S|  'a\\': z.string(), // it's "fine"|)
    end
  end

  describe "T-SQL batch separators" do
    # sqlcmd and SSMS split a script into batches on any line that is only
    # `GO` or `GO n` (case-insensitive, surrounding blanks allowed) and run
    # `:command` and `!!` lines themselves, before T-SQL parses a thing
    # (WTF-409). Brackets allow raw line breaks, so a name holding "\nGO\n"
    # once cut the script in two. No T-SQL parser is cheap in CI (sqlcmd
    # needs a server), so this is a structural check over every fixture: the
    # only batch-tool lines are the encoder's own `GO` after `CREATE SCHEMA`.
    @tsql_fixtures Enum.sort(
                     Path.wildcard("test/support/model/*.json") ++
                       Path.wildcard("test/support/db/fixtures/*.json") ++
                       ~w(test/support/samples/synthetic_app.json test/support/samples/synthetic_export.json)
                   )

    test "every GO line is the encoder's own separator after CREATE SCHEMA" do
      for fixture <- @tsql_fixtures,
          naming <- [:proper, :id],
          foreign_keys <- [:none, :enforced] do
        {:ok, result} =
          Encoder.render(:tsql, db(fixture), naming: naming, foreign_keys: foreign_keys)

        assert batch_tool_violations(result.content) == [],
               "#{Path.basename(fixture)} (#{naming}, #{foreign_keys})"
      end
    end

    test "the hostile GO names are in the fixture and stay on their line" do
      db = db("test/support/db/fixtures/hostile_go_separators.json")
      names = Enum.flat_map(db.tables, &[&1.name | Enum.map(&1.columns, fn c -> c.name end)])

      for pattern <- [~r/\nGO\n/, ~r/\ngo\n/, ~r/\n GO \n/, ~r/\nGO 5\n/, ~r/\r\nGO\r\n/] do
        assert Enum.any?(names, &(&1 =~ pattern)), inspect(pattern)
      end

      content = render(db, :tsql)
      refute content =~ ~r/[\x{00}-\x{09}\x{0B}-\x{1F}\x{7F}\x{85}\x{2028}\x{2029}]/u
      assert content =~ "[a GO b_cbdcf979] NVARCHAR(MAX)"
      assert content =~ "[a GO b] NVARCHAR(MAX)"
    end

    test "the batch check rejects a name that splits the batch" do
      assert batch_tool_violations("CREATE SCHEMA [custom];\nGO\n") == []

      for line <- ["GO", "go", "  GO  ", "GO 5", "Go;", ":r evil.sql", "!!del x"] do
        assert batch_tool_violations("CREATE TABLE [custom].[a\n#{line}\nb] (\n);") == [line]
      end
    end
  end

  # Lines sqlcmd would act on, except `GO` right after a `CREATE SCHEMA`.
  defp batch_tool_violations(content) do
    lines = String.split(content, ~r/\r\n|\r|\n/)

    lines
    |> Enum.zip(["" | lines])
    |> Enum.flat_map(fn {line, previous} ->
      cond do
        line == "GO" and previous =~ ~r/^CREATE SCHEMA \[[^\]]+\];$/ -> []
        line =~ ~r/^\s*(GO\b|:|!!)/i -> [line]
        true -> []
      end
    end)
  end

  # The Project block's note is a DBML ''' multi-line string, fixed text.
  defp skip_dbml_project(lines, :dbml), do: Enum.drop_while(lines, &(&1 != ""))
  defp skip_dbml_project(lines, _format), do: lines

  # Scans one line: `'` and `"` open string literals, a backslash escapes the
  # next character, and `//` outside a literal starts a comment.
  defp closed?(line), do: scan(line, nil)

  defp scan("", quote), do: quote == nil
  defp scan("//" <> _comment, nil), do: true
  defp scan(<<q, rest::binary>>, nil) when q in [?', ?"], do: scan(rest, q)
  defp scan(<<_, rest::binary>>, nil), do: scan(rest, nil)
  defp scan(<<?\\, _escaped::utf8, rest::binary>>, quote), do: scan(rest, quote)
  defp scan(<<q, rest::binary>>, q), do: scan(rest, nil)
  defp scan(<<_::utf8, rest::binary>>, quote), do: scan(rest, quote)
end

defmodule BubbleEx.Characterization.DbSyntaxParserTest do
  # The `:syntax_check` half of DbSyntaxTest (see its header): real parsers
  # over every schema fixture's DBML, Zod and Convex output.
  use ExUnit.Case, async: true

  alias BubbleEx.Db.{Encoder, Reader}

  @moduletag :syntax_check

  @checker "test/support/syntax_check/check.mjs"
  @hostile_fixture "test/support/db/fixtures/hostile_names.json"

  @fixtures Enum.sort(
              Path.wildcard("test/support/model/*.json") ++
                Path.wildcard("test/support/db/fixtures/*.json") ++
                ~w(test/support/samples/synthetic_app.json test/support/samples/synthetic_export.json)
            )

  @formats [dbml: "dbml", zod: "ts", convex: "ts"]

  defp db(fixture) do
    {:ok, db} = fixture |> File.read!() |> Jason.decode!() |> Reader.parse()
    db
  end

  defp render(db, format, opts) do
    {:ok, result} = Encoder.render(format, db, opts)
    result.content
  end

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bubble_ex_syntax_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    files =
      for fixture <- @fixtures,
          naming <- [:proper, :id],
          external_types <- [:legacy, :preserve],
          {format, ext} <- @formats do
        content =
          fixture |> db() |> render(format, naming: naming, external_types: external_types)

        name = "#{Path.basename(fixture, ".json")}.#{naming}.#{external_types}.#{format}.#{ext}"
        path = Path.join(dir, name)
        File.write!(path, content)
        path
      end

    {output, 0} = System.cmd("node", [@checker | files], stderr_to_stdout: true)

    results =
      output
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        result = Jason.decode!(line)
        {Path.basename(result["file"]), result}
      end)

    %{results: results}
  end

  test "every generated DBML, Zod and Convex schema parses", %{results: results} do
    assert map_size(results) == length(@fixtures) * 2 * 2 * length(@formats)

    failures = for {file, %{"errors" => [_ | _] = errors}} <- results, do: {file, errors}
    assert failures == []
  end

  test "hostile DBML names parse back unchanged", %{results: results} do
    db = db(@hostile_fixture)
    %{"names" => names} = results["hostile_names.proper.legacy.dbml.dbml"]

    expected =
      Enum.flat_map(db.tables, fn table ->
        prefix = "#{table.group}.#{table.name}"

        columns =
          for column <- table.columns, not column.deleted, do: "#{prefix}.#{column.name}"

        [prefix | columns]
      end)

    assert expected -- names == []
    assert Enum.any?(expected, &(&1 =~ "\n")) and Enum.any?(expected, &(&1 =~ ~s(")))
  end

  test "hostile Zod keys parse back unchanged", %{results: results} do
    db = db(@hostile_fixture)
    %{"names" => names} = results["hostile_names.proper.legacy.zod.ts"]

    expected =
      for table <- db.tables,
          table.group != :api,
          column <- table.columns,
          not column.deleted,
          do: column.name

    assert expected -- names == []
    assert Enum.any?(expected, &(&1 =~ "\u2028"))
  end
end
