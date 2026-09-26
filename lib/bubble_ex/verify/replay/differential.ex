defmodule BubbleEx.Verify.Replay.Differential do
  @moduledoc """
  Differential masking (WTF-358 §3.7): the same scenario recorded in two
  (or more) runs, each from a fresh seed. Observations every run agrees on
  are kept; where runs disagree, the differing parts are masked
  (`BubbleEx.Verify.Mask`, reason `differential`) when a mask may cover
  them, and the observation is **unstable** otherwise.

  What may be masked follows the V1 rules (`Mask.check_class/2`):

    * never a whole observation (a difference at the root is unstable)
    * in privacy, data and auth scenarios, never a verdict: a differing
      `visible`, `visible_fields` or `record_set` is unstable, and a
      differing `values` observation is masked field by field
      (`/<field ID>`), never deeper or wider
    * elsewhere, the differing leaves (JSON pointers into the value)

  A scenario with an unstable observation cannot yield a complete
  recording: nondeterminism in the verdict itself needs a human. The
  observations kept are the first run's.
  """

  alias BubbleEx.Verify.{Mask, Observation}

  @verdicts [:visible, :visible_fields, :record_set]

  @type merged :: %{
          observations: [Observation.t()],
          masks: [Mask.t()],
          unstable: [%{op: String.t(), kind: atom(), record: String.t() | nil, why: atom()}]
        }

  @doc "Merges the observations of each run (`runs`, a list of lists) for a check class."
  @spec merge([[Observation.t()]], atom()) :: merged()
  def merge([first | _] = runs, class) do
    by_run = Enum.map(runs, &Map.new(&1, fn o -> {Observation.key(o), o} end))
    keys = by_run |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()
    firsts = Map.new(first, &{Observation.key(&1), &1})

    {masks, unstable} =
      Enum.reduce(keys, {[], []}, fn key, {masks, unstable} ->
        case compare(key, Enum.map(by_run, &Map.get(&1, key)), class) do
          {:ok, new} -> {new ++ masks, unstable}
          {:unstable, why} -> {masks, [unstable(key, why) | unstable]}
        end
      end)

    %{
      observations: keys |> Enum.map(&firsts[&1]) |> Enum.reject(&is_nil/1),
      masks: Mask.sort(masks),
      unstable: Enum.reverse(unstable)
    }
  end

  defp unstable({op, kind, record}, why), do: %{op: op, kind: kind, record: record, why: why}

  defp compare(key, observations, class) do
    if Enum.any?(observations, &is_nil/1) do
      {:unstable, :missing_in_a_run}
    else
      [a | others] = Enum.map(observations, &Observation.value_json/1)
      pointers = others |> Enum.flat_map(&diff(a, &1, "")) |> Enum.uniq()
      masks_for(key, pointers, class)
    end
  end

  defp masks_for(_key, [], _class), do: {:ok, []}

  defp masks_for({_op, kind, _record} = key, pointers, class) do
    cond do
      class in [:privacy, :data, :auth] and kind in @verdicts ->
        {:unstable, :verdict_differs}

      "" in pointers ->
        {:unstable, :whole_value_differs}

      class in [:privacy, :data, :auth] and kind == :values ->
        {:ok, pointers |> Enum.map(&top_level/1) |> Enum.uniq() |> Enum.map(&mask(key, &1))}

      true ->
        {:ok, Enum.map(pointers, &mask(key, &1))}
    end
  end

  defp top_level("/" <> rest), do: "/" <> (rest |> String.split("/") |> hd())

  defp mask({op, kind, record}, pointer),
    do: %Mask{op: op, kind: kind, record: record, pointer: pointer, reason: :differential}

  @doc """
  JSON pointers (RFC 6901) of the parts where two JSON values differ: the
  deepest differing members and items (`""` when the roots differ in kind
  or, for lists, in length).
  """
  @spec diff(term(), term(), String.t()) :: [String.t()]
  def diff(a, a, _path), do: []

  def diff(a, b, path) when is_map(a) and is_map(b) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn k -> diff(Map.get(a, k), Map.get(b, k), path <> "/" <> escape(k)) end)
  end

  def diff(a, b, path) when is_list(a) and is_list(b) and length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{x, y}, i} -> diff(x, y, "#{path}/#{i}") end)
  end

  def diff(_a, _b, path), do: [path]

  defp escape(k), do: k |> to_string() |> String.replace("~", "~0") |> String.replace("/", "~1")

  @doc "Share of observations with at least one mask (0.0 when there are none)."
  @spec masked_share(merged()) :: float()
  def masked_share(%{observations: []}), do: 0.0

  def masked_share(%{observations: obs, masks: masks}) do
    masked = Enum.count(obs, fn o -> Enum.any?(masks, &Mask.covers?(&1, o)) end)
    masked / length(obs)
  end
end
