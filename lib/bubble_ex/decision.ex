defmodule BubbleEx.Decision do
  @moduledoc """
  An owner's decision about a generated project, as a stack-neutral,
  versioned record (WTF-352).

  One envelope, three kinds:

  | `kind` | Key (one current record per key) | Decides |
  |--------|----------------------------------|---------|
  | `:finding` | `"finding:<finding id>"` | accept, reject or modify a `BubbleEx.Finding`'s proposal, or acknowledge that a decision no longer applies |
  | `:rename` | `"rename:<hash>"` of target, slot and subject | a target name overriding the name map |
  | `:parity_exception` | `"parity_exception:<hash>"` of scope and subject | an accepted behavioural difference with no finding |

  Fields:

    * `id` - record ID, assigned by the store (`nil` before)
    * `key` - computed by `key/1` from the kind and its identity; a
      supplied key must match
    * `revision` - 1, 2, … per key. Records are append-only: a change is a
      new revision, and the highest revision of a key is its current record
      (older ones are `:superseded`)
    * `subject` - Bubble IDs, keyed like a `BubbleEx.Finding`'s subject
    * `target` - the target stack of a `:rename` (`"ash"`), else `nil`
    * `choice` - findings: `:accept`, `:reject`, `:modify` or
      `:acknowledge` (a stale or orphaned decision was seen: stop blocking,
      keep the faithful mapping; `acknowledge/2`); renames and parity
      exceptions: `:accept` or `:withdraw` (`withdraw/2`)
    * `params` - `%{}` for accept, reject and acknowledge; for `modify`, only what
      `BubbleEx.Decision.Params` allows for the finding's transform. A
      rename's are `%{slot, name}`, a parity exception's
      `%{scope, bubble_behavior, chosen_behavior}`
    * `basis` - what the decision was made against: `finding_id`,
      `proposal_sha256` and `basis_sha256` (required for findings, see
      `BubbleEx.Finding`), and optionally `source_sha256`,
      `index_semantic_sha256`, `bubble_version`, `bubble_ex` and (parity
      exceptions) `scenario_sha256`
    * `rationale`, `author` (`%{kind: :owner | :agent | :wtf_staff, id,
      via: :chat | :form | :cli}`), `decided_at` - audit only
    * `expires_at` - optional, parity exceptions only

  Only `key`, `kind`, `subject`, `target`, `choice`, `params`,
  `expires_at` and the basis hashes decide state and what applies
  (`decisions_sha256/1`); editing a rationale never regenerates anything.

  ## JSON

  `to_map/1` / `to_json/1` and `from_map/1` / `from_json/1` are a stable,
  versioned codec (`schema_version` 1); the JSON is canonical (sorted
  keys, `BubbleEx.CanonicalJson`) and decoding is strict: unknown members,
  kinds, choices, slots and parameters are `:invalid_input`.

  ```json
  {
    "author": {"id": "user:42", "kind": "owner", "via": "form"},
    "basis": {
      "basis_sha256": "9c1f…",
      "bubble_ex": "0.9.0",
      "bubble_version": "test",
      "finding_id": "number_type:568835fc8a7c3aac",
      "proposal_sha256": "4be0…"
    },
    "choice": "modify",
    "decided_at": "2026-09-25T14:02:11Z",
    "expires_at": null,
    "id": "dec_01J8",
    "key": "finding:number_type:568835fc8a7c3aac",
    "kind": "finding",
    "params": {"to": "decimal"},
    "rationale": "Points can be fractional.",
    "revision": 2,
    "schema_version": 1,
    "subject": {"field": "points_number", "type": "task"},
    "target": null
  }
  ```

  ## Lifecycle

  `resolve/3` computes each record's state against the current findings
  (see `BubbleEx.Decision.Resolved`), `applicable/2` lists what generation
  may apply, and `decisions_sha256/1` hashes the generation inputs.
  """

  alias BubbleEx.{CanonicalJson, Error, Finding, Index}
  alias BubbleEx.Decision.{Applied, Params, Resolved}
  alias BubbleEx.Finding.Kinds
  alias BubbleEx.Index.Subject

  @schema_version 1

  @kinds [:finding, :rename, :parity_exception]
  @choices [:accept, :reject, :modify, :acknowledge, :withdraw]
  @kind_choices %{
    finding: [:accept, :reject, :modify, :acknowledge],
    rename: [:accept, :withdraw],
    parity_exception: [:accept, :withdraw]
  }
  @author_kinds [:owner, :agent, :wtf_staff]
  @vias [:chat, :form, :cli]
  @targets ["ash"]
  @subject_keys [:type, :option_set, :external_type, :field, :rule, :workflow]
  @basis_keys [
    :finding_id,
    :proposal_sha256,
    :basis_sha256,
    :source_sha256,
    :index_semantic_sha256,
    :bubble_version,
    :bubble_ex,
    :scenario_sha256
  ]
  @finding_basis [:finding_id, :proposal_sha256, :basis_sha256]

  # Top-level module names a rename may not take: Elixir's own modules and
  # the namespaces of the target's libraries.
  @reserved_modules for mod <- elem(:application.get_key(:elixir, :modules), 1),
                        "Elixir." <> name <- [Atom.to_string(mod)],
                        into: MapSet.new(~w(Elixir Erlang Ash AshPostgres Ecto Phoenix Spark)),
                        do: name |> String.split(".") |> hd()

  # Rename slots and the subject shapes (sorted subject keys) each names.
  @slots %{
    module: [[:type], [:external_type]],
    table: [[:type]],
    attribute: [[:field, :type], [:field, :option_set]],
    relationship: [[:field, :type]],
    calculation: [[:field, :type]],
    enum_module: [[:option_set]],
    endpoint_path: [[:workflow]]
  }
  @parity_params [:scope, :bubble_behavior, :chosen_behavior]

  @members ~w(schema_version id key kind revision subject target choice params basis
              rationale author decided_at expires_at)
  @required ~w(schema_version kind revision subject choice)
  @attrs Enum.map(@members, &String.to_atom/1)

  @type kind :: :finding | :rename | :parity_exception
  @type choice :: :accept | :reject | :modify | :acknowledge | :withdraw
  @type author :: %{
          kind: :owner | :agent | :wtf_staff,
          id: String.t() | nil,
          via: :chat | :form | :cli | nil
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          key: String.t(),
          kind: kind(),
          revision: pos_integer(),
          subject: map(),
          target: String.t() | nil,
          choice: choice(),
          params: map(),
          basis: %{optional(atom()) => String.t()},
          rationale: String.t() | nil,
          author: author() | nil,
          decided_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @enforce_keys [:key, :kind, :revision, :subject, :choice]
  defstruct [
    :id,
    :key,
    :kind,
    :revision,
    :subject,
    :target,
    :choice,
    :rationale,
    :author,
    :decided_at,
    :expires_at,
    params: %{},
    basis: %{}
  ]

  @doc "The JSON format version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "The rename slots."
  @spec slots() :: [atom()]
  def slots, do: @slots |> Map.keys() |> Enum.sort()

  # --- construction ---------------------------------------------------------

  @doc """
  Builds a decision from atom-keyed attributes (`:kind`, `:subject`,
  `:choice`, `:revision` (default 1), `:params`, `:basis`, `:target`, `:id`,
  `:rationale`, `:author`, `:decided_at`, `:expires_at`), validated exactly
  like `from_map/1`. The key is computed.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    attrs
    |> Map.take(@attrs)
    |> Map.put_new(:revision, 1)
    |> Map.put(:schema_version, @schema_version)
    |> json()
    |> from_map()
  end

  @doc """
  A decision on `finding` (built by `BubbleEx.Findings.analyze/2`, so it has
  a `basis_sha256`): subject and basis come from the finding, and `modify`
  `params` are checked against its proposal.

  Options: `:revision` (default 1), `:id`, `:rationale`, `:author`,
  `:decided_at` and `:basis` (extra basis members such as `source_sha256`,
  `bubble_version` or `bubble_ex`).
  """
  @spec for_finding(Finding.t(), choice(), map(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def for_finding(%Finding{} = finding, choice, params \\ %{}, opts \\ []) do
    basis =
      opts
      |> Keyword.get(:basis, %{})
      |> Map.new()
      |> Map.merge(%{
        finding_id: finding.id,
        proposal_sha256: finding.proposal_sha256,
        basis_sha256: finding.basis_sha256
      })

    attrs =
      opts
      |> Keyword.take([:revision, :id, :rationale, :author, :decided_at])
      |> Map.new()
      |> Map.merge(%{
        kind: :finding,
        subject: finding.subject,
        choice: choice,
        params: params,
        basis: basis
      })

    with {:ok, decision} <- new(attrs),
         :ok <- check(decision, finding),
         do: {:ok, decision}
  end

  @doc """
  The next revision of finding decision `decision`, acknowledging that it
  no longer applies: an orphaned decision (its finding is gone) or a stale
  one (its finding changed). It stops blocking publication and keeps the
  source-faithful mapping, like a reject; to apply a changed proposal,
  accept it again instead.

  Pass the current finding as `:finding` when there is one (a stale
  decision), so the acknowledgement records its hashes and resolves
  `:acknowledged`; if the finding changes again it is `:stale` again. Other
  options: `:id`, `:rationale`, `:author`, `:decided_at`, `:basis` (extra
  basis members).
  """
  @spec acknowledge(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def acknowledge(decision, opts \\ [])

  def acknowledge(%__MODULE__{kind: :finding} = d, opts) do
    hashes =
      case Keyword.get(opts, :finding) do
        %Finding{id: id} = f when id == d.basis.finding_id ->
          {:ok, %{proposal_sha256: f.proposal_sha256, basis_sha256: f.basis_sha256}}

        nil ->
          {:ok, %{}}

        other ->
          error("acknowledge needs the decision's own finding", %{finding: other})
      end

    with {:ok, hashes} <- hashes do
      basis =
        opts
        |> Keyword.get(:basis, %{})
        |> Map.new()
        |> Map.merge(hashes)
        |> Map.put(:finding_id, d.basis.finding_id)

      next(d, :acknowledge, %{}, basis, opts)
    end
  end

  def acknowledge(%__MODULE__{kind: kind}, _opts),
    do: error("only finding decisions are acknowledged; withdraw a #{kind}", %{kind: kind})

  @doc """
  The next revision of a rename or parity exception, withdrawing it: the
  rename's derived name comes back, the exception no longer excuses a
  difference. Options: `:id`, `:rationale`, `:author`, `:decided_at`.
  """
  @spec withdraw(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def withdraw(decision, opts \\ [])

  def withdraw(%__MODULE__{kind: kind} = d, opts) when kind in [:rename, :parity_exception],
    do: next(d, :withdraw, d.params, d.basis, opts)

  def withdraw(%__MODULE__{kind: kind}, _opts),
    do: error("only renames and parity exceptions are withdrawn; acknowledge a #{kind}", %{})

  defp next(d, choice, params, basis, opts) do
    opts
    |> Keyword.take([:id, :rationale, :author, :decided_at])
    |> Map.new()
    |> Map.merge(%{
      kind: d.kind,
      subject: d.subject,
      target: d.target,
      choice: choice,
      params: params,
      basis: basis,
      revision: d.revision + 1
    })
    |> new()
  end

  @doc """
  Checks a finding decision against `finding`: it is about that finding and
  its `modify` parameters fit the finding's proposal
  (`BubbleEx.Decision.Params.check/2`).
  """
  @spec check(t(), Finding.t()) :: :ok | {:error, Error.t()}
  def check(%__MODULE__{kind: :finding} = d, %Finding{} = finding) do
    cond do
      d.basis.finding_id != finding.id ->
        error("decision is about another finding", %{
          finding_id: d.basis.finding_id,
          given: finding.id
        })

      d.choice == :modify ->
        Params.check(finding.proposal, d.params, finding.evidence)

      true ->
        :ok
    end
  end

  def check(%__MODULE__{kind: kind}, _finding),
    do: error("only finding decisions are checked against a finding", %{kind: kind})

  @doc """
  The key of a decision: `"finding:<finding id>"`, or for renames and parity
  exceptions the kind and the first 16 hex digits of the SHA-256 of their
  identity (target, slot and subject; scope and subject).
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{kind: :finding, basis: %{finding_id: id}}), do: "finding:" <> id

  def key(%__MODULE__{kind: :rename} = d),
    do: hashed_key(:rename, %{target: d.target, slot: d.params.slot, subject: d.subject})

  def key(%__MODULE__{kind: :parity_exception} = d),
    do: hashed_key(:parity_exception, %{scope: d.params.scope, subject: d.subject})

  defp hashed_key(kind, identity),
    do: "#{kind}:" <> binary_part(CanonicalJson.sha256(json(identity)), 0, 16)

  # --- codec ----------------------------------------------------------------

  @doc "JSON form: string keys, JSON primitives, ISO 8601 UTC timestamps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = d) do
    %{
      "schema_version" => @schema_version,
      "id" => d.id,
      "key" => d.key,
      "kind" => Atom.to_string(d.kind),
      "revision" => d.revision,
      "subject" => json(d.subject),
      "target" => d.target,
      "choice" => Atom.to_string(d.choice),
      "params" => json(d.params),
      "basis" => json(d.basis),
      "rationale" => d.rationale,
      "author" => json(d.author),
      "decided_at" => json(d.decided_at),
      "expires_at" => json(d.expires_at)
    }
  end

  @doc "Canonical JSON text of `to_map/1`."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = d), do: d |> to_map() |> CanonicalJson.encode()

  @doc "Decodes JSON text (see `from_map/1`)."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} -> from_map(map)
      {:error, e} -> error("invalid decision JSON", %{reason: Exception.message(e)})
    end
  end

  def from_json(other), do: error("decision JSON must be a string", %{value: other})

  @doc """
  Decodes and validates the JSON form. Unknown members, an unknown
  `schema_version`, kind, choice, author, rename slot or `modify` parameter,
  a subject that is not Bubble IDs, a finding basis that does not match the
  subject, or a key that differs from `key/1` is `:invalid_input`.
  """
  @spec from_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) when is_map(map) do
    with :ok <- members(map),
         :ok <- version(map["schema_version"]),
         {:ok, kind} <- enum(map["kind"], @kinds, "kind"),
         {:ok, choice} <- enum(map["choice"], @choices, "choice"),
         {:ok, revision} <- revision(map["revision"]),
         {:ok, subject} <- subject(map["subject"]),
         {:ok, basis} <- basis(Map.get(map, "basis") || %{}),
         {:ok, author} <- author(map["author"]),
         {:ok, decided_at} <- timestamp(map["decided_at"], "decided_at"),
         {:ok, expires_at} <- timestamp(map["expires_at"], "expires_at"),
         {:ok, id} <- non_empty(map["id"], "id"),
         {:ok, rationale} <- string(map["rationale"], "rationale"),
         {:ok, target} <- string(map["target"], "target"),
         decision = %__MODULE__{
           id: id,
           key: "",
           kind: kind,
           revision: revision,
           subject: subject,
           target: target,
           choice: choice,
           basis: basis,
           rationale: rationale,
           author: author,
           decided_at: decided_at,
           expires_at: expires_at
         },
         {:ok, decision} <- by_kind(decision, Map.get(map, "params") || %{}) do
      with_key(decision, map["key"])
    end
  end

  def from_map(other), do: error("a decision must be a JSON object", %{value: other})

  defp members(map) do
    keys = Map.keys(map)

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        error("decision members must be strings", %{members: Enum.reject(keys, &is_binary/1)})

      (extra = keys -- @members) != [] ->
        error("unknown decision members", %{members: extra})

      (missing = @required -- keys) != [] ->
        error("missing decision members", %{members: missing})

      true ->
        :ok
    end
  end

  defp version(@schema_version), do: :ok

  defp version(v),
    do: error("unsupported decision schema_version", %{schema_version: v, supported: 1})

  defp revision(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp revision(n), do: error("revision must be a positive integer", %{revision: n})

  defp subject(subject) when is_map(subject) and map_size(subject) > 0 do
    names = Map.new(@subject_keys, &{Atom.to_string(&1), &1})

    Enum.reduce_while(subject, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case Map.fetch(names, k) do
        {:ok, key} when is_binary(v) and v != "" -> {:cont, {:ok, Map.put(acc, key, v)}}
        _ -> {:halt, error("invalid subject entry", %{entry: {k, v}})}
      end
    end)
  end

  defp subject(subject), do: error("subject must be a non-empty object", %{subject: subject})

  defp basis(basis) when is_map(basis) do
    names = Map.new(@basis_keys, &{Atom.to_string(&1), &1})

    Enum.reduce_while(basis, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case {Map.fetch(names, k), v} do
        {{:ok, _}, nil} -> {:cont, {:ok, acc}}
        {{:ok, key}, v} when is_binary(v) -> basis_value(acc, key, v)
        _ -> {:halt, error("invalid basis entry", %{entry: {k, v}})}
      end
    end)
  end

  defp basis(basis), do: error("basis must be an object", %{basis: basis})

  # Hashes are lowercase hex SHA-256; every other basis member a non-empty
  # string.
  defp basis_value(acc, key, v) do
    valid? =
      if key |> Atom.to_string() |> String.ends_with?("sha256"),
        do: v =~ ~r/\A[0-9a-f]{64}\z/,
        else: v != ""

    if valid?,
      do: {:cont, {:ok, Map.put(acc, key, v)}},
      else: {:halt, error("invalid basis #{key}", %{value: v})}
  end

  defp author(nil), do: {:ok, nil}

  defp author(%{} = author) do
    with :ok <- only(author, ~w(kind id via), "author"),
         {:ok, kind} <- enum(author["kind"], @author_kinds, "author kind"),
         {:ok, id} <- non_empty(author["id"], "author id"),
         {:ok, via} <- optional_enum(author["via"], @vias, "author via") do
      {:ok, %{kind: kind, id: id, via: via}}
    end
  end

  defp author(other), do: error("author must be an object", %{author: other})

  defp timestamp(nil, _), do: {:ok, nil}

  defp timestamp(text, name) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> error("#{name} must be an ISO 8601 timestamp", %{value: text})
    end
  end

  defp timestamp(value, name), do: error("#{name} must be a string", %{value: value})

  defp string(nil, _), do: {:ok, nil}
  defp string(s, _) when is_binary(s), do: {:ok, s}
  defp string(value, name), do: error("#{name} must be a string", %{value: value})

  defp non_empty("", name), do: error("#{name} must not be empty", %{})
  defp non_empty(value, name), do: string(value, name)

  defp enum(value, allowed, name) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> error("unknown #{name}", %{value: value, allowed: allowed})
      atom -> {:ok, atom}
    end
  end

  defp enum(value, allowed, name),
    do: error("unknown #{name}", %{value: value, allowed: allowed})

  defp optional_enum(nil, _, _), do: {:ok, nil}
  defp optional_enum(value, allowed, name), do: enum(value, allowed, name)

  defp only(map, allowed, name) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      extra -> error("unknown #{name} members", %{members: extra})
    end
  end

  # Kind-specific rules: target, choice, basis, params and expiry.
  defp by_kind(%{kind: :finding} = d, params) do
    with :ok <- choice_of(d),
         :ok <- absent(d.target, "target", :finding),
         :ok <- absent(d.expires_at, "expires_at", :finding),
         :ok <- finding_basis(d),
         {:ok, kind} <- finding_kind(d),
         {:ok, params} <- params_object(params),
         {:ok, params} <- Params.cast(kind, d.choice, params) do
      {:ok, %{d | params: params}}
    end
  end

  defp by_kind(%{kind: :rename} = d, params) do
    with :ok <- choice_of(d),
         :ok <- absent(d.expires_at, "expires_at", :rename),
         :ok <- target(d.target),
         {:ok, params} <- params_object(params),
         :ok <- only(params, ~w(slot name), "rename params"),
         {:ok, slot} <- enum(params["slot"], slots(), "rename slot"),
         :ok <- slot_subject(slot, d.subject),
         {:ok, name} <- slot_name(slot, params["name"]) do
      {:ok, %{d | params: %{slot: slot, name: name}}}
    end
  end

  defp by_kind(%{kind: :parity_exception} = d, params) do
    with :ok <- choice_of(d),
         :ok <- absent(d.target, "target", :parity_exception),
         {:ok, params} <- params_object(params),
         :ok <- only(params, Enum.map(@parity_params, &Atom.to_string/1), "parity params"),
         {:ok, params} <-
           Enum.reduce_while(@parity_params, {:ok, %{}}, &parity_param(params, &1, &2)) do
      {:ok, %{d | params: params}}
    end
  end

  defp parity_param(params, name, {:ok, acc}) do
    case params[Atom.to_string(name)] do
      value when is_binary(value) and value != "" ->
        {:cont, {:ok, Map.put(acc, name, value)}}

      value ->
        {:halt, error("parity exception #{name} must be a non-empty string", %{value: value})}
    end
  end

  defp params_object(params) when is_map(params), do: {:ok, params}
  defp params_object(params), do: error("params must be an object", %{params: params})

  defp absent(nil, _, _), do: :ok
  defp absent(_, name, kind), do: error("#{kind} decisions have no #{name}", %{})

  defp choice_of(%{kind: kind, choice: choice}) do
    allowed = @kind_choices[kind]

    if choice in allowed,
      do: :ok,
      else: error("#{kind} decisions are #{Enum.join(allowed, ", ")}", %{choice: choice})
  end

  defp target(target) when target in @targets, do: :ok
  defp target(target), do: error("unknown rename target", %{target: target, allowed: @targets})

  # An acknowledgement of an orphaned decision has no finding to hash.
  defp finding_basis(%{basis: basis, choice: choice}) do
    required = if choice == :acknowledge, do: [:finding_id], else: @finding_basis

    case Enum.reject(required, &Map.has_key?(basis, &1)) do
      [] -> :ok
      missing -> error("a finding decision's basis needs #{Enum.join(missing, ", ")}", %{})
    end
  end

  # The finding ID names a registered kind and is the ID of that kind and
  # the decision's subject.
  defp finding_kind(%{basis: %{finding_id: id}, subject: subject}) do
    with [name, _] <- String.split(id, ":", parts: 2),
         kind when not is_nil(kind) <- Enum.find(Kinds.all(), &(Atom.to_string(&1) == name)),
         ^id <- Finding.id(kind, subject) do
      {:ok, kind}
    else
      _ -> error("finding_id is not a finding about the subject", %{finding_id: id})
    end
  end

  defp slot_subject(slot, subject) do
    shape = subject |> Map.keys() |> Enum.sort()

    if shape in @slots[slot],
      do: :ok,
      else: error("a #{slot} rename needs a subject of #{inspect(@slots[slot])}", %{shape: shape})
  end

  defp slot_name(slot, name) when is_binary(name) do
    pattern =
      case slot do
        s when s in [:module, :enum_module] -> ~r/\A[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*\z/
        :endpoint_path -> ~r/\A[a-z0-9][a-z0-9_-]*(\/[a-z0-9][a-z0-9_-]*)*\z/
        _ -> ~r/\A[a-z][a-z0-9_]{0,62}\z/
      end

    cond do
      not (name =~ pattern) -> bad_name(slot, name)
      slot in [:module, :enum_module] and reserved_module?(name) -> bad_name(slot, name)
      true -> {:ok, name}
    end
  end

  defp slot_name(slot, name), do: bad_name(slot, name)

  @doc """
  Whether a module name's first segment is one a rename may not take:
  Elixir's own modules and the namespaces of the target's libraries
  (`Elixir`, `Erlang`, `Ash`, `AshPostgres`, `Ecto`, `Phoenix`, `Spark`).
  """
  @spec reserved_module?(String.t()) :: boolean()
  def reserved_module?(name) when is_binary(name),
    do: MapSet.member?(@reserved_modules, name |> String.split(".") |> hd())

  defp bad_name(slot, name), do: error("invalid #{slot} name", %{name: name})

  defp with_key(decision, given) do
    key = key(decision)

    if given in [nil, key],
      do: {:ok, %{decision | key: key}},
      else: error("key does not match the decision", %{key: given, expected: key})
  end

  # --- lifecycle ------------------------------------------------------------

  @doc """
  Computes the state of every record in `decisions` against the current
  `findings` (all kinds, as returned by `BubbleEx.Findings.analyze/2`: a
  decision on a kind that was not analyzed looks orphaned). See
  `BubbleEx.Decision.Resolved` for the states and reasons.

  Options:

    * `:index` (required) - the `BubbleEx.Index` of the snapshot the
      findings come from. It tells an orphan whose subject still exists
      (the owner must acknowledge it) from one whose subject is gone
      (archived), orphans a rename whose subject is gone or deleted, and
      checks a `modify`'s `target_type` still names a live data type.
    * `:now` (required) - the `DateTime` parity exceptions expire against;
      explicit so resolving stays a pure function of its inputs
    * `:scenarios` - `%{scope => scenario sha256}` of the current
      scenarios (default `%{}`). A parity exception with a
      `basis.scenario_sha256` is expired when its scope's hash differs
      (`:scenario_changed`) or is not given (`:scenario_unknown`): an
      exception is never kept on a scenario nobody vouched for.
    * `:bubble_ex` - the current analyzer version, to flag stale decisions
      recorded by another one (`:analyzer_updated`)

  Missing or invalid options, and two records with the same key and
  revision, are `:invalid_input`. `BubbleEx.Decision.Resolved.blocking/1`
  lists what blocks publication.
  """
  @spec resolve([t()], [Finding.t()], keyword()) :: {:ok, Resolved.t()} | {:error, Error.t()}
  def resolve(decisions, findings, opts) when is_list(decisions) and is_list(findings) do
    with {:ok, latest} <- latest(decisions),
         {:ok, ctx} <- resolve_context(opts) do
      ctx = Map.put(ctx, :findings, Map.new(findings, &{&1.id, &1}))

      entries =
        decisions
        |> Enum.sort_by(&{&1.key, &1.revision})
        |> Enum.map(&state(&1, latest, ctx))

      undecided =
        for %Finding{category: :decision, id: id} <- findings,
            not Map.has_key?(latest, "finding:" <> id),
            do: id

      {:ok, %Resolved{entries: entries, undecided: Enum.sort(undecided)}}
    end
  end

  defp resolve_context(opts) do
    case {Keyword.get(opts, :index), Keyword.get(opts, :now), Keyword.get(opts, :scenarios, %{})} do
      {%Index{} = index, %DateTime{} = now, scenarios} when is_map(scenarios) ->
        {:ok,
         %{index: index, now: now, scenarios: scenarios, bubble_ex: Keyword.get(opts, :bubble_ex)}}

      _ ->
        error("resolve needs index: %BubbleEx.Index{}, now: %DateTime{} and a scenarios map", %{})
    end
  end

  # The current (highest-revision) record of every key.
  defp latest(decisions) do
    with :ok <- all_decisions(decisions),
         :ok <- unique_revisions(decisions) do
      {:ok,
       decisions
       |> Enum.group_by(& &1.key)
       |> Map.new(fn {key, records} -> {key, Enum.max_by(records, & &1.revision)} end)}
    end
  end

  defp unique_revisions(decisions) do
    case decisions
         |> Enum.frequencies_by(&{&1.key, &1.revision})
         |> Enum.find(fn {_, n} -> n > 1 end) do
      nil ->
        :ok

      {{key, rev}, _} ->
        error("two decisions share a key and revision", %{key: key, revision: rev})
    end
  end

  defp state(d, latest, ctx) do
    if d.revision < latest[d.key].revision,
      do: entry(d, :superseded, [:newer_revision]),
      else: current(d, ctx)
  end

  defp all_decisions(decisions) do
    if Enum.all?(decisions, &is_struct(&1, __MODULE__)),
      do: :ok,
      else: error("expected a list of BubbleEx.Decision structs", %{})
  end

  defp current(%{kind: :finding} = d, ctx) do
    presence = subject_presence(d.subject, ctx.index)

    case {Map.fetch(ctx.findings, d.basis.finding_id), d.choice} do
      {{:ok, finding}, choice} ->
        case changes(d, finding, ctx.index) do
          [] when choice == :acknowledge -> entry(d, :acknowledged, [])
          [] -> entry(d, :active, [])
          reasons -> entry(d, :stale, reasons ++ analyzer(d, ctx))
        end

      {:error, :acknowledge} ->
        entry(d, :acknowledged, [:finding_absent, presence])

      {:error, _} ->
        entry(d, :orphaned, [:finding_absent, presence])
    end
  end

  defp current(%{choice: :withdraw} = d, _ctx), do: entry(d, :withdrawn, [])

  defp current(%{kind: :rename} = d, ctx) do
    if subject_presence(d.subject, ctx.index) == :subject_gone,
      do: entry(d, :orphaned, [:subject_gone]),
      else: entry(d, :active, [])
  end

  defp current(%{kind: :parity_exception} = d, ctx) do
    reasons =
      [
        if(d.expires_at != nil and DateTime.compare(ctx.now, d.expires_at) != :lt,
          do: :expired
        ),
        scenario(d, ctx.scenarios)
      ]
      |> Enum.reject(&is_nil/1)

    if reasons == [], do: entry(d, :active, []), else: entry(d, :expired, reasons)
  end

  # What changed between the finding a decision was made on and `finding`.
  defp changes(d, finding, index) do
    [
      {:proposal_changed, finding.proposal_sha256 != d.basis[:proposal_sha256]},
      {:basis_changed, finding.basis_sha256 != d.basis[:basis_sha256]},
      {:params_invalid, d.choice == :modify and not params_valid?(d, finding, index)}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp params_valid?(d, finding, index) do
    check(d, finding) == :ok and
      case d.params do
        %{target_type: type} -> live?(index, type)
        _ -> true
      end
  end

  defp entry(d, state, reasons), do: %{decision: d, state: state, reasons: reasons}

  defp analyzer(%{basis: %{bubble_ex: recorded}}, %{bubble_ex: current})
       when is_binary(current) and recorded != current,
       do: [:analyzer_updated]

  defp analyzer(_, _), do: []

  defp scenario(%{basis: %{scenario_sha256: recorded}, params: %{scope: scope}}, scenarios) do
    case Map.fetch(scenarios, scope) do
      {:ok, ^recorded} -> nil
      {:ok, _} -> :scenario_changed
      :error -> :scenario_unknown
    end
  end

  defp scenario(_, _), do: nil

  # Whether every symbol of the subject exists (and is not deleted).
  defp subject_presence(subject, index) do
    if Enum.all?(Subject.symbol_ids(subject), &live?(index, &1)),
      do: :subject_present,
      else: :subject_gone
  end

  defp live?(index, id) do
    case Index.symbol(index, id) do
      nil -> false
      symbol -> not Map.get(symbol.attrs, :deleted, false)
    end
  end

  @doc """
  What generation may apply, sorted by key: every `:active` accept or
  modify of a finding (its proposal with the parameters merged in), every
  `:active` rename, and every hint finding with no current record (hints
  apply by default and are recorded only when rejected or trimmed; these
  are `automatic`). Rejections, acknowledgements, withdrawals, parity
  exceptions and records in any other state apply nothing: previews fall
  back to the source-faithful mapping.
  """
  @spec applicable(Resolved.t(), [Finding.t()]) :: [Applied.t()]
  def applicable(%Resolved{entries: entries}, findings) when is_list(findings) do
    by_id = Map.new(findings, &{&1.id, &1})

    decided =
      for %{state: s, decision: d} <- entries, s != :superseded, into: MapSet.new(), do: d.key

    decisions =
      for %{state: :active, decision: d} <- entries,
          applied = applied(d, by_id),
          do: applied

    automatic =
      for %Finding{category: :hint} = f <- findings,
          not MapSet.member?(decided, "finding:" <> f.id),
          do: %Applied{
            key: "finding:" <> f.id,
            kind: :finding,
            automatic: true,
            finding_id: f.id,
            transform: f.proposal.transform,
            subject: f.subject,
            proposal: f.proposal,
            proposal_sha256: f.proposal_sha256,
            basis_sha256: f.basis_sha256
          }

    Enum.sort_by(decisions ++ automatic, & &1.key)
  end

  defp applied(%{kind: :finding, choice: choice} = d, by_id) when choice in [:accept, :modify] do
    case Map.fetch(by_id, d.basis.finding_id) do
      {:ok, finding} -> applied_finding(d, finding)
      :error -> nil
    end
  end

  defp applied(%{kind: :rename} = d, _by_id) do
    %Applied{
      key: d.key,
      kind: :rename,
      decision_id: d.id,
      transform: :rename,
      subject: d.subject,
      target: d.target,
      params: d.params
    }
  end

  defp applied(_d, _by_id), do: nil

  defp applied_finding(d, finding) do
    proposal = Params.apply(finding.proposal, d.params)

    %Applied{
      key: d.key,
      kind: :finding,
      decision_id: d.id,
      finding_id: finding.id,
      transform: proposal.transform,
      subject: d.subject,
      proposal: proposal,
      params: d.params,
      proposal_sha256: finding.proposal_sha256,
      basis_sha256: finding.basis_sha256,
      basis: Map.take(d.basis, [:proposal_sha256, :basis_sha256])
    }
  end

  @doc """
  SHA-256 of the inputs of the current record of every key that decide
  its state or what it applies: `key`, `kind`, `subject`, `target`,
  `choice`, `params`, `expires_at` and the basis hashes
  (`proposal_sha256`, `basis_sha256`, `scenario_sha256`), sorted by key.
  Record IDs, revisions, `decided_at`, rationales, authors and the
  informational basis members (`source_sha256`, `index_semantic_sha256`,
  `bubble_version`, `bubble_ex`) are excluded, so an audit-only revision
  does not change it; a re-accept of a changed finding does. Raises `ArgumentError` when two records
  share a key and revision.
  """
  @spec decisions_sha256([t()]) :: String.t()
  def decisions_sha256(decisions) when is_list(decisions) do
    case latest(decisions) do
      {:ok, latest} ->
        latest
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_key, d} -> generation_inputs(d) end)
        |> then(&%{"schema_version" => @schema_version, "decisions" => &1})
        |> CanonicalJson.sha256()

      {:error, e} ->
        raise ArgumentError, e.message
    end
  end

  defp generation_inputs(d) do
    %{
      "key" => d.key,
      "kind" => Atom.to_string(d.kind),
      "subject" => json(d.subject),
      "target" => d.target,
      "choice" => Atom.to_string(d.choice),
      "params" => json(d.params),
      "expires_at" => json(d.expires_at),
      "basis" =>
        d.basis |> Map.take([:proposal_sha256, :basis_sha256, :scenario_sha256]) |> json()
    }
  end

  # --- helpers --------------------------------------------------------------

  defp json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp json(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)

  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(value) when value in [true, false, nil], do: value
  defp json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json(value), do: value

  defp error(message, context), do: {:error, Error.new(:invalid_input, message, context)}
end
