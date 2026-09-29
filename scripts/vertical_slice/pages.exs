# Page statistics and the median-page choice of a vertical slice (WTF-378),
# over a built pipeline (scripts/vertical_slice/pipeline.exs).
#
# A page's size counts what the page renders: its own elements plus those
# of every reusable element it renders, transitively (a page made of
# reusables is as large as they are), its workflows and theirs, and the
# data sources of all of them. The median page is the one closest to the
# median on all three at once: each metric is turned into a percentile rank
# among the app's pages (ties share their average rank), and the page with
# the smallest sum of distances to the 50th percentile wins (ties: fewer
# elements, then Bubble ID). Pages with no workflow or no data source are
# not candidates: a slice must exercise both.
defmodule VerticalSlice.Pages do
  @moduledoc false

  alias BubbleEx.Target.Elixir.FrontendWorkflows.Spec

  @metrics [:elements, :workflows, :data_sources]

  def criteria do
    """
    median page: size = own elements + elements of every reusable it renders
    (transitively), workflows (its own and its reusables'), data sources (idem);
    percentile rank per metric among all pages (ties averaged); candidates have
    >= 1 workflow and >= 1 data source; winner = smallest sum of |rank - 0.5|
    (ties: fewer elements, then Bubble ID)
    """
  end

  @doc "One row of statistics per page (not mobile views), sorted by Bubble ID."
  def stats(%{spec: spec, app: app}) do
    names = for {_k, p} <- app["pages"] || %{}, into: %{}, do: {p["id"], p["name"]}
    by_surface = Enum.group_by(spec.elements, fn {_, e} -> e.surface end)

    for {id, %{kind: :page}} <- spec.surfaces do
      reusables = reusables(id, by_surface)
      surfaces = [id | reusables]
      workflows = Enum.flat_map(surfaces, &surface_workflows(spec, &1))
      data = Enum.flat_map(surfaces, &(Spec.data(spec, &1) || []))
      steps = Enum.flat_map(workflows, & &1.steps)

      %{
        id: id,
        name: names[id],
        own_elements: length(Map.get(by_surface, id, [])),
        elements: Enum.sum(for s <- surfaces, do: length(Map.get(by_surface, s, []))),
        reusables: reusables,
        workflows: length(workflows),
        steps: length(steps),
        native: Enum.count(workflows, &Spec.native?/1),
        wired: Enum.count(workflows, &Spec.wired?/1),
        data_workflows: Enum.count(workflows, & &1.data?),
        data_sources: length(data),
        data_wired: Enum.count(data, &(&1.residue == [])),
        backend_schedules: Enum.count(steps, &(&1.op in [:schedule, :schedule_list]))
      }
    end
    |> Enum.sort_by(& &1.id)
  end

  @doc "`{chosen, ranked candidates}`: the median page and every candidate by score."
  def choose(rows) do
    ranks = for m <- @metrics, into: %{}, do: {m, percentiles(rows, m)}

    ranked =
      rows
      |> Enum.filter(&(&1.workflows > 0 and &1.data_sources > 0))
      |> Enum.map(fn row ->
        score = Enum.sum(for m <- @metrics, do: abs(ranks[m][row.id] - 0.5))
        Map.put(row, :score, Float.round(score, 4))
      end)
      |> Enum.sort_by(&{&1.score, &1.elements, &1.id})

    {List.first(ranked), ranked}
  end

  defp percentiles(rows, metric) do
    n = length(rows)
    sorted = rows |> Enum.map(&Map.fetch!(&1, metric)) |> Enum.sort()

    for row <- rows, into: %{} do
      v = Map.fetch!(row, metric)
      below = Enum.count(sorted, &(&1 < v))
      equal = Enum.count(sorted, &(&1 == v))
      rank = below + (equal - 1) / 2
      {row.id, if(n > 1, do: rank / (n - 1), else: 0.5)}
    end
  end

  defp surface_workflows(spec, id) do
    case spec.surfaces[id] do
      %{workflows: w} -> w
      _ -> []
    end
  end

  # Every reusable element a surface renders, transitively, sorted.
  defp reusables(id, by_surface), do: reusables([id], by_surface, MapSet.new())

  defp reusables([], _by_surface, seen), do: seen |> MapSet.to_list() |> Enum.sort()

  defp reusables([h | t], by_surface, seen) do
    new =
      for {_, %{instance_of: r}} <- Map.get(by_surface, h, []),
          is_binary(r),
          not MapSet.member?(seen, r),
          uniq: true,
          do: r

    reusables(t ++ new, by_surface, MapSet.union(seen, MapSet.new(new)))
  end
end
