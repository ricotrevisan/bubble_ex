defmodule BubbleEx.Plan.Content do
  @moduledoc """
  Keyed per-symbol digests of what the `BubbleEx.Index` does not record about
  a symbol but generation or behaviour depends on, for
  `BubbleEx.Plan.build/5` (`content:`). With them a task's `source_sha256`
  changes when the raw text of an expression, a condition, a setting, a
  field default or an option value it covers changes, not only when the
  reference graph does (WTF-367).

      key = File.read!(".wtf/plan.key") |> Base.decode64!()   # gitignored, or a CI secret
      {:ok, content} = BubbleEx.Plan.Content.digests(app, model, index, key: key)
      {:ok, plan} = BubbleEx.Plan.build(model, index, frontend, applied, content: content)

  ## Keyed digests

  Definitions hold literals (header values, passwords in API calls, default
  values), and a plain hash of a short literal can be brute-forced. So every
  digest is an HMAC-SHA256 (`algorithm/0`) under a per-project key of at
  least 32 bytes (`generate_key/0`) that is never written to the plan: keep
  it next to the owner's repository (`.wtf/plan.key`, gitignored) or as a CI
  secret. The plan records the algorithm and a key ID (`key_id`, an HMAC of
  a constant under the key, which reveals nothing about it), and every
  task's `source_sha256` includes them: building with another key, another
  algorithm or no key at all changes every task (`BubbleEx.Plan.Diff`
  reports it as `content_changed`), so a lost or rotated key fails safe.

  ## What is digested

  The canonical JSON of one symbol's definition, normalized:

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
      conditional states, custom states and settings. An element's named
      style counts with the style's definition, so editing a style changes
      the elements (and surfaces) using it
    * data types, fields (built-in ones included), option sets, option set
      attributes and option values, from the `BubbleEx.Model`: a field's
      full type (list, reference, external type details) and default
      value, an option value's display text, sort order and attribute
      values, a data type's API exposure, and what each keeps unmodeled
      (`extra`). Display names of types, fields and sets are captions
    * privacy rules: the canonical hash of the condition
      (`BubbleEx.Expression.sha256/1`) and the permissions, from the Model
    * API Connector groups and calls: the whole definition (URL with path,
      parameters and their values, body, headers) without the call's
      caption, and the Model's response shape. The key keeps the values
      out of reach

  Symbols with no definition at their path get none.
  """

  alias BubbleEx.{CanonicalJson, Error, Expression, Index, Model}
  alias BubbleEx.Expression.{Keys, Vocabulary}
  alias BubbleEx.Frontend.Payload
  alias BubbleEx.Index.Symbol
  alias BubbleEx.Workflows.ExplanationContext

  @algorithm "hmac-sha256/1"
  @min_key_bytes 32

  @enforce_keys [:algorithm, :key_id, :digests]
  defstruct [:algorithm, :key_id, digests: %{}]

  @type t :: %__MODULE__{
          algorithm: String.t(),
          key_id: String.t(),
          digests: %{String.t() => String.t()}
        }

  @raw_kinds [:page, :reusable, :element, :workflow, :action]

  # Child collections: symbols of their own.
  @children ~w(elements %el workflows %wf actions %a)

  # Definition members that are captions, editor state or split-export
  # artefacts. A page's `name` is its route and stays.
  @dropped ~w(id %id default_name %dn comment bp_layout children)
  @dropped_properties ~w(left top editor_preview_text lock_in_editor event_color breakpoint)

  @doc "The digest algorithm and its version, as recorded in the plan."
  @spec algorithm() :: String.t()
  def algorithm, do: @algorithm

  @doc "A new random key (32 bytes). Store it Base64-encoded, never in the plan."
  @spec generate_key() :: binary()
  def generate_key, do: :crypto.strong_rand_bytes(@min_key_bytes)

  @doc """
  Digests of every symbol of `index` that has content the index does not
  record, keyed by symbol ID. `key:` (required) is the project's key, at
  least #{@min_key_bytes} bytes.
  """
  @spec digests(map(), Model.t(), Index.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def digests(app, model, index, opts \\ [])

  def digests(app, %Model{} = model, %Index{} = index, opts)
      when is_map(app) and not is_struct(app) and is_list(opts) do
    case Keyword.get(opts, :key) do
      key when is_binary(key) and byte_size(key) >= @min_key_bytes ->
        mac = &hmac(key, &1)
        styles = Payload.styles(app)

        raw =
          for %Symbol{kind: kind} = s <- index.symbols,
              kind in @raw_kinds,
              definition = ExplanationContext.at_pointer(app, s.path),
              is_map(definition),
              into: %{},
              do: {s.id, definition |> normalize(kind, styles) |> mac.()}

        digests =
          raw
          |> Map.merge(data_model(model))
          |> Map.merge(rules(model))
          |> Map.merge(calls(app, model))
          |> Map.filter(fn {id, _} -> Index.symbol(index, id) != nil end)
          |> Map.new(fn {id, value} ->
            {id, if(is_binary(value), do: value, else: mac.(value))}
          end)

        {:ok, %__MODULE__{algorithm: @algorithm, key_id: key_id(key), digests: digests}}

      _ ->
        {:error,
         Error.new(
           :invalid_input,
           "content digests need the project's key: key: a binary of at least " <>
             "#{@min_key_bytes} bytes (Plan.Content.generate_key/0), never stored in the plan"
         )}
    end
  end

  def digests(_app, _model, _index, _opts),
    do: {:error, Error.new(:invalid_input, "expected app JSON, its Model, its Index and options")}

  @doc "The key's public ID: a truncated HMAC of a constant under it."
  @spec key_id(binary()) :: String.t()
  def key_id(key), do: :hmac |> :crypto.mac(:sha256, key, "bubble_ex plan key id") |> hex(16)

  defp hmac(key, value),
    do: :hmac |> :crypto.mac(:sha256, key, CanonicalJson.encode(value)) |> hex(32)

  defp hex(bin, bytes), do: bin |> binary_part(0, bytes) |> Base.encode16(case: :lower)

  # --- raw definitions ----------------------------------------------------------

  @doc false
  @spec normalize(map(), Symbol.kind(), map()) :: map()
  def normalize(definition, kind, styles \\ %{}) do
    own = Map.drop(definition, @children ++ @dropped)
    own = if kind == :page, do: own, else: Map.drop(own, ["name", "%nm"])

    own
    |> Enum.reject(fn {key, _} -> String.starts_with?(key, "__bp_") end)
    |> Map.new()
    |> Keys.normalize()
    |> strip()
    |> update_properties(kind)
    |> put_actions(definition, kind)
    |> put_style(kind, styles)
  end

  # A named style counts with its definition.
  defp put_style(%{"style" => key} = own, :element, styles) when is_binary(key) do
    case Map.get(styles, key) do
      style when is_map(style) ->
        Map.put(own, "style", %{
          "key" => key,
          "definition" => style |> Keys.normalize() |> strip()
        })

      _ ->
        own
    end
  end

  defp put_style(own, _kind, _styles), do: own

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
       %{condition: condition, permissions: plain(rule.permissions)}}
    end
  end

  # A data type's exposure, a field's type and default, an option value's
  # display text, order and attribute values, and what each keeps
  # unmodeled. Captions (display names, comments) are left out.
  defp data_model(%Model{data_types: types, option_sets: sets}) do
    type_entries =
      for type <- types,
          entry <- [
            {Symbol.id(:data_type, type.id),
             %{deleted: type.deleted, exposed_api: type.exposed_api, extra: plain(type.extra)}}
            | Enum.map(type.fields ++ type.system_fields, &field(:field, type.id, &1))
          ],
          do: entry

    set_entries =
      for set <- sets,
          entry <-
            [{Symbol.id(:option_set, set.id), %{deleted: set.deleted, extra: plain(set.extra)}}] ++
              Enum.map(set.attributes, &field(:option_attribute, set.id, &1)) ++
              Enum.map(set.values, &option_value(set.id, &1)),
          do: entry

    Map.new(type_entries ++ set_entries)
  end

  defp field(kind, owner, field) do
    {Symbol.id(kind, [owner, field.id]),
     %{
       type: plain(field.type),
       default: plain(field.default),
       system: field.system,
       deleted: field.deleted,
       extra: plain(field.extra),
       raw: plain(field.raw)
     }}
  end

  defp option_value(set_id, value) do
    {Symbol.id(:option_value, [set_id, value.key]),
     %{
       id: value.id,
       display: value.name,
       order: value.sort_factor,
       attributes: plain(value.attributes),
       deleted: value.deleted,
       extra: plain(value.extra),
       raw: plain(value.raw)
     }}
  end

  # API Connector groups and calls: their whole definitions (values
  # included; the digest is keyed) and the Model's response shapes. A
  # group's digest leaves out its calls, which are symbols of their own.
  defp calls(app, %Model{external_types: types, connectors: connectors}) do
    shapes = Enum.group_by(types, &{&1.connector, &1.call})

    for connector <- connectors,
        entry <- [
          group(app, connector) | Enum.map(connector.calls, &call(app, connector, &1, shapes))
        ],
        into: %{},
        do: entry
  end

  defp group(app, connector) do
    call_ids = MapSet.new(connector.calls, & &1.id)

    definition =
      case ExplanationContext.at_pointer(app, connector.path) do
        map when is_map(map) ->
          map |> Map.drop(["calls", "name", "%nm"]) |> Map.reject(fn {k, _} -> k in call_ids end)

        other ->
          other
      end

    {Symbol.id(:api_group, connector.id), %{definition: definition, auth: plain(connector.auth)}}
  end

  defp call(app, connector, call, shapes) do
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

    definition =
      case ExplanationContext.at_pointer(app, call.path) do
        map when is_map(map) -> Map.drop(map, ["name", "%nm"])
        other -> other
      end

    {Symbol.id(:api_call, [connector.id, call.id]),
     %{definition: definition, returns: plain(call.returns), shape: shape}}
  end

  # Structs as plain maps, for canonical JSON.
  defp plain(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort() |> plain()
  defp plain(%_{} = struct), do: struct |> Map.from_struct() |> plain()
  defp plain(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(other), do: other
end
