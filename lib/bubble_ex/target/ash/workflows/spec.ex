defmodule BubbleEx.Target.Ash.Workflows.Spec do
  @moduledoc """
  Backend workflows bound to Ash (`BubbleEx.Target.Ash.Workflows.map/3`),
  plain data:

    * `namespace` - the root module the names are relative to
    * `resources` - one per backend folder: `%{module, folder, actions}`,
      sorted by module; each action is described below
    * `triggers` - `%{resource, data_type, workflows}`: the data
      resources whose writes enqueue database-trigger workflows
    * `stamps` - per data resource module, the attributes Bubble sets
      itself (`created`, `modified`, `creator`)
    * `cycles` - `%{id, workflows, bubble_ids, synchronous}`: call cycles
      among backend workflows (the ID is the plan's cycle task ID)
    * `privacy_bypasses` - Bubble IDs of the workflows lowered with
      `authorize?: false`
    * `names` - the name map to pass back as `names:` (JSON-stable)
    * `diagnostics` - the lowering's and this binding's

  An action: `%{workflow, symbol, name, bubble_name, kind, module,
  arguments, returns, authorize, exposed, trigger, cycle, condition,
  steps, residue}`. `authorize` is `true`, `false` (a bypass) or
  `:inherit`; `exposed` is nil or `%{endpoint, auth, method,
  return_200?}`; `condition` and every value are compiled expressions
  `%{source, bindings}` (each binding `%{var, bind, loads}`); `steps`
  are `%{index, bubble_id, symbol, type, op, condition, args, residue}`
  with op-specific args.
  """

  defstruct namespace: nil,
            resources: [],
            triggers: [],
            stamps: %{},
            cycles: [],
            privacy_bypasses: [],
            names: %{},
            diagnostics: []

  @type t :: %__MODULE__{}

  @doc "Every action, sorted by Bubble ID."
  @spec actions(t()) :: [map()]
  def actions(%__MODULE__{resources: resources}),
    do: resources |> Enum.flat_map(& &1.actions) |> Enum.sort_by(& &1.workflow)

  @doc """
  Every residue entry (the lowering's and the binding's), sorted:
  `BubbleEx.Plan.Residue` entries (`%{subject, reason, detail}`).
  """
  @spec residue(t()) :: [map()]
  def residue(%__MODULE__{} = spec),
    do:
      spec
      |> actions()
      |> Enum.flat_map(&action_residue/1)
      |> Enum.sort_by(&{&1.subject, &1.reason, inspect(&1.detail)})

  # Every workflow reachable through call and schedule steps is native.
  defp callees_native?(action, actions) do
    by_id = Map.new(actions, &{&1.workflow, &1})
    reach(action, by_id, MapSet.new([action.workflow]))
  end

  defp reach(action, by_id, seen) do
    Enum.all?(callees(action), fn id ->
      cond do
        MapSet.member?(seen, id) ->
          true

        match?(%{}, by_id[id]) and native?(by_id[id]) ->
          reach(by_id[id], by_id, MapSet.put(seen, id))

        true ->
          false
      end
    end)
  end

  defp callees(action),
    do:
      for(
        %{op: op, args: %{workflow: id}} <- action.steps,
        op in [:call, :schedule, :schedule_list],
        do: id
      )

  @doc "Whether an action has no residue: its whole body is generated."
  @spec native?(map()) :: boolean()
  def native?(action), do: action_residue(action) == []

  defp action_residue(action), do: action.residue ++ Enum.flat_map(action.steps, & &1.residue)

  @doc """
  Generated-code coverage, with string keys. The metric:

    * `"entry_points"` - backend workflows; every one gets a generated
      entry point (its Ash action, registry entry and, when exposed, its
      endpoint)
    * `"workflows"` - `"native"`: workflows whose **whole body** is
      generated with no residue (neither the lowering's, see
      `BubbleEx.Workflows.Backend.coverage/1`, nor the Ash binding's: an
      IR that does not compile to Elixir, a context input a backend
      workflow lacks); `"residue"`: the rest, which need agent work
    * `"steps"` - actions of those workflows; `"native"` the ones generated
      with no residue
    * `"by_kind"` - `{total, native}` workflows per kind; `"step_ops"` -
      native steps per operation; `"residue_reasons"` - residue entries
      per reason (a subject may have several)
    * `"native_with_callees"` - native workflows whose every called or
      scheduled workflow is native too, transitively (a native body can
      still call a workflow with residue, which fails when it runs)
    * `"exposed_privacy_bypasses"` - exposed workflows that run with
      `authorize?: false`, by the authentication their endpoint requires
      (`none` means anyone on the internet can run it)
    * `"privacy_bypasses"` (workflows run with `authorize?: false`),
      `"exposed"`, `"triggers"` (data resources with a trigger change) and
      `"cycles"`
  """
  @spec coverage(t()) :: map()
  def coverage(%__MODULE__{} = spec) do
    actions = actions(spec)
    steps = Enum.flat_map(actions, & &1.steps)
    native = Enum.filter(actions, &native?/1)

    %{
      "entry_points" => length(actions),
      "workflows" => %{
        "total" => length(actions),
        "native" => length(native),
        "residue" => length(actions) - length(native)
      },
      "steps" => %{
        "total" => length(steps),
        "native" => Enum.count(steps, &(&1.residue == [])),
        "residue" => Enum.count(steps, &(&1.residue != []))
      },
      "by_kind" =>
        actions
        |> Enum.group_by(&Atom.to_string(&1.kind))
        |> Map.new(fn {kind, as} ->
          {kind, %{"total" => length(as), "native" => Enum.count(as, &native?/1)}}
        end),
      "step_ops" =>
        steps
        |> Enum.filter(&(&1.residue == [] and &1.op != nil))
        |> Enum.frequencies_by(&Atom.to_string(&1.op)),
      "residue_reasons" =>
        actions
        |> Enum.flat_map(&action_residue/1)
        |> Enum.frequencies_by(&Atom.to_string(&1.reason)),
      "native_with_callees" => native |> Enum.filter(&callees_native?(&1, actions)) |> length(),
      "privacy_bypasses" => length(spec.privacy_bypasses),
      "exposed_privacy_bypasses" =>
        actions
        |> Enum.filter(&(&1.exposed && &1.authorize == false))
        |> Enum.frequencies_by(&Atom.to_string(&1.exposed.auth)),
      "exposed" => Enum.count(actions, & &1.exposed),
      "triggers" => length(spec.triggers),
      "cycles" => length(spec.cycles)
    }
  end
end
