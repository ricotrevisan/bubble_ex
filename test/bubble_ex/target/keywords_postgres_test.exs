defmodule BubbleEx.Target.KeywordsPostgresTest do
  # The generated keyword module (templates/lib/app/bubble/keywords.ex.eex)
  # against PostgreSQL itself: its Porter2 stems and stop words must stay
  # PostgreSQL's `english_stem`, and its words those of
  # `to_tsvector('english', ...)` on plain text, so an in-memory keyword
  # match agrees with a search (replay 2026-10-14, WTF-387). It needs a
  # server (BUBBLE_EX_DDL_PG, a URL without a database); CI runs it in the
  # ash-compile-check job with the other PostgreSQL tests:
  #
  #     BUBBLE_EX_DDL_PG=postgres://… mix test --only ddl_postgres
  use ExUnit.Case, async: true

  alias BubbleEx.Target.Phoenix.Templates

  @moduletag :ddl_postgres
  @keywords Module.concat(["KeywordsPgCheck", Bubble, Keywords])

  # Stems that exercise every step of the algorithm, with the suffixes
  # below: a sample, not a dictionary.
  @stems ~w(
    abl accept act adjust admir agre alloc analys appear argu arriv bake bear beauti
    beli beta bless bodi bright build busi care carri caus centr chang charg cheer
    child cri cultur cycl danc deal decid defin deliv depend design develop differ
    direct discov dress driv dye earli econom educ effect electr emot employ enjoy
    equal exceed experi fail fit fli formal fortun friend gener generous gentl
    happi help hop hope hurri idl illustr import industri inform innov integr
    judg kind lazi lie live logic love manag measur mix nation natur ness news
    norm number obey oper organ origin pass permit plan play pleas posit possibl
    prefer proceed product profession quick rate real reli remov respons revers
    run sad sens servic shop sing ski sky slow speak stop succeed teach test tie
    tri ugli use valu visit walk weak wonder write yell
  )
  @suffixes ~w(s es ed ing ly er est ness ful fulness able ible ation ational
              ization izer ive iveness ity ities ment ments ence ance ous ousli
              alism aliti alli bli ogi li ical icate ative al ism ion ions y ies ied)

  setup_all do
    unless Code.ensure_loaded?(@keywords) do
      "lib/app/bubble/keywords.ex"
      |> Templates.render(%{module: "KeywordsPgCheck", app: :keywords_pg_check, enforced?: false})
      |> Code.compile_string()
    end

    # A variable, not a literal module: it is compiled at run time.
    %{keywords: @keywords}
  end

  defp pg_url, do: System.get_env("BUBBLE_EX_DDL_PG") || flunk("set BUBBLE_EX_DDL_PG")

  defp psql(sql) do
    {out, 0} =
      System.cmd("psql", [pg_url() <> "/postgres", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
        stderr_to_stdout: true
      )

    out |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "NOTICE"))
  end

  # Only [a-z] words go into the SQL text.
  defp array(words) do
    for w <- words, do: true = w =~ ~r/\A[a-z]+\z/
    "ARRAY['" <> Enum.join(words, "','") <> "']"
  end

  test "stems and stop words agree with PostgreSQL's english_stem", %{keywords: keywords} do
    stop = ~w(the and of is was were being having does doing myself ourselves)

    words =
      (for(s <- @stems, x <- ["" | @suffixes], do: s <> x) ++ stop)
      |> Enum.uniq()
      |> Enum.sort()

    rows =
      psql(
        "SELECT w || ',' || coalesce((ts_lexize('english_stem', w))[1], '') " <>
          "FROM unnest(#{array(words)}) AS w ORDER BY w"
      )

    assert length(rows) == length(words)

    differ =
      for row <- rows,
          [w, pg] = String.split(row, ","),
          ours = keywords.lexemes(w),
          ours != if(pg == "", do: [], else: [pg]),
          do: {w, pg, ours}

    assert differ == [],
           "#{length(differ)} of #{length(words)} differ: #{inspect(Enum.take(differ, 20))}"
  end

  test "the words of plain text agree with to_tsvector('english', ...)", %{keywords: keywords} do
    for text <- [
          "Bake the bread, then the BETA-test!",
          "alphabet soup; alpha beta gamma",
          "Running runners ran: the generalization of happiness",
          "Hyphen-split words and well-known re-entry",
          "It's 100% rye in 2024"
        ] do
      [vector] = psql("SELECT to_tsvector('english', #{sql_text(text)})::text")

      pg =
        ~r/'([^']+)'/
        |> Regex.scan(vector, capture: :all_but_first)
        |> List.flatten()
        |> Enum.sort()

      assert Enum.sort(keywords.lexemes(text)) == pg, text
    end
  end

  defp sql_text(text), do: "'" <> String.replace(text, "'", "''") <> "'"
end
