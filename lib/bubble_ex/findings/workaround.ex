defmodule BubbleEx.Findings.Workaround do
  @moduledoc false

  # `:workaround_element` (category `:default`, WTF-586) - one finding per
  # tiny or never-visible element of `BubbleEx.Workarounds.catalog/2`: its
  # class, the lowering it suggests (`proposal.option`, one of
  # `proposal.options`) and the facts behind it (`evidence`). A `:high`
  # confidence finding applies by default; any other waits for the owner,
  # who may also override a default (`modify` with another `option`, or
  # `reject` to keep the markup).
  #
  # The decision is about the element and its class, so `proposal` holds
  # the class and options, and the facts (who sets and reads it, its
  # events and plugins) are evidence: a new reader does not make a decision
  # stale, a new class does.

  alias BubbleEx.{Finding, Workarounds}
  alias BubbleEx.Findings.Context

  @spec run(Context.t()) :: [Finding.t()]
  def run(ctx) do
    for entry <- Workarounds.catalog(ctx.app, ctx.index), do: finding(ctx, entry)
  end

  defp finding(ctx, entry) do
    readers = Enum.map(entry.readers, & &1.from)
    maintainers = Enum.map(entry.setters, & &1.action)

    Finding.new(:workaround_element, %{element: entry.element},
      path: entry.path,
      evidence: %{
        symbols: [entry.symbol],
        references: [],
        surface: entry.surface,
        type: entry.type,
        signals: entry.signals,
        tiny: entry.tiny,
        inside: entry.inside,
        setters: entry.setters,
        readers: entry.readers,
        events: entry.events,
        plugins: entry.plugins,
        data_source: entry.data_source,
        custom_states: entry.custom_states,
        properties: entry.properties,
        conditionals: entry.conditionals,
        contents: entry.contents,
        script: entry.script
      },
      proposal: proposal(entry),
      confidence: entry.confidence,
      confidence_reason: entry.reason,
      affects: Context.affects(ctx, [entry.symbol | readers], maintainers),
      message: message(entry)
    )
  end

  # An unused element names the unused one holding it (`Workarounds.skipped/1`
  # skips them together); other proposals are as they were.
  defp proposal(entry) do
    proposal = %{
      transform: :lower_workaround,
      element: entry.symbol,
      type: entry.type,
      holds: entry.held,
      class: entry.class,
      option: entry.option,
      options: entry.options
    }

    if entry.class == :unused, do: Map.put(proposal, :inside, entry.unused_inside), else: proposal
  end

  defp message(entry) do
    what =
      case entry.signals do
        [:tiny, :never_visible] -> "tiny and never visible"
        [:tiny] -> "tiny"
        [:never_visible] -> "never visible"
      end

    "#{entry.type || "Element"} #{entry.element} is #{what}: " <>
      case entry.class do
        :unknown ->
          "what it is for is unclear (#{entry.reason}); keep its markup unless the owner decides"

        :unused ->
          "unused (#{entry.reason}); it is not generated unless the owner keeps it"

        class ->
          "a #{class |> Atom.to_string() |> String.replace("_", " ")} (#{entry.reason}); lower it as #{entry.option}"
      end
  end
end
