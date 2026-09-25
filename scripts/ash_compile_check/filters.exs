# Static check of the compiled privacy-rule filters (run by
# scripts/ash_compile_check.sh in the scratch project; no database): for
# every `<namespace>.PrivacyFilters` entry, fills the `^actor(...)`
# templates with a logged-out actor (nil) and with a sample actor whose
# `actor_loads` relationships are loaded, builds the query and translates
# it to an AshPostgres (Ecto) query. Every reference, relationship path,
# operator and function must resolve against the generated resources.

defmodule FiltersCheck do
  require Ash.Query

  def run do
    entries =
      for domain <- Application.fetch_env!(:ash_compile_check, :ash_domains),
          module = Module.concat(domain, PrivacyFilters),
          Code.ensure_loaded?(module),
          entry <- module.all(),
          do: entry

    failures =
      for entry <- entries,
          actor <- [nil, sample_actor(entry.actor, entry.actor_loads)],
          failure <- check(entry, actor),
          do: failure

    if failures != [] do
      Enum.each(failures, &IO.puts/1)
      raise "privacy filter check failed: #{length(failures)} failures"
    end

    IO.puts("privacy filter check passed: #{length(entries)} filters, 2 actors each")
  end

  defp check(entry, actor) do
    filled = Ash.Expr.fill_template(entry.filter, actor: actor)
    query = Ash.Query.filter(entry.resource, ^filled)

    case Ash.Query.data_layer_query(query) do
      {:ok, _ecto_query} -> []
      {:error, error} -> ["#{entry.type}/#{entry.rule} (actor #{inspect(actor && actor.id)}): #{Exception.message(error)}"]
    end
  rescue
    error -> ["#{entry.type}/#{entry.rule}: #{Exception.message(error)}"]
  end

  # A record of `resource` with the given relationships loaded (as records
  # with every attribute nil).
  def sample_actor(resource, loads) do
    Enum.reduce(loads, struct(resource, id: "actor"), fn {name, nested}, acc ->
      destination = Ash.Resource.Info.relationship(resource, name).destination
      Map.put(acc, name, sample_actor(destination, nested))
    end)
  end
end

FiltersCheck.run()
