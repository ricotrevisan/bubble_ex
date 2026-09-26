defmodule BubbleEx.Findings.Plugin do
  @moduledoc false

  # `:plugin` - one decision finding per marketplace plugin the app installs
  # or uses (`BubbleEx.Plugins.Inventory`). A plugin is one decision because
  # it is one dependency: it is installed, versioned and replaced as a whole,
  # and the plan has one task per plugin that its users wait for (WTF-359
  # §2.10). The members the app uses (element, action and event types, with
  # counts) are evidence, so an owner sees how much of the plugin a choice
  # affects.
  #
  # Options (`proposal.options`, in this order):
  #
  #   * `:drop` - always: remove the plugin and every use of it
  #   * `:replace_native` - when `BubbleEx.Plugins.Catalog` knows an
  #     equivalent (`proposal.equivalent`) and the plugin is used
  #   * `:rebuild` - when the plugin is used
  #
  # Suggested (`proposal.option`): `:drop` for an installed plugin nothing
  # uses (confidence high), else `:replace_native` when known, else
  # `:rebuild` (medium; low when the plugin is used but not installed).

  alias BubbleEx.{Finding, Index}
  alias BubbleEx.Findings.Context
  alias BubbleEx.Plugins.{Catalog, Inventory}

  @spec run(Context.t()) :: [Finding.t()]
  def run(ctx) do
    for entry <- Inventory.build(ctx.index), do: finding(ctx, entry)
  end

  defp finding(ctx, entry) do
    used? = Inventory.used?(entry)

    equivalent =
      case Catalog.fetch(entry.bubble_id) do
        {:ok, %{equivalent: e}} when used? -> e
        _ -> nil
      end

    options =
      [:drop] ++
        if(equivalent, do: [:replace_native], else: []) ++ if(used?, do: [:rebuild], else: [])

    {option, confidence, reason} =
      cond do
        not used? ->
          {:drop, :high, "installed, but nothing in the app uses it"}

        not entry.installed ->
          {suggest(equivalent), :low,
           "used, but not among the installed plugins (a development or removed version)"}

        equivalent ->
          {:replace_native, :medium,
           "a known native equivalent (#{equivalent}) covers this plugin; check the members used"}

        true ->
          {:rebuild, :medium, "no known native equivalent"}
      end

    users = entry.elements ++ entry.actions ++ entry.events

    Finding.new(:plugin, %{plugin: entry.bubble_id},
      path: Index.symbol(ctx.index, entry.plugin).path,
      evidence: %{
        symbols: [entry.plugin | users],
        references: entry.references,
        installed: entry.installed,
        version: entry.version,
        members: entry.members,
        counts: entry.counts
      },
      proposal: %{
        transform: :replace_plugin,
        plugin: entry.plugin,
        option: option,
        options: options,
        equivalent: equivalent
      },
      confidence: confidence,
      confidence_reason: reason,
      affects: Context.affects(ctx, users ++ Enum.map(entry.state_reads, & &1.from), []),
      message: message(entry, option, equivalent)
    )
  end

  defp suggest(nil), do: :rebuild
  defp suggest(_equivalent), do: :replace_native

  defp message(entry, option, equivalent) do
    name = if entry.name, do: "“#{entry.name}” (#{entry.bubble_id})", else: entry.bubble_id
    c = entry.counts

    usage =
      if Inventory.used?(entry),
        do:
          "used by #{c.elements} elements, #{c.actions} actions and #{c.events} events " <>
            "on #{c.surfaces} pages or reusables and in #{c.workflows} workflows",
        else: "installed but unused"

    "Plugin #{name} is #{usage}; " <>
      case option do
        :drop -> "drop it"
        :replace_native -> "replace it with a native #{equivalent}"
        :rebuild -> "rebuild what the app uses of it"
      end
  end
end
