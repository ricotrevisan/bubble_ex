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

  defstruct namespace: nil, surfaces: %{}, elements: %{}, diagnostics: []

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

  defp values(op, args) when op in [:schedule, :schedule_list],
    do: [args[:at], args[:list], args[:interval] | Enum.map(args[:params] || [], & &1.value)]

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
  `{:input, key}` or nil when the page does not keep it.
  """
  @spec read(t(), String.t(), term()) :: {:state | :input, map()} | nil
  def read(%__MODULE__{} = spec, surface, {:element_state, %{"element" => e, "state" => s}})
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

  def read(_spec, _surface, _input), do: nil

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
