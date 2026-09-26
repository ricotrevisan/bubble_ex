defmodule BubbleEx.Plan.Criteria do
  @moduledoc """
  The abstract acceptance criteria of plan tasks (WTF-359 §4). A criterion
  is `%{id, check, args, waiver}`: `check` names what to verify, `args`
  what it applies to (symbol IDs, never commands or paths). A target
  adapter binds each check to a concrete verifier; the plan stays
  stack-neutral.

  | check | verifies |
  |-------|----------|
  | `:generated_unchanged` | generated files still match the generator's manifest hashes |
  | `:deterministic` | regenerating from the same inputs gives identical output (generator nodes) |
  | `:compiles` | the project builds without warnings |
  | `:lint` | formatting and lint pass on the touched files |
  | `:traceability` | the rendered output carries the Bubble ID of every listed element (`args.elements`) |
  | `:render_smoke` | the surface renders with fixtures and no placeholder is left |
  | `:visual_parity` | screenshots match the Bubble snapshot within tolerance |
  | `:step_order` | one step marker per action of `args.workflow`, in the order of `args.steps` |
  | `:unit_test` | a test calls each listed workflow or flow with fixtures |
  | `:request_shape` | a test asserts each listed API call's method, URL, headers and body |
  | `:policy_matrix` | the privacy rules' allow and deny matrix holds |
  | `:replay` | recorded Bubble scenarios in `args.scope` replay identically |
  | `:data_counts` | the load's per-type counts match the export (`args.mode`: `:dry_run` or `:full`) |
  | `:subtasks_done` | every subtask is closed |
  | `:independent_review` | the reviewer is not the implementer of `args.of` |
  | `:decision_recorded` | the owner decision `args.key` is recorded and active |
  | `:attested` | a person or agent states `args.about` holds, with a reason |

  Only `:attested` criteria may be waived (`waiver: :allowed`); every other
  one is `:forbidden`.
  """

  alias BubbleEx.Plan.Task

  @checks ~w(generated_unchanged deterministic compiles lint traceability render_smoke visual_parity
             step_order unit_test request_shape policy_matrix replay data_counts subtasks_done
             independent_review decision_recorded attested)a

  @doc "The check kinds."
  @spec checks() :: [atom()]
  def checks, do: @checks

  @doc """
  The criteria of `task`. `facts` carries what the checks need beyond the
  task: `:elements` (traced element IDs), `:steps` (a workflow's action
  types in order), `:children` (subtask IDs), `:backend` (a backend
  workflow), `:surface` (an acceptance task's surface task).
  """
  @spec for_task(Task.t(), map()) :: [Task.criterion()]
  def for_task(%Task{} = task, facts) do
    task
    |> checks_for(facts)
    |> then(&if(Map.get(facts, :children, []) != [], do: &1 ++ [{:subtasks_done, %{}}], else: &1))
    |> Enum.with_index(1)
    |> Enum.map(fn {{check, args}, id} ->
      %{
        id: id,
        check: check,
        args: args,
        waiver: if(check == :attested, do: :allowed, else: :forbidden)
      }
    end)
  end

  defp checks_for(%Task{kind: :generate, id: id, subjects: subjects}, _facts) do
    base = [{:generated_unchanged, %{}}, {:deterministic, %{}}, {:compiles, %{}}]

    case id do
      "generate:policies" -> base ++ [{:policy_matrix, %{rules: subjects}}]
      "generate:api_clients" -> base ++ [{:request_shape, %{calls: calls(subjects)}}]
      _ -> base
    end
  end

  defp checks_for(%Task{kind: kind, closed_by: key}, _facts)
       when kind in [:remove_writes, :delete_workflows],
       do: [{:decision_recorded, %{key: key}}, {:generated_unchanged, %{}}]

  defp checks_for(%Task{kind: :setup_secrets, subjects: subjects}, _facts),
    do: [{:attested, %{about: :secrets_provided, subjects: subjects}}]

  defp checks_for(%Task{kind: :auth, subjects: subjects}, _facts),
    do: code() ++ [{:unit_test, %{workflows: subjects}}, {:replay, %{scope: :auth}}]

  defp checks_for(%Task{kind: :styles_residue, subjects: subjects}, _facts),
    do:
      code() ++
        [
          {:visual_parity, %{styles: subjects}},
          {:attested, %{about: :styles_match}}
        ]

  defp checks_for(%Task{kind: :plugin, subjects: subjects}, _facts),
    do:
      code() ++
        [
          {:render_smoke, %{elements: Enum.filter(subjects, &element?/1)}},
          {:attested, %{about: :plugin_replaced}}
        ]

  defp checks_for(%Task{kind: :surface, subjects: subjects}, facts),
    do:
      [{:generated_unchanged, %{}} | code()] ++
        [
          {:traceability, %{elements: Map.get(facts, :elements, [])}},
          {:render_smoke, %{surfaces: subjects}},
          {:visual_parity, %{surfaces: subjects}}
        ]

  defp checks_for(%Task{kind: :fragment}, facts),
    do:
      [{:generated_unchanged, %{}} | code()] ++
        [{:traceability, %{elements: Map.get(facts, :elements, [])}}]

  defp checks_for(%Task{kind: :workflow, subjects: [workflow]}, facts) do
    steps = [{:step_order, %{workflow: workflow, steps: Map.get(facts, :steps, [])}}]
    tests = if facts[:backend], do: [{:unit_test, %{workflows: [workflow]}}], else: []
    code() ++ steps ++ tests
  end

  defp checks_for(%Task{kind: kind, subjects: subjects}, _facts) when kind in [:backend, :cycle],
    do: code() ++ [{:unit_test, %{workflows: Enum.filter(subjects, &workflow?/1)}}]

  defp checks_for(%Task{kind: :api_group, subjects: subjects}, facts),
    do:
      [{:generated_unchanged, %{}} | code()] ++
        [{:request_shape, %{calls: Map.get(facts, :children, calls(subjects))}}]

  defp checks_for(%Task{kind: :api_call, subjects: subjects}, _facts),
    do: [{:request_shape, %{calls: subjects}}]

  defp checks_for(%Task{kind: :acceptance, subjects: subjects}, facts),
    do: [
      {:traceability, %{elements: Map.get(facts, :elements, [])}},
      {:render_smoke, %{surfaces: subjects}},
      {:visual_parity, %{surfaces: subjects}},
      {:independent_review, %{of: facts[:surface]}},
      {:attested, %{about: :reviewed_against_bubble}}
    ]

  defp checks_for(%Task{id: "data:dry_run"}, _facts), do: [{:data_counts, %{mode: :dry_run}}]
  defp checks_for(%Task{id: "data:full_load"}, _facts), do: [{:data_counts, %{mode: :full}}]
  defp checks_for(%Task{kind: :replay}, _facts), do: [{:replay, %{scope: :all}}]

  defp checks_for(%Task{kind: kind, id: id}, _facts) when kind in [:delivery, :cutover],
    do: [{:attested, %{about: id}}]

  defp code, do: [{:compiles, %{}}, {:lint, %{}}]

  defp calls(subjects), do: Enum.filter(subjects, &String.starts_with?(&1, "api_call:"))
  defp element?(id), do: String.starts_with?(id, "element:")
  defp workflow?(id), do: String.starts_with?(id, "workflow:")
end
