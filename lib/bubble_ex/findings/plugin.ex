defmodule BubbleEx.Findings.Plugin do
  @moduledoc false

  # `:plugin` - one decision finding per marketplace plugin the app installs
  # or uses (`BubbleEx.Plugins.Inventory`). A plugin is one decision because
  # it is one dependency: it is installed, versioned and replaced as a whole,
  # and the plan has one task per plugin that its users wait for (WTF-359
  # §2.10).
  #
  # What a decision is about is the plugin and the SET of its features the
  # app uses (`proposal.features`: element, action, event and data types,
  # and element types whose states are read), not the individual uses: a
  # new icon of an already used icon type does not make a decision stale; a
  # newly used feature does. Uses, counts and the workflows its events
  # trigger are evidence facts (outside `proposal_sha256`); `basis_sha256`
  # is the plugin symbol (its installed version).
  #
  # Options (`proposal.options`, in this order):
  #
  #   * `:drop` - always: remove the plugin's elements and actions. A
  #     workflow one of its events triggers goes too when the plugin's
  #     actions are all it runs; one that runs other actions keeps its body
  #     and needs a new trigger (`evidence.rewire`), unless the decision
  #     lists it in `delete_workflows`
  #   * `:replace_native` - the plugin is used and `BubbleEx.Plugins.Catalog`
  #     has an equivalent for every feature used (`features[].equivalent`)
  #   * `:rebuild` - the plugin is used
  #
  # Suggested (`proposal.option`): `:drop` for a plugin nothing uses (high),
  # else `:replace_native` when offered (medium; low when an equivalent is a
  # code-level port), else `:rebuild` (medium; low when the plugin is used
  # but not installed).

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Findings.Context
  alias BubbleEx.Plugins.{Catalog, Inventory}

  @spec run(Context.t()) :: [Finding.t()]
  def run(ctx) do
    for entry <- Inventory.build(ctx.index), do: finding(ctx, entry)
  end

  defp finding(ctx, entry) do
    used? = Inventory.used?(entry)

    features =
      Enum.map(entry.features, &Map.put(&1, :equivalent, equivalent(entry.bubble_id, &1)))

    native? = used? and Enum.all?(features, & &1.equivalent)
    code_level? = Enum.any?(features, &(&1.equivalent && Catalog.code_level?(&1.equivalent)))
    options = options(used?, native?)
    {option, confidence, reason} = suggest(used?, entry.installed, native?, code_level?)

    {rewire, event_only} = event_workflows(ctx.index, entry)
    users = entry.elements ++ entry.actions ++ entry.events ++ entry.data_types
    readers = Enum.map(entry.state_reads ++ entry.step_reads, & &1.from)

    Finding.new(:plugin, %{plugin: entry.bubble_id},
      path: Index.symbol(ctx.index, entry.plugin).path,
      evidence: %{
        symbols: [entry.plugin],
        references: [],
        installed: entry.installed,
        version: entry.version,
        members: entry.members,
        counts: entry.counts,
        uses: %{
          elements: entry.elements,
          actions: entry.actions,
          events: entry.events,
          data_types: entry.data_types
        },
        rewire: rewire,
        event_only: event_only
      },
      proposal: %{
        transform: :replace_plugin,
        plugin: entry.plugin,
        option: option,
        options: options,
        features: features
      },
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, users ++ readers, []),
      message: message(entry, option)
    )
  end

  defp options(used?, native?),
    do:
      [:drop] ++
        if(native?, do: [:replace_native], else: []) ++ if(used?, do: [:rebuild], else: [])

  defp suggest(false, _installed?, _native?, _code_level?),
    do: {:drop, :high, "installed, but nothing in the app uses it"}

  defp suggest(true, false, native?, _code_level?),
    do:
      {if(native?, do: :replace_native, else: :rebuild), :low,
       "used, but not among the installed plugins (a development or removed version)"}

  defp suggest(true, true, true, true),
    do:
      {:replace_native, :low,
       "the features used run the app author's code: port it by hand, feature by feature"}

  defp suggest(true, true, true, false),
    do: {:replace_native, :medium, "a standard component covers every feature used"}

  defp suggest(true, true, false, _code_level?),
    do: {:rebuild, :medium, "no known native equivalent for every feature used"}

  defp equivalent(plugin, %{role: _, code: code}), do: Catalog.equivalent(plugin, code)

  # Workflows the plugin's events trigger: those running other actions too
  # (`rewire`: kept with a new trigger when the plugin is dropped) and those
  # running only the plugin's actions, or none (`event_only`).
  defp event_workflows(index, entry) do
    own = MapSet.new(entry.actions)

    entry.events
    |> Enum.split_with(fn w ->
      index
      |> Index.children(w)
      |> Enum.any?(&(&1.kind == :action and not MapSet.member?(own, &1.id)))
    end)
  end

  defp message(entry, option) do
    name = if entry.name, do: "“#{entry.name}” (#{entry.bubble_id})", else: entry.bubble_id
    c = entry.counts

    usage =
      if Inventory.used?(entry),
        do:
          "used by #{c.elements} elements, #{c.actions} actions and #{c.events} events " <>
            "on #{c.surfaces} pages or reusables and in #{c.workflows} workflows " <>
            "(#{length(entry.features)} features)",
        else: "installed but unused"

    "Plugin #{name} is #{usage}; " <>
      case option do
        :drop -> "drop it"
        :replace_native -> "replace it with native equivalents"
        :rebuild -> "rebuild what the app uses of it"
      end
  end
end
