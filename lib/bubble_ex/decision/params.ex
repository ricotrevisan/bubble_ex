defmodule BubbleEx.Decision.Params do
  @moduledoc """
  The closed vocabulary of `modify` parameters per finding transform
  (`BubbleEx.Finding.Kinds`). A `modify` decision may only carry the
  parameters its finding's transform allows here, with values of the listed
  shape; anything else is rejected, so no one (and no assistant) can invent a
  schema change through a decision. Transforms with no parameters are
  decided by `accept` or `reject` only.

  | Transform | Parameters |
  |-----------|------------|
  | `:derive_from_related`, `:derive_count` | `alternative` - index (from 0) into `proposal.alternatives`: derive from that alternative instead |
  | `:refine_number_type` | `to` - `:integer` or `:decimal` |
  | `:normalize_list_to_join` | `keep_order` - boolean; `join_name` - snake_case name of the join |
  | `:text_to_reference` | `target_type` - the data type symbol (`"data_type:<key>"`) the IDs reference: one of the finding's `evidence.target_types`, only when the finding named none |
  | `:add_indexes` | `drop` - indexes (from 0) into `proposal.indexes` not to create |
  | `:replace_plugin` | `option` - `:drop`, `:replace_native` or `:rebuild`: one of the finding's `proposal.options` |
  | `:membership_policy`, `:derive_reverse_relationship` | none |

  A `:plugin` finding has no source-faithful mapping to fall back to (a
  plugin's code is not part of the app), so it cannot be rejected: the
  owner accepts the suggested option or picks another with `modify`.

  `cast/3` checks shapes when a decision is decoded (it knows the finding's
  kind, not yet the finding); `check/2` checks them against the finding's
  proposal, and `apply/2` merges them into it.
  """

  alias BubbleEx.Error
  alias BubbleEx.Finding.Kinds

  @transforms %{
    derive_from_related: [:alternative],
    derive_count: [:alternative],
    refine_number_type: [:to],
    normalize_list_to_join: [:keep_order, :join_name],
    text_to_reference: [:target_type],
    add_indexes: [:drop],
    replace_plugin: [:option],
    membership_policy: [],
    derive_reverse_relationship: []
  }

  @number_types [:integer, :decimal]
  @plugin_options [:drop, :replace_native, :rebuild]

  # Finding kinds with no faithful mapping to keep: never rejected.
  @no_reject [:plugin]

  @type t :: %{optional(atom()) => term()}

  @doc "The transforms with a parameter whitelist (every registered transform)."
  @spec transforms() :: [atom()]
  def transforms, do: @transforms |> Map.keys() |> Enum.sort()

  @doc "The `modify` parameters `transform` allows (`:error` for an unknown transform)."
  @spec allowed(atom()) :: {:ok, [atom()]} | :error
  def allowed(transform), do: Map.fetch(@transforms, transform)

  @doc """
  Casts decoded JSON `params` (string keys) of a `choice` on a finding of
  `kind`: `accept` and `reject` take none; `modify` takes at least one, each
  allowed by one of the kind's transforms and of the right shape.
  """
  @spec cast(atom(), atom(), map()) :: {:ok, t()} | {:error, Error.t()}
  def cast(kind, :reject, _params) when kind in @no_reject,
    do:
      error(
        "#{kind} findings cannot be rejected: accept the suggested option or modify it",
        %{kind: kind}
      )

  def cast(_kind, choice, params)
      when choice in [:accept, :reject, :acknowledge] and map_size(params) == 0,
      do: {:ok, %{}}

  def cast(_kind, choice, params) when choice in [:accept, :reject, :acknowledge],
    do: error("#{choice} takes no parameters; use modify", %{params: Map.keys(params)})

  def cast(kind, :modify, params) when is_map(params) do
    allowed = kind_params(kind)

    cond do
      allowed == [] ->
        error("#{kind} findings are decided by accept or reject only", %{kind: kind})

      map_size(params) == 0 ->
        error("modify needs at least one parameter; use accept", %{allowed: allowed})

      true ->
        cast_all(params, allowed)
    end
  end

  def cast(_kind, _choice, params), do: error("params must be an object", %{params: params})

  defp kind_params(kind) do
    {:ok, %{transforms: transforms}} = Kinds.fetch(kind)
    transforms |> Enum.flat_map(&Map.get(@transforms, &1, [])) |> Enum.uniq() |> Enum.sort()
  end

  defp cast_all(params, allowed) do
    names = Map.new(allowed, &{Atom.to_string(&1), &1})

    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, name} <- param_name(names, key, allowed),
           {:ok, value} <- value(name, value) do
        {:cont, {:ok, Map.put(acc, name, value)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp param_name(names, key, allowed) do
    case Map.fetch(names, key) do
      {:ok, name} -> {:ok, name}
      :error -> error("parameter #{inspect(key)} is not allowed", %{allowed: allowed})
    end
  end

  defp value(:alternative, n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp value(:to, to) when is_binary(to) do
    case Enum.find(@number_types, &(Atom.to_string(&1) == to)) do
      nil -> bad(:to, to)
      type -> {:ok, type}
    end
  end

  defp value(:option, option) when is_binary(option) do
    case Enum.find(@plugin_options, &(Atom.to_string(&1) == option)) do
      nil -> bad(:option, option)
      option -> {:ok, option}
    end
  end

  defp value(:keep_order, bool) when is_boolean(bool), do: {:ok, bool}

  defp value(:join_name, name) when is_binary(name) do
    if name =~ ~r/\A[a-z][a-z0-9_]{0,62}\z/, do: {:ok, name}, else: bad(:join_name, name)
  end

  defp value(:target_type, "data_type:" <> key = id) when byte_size(key) > 0 do
    if id =~ ~r/\A\S+\z/, do: {:ok, id}, else: bad(:target_type, id)
  end

  defp value(:drop, [_ | _] = list) do
    if Enum.all?(list, &(is_integer(&1) and &1 >= 0)),
      do: {:ok, list |> Enum.uniq() |> Enum.sort()},
      else: bad(:drop, list)
  end

  defp value(name, value), do: bad(name, value)

  defp bad(name, value), do: error("invalid value for parameter #{name}", %{value: value})

  @doc """
  Checks cast `params` against the finding `proposal` they modify and its
  `evidence`: every parameter is allowed by its transform and points into
  it (an existing alternative or index; a `target_type` only where the
  finding named none, and one of its `evidence.target_types`; an `option`
  among the finding's `options`).
  """
  @spec check(map(), t(), map()) :: :ok | {:error, Error.t()}
  def check(%{transform: transform} = proposal, params, evidence \\ %{}) when is_map(params) do
    allowed = Map.get(@transforms, transform, [])

    case Enum.reject(Map.keys(params), &(&1 in allowed)) do
      [] ->
        Enum.find_value(params, :ok, &error_or_nil(fits(proposal, evidence, &1)))

      extra ->
        error("parameters not allowed for #{transform}", %{params: extra, allowed: allowed})
    end
  end

  defp error_or_nil(:ok), do: nil
  defp error_or_nil(error), do: error

  defp fits(proposal, _evidence, {:alternative, n}) do
    if n < length(Map.get(proposal, :alternatives, [])),
      do: :ok,
      else: error("the finding has no alternative #{n}", %{alternative: n})
  end

  defp fits(proposal, evidence, {:target_type, type}) do
    candidates = Map.get(evidence, :target_types, [])

    cond do
      Map.get(proposal, :target_type) != nil ->
        error("the finding already names its target type", %{})

      type not in candidates ->
        error("target_type is not one the finding saw", %{target_type: type, allowed: candidates})

      true ->
        :ok
    end
  end

  defp fits(proposal, _evidence, {:drop, drop}) do
    count = length(Map.get(proposal, :indexes, []))

    if Enum.all?(drop, &(&1 < count)),
      do: :ok,
      else: error("the finding has #{count} indexes", %{drop: drop})
  end

  defp fits(proposal, _evidence, {:option, option}) do
    options = Map.get(proposal, :options, [])

    if option in options,
      do: :ok,
      else:
        error("the finding does not offer option #{option}", %{option: option, allowed: options})
  end

  defp fits(_proposal, _evidence, _param), do: :ok

  @doc """
  The finding `proposal` modified by checked `params`: `alternative` swaps
  in that alternative's transform and derivation, `drop` removes those
  indexes, and every other parameter is set on the proposal.
  """
  @spec apply(map(), t()) :: map()
  def apply(proposal, params) do
    Enum.reduce(Enum.sort(params), proposal, fn
      {:alternative, n}, p ->
        Map.merge(p, Map.take(Enum.at(p.alternatives, n), [:transform, :derivation]))

      {:drop, drop}, p ->
        indexes =
          for {index, i} <- Enum.with_index(p.indexes), i not in drop, do: index

        %{p | indexes: indexes}

      {name, value}, p ->
        Map.put(p, name, value)
    end)
  end

  defp error(message, context), do: {:error, Error.new(:invalid_input, message, context)}
end
