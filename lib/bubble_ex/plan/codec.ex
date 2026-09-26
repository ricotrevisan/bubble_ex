defmodule BubbleEx.Plan.Codec do
  @moduledoc """
  Reads `.wtf/plan.json` back into a `BubbleEx.Plan` (`BubbleEx.Plan.decode/1`),
  checking its schema, so a tool in the owner's repository (`mix wtf.task`)
  works from a plan it can trust:

    * `schema_version` must be `BubbleEx.Plan.schema_version/0` (an older
      plan is rebuilt, not migrated)
    * `plan_sha256` must be the SHA-256 of the rest of the plan: a
      hand-edited or truncated plan is refused
    * every task has a unique `id`, a known `kind`, `actor` and `status`,
      dependencies of a known kind on tasks of the plan, a `parent` in the
      plan, criteria with a known check (`BubbleEx.Plan.Criteria`) and
      waiver, and residue with a known reason

  The enumerations of a task (`kind`, `actor`, `status`, a dependency's
  `kind`, a criterion's `check` and `waiver`, a residue entry's `reason`)
  become atoms from closed lists; free-form maps (`inputs`, `coverage`,
  `symbols`, `skipped`, criterion `args`, residue `detail`) keep their
  JSON form (string keys). `BubbleEx.Plan.to_json/1` of a decoded plan
  gives back the same bytes.
  """

  alias BubbleEx.{CanonicalJson, Error, Plan}
  alias BubbleEx.Plan.{Criteria, Residue, Task}

  @kinds ~w(generate remove_writes delete_workflows setup_secrets auth styles_residue decision
            plugin surface fragment workflow backend cycle api_group api_call acceptance data
            replay delivery cutover)a
  @actors ~w(generator agent reviewer owner loader harness)a
  @statuses ~w(auto open closed)a
  @edge_kinds ~w(generate early secrets decision reusable fragment acceptance plugin api calls
                 coordinate release)a
  @waivers ~w(forbidden allowed)a
  @members ~w(schema_version plan_sha256 inputs tasks skipped coverage symbols)

  @doc "The task kinds a plan may hold."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "See `BubbleEx.Plan.decode/1`."
  @spec decode(String.t() | map()) :: {:ok, Plan.t()} | {:error, Error.t()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> decode(map)
      {:error, _} -> error("the plan is not JSON")
    end
  end

  def decode(%{"schema_version" => version} = map) do
    cond do
      version != Plan.schema_version() ->
        error(
          "the plan has schema_version #{inspect(version)}; rebuild it with schema_version " <>
            "#{Plan.schema_version()}"
        )

      (extra = Map.keys(map) -- @members) != [] ->
        error("the plan has unknown members", %{members: Enum.sort(extra)})

      not shaped?(map) ->
        error("the plan's tasks, inputs, symbols, coverage and skipped are malformed")

      map["plan_sha256"] != map |> Map.delete("plan_sha256") |> CanonicalJson.sha256() ->
        error("plan_sha256 does not match the plan: it was edited or truncated; regenerate it")

      true ->
        tasks(map)
    end
  end

  def decode(_), do: error("not a plan: no schema_version")

  defp shaped?(map) do
    is_list(map["tasks"]) and is_map(map["inputs"]) and is_map(map["symbols"]) and
      is_map(map["coverage"]) and is_list(map["skipped"])
  end

  defp tasks(map) do
    ids = for %{"id" => id} when is_binary(id) <- map["tasks"], do: id
    known = MapSet.new(ids)

    with :ok <- unique(ids),
         {:ok, tasks} <- all(map["tasks"], &task(&1, known)) do
      {:ok,
       %Plan{
         schema_version: map["schema_version"],
         plan_sha256: map["plan_sha256"],
         inputs: map["inputs"],
         tasks: tasks,
         skipped: map["skipped"],
         coverage: map["coverage"],
         symbols: map["symbols"]
       }}
    end
  end

  defp unique(ids) do
    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [dup | _] -> error("two tasks share an id", %{task: dup})
    end
  end

  defp task(%{"id" => id} = t, known) when is_binary(id) and id != "" do
    with {:ok, kind} <- enum(t["kind"], @kinds, "kind", id),
         {:ok, actor} <- enum(t["actor"], @actors, "actor", id),
         {:ok, status} <- enum(t["status"], @statuses, "status", id),
         :ok <- parent(t["parent"], known, id),
         {:ok, deps} <- all(t["depends_on"], &dependency(&1, known, id)),
         {:ok, criteria} <- all(t["criteria"], &criterion(&1, id)),
         {:ok, residue} <- all(t["residue"], &residue(&1, id)),
         :ok <- strings(t, ~w(subjects decisions), id),
         :ok <- optional_strings(t, ~w(label batch closed_by decisions_sha256 source_sha256), id),
         :ok <- order(t["order"], id) do
      {:ok,
       %Task{
         id: id,
         kind: kind,
         actor: actor,
         status: status,
         parent: t["parent"],
         subjects: t["subjects"],
         label: t["label"],
         batch: t["batch"],
         order: t["order"],
         depends_on: deps,
         decisions: t["decisions"],
         closed_by: t["closed_by"],
         residue: residue,
         criteria: criteria,
         decisions_sha256: t["decisions_sha256"],
         source_sha256: t["source_sha256"]
       }}
    end
  end

  defp task(other, _known), do: error("a task must be an object with an id", %{task: other})

  defp parent(nil, _known, _id), do: :ok

  defp parent(parent, known, id) do
    if is_binary(parent) and MapSet.member?(known, parent),
      do: :ok,
      else: error("a task's parent is not in the plan", %{task: id, parent: parent})
  end

  defp dependency(%{"task" => to, "kind" => kind, "via" => via}, known, id)
       when is_binary(to) and is_list(via) do
    with {:ok, kind} <- enum(kind, @edge_kinds, "dependency kind", id) do
      cond do
        not MapSet.member?(known, to) ->
          error("a dependency names a task that is not in the plan", %{task: id, on: to})

        not Enum.all?(via, &is_binary/1) ->
          error("a dependency's via must be symbol IDs", %{task: id})

        true ->
          {:ok, %{task: to, kind: kind, via: via}}
      end
    end
  end

  defp dependency(other, _known, id),
    do: error("a dependency must be {task, kind, via}", %{task: id, dependency: other})

  defp criterion(%{"id" => n, "check" => check, "args" => args, "waiver" => waiver}, id)
       when is_integer(n) and n > 0 and is_map(args) do
    with {:ok, check} <- enum(check, Criteria.checks(), "check", id),
         {:ok, waiver} <- enum(waiver, @waivers, "waiver", id) do
      if waiver == :allowed and check != :attested,
        do: error("only attested criteria may be waived", %{task: id, criterion: n}),
        else: {:ok, %{id: n, check: check, args: args, waiver: waiver}}
    end
  end

  defp criterion(other, id),
    do: error("a criterion must be {id, check, args, waiver}", %{task: id, criterion: other})

  defp residue(%{"subject" => s, "reason" => reason, "detail" => detail}, id)
       when is_binary(s) and is_map(detail) do
    with {:ok, reason} <- enum(reason, Residue.reasons(), "residue reason", id),
         do: {:ok, %{subject: s, reason: reason, detail: detail}}
  end

  defp residue(other, id),
    do: error("a residue entry must be {subject, reason, detail}", %{task: id, residue: other})

  defp strings(t, keys, id) do
    case Enum.find(keys, &(not (is_list(t[&1]) and Enum.all?(t[&1], fn s -> is_binary(s) end)))) do
      nil -> :ok
      key -> error("a task's #{key} must be a list of strings", %{task: id})
    end
  end

  defp optional_strings(t, keys, id) do
    case Enum.find(keys, &(not (is_nil(t[&1]) or is_binary(t[&1])))) do
      nil -> :ok
      key -> error("a task's #{key} must be a string or null", %{task: id})
    end
  end

  defp order(nil, _id), do: :ok
  defp order(n, _id) when is_integer(n) and n >= 0, do: :ok
  defp order(_, id), do: error("a task's order must be a non-negative integer", %{task: id})

  defp enum(value, allowed, name, id) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> error("unknown #{name}", %{task: id, value: value})
      atom -> {:ok, atom}
    end
  end

  defp enum(value, _allowed, name, id), do: error("unknown #{name}", %{task: id, value: value})

  defp all(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp all(other, _fun), do: error("expected a list", %{value: other})

  defp error(message, context \\ %{}), do: {:error, Error.new(:invalid_input, message, context)}
end
