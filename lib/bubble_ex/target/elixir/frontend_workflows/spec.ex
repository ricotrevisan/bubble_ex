defmodule BubbleEx.Target.Elixir.FrontendWorkflows.Spec do
  @moduledoc """
  Page and reusable-element workflows bound to Phoenix LiveView
  (`BubbleEx.Target.Elixir.FrontendWorkflows.map/3`), plain data that
  `BubbleEx.Target.Phoenix` prints with the pages (WTF-372):

    * `namespace` - the root module the resource names are relative to
    * `surfaces` - by page or reusable Bubble ID: `%{kind, workflows,
      states, inputs}`. `workflows` (sorted by Bubble ID) are described
      below; `states` are the custom states of the surface's elements
      (`%{element, state, default}`, `default` a literal or nil); `inputs`
      the inputs whose value the page tracks (element => `:text`,
      `:number` or `:boolean`)
    * `elements` - by Bubble ID: `%{surface, instance_of, root?}` for every
      element of a surface (`root?`: the page or reusable element itself)
    * `cells` - the reusable instances in a repeating group's cell
      (WTF-494), by Bubble ID: `%{surface, cell, holder, residue}`; the
      page renders one per cell, in a scope of its own, when `residue` is
      empty (see `BubbleEx.Target.Elixir.FrontendWorkflows.Data`)
    * `diagnostics` - the lowering's and this binding's

  A workflow: `%{workflow, symbol, name, surface, kind, element, run_when,
  interval, disabled?, client?, params, condition, steps, residue, data?,
  callees, blocked_by}`. `client?` is a workflow run in the browser as JS commands (a
  click whose steps all show, hide, toggle, focus or scroll to elements,
  with no condition); `data?` one that reads or writes stored data;
  `callees` the custom events it calls or schedules (`%{surface,
  workflow}`); `residue` its own and its steps' (the lowering's and this
  binding's); `blocked_by`, as in `BubbleEx.Target.Ash.Workflows.Spec`,
  its own residue subjects and the blocked (or unknown) workflows it calls
  or schedules directly (custom events and backend workflows): a workflow
  with any fails before its first step. `data?` is transitive: it or a
  custom event it calls reads or writes stored data. A step: `%{index, bubble_id, symbol, type, op, condition,
  args, residue}`.

  A compiled value is `%{source, bindings}`, each binding `%{var, bind,
  loads}` with `bind` one of `:actor`, `:now`, `{:param, id}`, `{:step,
  action}`, `{:url, name}`, `{:state, key}` (key `%{path, element,
  state}`) or `{:input, key}` (key `%{path, element}`). A key's `path` is
  the reusable-element instances between the workflow's surface and the
  element (Bubble IDs), `[]` for the surface's own elements. A target
  (`%{path, element}`, `element` `:root` for an instance or the reusable
  element itself) names an element to show, hide, focus…
  """

  defstruct namespace: nil,
            surfaces: %{},
            elements: %{},
            diagnostics: [],
            data_index: %{elements: %{}, roots: MapSet.new(), params: %{}, set: %{}},
            cells: %{}

  @type t :: %__MODULE__{}

  @doc "Every workflow, sorted by surface then Bubble ID."
  @spec workflows(t()) :: [map()]
  def workflows(%__MODULE__{surfaces: surfaces}) do
    surfaces
    |> Enum.sort()
    |> Enum.flat_map(fn {_id, s} -> s.workflows end)
  end

  @doc "A workflow by its surface and Bubble ID, or nil."
  @spec workflow(t(), String.t(), String.t()) :: map() | nil
  def workflow(%__MODULE__{surfaces: surfaces}, surface, id) do
    case surfaces[surface] do
      %{workflows: workflows} -> Enum.find(workflows, &(&1.workflow == id))
      nil -> nil
    end
  end

  @doc """
  Every residue entry (the lowering's and the binding's), sorted:
  `BubbleEx.Plan.Residue` entries (`%{subject, reason, detail}`).
  """
  @spec residue(t()) :: [map()]
  def residue(%__MODULE__{} = spec),
    do:
      spec
      |> workflows()
      |> Enum.flat_map(&own_residue/1)
      |> Enum.sort_by(&{&1.subject, &1.reason, inspect(&1.detail)})

  @doc """
  Whether the page triggers a workflow: not disabled in the editor, and
  its event is wired (its element is rendered and the event has a
  binding here). A wired workflow with residue elsewhere is still
  triggered: the runtime refuses it, loudly.
  """
  @spec wired?(map()) :: boolean()
  def wired?(w) do
    not w.disabled? and
      not Enum.any?(w.residue, fn r ->
        r.subject == w.symbol and
          r.reason in [
            :trigger_not_normalized,
            :trigger_in_runtime_template,
            :unsupported_event,
            :plugin_event,
            :unresolved_reference
          ]
      end)
  end

  @doc """
  Whether a workflow is native: its whole body is generated with no
  residue, and so is every workflow it calls or schedules, transitively
  (`blocked_by` is empty), as `BubbleEx.Target.Ash.Workflows.Spec.native?/1`.
  The runtime starts only native workflows.
  """
  @spec native?(map()) :: boolean()
  def native?(workflow),
    do: own_residue(workflow) == [] and Map.get(workflow, :blocked_by, []) == []

  @doc "Whether a workflow's own body has no residue (its callees may)."
  @spec native_own_body?(map()) :: boolean()
  def native_own_body?(workflow), do: own_residue(workflow) == []

  defp own_residue(w), do: w.residue ++ Enum.flat_map(w.steps, & &1.residue)

  @doc "The compiled values of a bound step's arguments (not its condition)."
  @spec step_values(map()) :: [map()]
  def step_values(%{op: op, args: args}), do: op |> values(args) |> Enum.reject(&is_nil/1)

  @writes [:create, :update, :update_current_user, :update_list]

  defp values(op, args) when op in @writes,
    do: [args[:target] | Enum.map(args[:changes] || [], & &1.value)]

  defp values(op, args) when op in [:delete, :delete_list], do: [args[:target]]
  defp values(:open_url, args), do: [args[:url]]

  defp values(:navigate, args),
    do: [args[:thing] | Enum.map(args[:params] || [], & &1.value)]

  defp values(op, args) when op in [:schedule, :schedule_list],
    do: [args[:at], args[:list], args[:interval] | Enum.map(args[:params] || [], & &1.value)]

  defp values(:pause, args), do: [args[:length]]
  defp values(op, args) when op in [:display_data, :display_list], do: [args[:value]]

  defp values(:schedule_custom, args),
    do: [args[:delay] | Enum.map(args[:params] || [], & &1.value)]

  defp values(_op, args) do
    Enum.flat_map([:states, :params, :returns], fn key ->
      Enum.map(args[key] || [], & &1.value)
    end)
  end

  @doc """
  How a value read of a compiled page binding (`input`, as
  `BubbleEx.Target.Elixir` names it: `{:element_state, %{"element" => id,
  "state" => state}}`) is stored when read in `surface`: `{:state, key}`,
  `{:input, key}`, page data (see `data_read/4`), `{:url, name}` (a URL
  parameter read as text, kept by the runtime from the URL's query) or
  nil when the page does not keep it.

  A reusable instance's property read where the instance is (`Card A's
  Title` on the page) is also its reusable element's default when the
  instance sets none (see `instance_property/4`).
  """
  @spec read(t(), String.t(), term(), String.t() | nil) :: {atom(), term()} | nil
  def read(spec, surface, input, cell \\ nil)

  def read(%__MODULE__{}, _surface, {:url_parameter, %{"name" => name}}, _cell)
      when is_binary(name),
      do: {:url, name}

  def read(%__MODULE__{} = spec, surface, {:element_state, %{"state" => s}} = input, cell)
      when s in ["get_group_data", "get_list_data"] do
    case data_read(spec.data_index, surface, cell, input) do
      {:ok, bind} -> bind
      {:error, _} -> nil
    end
  end

  # A reusable element's property (WTF-493).
  def read(
        %__MODULE__{} = spec,
        surface,
        {:element_state, %{"element" => element, "state" => "param_" <> _ = param}} = input,
        cell
      ) do
    case data_read(spec.data_index, surface, cell, input) do
      {:ok, bind} -> bind
      {:error, _} -> instance_property(spec, surface, element, param)
    end
  end

  def read(%__MODULE__{} = spec, surface, {kind, _} = input, cell)
      when kind in [:page_thing, :cell_thing, :cell_index] do
    case data_read(spec.data_index, surface, cell, input) do
      {:ok, bind} -> bind
      {:error, _} -> nil
    end
  end

  def read(
        %__MODULE__{} = spec,
        surface,
        {:element_state, %{"element" => e, "state" => s}},
        _cell
      )
      when is_binary(e) and is_binary(s) do
    case {spec.elements[e], s} do
      {%{surface: ^surface} = el, "custom." <> _} ->
        key = state_key(e, el, s)
        if state?(spec, key), do: {:state, key}

      {%{surface: ^surface, instance_of: nil, root?: false}, "get_data"} ->
        if Map.has_key?(spec.surfaces[surface].inputs, e),
          do: {:input, %{path: [], element: e}}

      _ ->
        nil
    end
  end

  def read(_spec, _surface, _input, _cell), do: nil

  @doc """
  How the page's data (WTF-420) supplies `input` read in `surface`,
  inside the cell of the repeating group `cell` (or nil), given the index
  of the sources it loads (`data_index`: `%{elements: %{element =>
  %{kind, surface, cell, holder}}, roots: reusable elements an instance
  gives their thing to}`): `{:ok, bind}` or `{:error, kind}` (the input's
  kind, for `:unavailable_input` residue).

    * `{:data, %{path, element}}` - a page's thing, a group's thing, a
      repeating group's list, an instance's thing (stored under its
      reusable element, one level down) or the surface's own reusable
      element's thing (what its instance gives it, possibly nothing)
    * `{:cell, rg}`, `{:cell_index, rg}` - the current cell's thing and
      index, in the cell of `rg`
    * `{:cell_data, group}` - a group's thing computed in the current cell

  A reusable element's property (`"param_<id>"`, WTF-493) is
  `{:data, %{path: [], element: key}}` read in the reusable element (when
  every value of it loads, see `index.params`), or `{:data, %{path:
  [instance], element: key}}` read where an instance setting it is, `key`
  being `param_key/2`.
  """
  @spec data_read(map(), String.t(), String.t() | nil, term()) ::
          {:ok, term()} | {:error, String.t()}
  def data_read(index, surface, _cell, {:page_thing, %{"page" => page}}) do
    case index.elements[page] do
      %{kind: :page_thing, surface: ^surface} -> {:ok, {:data, %{path: [], element: page}}}
      _ -> {:error, "page_thing"}
    end
  end

  def data_read(index, surface, cell, {:element_state, %{"element" => e, "state" => state}})
      when state in ["get_group_data", "get_list_data"] do
    case {index.elements[e], state} do
      {nil, "get_group_data"} when e == surface ->
        if MapSet.member?(index.roots, e),
          do: {:ok, {:data, %{path: [], element: e}}},
          else: {:error, "element_state:" <> state}

      {%{kind: :instance, surface: ^surface, cell: nil, holder: holder}, "get_group_data"}
      when is_binary(holder) ->
        {:ok, {:data, %{path: [e], element: holder}}}

      {%{kind: kind, surface: ^surface, cell: nil}, _} when kind in [:group, :list] ->
        if kind == :list == (state == "get_list_data"),
          do: {:ok, {:data, %{path: [], element: e}}},
          else: {:error, "element_state:" <> state}

      {%{kind: :group, surface: ^surface, cell: ^cell}, "get_group_data"} when is_binary(cell) ->
        {:ok, {:cell_data, e}}

      _ ->
        {:error, "element_state:" <> state}
    end
  end

  def data_read(
        index,
        surface,
        _cell,
        {:element_state, %{"element" => e, "state" => "param_" <> _ = state}}
      )
      when is_binary(e) do
    key = param_key(e, state)

    cond do
      e == surface and Map.get(Map.get(index, :params, %{}), key, true) ->
        {:ok, {:data, %{path: [], element: key}}}

      match?(%{surface: ^surface}, Map.get(Map.get(index, :set, %{}), {e, state})) ->
        {:ok, {:data, %{path: [e], element: index.set[{e, state}].key}}}

      true ->
        {:error, "element_state:param"}
    end
  end

  def data_read(index, surface, cell, {kind, %{"element" => rg}})
      when kind in [:cell_thing, :cell_index] and is_binary(cell) and rg == cell do
    case index.elements[rg] do
      %{kind: :list, surface: ^surface, cell: nil} ->
        {:ok, if(kind == :cell_thing, do: {:cell, rg}, else: {:cell_index, rg})}

      _ ->
        {:error, Atom.to_string(kind)}
    end
  end

  def data_read(_index, _surface, _cell, {kind, _ref}) when is_atom(kind),
    do: {:error, Atom.to_string(kind)}

  def data_read(_index, _surface, _cell, _input), do: {:error, "unknown"}

  @doc """
  Property `param` of reusable instance `instance`, read in `surface`
  where the instance is, when the instance sets no value of it that loads
  (`data_read/4` reads those): `{:data, %{path: [instance], element:
  key}}`, the reusable element's default, which the page computes in the
  instance's scope and keeps under the same key as a value the instance
  sets (WTF-493), or nil. Only when every value of the property loads
  (`index.params`, so the instance's own value too, and the default), for
  an instance outside a repeating group's cell (rendered once, in one
  scope). Read when the page renders, after its data loaded; the page's
  data sources and workflows do not read it (they run before the
  instance's sources, or the default would be read before it is
  computed).
  """
  @spec instance_property(t(), String.t(), String.t(), String.t()) :: {:data, map()} | nil
  def instance_property(%__MODULE__{} = spec, surface, instance, param) do
    with %{surface: ^surface, instance_of: reusable} when is_binary(reusable) <-
           spec.elements[instance],
         false <- Map.has_key?(spec.cells, instance),
         key = param_key(reusable, param),
         true <- Map.get(spec.data_index.params, key) == true do
      {:data, %{path: [instance], element: key}}
    else
      _ -> nil
    end
  end

  @doc """
  Where the page keeps property `param` (`"param_<id>"`) of reusable
  element `reusable` (WTF-493): property IDs are unique only within a
  reusable element, so the key names both.
  """
  @spec param_key(String.t(), String.t()) :: String.t()
  def param_key(reusable, param), do: param <> "/" <> reusable

  @doc """
  Whether the page renders reusable instance `id` once per cell of the
  repeating group holding it, in a scope of its own (WTF-494).
  """
  @spec per_cell?(t(), String.t()) :: boolean()
  def per_cell?(%__MODULE__{cells: cells}, id), do: match?(%{residue: []}, cells[id])

  @doc "The data sources the page loads for surface `id` (WTF-420), in order."
  @spec data(t(), String.t()) :: [map()]
  def data(%__MODULE__{surfaces: surfaces}, id) do
    case surfaces[id] do
      %{data: data} -> data
      _ -> []
    end
  end

  @doc """
  Generated-code coverage of the page's data sources (WTF-420), with
  string keys: `"sources"` (`total`; `wired`: loaded by the generated
  page, with no residue, neither the lowering's nor this target's, and
  every source it reads loaded too; `residue`), `"by_kind"` (`{total,
  wired}` per kind), `"reads"` (wired sources per read: `url_thing`,
  `query`, `value`, `displayed`: an element with no source of its own
  that a "Display data" step sets, WTF-492) and `"residue_reasons"`.
  """
  @spec data_coverage(t()) :: map()
  def data_coverage(%__MODULE__{surfaces: surfaces}) do
    sources = surfaces |> Enum.sort() |> Enum.flat_map(fn {_id, s} -> Map.get(s, :data, []) end)
    wired = Enum.filter(sources, &(&1.residue == []))

    %{
      "sources" => %{
        "total" => length(sources),
        "wired" => length(wired),
        "residue" => length(sources) - length(wired)
      },
      "by_kind" =>
        sources
        |> Enum.group_by(&Atom.to_string(&1.kind))
        |> Map.new(fn {k, ss} ->
          {k, %{"total" => length(ss), "wired" => Enum.count(ss, &(&1.residue == []))}}
        end),
      "reads" =>
        Enum.frequencies_by(wired, fn
          %{read: {kind, _}} -> Atom.to_string(kind)
          %{read: kind} when is_atom(kind) -> Atom.to_string(kind)
        end),
      "residue_reasons" =>
        sources |> Enum.flat_map(& &1.residue) |> Enum.frequencies_by(&Atom.to_string(&1.reason))
    }
  end

  @doc """
  The storage key of state `state` of element `id` (its entry `element`
  in `elements`), relative to the element's surface: an instance's states
  are its reusable element's, one level down.
  """
  @spec state_key(String.t(), map(), String.t()) :: map()
  def state_key(id, %{instance_of: definition}, state) when is_binary(definition),
    do: %{path: [id], element: definition, state: state}

  def state_key(id, _element, state), do: %{path: [], element: id, state: state}

  # Whether the key names a declared state: the element's (or, one level
  # down, the reusable element's).
  defp state?(spec, %{element: element, state: state}) do
    case spec.elements[element] do
      %{surface: surface} ->
        case spec.surfaces[surface] do
          %{states: states} -> Enum.any?(states, &(&1.element == element and &1.state == state))
          nil -> false
        end

      nil ->
        false
    end
  end

  @doc """
  Generated-code coverage, with string keys. The metric (the backend's,
  `BubbleEx.Target.Ash.Workflows.Spec.coverage/1`, plus what pages add):

    * `"workflows"` - page and reusable-element workflows; `"native"` the
      ones whose **whole body** is generated, and whose every callee (a
      custom event it calls or schedules, a backend workflow it schedules,
      transitively) is too, with no residue (neither the lowering's, see
      `BubbleEx.Workflows.Frontend.coverage/1`, nor this binding's: an IR
      that does not compile to Elixir, a value the generated page does not
      provide, a step this target does not run yet): the runtime starts
      only these; `"native_own_body"` the ones whose own body has no
      residue, callees aside; `"wired"` the native ones the page triggers
      (not disabled in the editor, and not a custom event, which runs only
      when called); `"client"` the native ones run in the browser;
      `"residue"` the rest (total - native)
    * `"steps"` - their actions; `"native"` the ones generated with no
      residue
    * `"by_kind"` - `{total, native}` workflows per event kind;
      `"by_surface"` - for pages and reusable elements; `"step_ops"` -
      native steps per operation; `"residue_reasons"` - residue entries per
      reason (a subject may have several)
    * `"data"` - native workflows that read or write stored data (they run
      only with the data-access opt-in, see the generated runtime)
  """
  @spec coverage(t()) :: map()
  def coverage(%__MODULE__{} = spec) do
    workflows = workflows(spec)
    steps = Enum.flat_map(workflows, & &1.steps)
    native = Enum.filter(workflows, &native?/1)

    %{
      "workflows" => %{
        "total" => length(workflows),
        "native" => length(native),
        "native_own_body" => Enum.count(workflows, &native_own_body?/1),
        "wired" => Enum.count(native, &(not &1.disabled? and &1.kind != :custom_event)),
        "residue" => length(workflows) - length(native),
        "client" => Enum.count(native, & &1.client?)
      },
      "steps" => %{
        "total" => length(steps),
        "native" => Enum.count(steps, &(&1.residue == [])),
        "residue" => Enum.count(steps, &(&1.residue != []))
      },
      "by_kind" => totals(workflows, &Atom.to_string(&1.kind)),
      "by_surface" => totals(workflows, &Atom.to_string(spec.surfaces[&1.surface].kind)),
      "step_ops" =>
        steps
        |> Enum.filter(&(&1.residue == [] and &1.op != nil))
        |> Enum.frequencies_by(&Atom.to_string(&1.op)),
      "residue_reasons" =>
        workflows
        |> Enum.flat_map(&own_residue/1)
        |> Enum.frequencies_by(&Atom.to_string(&1.reason)),
      "data" => Enum.count(native, & &1.data?)
    }
  end

  defp totals(workflows, key) do
    workflows
    |> Enum.group_by(key)
    |> Map.new(fn {k, ws} ->
      {k, %{"total" => length(ws), "native" => Enum.count(ws, &native?/1)}}
    end)
  end
end
