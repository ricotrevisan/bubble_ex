defmodule BubbleEx.Verify.Scenario do
  @moduledoc """
  A stack-neutral scenario: a persona runs ops against a seed set, and the
  oracles record what the scenario says to observe (WTF-358 §3.1). Stored
  as `.wtf/verification/scenarios/<kind>/<id>.json` in the owner repo.

  ```json
  {
    "format": "bubble_ex.verify.scenario",
    "schema_version": 1,
    "id": "privacy_read.custom.task.w2_member",
    "kind": "privacy_read",
    "check": "privacy_read",
    "seed": {"id": "privacy_matrix", "sha256": "…"},
    "persona": "w2_member",
    "subjects": {"type": "custom.task"},
    "ops": [
      {"id": "o1", "op": "search", "type": "custom.task", "observe": ["record_set"]},
      {"id": "o2", "op": "get", "type": "custom.task", "record": "task_w1",
       "observe": ["visible", "visible_fields"]}
    ],
    "masks": [],
    "covers": {"findings": [], "rules": ["custom.task/ab_"], "tasks": ["generate:policies"]},
    "source_sha256": "…"
  }
  ```

    * `kind` - `privacy_read`, `workflow`, `api_workflow`, `page` or
      `journey`; it limits the ops (below)
    * `check` - the `BubbleEx.Verify.Check` whose results the scenario feeds
    * `seed` - the seed set's ID and `BubbleEx.Verify.Seed.sha256/1`
    * `persona` - a persona of the seed; an op may name another (journeys)
    * `subjects` - Bubble IDs (`BubbleEx.Verify.Check.subject_keys/0`)
    * `ops` - unique `id`s, run in order; each lists what to `observe`
      (`BubbleEx.Verify.Observation` kinds its op allows)
    * `masks` - `BubbleEx.Verify.Mask`s known in advance
    * `covers` - plan task IDs, privacy rule refs and finding IDs it
      exercises (sorted sets)
    * `source_sha256` - hash of the index subgraph the scenario touches
      (computed by synthesis; the scenario is stale when it changes)

  | op | members | observes |
  |----|---------|----------|
  | `get` | `type`, `record` | `visible`, `visible_fields`, `values` |
  | `search` | `type`, `sort` (optional `{"field", "descending"}`) | `record_set` |
  | `call_api_workflow` | `workflow`, `auth` (`none`/`persona`/`admin`), `params` | `status`, `response`, `db_diff`, `step_trace` |
  | `trigger` | `workflow`, `params` | `db_diff`, `step_trace` |
  | `visit` | `page`, `params` | `dom_text`, `db_diff` |
  | `click` | `element` | `dom_text`, `db_diff` |
  | `input` | `element`, `value` | `dom_text`, `db_diff` |

  Every op may also name a `persona`. `params` map names to
  `BubbleEx.Verify.Value`s.

  | kind | ops |
  |------|-----|
  | `privacy_read` | `get`, `search` |
  | `workflow` | `trigger`, `get`, `search` |
  | `api_workflow` | `call_api_workflow`, `get`, `search` |
  | `page` | `visit`, `click`, `input` |
  | `journey` | any |

  `sha256/1` hashes the whole scenario, masks and subjects included: a new
  mask (which can hide a difference) makes every recording and result made
  before it stale.
  """

  alias BubbleEx.{CanonicalJson, Error}
  alias BubbleEx.Verify.{Check, Json, Mask, Seed, Value}

  @format "bubble_ex.verify.scenario"
  @schema_version 1
  @members ~w(format schema_version id kind check seed persona subjects ops masks covers source_sha256)
  @required ~w(format schema_version id kind check seed persona ops source_sha256)

  @kinds [:privacy_read, :workflow, :api_workflow, :page, :journey]
  @ops %{
    get: {~w(type record), [:visible, :visible_fields, :values]},
    search: {~w(type sort), [:record_set]},
    call_api_workflow: {~w(workflow auth params), [:status, :response, :db_diff, :step_trace]},
    trigger: {~w(workflow params), [:db_diff, :step_trace]},
    visit: {~w(page params), [:dom_text, :db_diff]},
    click: {~w(element), [:dom_text, :db_diff]},
    input: {~w(element value), [:dom_text, :db_diff]}
  }
  @op_required %{
    get: ~w(type record),
    search: ~w(type),
    call_api_workflow: ~w(workflow auth),
    trigger: ~w(workflow),
    visit: ~w(page),
    click: ~w(element),
    input: ~w(element value)
  }
  @kind_ops %{
    privacy_read: [:get, :search],
    workflow: [:trigger, :get, :search],
    api_workflow: [:call_api_workflow, :get, :search],
    page: [:visit, :click, :input],
    journey: [:get, :search, :call_api_workflow, :trigger, :visit, :click, :input]
  }
  @auths [:none, :persona, :admin]
  @covers ~w(findings rules tasks)

  @type kind :: :privacy_read | :workflow | :api_workflow | :page | :journey
  @type op :: %{
          required(:id) => String.t(),
          required(:op) => atom(),
          required(:observe) => [atom()],
          optional(atom()) => term()
        }
  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          check: String.t(),
          seed: %{id: String.t(), sha256: String.t()},
          persona: String.t(),
          subjects: %{atom() => String.t()},
          ops: [op()],
          masks: [Mask.t()],
          covers: %{findings: [String.t()], rules: [String.t()], tasks: [String.t()]},
          source_sha256: String.t()
        }

  @enforce_keys [:id, :kind, :check, :seed, :persona, :source_sha256]
  defstruct [
    :id,
    :kind,
    :check,
    :seed,
    :persona,
    :source_sha256,
    subjects: %{},
    ops: [],
    masks: [],
    covers: %{findings: [], rules: [], tasks: []}
  ]

  @doc "The `format` member."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The JSON format version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "The scenario kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The observation kinds op `op` allows."
  @spec observable(atom()) :: [atom()]
  def observable(op), do: @ops |> Map.fetch!(op) |> elem(1)

  @doc "Builds and validates a scenario from atom-keyed attributes (as `from_map/1`)."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    attrs = Map.new(attrs)

    __MODULE__
    |> struct(Map.merge(%{subjects: %{}, ops: [], masks: [], covers: %{}}, attrs))
    |> Map.update!(:covers, &Map.merge(%{findings: [], rules: [], tasks: []}, &1))
    |> to_map()
    |> from_map()
  end

  @doc "Decodes and validates the JSON form."
  @spec from_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) do
    with :ok <- Json.envelope(map, @format, @schema_version, @members, @required, "scenario"),
         {:ok, id} <- Json.symbol(map["id"], "scenario id"),
         {:ok, kind} <- Json.enum(map["kind"], @kinds, "scenario kind"),
         {:ok, {check, class}} <- check(map["check"]),
         {:ok, seed} <- seed_ref(map["seed"]),
         {:ok, persona} <- Json.symbol(map["persona"], "scenario persona"),
         {:ok, subjects} <- Check.subjects(Map.get(map, "subjects") || %{}),
         {:ok, ops} <- Json.list(map["ops"], "scenario ops", &op/1),
         :ok <- ops_fit(kind, ops),
         {:ok, masks} <-
           Json.list(Map.get(map, "masks") || [], "scenario masks", &Mask.from_map/1),
         :ok <- masks_fit(masks, ops),
         :ok <- Mask.check_class(masks, class),
         {:ok, covers} <- covers(Map.get(map, "covers") || %{}),
         {:ok, source} <- Json.sha256(map["source_sha256"], "scenario source_sha256") do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         check: check,
         seed: seed,
         persona: persona,
         subjects: subjects,
         ops: ops,
         masks: Mask.sort(masks),
         covers: covers,
         source_sha256: source
       }}
    end
  end

  defp check(name) do
    with {:ok, {_level, class}} <- Check.fetch(name), do: {:ok, {name, class}}
  end

  defp seed_ref(map) do
    with :ok <- Json.members(map, ~w(id sha256), ~w(id sha256), "scenario seed"),
         {:ok, id} <- Json.symbol(map["id"], "scenario seed id"),
         {:ok, sha} <- Json.sha256(map["sha256"], "scenario seed sha256") do
      {:ok, %{id: id, sha256: sha}}
    end
  end

  defp op(map) when is_map(map) do
    with {:ok, name} <- Json.enum(map["op"], Map.keys(@ops) |> Enum.sort(), "op"),
         {members, observable} = Map.fetch!(@ops, name),
         :ok <-
           Json.members(
             map,
             ~w(id op observe persona) ++ members,
             ~w(id op observe) ++ @op_required[name],
             "#{name} op"
           ),
         {:ok, id} <- Json.symbol(map["id"], "op id"),
         {:ok, persona} <- optional_symbol(map["persona"], "op persona"),
         {:ok, observe} <- observe(map["observe"], observable, name),
         {:ok, fields} <- op_fields(name, map) do
      {:ok, Map.merge(%{id: id, op: name, observe: observe, persona: persona}, fields)}
    end
  end

  defp op(other), do: Json.error("an op must be an object", %{value: other})

  defp observe(kinds, observable, name) do
    with {:ok, list} <- Json.string_set(kinds, "op observe") do
      Json.list(list, "op observe", &observable(&1, observable, name))
    end
  end

  defp observable(kind, observable, name) do
    case Enum.find(observable, &(Atom.to_string(&1) == kind)) do
      nil -> Json.error("a #{name} op cannot observe #{kind}", %{allowed: observable})
      atom -> {:ok, atom}
    end
  end

  defp op_fields(:get, m) do
    with {:ok, type} <- Json.string(m["type"], "get type"),
         {:ok, record} <- Json.symbol(m["record"], "get record"),
         do: {:ok, %{type: type, record: record}}
  end

  defp op_fields(:search, m) do
    with {:ok, type} <- Json.string(m["type"], "search type"),
         {:ok, sort} <- sort(m["sort"]),
         do: {:ok, %{type: type, sort: sort}}
  end

  defp op_fields(:call_api_workflow, m) do
    with {:ok, workflow} <- Json.string(m["workflow"], "call_api_workflow workflow"),
         {:ok, auth} <- Json.enum(m["auth"], @auths, "call_api_workflow auth"),
         {:ok, params} <- params(m["params"]),
         do: {:ok, %{workflow: workflow, auth: auth, params: params}}
  end

  defp op_fields(:trigger, m) do
    with {:ok, workflow} <- Json.string(m["workflow"], "trigger workflow"),
         {:ok, params} <- params(m["params"]),
         do: {:ok, %{workflow: workflow, params: params}}
  end

  defp op_fields(:visit, m) do
    with {:ok, page} <- Json.string(m["page"], "visit page"),
         {:ok, params} <- params(m["params"]),
         do: {:ok, %{page: page, params: params}}
  end

  defp op_fields(:click, m) do
    with {:ok, element} <- Json.string(m["element"], "click element"),
         do: {:ok, %{element: element}}
  end

  defp op_fields(:input, m) do
    with {:ok, element} <- Json.string(m["element"], "input element"),
         {:ok, value} <- Value.cast(m["value"]),
         do: {:ok, %{element: element, value: value}}
  end

  defp sort(nil), do: {:ok, nil}

  defp sort(map) do
    with :ok <- Json.members(map, ~w(field descending), ~w(field descending), "search sort"),
         {:ok, field} <- Json.string(map["field"], "sort field"),
         {:ok, desc} <- Json.boolean(map["descending"], "sort descending"),
         do: {:ok, %{field: field, descending: desc}}
  end

  defp params(nil), do: {:ok, %{}}
  defp params(map), do: Json.object(map, "params", &Value.cast/1)

  defp optional_symbol(nil, _), do: {:ok, nil}
  defp optional_symbol(value, name), do: Json.symbol(value, name)

  defp ops_fit(kind, ops) do
    allowed = @kind_ops[kind]

    cond do
      ops == [] ->
        Json.error("a scenario needs at least one op")

      (bad = Enum.reject(ops, &(&1.op in allowed))) != [] ->
        Json.error("a #{kind} scenario cannot run these ops", %{
          ops: Enum.map(bad, & &1.id),
          allowed: allowed
        })

      true ->
        Json.unique(ops, & &1.id, "op ids")
    end
  end

  defp masks_fit(masks, ops) do
    by_id = Map.new(ops, &{&1.id, &1})

    with {:ok, _} <- Json.list(masks, "scenario masks", &mask_fits(&1, by_id)), do: :ok
  end

  defp mask_fits(mask, by_id) do
    case Map.fetch(by_id, mask.op) do
      {:ok, op} -> if mask.kind in op.observe, do: {:ok, op}, else: mask_error(mask)
      :error -> Json.error("mask names an unknown op", %{op: mask.op})
    end
  end

  defp mask_error(mask),
    do: Json.error("mask covers an observation its op does not make", %{op: mask.op})

  defp covers(map) do
    with :ok <- Json.members(map, @covers, [], "scenario covers"),
         {:ok, findings} <- Json.string_set(Map.get(map, "findings", []), "covers findings"),
         {:ok, rules} <- Json.string_set(Map.get(map, "rules", []), "covers rules"),
         {:ok, tasks} <- Json.string_set(Map.get(map, "tasks", []), "covers tasks") do
      {:ok, %{findings: findings, rules: rules, tasks: tasks}}
    end
  end

  @doc "JSON form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = s) do
    s
    |> identity()
    |> Map.merge(%{
      "subjects" => Json.json(s.subjects),
      "masks" => s.masks |> Mask.sort() |> Enum.map(&Mask.to_map/1),
      "covers" => Json.json(s.covers)
    })
  end

  defp identity(%__MODULE__{} = s) do
    %{
      "format" => @format,
      "schema_version" => @schema_version,
      "id" => s.id,
      "kind" => Json.json(s.kind),
      "check" => s.check,
      "seed" => Json.json(s.seed),
      "persona" => s.persona,
      "ops" => Enum.map(s.ops, &op_json/1),
      "source_sha256" => s.source_sha256
    }
  end

  defp op_json(op) do
    op
    |> Enum.reject(fn {k, v} -> k == :persona and is_nil(v) end)
    |> Map.new(fn
      {:params, params} -> {"params", Map.new(params, fn {k, v} -> {k, Value.to_json(v)} end)}
      {:value, value} -> {"value", Value.to_json(value)}
      {:observe, kinds} -> {"observe", kinds |> Enum.map(&Atom.to_string/1) |> Enum.sort()}
      {k, v} -> {Atom.to_string(k), Json.json(v)}
    end)
  end

  @doc "Canonical JSON text."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = s), do: s |> to_map() |> Json.encode()

  @doc "Decodes JSON text (see `from_map/1`)."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(text), do: Json.from_json(text, "scenario", &from_map/1)

  @doc """
  SHA-256 of the canonical JSON (every member, masks included). Recordings
  and results pin it (`scenario.sha256`), and a parity exception's
  `basis.scenario_sha256` is this hash.
  """
  @spec sha256(t()) :: String.t()
  def sha256(%__MODULE__{} = s), do: s |> to_map() |> CanonicalJson.sha256()

  @doc """
  Checks the scenario against its seed set: the seed ID and hash match,
  every persona exists, and every record an op names (`get` records, `ref`
  values in params and inputs) is a seed record.
  """
  @spec check_seed(t(), Seed.t()) :: :ok | {:error, Error.t()}
  def check_seed(%__MODULE__{} = s, %Seed{} = seed) do
    keys = MapSet.new(seed.records, & &1.key)

    personas =
      [s.persona | Enum.map(s.ops, & &1.persona)] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    records =
      Enum.flat_map(s.ops, fn op ->
        [Map.get(op, :record)] ++
          Enum.flat_map(Map.get(op, :params, %{}), fn {_, v} -> Value.refs(v) end) ++
          Value.refs(Map.get(op, :value))
      end)
      |> Enum.reject(&is_nil/1)

    cond do
      s.seed.id != seed.id ->
        Json.error("scenario is for another seed set", %{seed: s.seed.id, given: seed.id})

      s.seed.sha256 != Seed.sha256(seed) ->
        Json.error("seed set changed since the scenario was made", %{seed: seed.id})

      (missing = Enum.reject(personas, &Map.has_key?(seed.personas, &1))) != [] ->
        Json.error("scenario personas are not in the seed", %{personas: missing})

      (missing = Enum.reject(records, &MapSet.member?(keys, &1))) != [] ->
        Json.error("scenario records are not in the seed", %{records: Enum.uniq(missing)})

      true ->
        :ok
    end
  end

  @doc "The op with `id`, or nil."
  @spec op(t(), String.t()) :: op() | nil
  def op(%__MODULE__{ops: ops}, id), do: Enum.find(ops, &(&1.id == id))
end
