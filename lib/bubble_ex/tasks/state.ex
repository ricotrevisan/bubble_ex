defmodule BubbleEx.Tasks.State do
  @moduledoc """
  The owner-repository state of one plan task (WTF-375), stored as
  `.wtf/tasks/<task id, percent-encoded>.json` next to `.wtf/plan.json`:

  ```json
  {
    "format": "bubble_ex.task_state",
    "schema_version": 1,
    "task": "surface:page/bUwyg1",
    "status": "done",
    "claim": null,
    "agents": ["agent-a"],
    "completed_by": "agent-a",
    "completed_at": "2026-09-26T10:00:00Z",
    "basis": {"plan_sha256": "…", "source_sha256": "…"},
    "evidence": [
      {"criterion": 2, "check": "compiles", "status": "pass",
       "binding": "mix compile --warnings-as-errors", "detail": null, "refs": []}
    ],
    "review": null,
    "notes": [],
    "reverify": null,
    "mode": "advisory"
  }
  ```

    * `status` - `open`, `done`, `needs_reverify` (was done; the plan
      changed under it or an audit failed: see `reverify`) or `removed`
      (its task left the plan; the record is kept for history)
    * `claim` - `{agent, claimed_at, expires_at}` while an agent works on
      it; expired claims are ignored
    * `agents` - every agent that claimed or completed it: its
      implementers, whom an independent reviewer may not be
    * `basis` - the plan and the task's `source_sha256` it was verified
      against
    * `evidence` - one entry per criterion from the last completion:
      its binding, outcome and the evidence files (`refs`: repository
      path and SHA-256; never file contents or command output)
    * `review` - `{reviewer, at, summary, basis}`: the independent
      review; `basis` pins the task's `source_sha256` and the evidence
      (`evidence_sha256/1`) of what it reviewed (`of`), so a review of
      other code or evidence no longer counts. Sync and audit drop it when
      they flip the task
    * `mode` - always `advisory`: the verdict is the implementing agent's
      own claim (`BubbleEx.Tasks`, "Threat model"; trusted verification
      is WTF-411)
    * `notes` - `{n, kind, text, by, at, resolved_by, resolved_at}`; kind
      `needs_decision` blocks the task until resolved, `info` does not
    * `reverify` - why it needs re-verifying: `{source, at, plan_sha256,
      reasons, via, changes, failed}`

  One file per task keeps concurrent agents out of each other's way in
  git; the JSON is canonical and pretty-printed (sorted keys, one member
  per line), so the same state gives the same bytes.
  """

  alias BubbleEx.{CanonicalJson, Error}

  @format "bubble_ex.task_state"
  @schema_version 1
  @statuses ~w(open done needs_reverify removed)a
  @note_kinds ~w(needs_decision info)a
  @members ~w(format schema_version task status claim agents completed_by completed_at basis
              evidence review notes reverify mode)
  @modes [:advisory]

  defstruct [
    :task,
    :claim,
    :completed_by,
    :completed_at,
    :basis,
    :review,
    :reverify,
    :mode,
    status: :open,
    agents: [],
    evidence: [],
    notes: []
  ]

  @type claim :: %{agent: String.t(), claimed_at: DateTime.t(), expires_at: DateTime.t()}
  @type note :: %{
          n: pos_integer(),
          kind: :needs_decision | :info,
          text: String.t(),
          by: String.t(),
          at: DateTime.t(),
          resolved_by: String.t() | nil,
          resolved_at: DateTime.t() | nil
        }
  @type t :: %__MODULE__{
          task: String.t(),
          status: :open | :done | :needs_reverify | :removed,
          claim: claim() | nil,
          agents: [String.t()],
          completed_by: String.t() | nil,
          completed_at: DateTime.t() | nil,
          basis: %{plan_sha256: String.t(), source_sha256: String.t() | nil} | nil,
          evidence: [map()],
          review:
            %{reviewer: String.t(), at: DateTime.t(), summary: String.t(), basis: map()} | nil,
          mode: :advisory | nil,
          notes: [note()],
          reverify: map() | nil
        }

  @doc "A fresh (open) state for `task`."
  @spec new(String.t()) :: t()
  def new(task) when is_binary(task), do: %__MODULE__{task: task}

  @doc "The state file's path, relative to the repository root."
  @spec path(String.t()) :: String.t()
  def path(task), do: Path.join(".wtf/tasks", filename(task))

  @doc """
  The file name of a task's state: its ID percent-encoded (everything but
  `A-Z a-z 0-9 - . _ ~`), plus `.json`. Reversible and safe on every file
  system: `surface:page/bUwyg1` is `surface%3Apage%2FbUwyg1.json`.
  """
  @spec filename(String.t()) :: String.t()
  def filename(task), do: URI.encode(task, &URI.char_unreserved?/1) <> ".json"

  @doc "Whether the claim is held (by anyone) at `now`."
  @spec claimed?(t(), DateTime.t()) :: boolean()
  def claimed?(%__MODULE__{claim: nil}, _now), do: false

  def claimed?(%__MODULE__{claim: %{expires_at: expires}}, now),
    do: DateTime.compare(expires, now) == :gt

  @doc "The unresolved `needs_decision` notes."
  @spec open_decisions(t()) :: [note()]
  def open_decisions(%__MODULE__{notes: notes}),
    do: Enum.filter(notes, &(&1.kind == :needs_decision and is_nil(&1.resolved_at)))

  @doc "SHA-256 of a state's evidence (what a review of it pins)."
  @spec evidence_sha256(t()) :: String.t()
  def evidence_sha256(%__MODULE__{evidence: evidence}),
    do: evidence |> json() |> CanonicalJson.sha256()

  @doc "Whether an unresolved `needs_decision` note blocks the task."
  @spec blocked?(t()) :: boolean()
  def blocked?(state), do: open_decisions(state) != []

  # --- JSON -------------------------------------------------------------------------

  @doc "JSON form: string keys, timestamps as ISO 8601."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = s) do
    %{
      "format" => @format,
      "schema_version" => @schema_version,
      "task" => s.task,
      "status" => s.status,
      "claim" => s.claim,
      "agents" => s.agents,
      "completed_by" => s.completed_by,
      "completed_at" => s.completed_at,
      "basis" => s.basis,
      "evidence" => s.evidence,
      "review" => s.review,
      "notes" => s.notes,
      "reverify" => s.reverify,
      "mode" => s.mode
    }
    |> json()
  end

  @doc "Canonical, pretty-printed JSON text (with a final newline)."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = s),
    do: (s |> to_map() |> CanonicalJson.ordered() |> Jason.encode!(pretty: true)) <> "\n"

  @doc "Decodes and validates a state (JSON text or decoded map)."
  @spec decode(String.t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> decode(map)
      {:error, _} -> error("a task state is not JSON")
    end
  end

  def decode(%{"format" => @format, "schema_version" => @schema_version} = m) do
    with :ok <- members(m),
         {:ok, task} <- string(m["task"], "task"),
         {:ok, status} <- enum(m["status"], @statuses, "status"),
         {:ok, claim} <- claim(m["claim"]),
         {:ok, agents} <- strings(m["agents"], "agents"),
         {:ok, completed_by} <- optional(m["completed_by"], &string(&1, "completed_by")),
         {:ok, completed_at} <- optional(m["completed_at"], &time(&1, "completed_at")),
         {:ok, basis} <- optional(m["basis"], &basis/1),
         {:ok, evidence} <- list(m["evidence"], "evidence", &object(&1, "evidence")),
         {:ok, review} <- optional(m["review"], &review/1),
         {:ok, notes} <- list(m["notes"], "notes", &note/1),
         {:ok, reverify} <- optional(m["reverify"], &object(&1, "reverify")),
         {:ok, mode} <- optional(m["mode"], &enum(&1, @modes, "mode")) do
      {:ok,
       %__MODULE__{
         task: task,
         status: status,
         claim: claim,
         agents: agents,
         completed_by: completed_by,
         completed_at: completed_at,
         basis: basis,
         evidence: evidence,
         review: review,
         notes: notes,
         reverify: reverify,
         mode: mode
       }}
    end
  end

  def decode(%{"format" => @format, "schema_version" => v}),
    do: error("unsupported task state schema_version #{inspect(v)}")

  def decode(_), do: error("not a task state")

  defp members(m) do
    case Map.keys(m) -- @members do
      [] -> :ok
      extra -> error("a task state has unknown members", %{members: Enum.sort(extra)})
    end
  end

  defp claim(nil), do: {:ok, nil}

  defp claim(%{"agent" => agent, "claimed_at" => at, "expires_at" => expires}) do
    with {:ok, agent} <- string(agent, "claim.agent"),
         {:ok, at} <- time(at, "claim.claimed_at"),
         {:ok, expires} <- time(expires, "claim.expires_at"),
         do: {:ok, %{agent: agent, claimed_at: at, expires_at: expires}}
  end

  defp claim(_), do: error("a claim must be {agent, claimed_at, expires_at}")

  defp basis(%{"plan_sha256" => plan, "source_sha256" => source})
       when is_binary(plan) and (is_binary(source) or is_nil(source)),
       do: {:ok, %{plan_sha256: plan, source_sha256: source}}

  defp basis(_), do: error("basis must be {plan_sha256, source_sha256}")

  defp review(%{"reviewer" => r, "at" => at, "summary" => summary, "basis" => basis})
       when is_map(basis) do
    with {:ok, r} <- string(r, "review.reviewer"),
         {:ok, at} <- time(at, "review.at"),
         {:ok, summary} <- string(summary, "review.summary"),
         do: {:ok, %{reviewer: r, at: at, summary: summary, basis: basis}}
  end

  defp review(_), do: error("a review must be {reviewer, at, summary, basis}")

  defp note(%{"n" => n, "kind" => kind, "text" => text, "by" => by, "at" => at} = m)
       when is_integer(n) and n > 0 do
    with {:ok, kind} <- enum(kind, @note_kinds, "note kind"),
         {:ok, text} <- string(text, "note.text"),
         {:ok, by} <- string(by, "note.by"),
         {:ok, at} <- time(at, "note.at"),
         {:ok, resolved_by} <- optional(m["resolved_by"], &string(&1, "note.resolved_by")),
         {:ok, resolved_at} <- optional(m["resolved_at"], &time(&1, "note.resolved_at")) do
      {:ok,
       %{
         n: n,
         kind: kind,
         text: text,
         by: by,
         at: at,
         resolved_by: resolved_by,
         resolved_at: resolved_at
       }}
    end
  end

  defp note(_), do: error("a note must be {n, kind, text, by, at}")

  # Evidence and reverify entries keep their JSON form (string keys).
  defp object(m, _name) when is_map(m), do: {:ok, m}
  defp object(_, name), do: error("#{name} entries must be objects")

  defp optional(nil, _fun), do: {:ok, nil}
  defp optional(value, fun), do: fun.(value)

  defp string(s, _name) when is_binary(s) and s != "", do: {:ok, s}
  defp string(_, name), do: error("#{name} must be a non-empty string")

  defp strings(list, name) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: {:ok, list},
      else: error("#{name} must be a list of strings")
  end

  defp strings(_, name), do: error("#{name} must be a list of strings")

  defp list(list, _name, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp list(_, name, _fun), do: error("#{name} must be a list")

  defp time(value, name) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> {:ok, dt}
      _ -> error("#{name} must be an ISO 8601 UTC timestamp")
    end
  end

  defp time(_, name), do: error("#{name} must be an ISO 8601 UTC timestamp")

  defp enum(value, allowed, name) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> error("unknown #{name}", %{value: value})
      atom -> {:ok, atom}
    end
  end

  defp enum(value, _allowed, name), do: error("unknown #{name}", %{value: value})

  @doc false
  def json(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  def json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)
  def json(list) when is_list(list), do: Enum.map(list, &json/1)
  def json(value) when value in [true, false, nil], do: value
  def json(atom) when is_atom(atom), do: Atom.to_string(atom)
  def json(value), do: value

  defp error(message, context \\ %{}), do: {:error, Error.new(:invalid_input, message, context)}
end
