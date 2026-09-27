# Reads the records scripts/ash_compile_check/load.exs loaded (WTF-357)
# back through Ash, in the scratch project, after load.exs wrote
# loaded.json:
#
#   * every resource of each loaded fixture reads all its records with
#     `Ash.read!` (authorization off): every loaded value casts to its Ash
#     type (enums, typed structs, arrays, dates, decimals), and Ash sees as
#     many records as PostgreSQL holds
#   * derived calculations and aggregates (owner decisions) compute the
#     expected values from the loaded data: counts without deleted IDs, a
#     count over a derived has_many, a field derived from a related record
#   * many_to_many relationships through join tables (cut 3) load the
#     members whose records exist

for repo <- Application.fetch_env!(:ash_compile_check, :ecto_repos),
    not match?({:error, {:already_started, _}}, repo.start_link()),
    do: :ok

defmodule LoadedCheck do
  def normalize(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  def normalize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()
  def normalize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), normalize(v)} end)
  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  def normalize(v), do: v
end

%{"domains" => domains, "checks" => checks} = "loaded.json" |> File.read!() |> Jason.decode!()

read =
  for namespace <- domains, resource <- Ash.Domain.Info.resources(Module.concat([namespace])) do
    records = Ash.read!(resource, authorize?: false)
    repo = AshPostgres.DataLayer.Info.repo(resource)
    table = AshPostgres.DataLayer.Info.table(resource)
    %{rows: [[count]]} = repo.query!("SELECT count(*) FROM \"#{table}\"", [])

    if length(records) != count,
      do: raise("loaded check: #{inspect(resource)} reads #{length(records)} of #{count} rows")

    length(records)
  end

for check <- checks do
  resource = Module.concat([check["resource"]])
  fields = Map.keys(check["expect"])

  loads =
    Enum.filter(fields, fn f ->
      name = String.to_existing_atom(f)
      Ash.Resource.Info.calculation(resource, name) || Ash.Resource.Info.aggregate(resource, name)
    end)
    |> Enum.map(&String.to_existing_atom/1)

  rels = Map.get(check, "relationships", %{})
  loads = loads ++ Enum.map(Map.keys(rels), &String.to_existing_atom/1)
  record = Ash.get!(resource, check["id"], load: loads, authorize?: false)

  for {rel, expected} <- rels do
    related = Map.fetch!(record, String.to_existing_atom(rel))
    [pk] = Ash.Resource.Info.primary_key(Ash.Resource.Info.relationship(resource, String.to_existing_atom(rel)).destination)
    actual = related |> Enum.map(&Map.fetch!(&1, pk)) |> Enum.sort()

    if actual != expected,
      do: raise("loaded check: #{inspect(resource)} #{check["id"]}.#{rel}: expected #{inspect(expected)}, got #{inspect(actual)}")
  end

  for {field, expected} <- check["expect"] do
    actual = record |> Map.get(String.to_existing_atom(field)) |> LoadedCheck.normalize()

    if actual != expected,
      do:
        raise(
          "loaded check: #{inspect(resource)} #{check["id"]}.#{field}: " <>
            "expected #{inspect(expected)}, got #{inspect(actual)}"
        )
  end
end

IO.puts(
  "loaded check passed: #{Enum.sum(read)} records read back through Ash, " <>
    "#{length(checks)} records' derived values computed from the loaded data"
)
