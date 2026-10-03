# Checks the migrations `mix ash.codegen` generated for the custom indexes
# (WTF-418), in the scratch project's priv/: the generated resources
# declare every index `concurrently: true`, so AshPostgres writes them as
# migrations of their own that add (and on rollback drop) indexes only,
# outside a transaction and without the migration lock (Ecto's recipe for
# CREATE INDEX CONCURRENTLY):
#
#   * a migration that builds an index concurrently has
#     `@disable_ddl_transaction true` and `@disable_migration_lock true`,
#     and its up/down hold nothing but `create index(...)` and
#     `drop_if_exists index(...)`
#   * every `create index(...)` is concurrent: an index a re-publish adds
#     to a loaded table never locks its writes (unique indexes, from
#     identities, are not custom indexes)
#   * at least one such migration exists (the fixtures have index hints)
#
#     elixir index_migrations.exs [priv dir]

dir = List.first(System.argv()) || "priv"
files = Path.wildcard(Path.join(dir, "**/migrations/*.exs"))

fail = fn message ->
  IO.puts(:stderr, "index migrations: " <> message)
  System.halt(1)
end

if files == [], do: fail.("no migrations under #{dir}")

statements = fn source ->
  # The bodies of up/0 and down/0, one statement per line once the
  # formatter's line breaks inside a call are joined (`create index(...)`,
  # or `create(index(...))` without Ecto's formatter locals).
  source
  |> String.split("\n")
  |> Enum.map(&String.trim/1)
  |> Enum.drop_while(&(&1 != "def up do"))
  |> Enum.reject(&(&1 in ["", "def up do", "def down do", "end"] or String.starts_with?(&1, "#")))
  |> Enum.chunk_while(
    "",
    fn line, acc ->
      joined = acc <> line
      opened = joined |> String.graphemes() |> Enum.count(&(&1 in ["(", "["]))
      closed = joined |> String.graphemes() |> Enum.count(&(&1 in [")", "]"]))
      if opened == closed, do: {:cont, joined, ""}, else: {:cont, joined <> " "}
    end,
    fn
      "" -> {:cont, ""}
      acc -> {:cont, acc, ""}
    end
  )
end

concurrent =
  for file <- files,
      source = File.read!(file),
      source =~ "concurrently: true" do
    for attribute <- ["@disable_ddl_transaction true", "@disable_migration_lock true"],
        not String.contains?(source, attribute),
        do: fail.("#{file} builds an index concurrently without #{attribute}")

    for statement <- statements.(source),
        not (statement =~ ~r/^create\(?\s*index\(/ and statement =~ "concurrently: true") and
          not (statement =~ ~r/^drop_if_exists\(?\s*index\(/),
        do: fail.("#{file} is not index-only: #{statement}")

    file
  end

for file <- files -- concurrent,
    source = File.read!(file),
    source =~ ~r/^\s*create\(?\s*index\(/m,
    do: fail.("#{file} creates an index that is not concurrent")

if concurrent == [], do: fail.("no concurrent index migration was generated")

IO.puts(
  "index migrations: #{length(concurrent)} index-only migration(s), concurrent, " <>
    "outside a transaction and the migration lock"
)
