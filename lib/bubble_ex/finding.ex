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
    * `kind` - stable atom, listed in `BubbleEx.Finding.Kinds`
    * `subject` - the Bubble IDs the finding is about, keyed like a
      diagnostic's (`:type`, `:option_set`, `:external_type`, `:field`,
      `:rule`, `:workflow`). IDs only, never display names.
    * `path` - RFC 6901 JSON pointer of the subject's definition
    * `evidence` - why: `symbols` (`BubbleEx.Index.Symbol` IDs) and
      `references` (`BubbleEx.Index.Reference`s, e.g. the actions writing a
      field), plus kind-specific facts
    * `proposal` - the stack-neutral transformation, `%{transform: atom, …}`.
      It says what to change, not how any target stack expresses it; values
      name symbols by index ID.
    * `confidence` - `:high | :medium | :low`, with `confidence_reason`
    * `affects` - symbol IDs of the `workflows`, `pages`, `reusables` and
      `privacy_rules` the change touches
    * `message` - for people; not part of the identity

  `normalize/1` drops duplicate IDs and orders by kind, subject and ID. Every
  list of findings BubbleEx returns is normalized.
  """

  alias BubbleEx.{CanonicalJson, Diagnostic}
  alias BubbleEx.Finding.Kinds
  alias BubbleEx.Index.Reference

  @type confidence :: :high | :medium | :low
  @type evidence :: %{
          required(:symbols) => [String.t()],
          required(:references) => [Reference.t()],
          optional(atom()) => term()
        }
  @type affects :: %{
          workflows: [String.t()],
          pages: [String.t()],
          reusables: [String.t()],
          privacy_rules: [String.t()]
        }

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          subject: Diagnostic.subject(),
          path: String.t(),
          evidence: evidence(),
          proposal: %{required(:transform) => atom(), optional(atom()) => term()},
          confidence: confidence(),
          confidence_reason: String.t(),
          affects: affects(),
          message: String.t()
        }

  @enforce_keys [:id, :kind, :subject, :path, :proposal, :confidence, :message]
  defstruct [
    :id,
    :kind,
    :subject,
    :path,
    :proposal,
    :confidence,
    :message,
    confidence_reason: "",
    evidence: %{symbols: [], references: []},
    affects: %{workflows: [], pages: [], reusables: [], privacy_rules: []}
  ]

  @subject_keys [:type, :option_set, :external_type, :field, :rule, :workflow]
  @affects_keys [:workflows, :pages, :reusables, :privacy_rules]
  @confidences [:high, :medium, :low]

  @type option ::
          {:path, String.t()}
          | {:evidence, map()}
          | {:proposal, map()}
          | {:confidence, confidence()}
          | {:confidence_reason, String.t()}
          | {:affects, map()}
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

    %__MODULE__{
      id: id(kind, subject),
      kind: kind,
      subject: subject,
      path: Diagnostic.pointer(Keyword.get(opts, :path, "")),
      evidence: evidence(Keyword.get(opts, :evidence, %{})),
      proposal: proposal,
      confidence: confidence,
      confidence_reason: Keyword.get(opts, :confidence_reason, ""),
      affects: affects(Keyword.get(opts, :affects, %{})),
      message: Keyword.fetch!(opts, :message)
    }
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
    |> Map.update(:symbols, [], &(&1 |> Enum.uniq() |> Enum.sort()))
    |> Map.update(
      :references,
      [],
      &(&1 |> Enum.uniq() |> Enum.sort_by(fn r -> Reference.sort_key(r) end))
    )
  end

  defp affects(affects) do
    Map.new(@affects_keys, &{&1, affects |> Map.get(&1, []) |> Enum.uniq() |> Enum.sort()})
  end

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

  @doc "Drops duplicate IDs (keeping the first) and sorts by kind, subject and ID."
  @spec normalize([t()]) :: [t()]
  def normalize(findings) when is_list(findings) do
    findings
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(
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
      "kind" => Atom.to_string(f.kind),
      "subject" => json(f.subject),
      "path" => f.path,
      "evidence" => json(f.evidence),
      "proposal" => json(f.proposal),
      "confidence" => Atom.to_string(f.confidence),
      "confidence_reason" => f.confidence_reason,
      "affects" => json(f.affects),
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
