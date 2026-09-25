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

  | Kind | Proposes |
  |------|----------|
  | `:redundant_reverse_list` | derive a maintained `list of A` on B from A's reference to B |
  | `:denormalized_field` | derive a copied or counted value (calculation or aggregate); drop its maintaining writes |
  | `:list_relationship` | a join resource for a `list of things` (10,000-item cap) |
  | `:privacy_access_list` | a membership relationship and policy for a `list of User` checked by privacy rules |
  | `:id_in_text` | a reference for a text field holding unique IDs |
  | `:search_index` | indexes for the fields searches constrain or sort on, by operator |
  | `:number_type` | an integer for a number field whose every write is integral |

  A `list of things` field gets at most one of `:redundant_reverse_list`,
  `:privacy_access_list` and `:list_relationship`, in that order of
  precedence. The analyzers cover what the index sees: writes by actions
  whose target type is unresolved (see the diagnostics) are missing, so a
  finding can overlook a writer. Unused fields and dangling references need
  typed model reads or loaded data and are not analyzed yet.

  `diagnostics` are the index's (`BubbleEx.Index`): what the analyzers could
  not see.

  ## Options

    * `:index` - a `BubbleEx.Index` already built from the same app
    * `:kinds` - only these kinds (default: all, see `BubbleEx.Finding.Kinds`).
      A kind's findings do not depend on which other kinds are requested.
  """

  alias BubbleEx.{Diagnostic, Error, Finding, Index}
  alias BubbleEx.Finding.Kinds

  alias BubbleEx.Findings.{
    Context,
    Denormalized,
    IdInText,
    ListRelationship,
    NumberType,
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

  @type option :: {:index, Index.t()} | {:kinds, [atom()]}

  @doc "Runs the analyzers over decoded app JSON."
  @spec analyze(term(), [option()]) :: {:ok, t()} | {:error, Error.t()}
  def analyze(app, opts \\ []) do
    with {:ok, kinds} <- kinds(Keyword.get(opts, :kinds, Kinds.all())),
         {:ok, index} <- index(app, Keyword.get(opts, :index)) do
      ctx = Context.build(app, index)
      reverse = ReverseList.run(ctx)
      privacy = PrivacyAccess.run(ctx)

      covered =
        MapSet.new(reverse ++ privacy, fn f -> f.proposal[:drop_field] || f.proposal[:field] end)

      runs = %{
        redundant_reverse_list: fn -> reverse end,
        privacy_access_list: fn -> privacy end,
        list_relationship: fn -> ListRelationship.run(ctx, covered) end,
        denormalized_field: fn -> Denormalized.run(ctx) end,
        id_in_text: fn -> IdInText.run(ctx) end,
        search_index: fn -> SearchIndex.run(ctx) end,
        number_type: fn -> NumberType.run(ctx) end
      }

      findings = kinds |> Enum.flat_map(&Map.fetch!(runs, &1).()) |> Finding.normalize()

      {:ok,
       %__MODULE__{
         findings: findings,
         diagnostics: index.diagnostics,
         index_sha256: index.semantic_sha256
       }}
    end
  end

  defp kinds(kinds) when is_list(kinds) do
    case Enum.reject(kinds, &Kinds.registered?/1) do
      [] -> {:ok, Enum.uniq(kinds)}
      unknown -> {:error, Error.new(:invalid_input, "unknown finding kinds", %{kinds: unknown})}
    end
  end

  defp kinds(other),
    do: {:error, Error.new(:invalid_input, "kinds must be a list", %{kinds: other})}

  defp index(app, nil) when is_map(app), do: Index.build(app)
  defp index(app, %Index{} = index) when is_map(app), do: {:ok, index}

  defp index(app, _) when is_map(app),
    do: {:error, Error.new(:invalid_input, "index must be a BubbleEx.Index")}

  defp index(_, _), do: {:error, Error.new(:invalid_input, "expected a decoded app JSON object")}

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
