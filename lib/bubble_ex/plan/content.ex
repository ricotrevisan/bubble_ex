defmodule BubbleEx.Plan.Content do
  @moduledoc """
  Per-symbol digests of what the `BubbleEx.Index` does not record about a
  symbol but its behaviour depends on, for `BubbleEx.Plan.build/5`
  (`content:`). With them a task's `source_sha256` changes when the raw
  text of an expression, a condition or a setting it covers changes, not
  only when the reference graph does (WTF-367).

      {:ok, content} = BubbleEx.Plan.Content.digests(app, model, index)
      {:ok, plan} = BubbleEx.Plan.build(model, index, frontend, applied, content: content)

  A digest is the SHA-256 of the canonical JSON of one symbol's own
  definition, normalized:

    * pages, reusables, elements, workflows and actions: the definition at
      the symbol's `path` without its children (elements, workflows and
      actions are symbols of their own; a workflow keeps the order of its
      action IDs, which the index leaves out), with compact keys spelled
      readably (`BubbleEx.Expression` aliases, so both key forms hash alike)
      and without what does not change behaviour: captions (`default_name`;
      `name` except a page's, which is its route; a custom event's
      `event_name`), editor notes and state (`comment`, `breakpoint`,
      `event_color`, `lock_in_editor`, `editor_preview_text`, members
      ending in `_friendly`, expression editor metadata) and canvas
      positions (`left`, `top`). Everything else counts: every expression
      verbatim (dynamic text, conditions, constraints, parameters),
      conditional states, custom states, named styles and settings
    * privacy rules: the canonical hash of the condition
      (`BubbleEx.Expression.sha256/1`) and the permissions, from the Model
    * API Connector calls: the call's return type and response shape (the
      Model's external types of the call, without captions). Parameter
      values, URL paths and bodies are never read (the Model does not read
      them); the index already records the method, host and parameter
      names
    * other symbols (data types, fields, option sets) have no digest: the
      index records all of their content

  Symbols with no definition at their path get none.
  """

  alias BubbleEx.{CanonicalJson, Error, Expression, Index, Model}
  alias BubbleEx.Expression.{Keys, Vocabulary}
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Workflows.ExplanationContext

  @raw_kinds [:page, :reusable, :element, :workflow, :action]

  # Child collections: symbols of their own.
  @children ~w(elements %el workflows %wf actions %a)

  # Definition members that are captions, editor state or split-export
  # artefacts. A page's `name` is its route and stays.
  @dropped ~w(id %id default_name %dn comment bp_layout children)
  @dropped_properties ~w(left top editor_preview_text lock_in_editor event_color breakpoint)

  @doc """
  Digests of every page, reusable, element, workflow, action, privacy rule
  and API Connector call of `index`, keyed by symbol ID.
  """
  @spec digests(map(), Model.t(), Index.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, Error.t()}
  def digests(app, %Model{} = model, %Index{} = index) when is_map(app) and not is_struct(app) do
    raw =
      for %Symbol{kind: kind} = s <- index.symbols,
          kind in @raw_kinds,
          definition = ExplanationContext.at_pointer(app, s.path),
          is_map(definition),
          into: %{},
          do: {s.id, definition |> normalize(kind) |> CanonicalJson.sha256()}

    {:ok, raw |> Map.merge(rules(model)) |> Map.merge(calls(model, index))}
  end

  def digests(_app, _model, _index),
    do: {:error, Error.new(:invalid_input, "expected app JSON, its Model and its Index")}

  # --- raw definitions ----------------------------------------------------------

  @doc false
  @spec normalize(map(), Symbol.kind()) :: map()
  def normalize(definition, kind) do
    own = Map.drop(definition, @children ++ @dropped)
    own = if kind == :page, do: own, else: Map.drop(own, ["name", "%nm"])

    own
    |> Enum.reject(fn {key, _} -> String.starts_with?(key, "__bp_") end)
    |> Map.new()
    |> Keys.normalize()
    |> strip()
    |> update_properties(kind)
    |> put_actions(definition, kind)
  end

  defp update_properties(own, kind) do
    case Map.fetch(own, "properties") do
      {:ok, props} -> Map.put(own, "properties", properties(props, kind))
      :error -> own
    end
  end

  defp properties(props, kind) when is_map(props) do
    props = Map.drop(props, @dropped_properties)
    if kind == :workflow, do: Map.delete(props, "event_name"), else: props
  end

  defp properties(other, _kind), do: other

  defp put_actions(own, definition, :workflow) do
    actions = Map.get(definition, "actions") || Map.get(definition, "%a")
    Map.put(own, "action_order", action_order(actions))
  end

  defp put_actions(own, _definition, _kind), do: own

  # Action Bubble IDs in step order (keys "0", "1", …, "10" numerically).
  defp action_order(actions) when is_map(actions) do
    actions
    |> Enum.sort_by(fn {key, _} -> step_key(key) end)
    |> Enum.map(fn {key, action} -> action_id(action) || to_string(key) end)
  end

  defp action_order(actions) when is_list(actions), do: Enum.map(actions, &action_id/1)
  defp action_order(_), do: []

  defp step_key(key) when is_integer(key), do: {0, key, ""}

  defp step_key(key) do
    case Integer.parse(to_string(key)) do
      {n, ""} -> {0, n, ""}
      _ -> {1, 0, to_string(key)}
    end
  end

  defp action_id(%{"id" => id}) when is_binary(id), do: id
  defp action_id(%{"%id" => id}) when is_binary(id), do: id
  defp action_id(_), do: nil

  # Expression editor metadata at any depth.
  defp strip(map) when is_map(map) do
    for {k, v} <- map, not Vocabulary.metadata_key?(to_string(k)), into: %{}, do: {k, strip(v)}
  end

  defp strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  defp strip(other), do: other

  # --- Model-backed symbols -----------------------------------------------------

  defp rules(%Model{data_types: types}) do
    for type <- types, rule <- type.rules, into: %{} do
      condition =
        case rule.condition && Expression.sha256(rule.condition) do
          {:ok, sha} -> sha
          _ -> nil
        end

      {Symbol.id(:privacy_rule, [type.id, rule.id]),
       CanonicalJson.sha256(%{condition: condition, permissions: plain(rule.permissions)})}
    end
  end

  defp calls(%Model{external_types: types, connectors: connectors}, index) do
    shapes = Enum.group_by(types, &{&1.connector, &1.call})

    for connector <- connectors,
        call <- connector.calls,
        id = Symbol.id(:api_call, [connector.id, call.id]),
        Index.symbol(index, id),
        into: %{} do
      shape =
        shapes
        |> Map.get({connector.id, call.id}, [])
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn t ->
          %{
            id: t.id,
            resolution: t.resolution,
            members:
              Enum.map(
                t.fields,
                &%{id: &1.id, at: &1.response_path, type: plain(&1.type), cycle: &1.cycle}
              )
          }
        end)

      {id, CanonicalJson.sha256(%{returns: plain(call.returns), shape: shape})}
    end
  end

  # Structs as plain maps, for canonical JSON.
  defp plain(%_{} = struct), do: struct |> Map.from_struct() |> plain()
  defp plain(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(other), do: other
end
