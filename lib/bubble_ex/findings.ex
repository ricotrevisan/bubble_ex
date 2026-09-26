defmodule BubbleEx.Findings do
  @moduledoc """
  Deterministic model-refinement analyzers over decoded Bubble app JSON.

      {:ok, %BubbleEx.Findings{findings: findings, diagnostics: diagnostics}} =
        BubbleEx.Findings.analyze(app)

  Each analyzer looks for a Bubble workaround and emits `BubbleEx.Finding`s:
  what it found (symbols and references from `BubbleEx.Index`), the
  stack-neutral transformation it proposes, how confident it is and why, and
  the workflows, pages, reusables and privacy rules the change touches. The
  model stays source-faithful; findings wait for the owner's decisions. No
  LLM is involved.

  | Kind | Category | Proposes |
  |------|----------|----------|
  | `:redundant_reverse_list` | decision | derive a maintained `list of A` on B from A's reference to B |
  | `:denormalized_field` | decision | derive a copied or counted value; drop exactly its maintaining writes |
  | `:list_relationship` | decision | a join for a used `list of things` (10,000-item cap) |
  | `:privacy_access_list` | decision | a membership join and access rule for a `list of User` checked by privacy rules |
  | `:id_in_text` | decision | a reference for a text field holding unique IDs of an app data type |
  | `:search_index` | hint | per data type, the indexes (access patterns) its searches need |
  | `:number_type` | decision | an integer for a number field whose every write is integral |
  | `:plugin` | decision | per marketplace plugin: drop it, replace it with a known native equivalent, or rebuild it |

  A `:plugin` finding covers one plugin (installed or used) as a whole: its
  evidence lists the members used (element, action and event types, with
  counts) and every use (`BubbleEx.Plugins.Inventory`); `proposal.options`
  are the choices open to the owner and `proposal.option` the suggested one
  (a `modify` picks another, `BubbleEx.Decision.Params`).

  A `list of things` field gets at most one of `:redundant_reverse_list`,
  `:privacy_access_list` and `:list_relationship`, in that order of
  precedence. Two lists mirroring each other (A's list of B and B's list of
  A) are one many-to-many: their findings name the same `join` in the
  proposal and list each other in `related`.

  The analyzers cover what the index sees: writes by actions whose target
  type is unresolved (see the diagnostics) are missing, so a finding can
  overlook a writer. Unused fields and dangling references need typed model
  reads or loaded data and are not analyzed yet.

  `diagnostics` are the index's (`BubbleEx.Index`): what the analyzers could
  not see.

  ## Options

    * `:index` - a `BubbleEx.Index` already built from the same app (its
      `source_sha256` must match the app; otherwise `:invalid_input`). Its
      Model is reused.
    * `:model` - a `BubbleEx.Model` already built from the same app
      (checked with `BubbleEx.Model.matches?/3`; otherwise `:invalid_input`),
      used for the index when none is given and for typing expressions.
      Without either, the Model is built once, here.
    * `:kinds` - only these kinds (default: all, see `BubbleEx.Finding.Kinds`).
      A kind's findings do not depend on which other kinds are requested.
  """

  alias BubbleEx.{CanonicalJson, Diagnostic, Error, Finding, Index, Model}
  alias BubbleEx.Finding.Kinds

  alias BubbleEx.Findings.{
    Context,
    Denormalized,
    IdInText,
    Joins,
    ListRelationship,
    NumberType,
    Plugin,
    PrivacyAccess,
    ReverseList,
    SearchIndex
  }

  @enforce_keys [:findings, :diagnostics]
  defstruct [:findings, :diagnostics, :index_sha256]

  @type t :: %__MODULE__{
          findings: [Finding.t()],
          diagnostics: [Diagnostic.t()],
          index_sha256: String.t() | nil
        }

  @type option :: {:index, Index.t()} | {:model, Model.t()} | {:kinds, [atom()]}

  @doc "Runs the analyzers over decoded app JSON."
  @spec analyze(term(), [option()]) :: {:ok, t()} | {:error, Error.t()}
  def analyze(app, opts \\ []) do
    with {:ok, kinds} <- kinds(Keyword.get(opts, :kinds, Kinds.all())),
         {:ok, index} <- index(app, Keyword.get(opts, :index), Keyword.get(opts, :model)),
         {:ok, model} <- model(app, Keyword.get(opts, :model), index) do
      ctx = Context.build(app, index, model)

      findings =
        ctx
        |> all_findings()
        |> Enum.filter(&(&1.kind in kinds))
        |> Enum.map(&Finding.put_basis(&1, index))
        |> Finding.normalize()

      {:ok,
       %__MODULE__{
         findings: findings,
         diagnostics: index.diagnostics,
         index_sha256: index.semantic_sha256
       }}
    end
  end

  # Every kind always runs, so a kind's findings never depend on which
  # kinds were requested (list findings defer to reverse-list and
  # privacy-access ones).
  defp all_findings(ctx) do
    reverse = ReverseList.run(ctx)
    one_to_many = MapSet.new(reverse, & &1.proposal.drop_field)
    joins = Joins.build(ctx, one_to_many)
    privacy = PrivacyAccess.run(ctx, joins)
    covered = MapSet.union(one_to_many, MapSet.new(privacy, & &1.proposal.field))
    lists = ListRelationship.run(ctx, covered, joins)

    link_joins(reverse ++ privacy ++ lists) ++
      Denormalized.run(ctx) ++
      IdInText.run(ctx) ++ SearchIndex.run(ctx) ++ NumberType.run(ctx) ++ Plugin.run(ctx)
  end

  # Findings whose proposals share a join are related to each other.
  defp link_joins(findings) do
    by_join =
      findings
      |> Enum.filter(&Map.has_key?(&1.proposal, :join))
      |> Enum.group_by(& &1.proposal.join.id, & &1.id)

    Enum.map(findings, fn
      %{proposal: %{join: %{id: join}}} = f -> Finding.put_related(f, by_join[join] -- [f.id])
      f -> f
    end)
  end

  defp kinds(kinds) when is_list(kinds) do
    case Enum.reject(kinds, &Kinds.registered?/1) do
      [] -> {:ok, Enum.uniq(kinds)}
      unknown -> {:error, Error.new(:invalid_input, "unknown finding kinds", %{kinds: unknown})}
    end
  end

  defp kinds(other),
    do: {:error, Error.new(:invalid_input, "kinds must be a list", %{kinds: other})}

  # With an index (already checked against the app's hash), a given model is
  # checked against that hash, else the index's Model is reused. Without
  # one, the index checks or builds the Model.
  defp model(app, model, %Index{source_sha256: sha} = index) when is_map(app) do
    case {model, index.model} do
      {nil, %Model{} = own} -> {:ok, own}
      _ -> Model.for_app(app, model, source_sha256: sha)
    end
  end

  defp model(_app, model, _index), do: {:ok, model}

  defp index(app, nil, model) when is_map(app), do: Index.build(app, model: model)

  defp index(app, %Index{} = index, _model) when is_map(app) do
    if index.source_sha256 == CanonicalJson.sha256(app),
      do: {:ok, index},
      else: {:error, Error.new(:invalid_input, "index was built from a different app")}
  end

  defp index(app, _, _) when is_map(app),
    do: {:error, Error.new(:invalid_input, "index must be a BubbleEx.Index")}

  defp index(_, _, _),
    do: {:error, Error.new(:invalid_input, "expected a decoded app JSON object")}

  @doc "Counts of findings by kind and confidence."
  @spec summary(t()) :: %{atom() => %{Finding.confidence() => pos_integer()}}
  def summary(%__MODULE__{findings: findings}) do
    findings
    |> Enum.group_by(& &1.kind)
    |> Map.new(fn {kind, fs} -> {kind, Enum.frequencies_by(fs, & &1.confidence)} end)
  end

  @doc "Plain-map JSON form of the result."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      "findings" => Enum.map(result.findings, &Finding.to_map/1),
      "diagnostics" => Enum.map(result.diagnostics, &Diagnostic.to_map/1),
      "index_sha256" => result.index_sha256
    }
  end
end
