defmodule BubbleEx.Test.Ddl do
  @moduledoc false

  # Loads generated DDL into a real database. SQLite runs in memory through
  # python3's sqlite3 module; PostgreSQL through `psql`, in a fresh database
  # on the server `url` (a URL without a database), dropped afterwards.

  @sqlite """
  import sqlite3, sys
  sqlite3.connect(":memory:").executescript(sys.stdin.read())
  """

  @spec sqlite(String.t()) :: {String.t(), non_neg_integer()}
  def sqlite(sql) do
    with_file(sql, fn path ->
      System.cmd("sh", ["-c", ~s(python3 -c "$0" < "$1"), @sqlite, path], stderr_to_stdout: true)
    end)
  end

  @spec postgres(String.t(), String.t()) :: {String.t(), non_neg_integer()}
  def postgres(url, sql) do
    database = "bubble_ex_ddl_#{System.unique_integer([:positive])}"
    {_, 0} = psql(url <> "/postgres", ["-c", "CREATE DATABASE #{database}"])

    try do
      with_file(sql, &psql("#{url}/#{database}", ["-v", "ON_ERROR_STOP=1", "-q", "-f", &1]))
    after
      psql(url <> "/postgres", ["-c", "DROP DATABASE IF EXISTS #{database}"])
    end
  end

  defp psql(url, args), do: System.cmd("psql", [url | args], stderr_to_stdout: true)

  defp with_file(contents, fun) do
    path = Path.join(System.tmp_dir!(), "bubble_ex_ddl_#{System.unique_integer([:positive])}.sql")
    File.write!(path, contents)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end
end
