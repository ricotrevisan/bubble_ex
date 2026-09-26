defmodule BubbleEx.Finding.Kinds do
  # The single registry of finding kinds. A kind fixes the category and the
  # proposal transforms a `BubbleEx.Finding` of that kind may carry:
  # `BubbleEx.Finding.new/3` raises on an unregistered kind or transform.
  # A test scans `lib/` for emitted kinds and requires this registry to match.

  # {kind, category, transforms, meaning}
  @kinds [
    {:redundant_reverse_list, :decision, [:derive_reverse_relationship],
     "a list of A on B mirrors a scalar reference from A to B and is maintained by workflows; derive it instead"},
    {:denormalized_field, :decision, [:derive_from_related, :derive_count],
     "a scalar field every write of which copies (or counts) a value of the same or a related record; derive it and drop the maintaining writes"},
    {:list_relationship, :decision, [:normalize_list_to_join],
     "a list of things that is used; model it as a join between the two types (Bubble lists also cap at 10,000 items)"},
    {:privacy_access_list, :decision, [:membership_policy],
     "a list of users that privacy rules test for access; model it as a membership join with a membership-based access rule"},
    {:id_in_text, :decision, [:text_to_reference],
     "a text field holding unique IDs of an app data type (written from `unique id` or compared with one); make it a reference"},
    {:search_index, :hint, [:add_indexes],
     "the access patterns database searches use on a data type (equality columns, ranges, sorts, membership, text and geographic search); a performance hint"},
    {:number_type, :decision, [:refine_number_type],
     "a number field whose every write is integral (counts, integer literals, integer increments); store it as an integer"},
    {:plugin, :decision, [:replace_plugin],
     "a marketplace plugin the app installs or uses; drop it, replace it with a known native equivalent or rebuild it"}
  ]

  @categories [:decision, :hint]

  @registry Map.new(@kinds, fn {kind, category, transforms, doc} ->
              {kind, %{category: category, transforms: transforms, doc: doc}}
            end)

  if map_size(@registry) != length(@kinds), do: raise("duplicate finding kind")

  if Enum.any?(@kinds, fn {_, category, _, _} -> category not in @categories end),
    do: raise("unknown finding category")

  @table Enum.map_join(@kinds, "\n", fn {kind, category, transforms, doc} ->
           "| `#{inspect(kind)}` | `#{inspect(category)}` | #{Enum.map_join(transforms, ", ", &"`#{inspect(&1)}`")} | #{doc} |"
         end)

  @moduledoc """
  The single finding kind registry. Each kind fixes the category and the
  proposal transforms of every `BubbleEx.Finding` of that kind.

  Categories: `:decision` findings propose a model change the owner decides
  on; `:hint` findings are performance hints a target adapter may apply
  without asking.

  | Kind | Category | Transforms | Meaning |
  |------|----------|------------|---------|
  #{@table}

  Transforms (stack-neutral; a target adapter decides how to render them):

    * `:derive_reverse_relationship` - drop a list and derive it from the
      other type's reference to this one (one-to-many)
    * `:derive_from_related` - drop a stored copy and compute it from a field
      reached through references
    * `:derive_count` - drop a stored count and compute it from a list
    * `:normalize_list_to_join` - replace a list of IDs with a join between
      the two types; both sides of one many-to-many share one join
    * `:membership_policy` - grant access by membership in a join instead of
      a stored user list
    * `:text_to_reference` - store a reference instead of an ID as text
    * `:add_indexes` - index the listed access patterns
    * `:refine_number_type` - store a number as an integer
    * `:replace_plugin` - carry out `proposal.option` for a plugin, one of
      `proposal.options`: `:drop` (remove the plugin and every use of it:
      its elements render nothing, its actions are skipped, workflows its
      events trigger never run), `:replace_native` (its uses become
      `proposal.equivalent`, see `BubbleEx.Plugins.Catalog`) or `:rebuild`
      (an agent rebuilds what the app uses of it)
  """

  @type category :: :decision | :hint
  @type entry :: %{category: category(), transforms: [atom()], doc: String.t()}

  @doc "Every registered kind, in registry order."
  @spec all() :: [atom()]
  def all, do: Enum.map(@kinds, &elem(&1, 0))

  @doc "The finding categories."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "The registry entry for `kind`, or `:error`."
  @spec fetch(atom()) :: {:ok, entry()} | :error
  def fetch(kind), do: Map.fetch(@registry, kind)

  @doc "Whether `kind` is registered."
  @spec registered?(atom()) :: boolean()
  def registered?(kind), do: is_map_key(@registry, kind)
end
