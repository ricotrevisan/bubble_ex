# The check scripts' database (scripts/ash_compile_check.sh,
# scripts/phoenix_compile_check.sh): fail closed. The URL comes from the
# environment and is never defaulted; it must name its port explicitly,
# and never 5432 (a developer's everyday PostgreSQL) unless
# ASH_COMPILE_CHECK_ALLOW_5432=1 (PHOENIX_COMPILE_CHECK_ALLOW_5432=1 for
# the Phoenix check); and the checks create, empty and drop only
# databases whose names carry a check prefix.
#
#     Code.require_file("scripts/check_db.exs")
#     base = CheckDb.url!()                       # ASH_COMPILE_CHECK_DB
#     CheckDb.database!("ash_check_field_types")  # raises without a prefix
defmodule CheckDb do
  @moduledoc false

  @prefixes ~w(ash_check_ ash_omit_check_ ash_matrix_ ecto_check_ phx_check_)

  @doc "The validated URL (no database) in `var`."
  def url!(var \\ "ASH_COMPILE_CHECK_DB", allow \\ "ASH_COMPILE_CHECK_ALLOW_5432") do
    url = System.fetch_env!(var)
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["ecto", "postgres", "postgresql"] ->
        raise "#{var} must be an ecto:// or postgres:// URL"

      uri.host in [nil, ""] ->
        raise "#{var} must name its host"

      # ecto:// and postgres:// have no default port: nil when not given
      is_nil(uri.port) ->
        raise "#{var} must name its port explicitly (e.g. ecto://postgres:postgres@127.0.0.1:55432)"

      uri.port == 5432 and System.get_env(allow) != "1" ->
        raise "#{var} points at port 5432: use a PostgreSQL of the check's own, or set #{allow}=1"

      uri.path not in [nil, "", "/"] ->
        raise "#{var} must not name a database (the checks name their own)"

      true ->
        String.trim_trailing(url, "/")
    end
  end

  @doc "`name`, when it carries a check prefix; raises otherwise."
  def database!(name) do
    if Enum.any?(@prefixes, &String.starts_with?(name, &1)),
      do: name,
      else: raise("refusing a database without a check prefix (#{Enum.join(@prefixes, ", ")})")
  end
end
