defmodule BubbleEx.Finding do
  @moduledoc """
  A proposed improvement to a Bubble app's model, found by a deterministic
  analyzer (`BubbleEx.Findings`) and waiting for the owner's decision.

  A finding is not a `BubbleEx.Diagnostic`: a diagnostic reports that
  BubbleEx could not do something faithfully and disappears as the tool
  improves; a finding is a statement about the app that proposes a
  redesign. The two share the `subject` and `path` conventions.

    * `id` - stable identity: `"<kind>:<hash>"`, the hash of `kind` and
      `subject` only (`id/2`). It survives re-runs, renames in the Bubble
      editor and unrelated edits, so decisions can key on it.
    * `proposal_sha256` - hash of what is proposed: kind, subject, proposal,
      evidence symbols and evidence references without source paths
      (`proposal_sha256/1`). A decision recorded against one value is stale
      when the finding with the same `id` comes back with another.
    * `basis_sha256` - hash of the content of the symbols the finding is
      about: its subject and evidence symbols, without source paths or
      display names (`basis_sha256/2`, set by `BubbleEx.Findings.analyze/2`;
      `nil` on a finding built without an index). It changes when one of
      them changes (e.g. a copied field's type), which `proposal_sha256`
      does not see, and not on caption edits.
    * `kind` - stable atom, listed in `BubbleEx.Finding.Kinds`
    * `category` - `:decision` (an owner decision) or `:hint` (a performance
      hint), fixed by the kind
    * `subject` - the Bubble IDs the finding is about, keyed like a
      diagnostic's (`:type`, `:option_set`, `:external_type`, `:field`,
      `:rule`, `:workflow`, `:plugin`). IDs only, never display names.
    * `path` - RFC 6901 JSON pointer of the subject's definition
    * `evidence` - why: `symbols` (`BubbleEx.Index.Symbol` IDs) and
      `references` (`BubbleEx.Index.Reference`s, e.g. the actions writing a
      field), plus kind-specific facts
    * `proposal` - the stack-neutral transformation, `%{transform: atom, …}`
      (transforms are documented in `BubbleEx.Finding.Kinds`). It says what
      to change, not how any target stack expresses it; values name symbols
      by index ID and carry no source paths.
    * `confidence` - `:high | :medium | :low`, with `confidence_reason`
    * `affects` - symbol IDs of the `workflows`, `pages`, `reusables` and
      `privacy_rules` touched, split into `readers` (whose reads must be
      rewritten) and `maintainers` (whose writes change or go)
    * `related` - IDs of findings that must be decided together (e.g. the
      two sides of one many-to-many)
    * `message` - for people; not part of the identity

  `normalize/1` orders by kind, subject and ID and raises when two findings
  share an ID. Every list of findings BubbleEx returns is normalized.
  """

  alias BubbleEx.{CanonicalJson, Diagnostic}
  alias BubbleEx.Finding.Kinds
  alias BubbleEx.Index
  alias BubbleEx.Index.{Reference, Subject}

  @type confidence :: :high | :medium | :low
  @type evidence :: %{
          required(:symbols) => [String.t()],
          required(:references) => [Reference.t()],
          optional(atom()) => term()
        }
  @type group :: %{
          workflows: [String.t()],
          pages: [String.t()],
          reusables: [String.t()],
          privacy_rules: [String.t()]
        }
  @type affects :: %{readers: group(), maintainers: group()}

  @type t :: %__MODULE__{
          id: String.t(),
          proposal_sha256: String.t(),
          basis_sha256: String.t() | nil,
          kind: atom(),
          category: Kinds.category(),
          subject: Diagnostic.subject(),
          path: String.t(),
          evidence: evidence(),
          proposal: %{required(:transform) => atom(), optional(atom()) => term()},
          confidence: confidence(),
          confidence_reason: String.t(),
          affects: affects(),
          related: [String.t()],
          message: String.t()
        }

  @enforce_keys [:id, :proposal_sha256, :kind, :category, :subject, :path, :proposal] ++
                  [:confidence, :message]
  defstruct [
    :id,
    :proposal_sha256,
    :kind,
    :category,
    :subject,
    :path,
    :proposal,
    :confidence,
    :message,
    :basis_sha256,
    confidence_reason: "",
    evidence: %{symbols: [], references: []},
    affects: %{readers: %{}, maintainers: %{}},
    related: []
  ]

  @subject_keys [:type, :option_set, :external_type, :field, :rule, :workflow, :plugin]
  @group_keys [:workflows, :pages, :reusables, :privacy_rules]
  @confidences [:high, :medium, :low]

  @type option ::
          {:path, String.t() | [String.t()]}
          | {:evidence, map()}
          | {:proposal, map()}
          | {:confidence, confidence()}
          | {:confidence_reason, String.t()}
          | {:affects, %{optional(:readers) => map(), optional(:maintainers) => map()}}
          | {:related, [String.t()]}
          | {:message, String.t()}

  @doc """
  Builds a finding of a registered `kind` about `subject`. `:proposal`,
  `:confidence` and `:message` are required; evidence symbol and reference
  lists and every `affects` list are deduplicated and sorted.

  Raises `ArgumentError` for an unregistered kind, a transform the kind does
  not allow, an invalid subject or confidence. These are programming errors.
  """
  @spec new(atom(), Diagnostic.subject(), [option()]) :: t()
  def new(kind, subject, opts) when is_atom(kind) and is_map(subject) do
    entry =
      case Kinds.fetch(kind) do
        {:ok, entry} -> entry
        :error -> raise ArgumentError, "unregistered finding kind #{inspect(kind)}"
      end

    proposal = Keyword.fetch!(opts, :proposal)

    unless proposal[:transform] in entry.transforms,
      do: raise(ArgumentError, "#{inspect(kind)} cannot propose #{inspect(proposal[:transform])}")

    confidence = Keyword.fetch!(opts, :confidence)

    unless confidence in @confidences,
      do: raise(ArgumentError, "invalid confidence #{inspect(confidence)}")

    subject = validate_subject!(subject)
    affects = Keyword.get(opts, :affects, %{})

    finding = %__MODULE__{
      id: id(kind, subject),
      proposal_sha256: "",
      kind: kind,
      category: entry.category,
      subject: subject,
      path: Diagnostic.pointer(Keyword.get(opts, :path, "")),
      evidence: evidence(Keyword.get(opts, :evidence, %{})),
      proposal: proposal,
      confidence: confidence,
      confidence_reason: Keyword.get(opts, :confidence_reason, ""),
      affects: %{
        readers: group(Map.get(affects, :readers, %{})),
        maintainers: group(Map.get(affects, :maintainers, %{}))
      },
      related: sorted(Keyword.get(opts, :related, [])),
      message: Keyword.fetch!(opts, :message)
    }

    %{finding | proposal_sha256: proposal_sha256(finding)}
  end

  defp validate_subject!(subject) do
    if map_size(subject) == 0, do: raise(ArgumentError, "a finding needs a subject")

    Enum.each(subject, fn
      {key, id} when key in @subject_keys and is_binary(id) -> :ok
      pair -> raise ArgumentError, "invalid finding subject entry #{inspect(pair)}"
    end)

    subject
  end

  defp evidence(evidence) do
    evidence
    |> Map.update(:symbols, [], &sorted/1)
    |> Map.update(
      :references,
      [],
      &(&1 |> Enum.uniq() |> Enum.sort_by(fn r -> Reference.sort_key(r) end))
    )
  end

  defp group(group), do: Map.new(@group_keys, &{&1, sorted(Map.get(group, &1, []))})

  defp sorted(list), do: list |> Enum.uniq() |> Enum.sort()

  @doc """
  The stable ID of a finding of `kind` about `subject`: the kind, a colon and
  the first 16 hex digits of the SHA-256 of their canonical JSON.

      iex> BubbleEx.Finding.id(:number_type, %{type: "task", field: "points_number"})
      "number_type:568835fc8a7c3aac"
  """
  @spec id(atom(), Diagnostic.subject()) :: String.t()
  def id(kind, subject) when is_atom(kind) and is_map(subject) do
    hash = CanonicalJson.sha256(%{"kind" => Atom.to_string(kind), "subject" => json(subject)})
    "#{kind}:" <> binary_part(hash, 0, 16)
  end

  @doc """
  SHA-256 of what a finding proposes: kind, subject, proposal, evidence
  symbols and evidence references as `{from, kind, to}` (no source paths, so
  moving a definition in the JSON does not change it). Messages, confidence,
  `affects` and `related` are excluded.
  """
  @spec proposal_sha256(t()) :: String.t()
  def proposal_sha256(%__MODULE__{} = f) do
    CanonicalJson.sha256(%{
      "kind" => Atom.to_string(f.kind),
      "subject" => json(f.subject),
      "proposal" => json(f.proposal),
      "symbols" => f.evidence.symbols,
      "references" =>
        f.evidence.references
        |> Enum.map(&[&1.from, Atom.to_string(&1.kind), &1.to])
        |> Enum.uniq()
        |> Enum.sort()
    })
  end

  @doc """
  The index symbol IDs a finding is about: its subject's symbols (see
  `BubbleEx.Index.Subject`) and the data-model symbols among its evidence
  (data types, fields, option sets, option values and attributes, privacy
  rules), sorted. Pages, elements, workflows and actions in the evidence
  (e.g. the hosts of a `:search_index` hint's searches) are left out: the
  references they make are in `proposal_sha256`, and unrelated edits to
  them must not invalidate a decision.
  """
  @spec basis_symbols(t()) :: [String.t()]
  def basis_symbols(%__MODULE__{} = f) do
    evidence = Enum.filter(f.evidence.symbols, &data_model_symbol?/1)
    sorted(Subject.symbol_ids(f.subject) ++ evidence)
  end

  @data_model ~w(data_type field option_set option_value option_attribute privacy_rule)

  defp data_model_symbol?(id) do
    case String.split(id, ":", parts: 2) do
      [kind, _] -> kind in @data_model
      _ -> false
    end
  end

  @doc """
  SHA-256 of the content of the finding's `basis_symbols/1` in `index`
  (`BubbleEx.Index.subject_sha256/2`): their kinds, Bubble IDs, parents and
  attributes, without source paths or display names. A decision recorded
  against one value is stale when the finding comes back with another, even
  if its `proposal_sha256` is unchanged.
  """
  @spec basis_sha256(t(), Index.t()) :: String.t()
  def basis_sha256(%__MODULE__{} = f, %Index{} = index),
    do: Index.subject_sha256(index, basis_symbols(f))

  @doc "Sets `basis_sha256` from `index` (not part of `id` or `proposal_sha256`)."
  @spec put_basis(t(), Index.t()) :: t()
  def put_basis(%__MODULE__{} = f, %Index{} = index),
    do: %{f | basis_sha256: basis_sha256(f, index)}

  @doc "Sets the related finding IDs (not part of `proposal_sha256`)."
  @spec put_related(t(), [String.t()]) :: t()
  def put_related(%__MODULE__{} = f, ids), do: %{f | related: sorted(ids)}

  @doc """
  Sorts by kind, subject and ID. Raises `ArgumentError` when two findings
  share an ID: one analyzer emitting a subject twice is a programming error,
  and silently keeping one would drop evidence.
  """
  @spec normalize([t()]) :: [t()]
  def normalize(findings) when is_list(findings) do
    case findings |> Enum.frequencies_by(& &1.id) |> Enum.filter(fn {_, n} -> n > 1 end) do
      [] ->
        :ok

      dups ->
        raise ArgumentError, "duplicate finding IDs #{inspect(Enum.map(dups, &elem(&1, 0)))}"
    end

    Enum.sort_by(
      findings,
      &{Atom.to_string(&1.kind), Enum.map(@subject_keys, fn k -> Map.get(&1.subject, k) end),
       &1.id}
    )
  end

  @doc """
  JSON form: a map with string keys whose values are JSON primitives. Atoms
  other than `true`/`false`/`nil` become strings and references become maps.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = f) do
    %{
      "id" => f.id,
      "proposal_sha256" => f.proposal_sha256,
      "basis_sha256" => f.basis_sha256,
      "kind" => Atom.to_string(f.kind),
      "category" => Atom.to_string(f.category),
      "subject" => json(f.subject),
      "path" => f.path,
      "evidence" => json(f.evidence),
      "proposal" => json(f.proposal),
      "confidence" => Atom.to_string(f.confidence),
      "confidence_reason" => f.confidence_reason,
      "affects" => json(f.affects),
      "related" => f.related,
      "message" => f.message
    }
  end

  defp json(%Reference{} = r), do: r |> Map.from_struct() |> json()

  defp json(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)

  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json()
  defp json(value) when value in [true, false, nil], do: value
  defp json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json(value) when is_binary(value) or is_number(value), do: value
  defp json(other), do: inspect(other)

  defimpl Jason.Encoder do
    def encode(finding, opts) do
      finding
      |> BubbleEx.Finding.to_map()
      |> BubbleEx.CanonicalJson.ordered()
      |> Jason.Encoder.encode(opts)
    end
  end
end
