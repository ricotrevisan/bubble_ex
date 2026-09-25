defmodule BubbleEx.Finding.Kinds do
  # The single registry of finding kinds. A kind fixes which proposal
  # transforms a `BubbleEx.Finding` of that kind may carry:
  # `BubbleEx.Finding.new/3` raises on an unregistered kind or transform.
  # A test scans `lib/` for emitted kinds and requires this registry to match.

  @kinds [
    {:redundant_reverse_list, [:derive_reverse_relationship],
     "a list of A on B mirrors a scalar reference from A to B and is maintained by workflows; derive it instead"},
    {:denormalized_field, [:derive_calculation, :derive_aggregate],
     "a scalar field whose writes copy (or count) a value read from a related record; derive it and drop the maintaining writes"},
    {:list_relationship, [:extract_join_resource],
     "a list of things; model it as a join resource (Bubble lists also cap at 10,000 items)"},
    {:privacy_access_list, [:membership_policy],
     "a list of users that privacy rules test for access; model it as a membership relationship with a membership-based policy"},
    {:id_in_text, [:text_to_reference],
     "a text field holding unique IDs (written from `unique id` or compared with one); make it a reference"},
    {:search_index, [:add_index],
     "a field constrained or sorted on by database searches; index it for the operators used"},
    {:number_type, [:refine_number_type],
     "a number field whose every write is integral (counts, integer literals, integer increments); store it as an integer"}
  ]

  @registry Map.new(@kinds, fn {kind, transforms, doc} ->
              {kind, %{transforms: transforms, doc: doc}}
            end)

  if map_size(@registry) != length(@kinds), do: raise("duplicate finding kind")

  @table Enum.map_join(@kinds, "\n", fn {kind, transforms, doc} ->
           "| `#{inspect(kind)}` | #{Enum.map_join(transforms, ", ", &"`#{inspect(&1)}`")} | #{doc} |"
         end)

  @moduledoc """
  The single finding kind registry. Each kind names the proposal transforms a
  `BubbleEx.Finding` of that kind may carry.

  | Kind | Transforms | Meaning |
  |------|------------|---------|
  #{@table}
  """

  @type entry :: %{transforms: [atom()], doc: String.t()}

  @doc "Every registered kind, in registry order."
  @spec all() :: [atom()]
  def all, do: Enum.map(@kinds, &elem(&1, 0))

  @doc "The registry entry for `kind`, or `:error`."
  @spec fetch(atom()) :: {:ok, entry()} | :error
  def fetch(kind), do: Map.fetch(@registry, kind)

  @doc "Whether `kind` is registered."
  @spec registered?(atom()) :: boolean()
  def registered?(kind), do: is_map_key(@registry, kind)
end
