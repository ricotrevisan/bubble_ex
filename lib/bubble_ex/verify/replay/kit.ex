defmodule BubbleEx.Verify.Replay.Kit do
  @moduledoc """
  The replay kit the owner adds to the `wtfreplay…` branch (decision D3 on
  WTF-358; the checklist is `docs/replay-kit.md`), and the harness
  preflight that checks it is there before any write.

    * `signup` - API workflow name (default `wtf_replay_signup`):
      parameters `email`, `password`; signs the user up and returns
      `user_id`
    * `login` - API workflow name (default `wtf_replay_login`): parameters
      `email`, `password`; logs the user in and returns `token` (and
      `user_id`, `expires`)

  `preflight/3` reads, and never writes:

    1. the API metadata of the branch (`/api/1.1/meta`): the branch and its
       API answer; the kit workflows are listed among the exposed
       workflows (`post`)
    2. per type under test, a Data API search constrained to an ID that
       cannot exist (`Client.probe/2`, so no record is read): the type is
       exposed

  Owner-only items (privacy rules unchanged from the parent version, the
  replay token is a dedicated one, the kit workflows need the admin token)
  cannot be read through the API; the report lists them as `:manual`.
  The report is `ok?` only when every read check is `:ok`.
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Replay.Client

  defstruct signup: "wtf_replay_signup", login: "wtf_replay_login"

  @type t :: %__MODULE__{signup: String.t(), login: String.t()}
  @type status :: :ok | :missing | :unverified
  @type report :: %{ok?: boolean(), checks: [map()], manual: [atom()]}

  @manual [
    :privacy_rules_unchanged_from_parent,
    :dedicated_replay_admin_token,
    :kit_workflows_require_admin_token,
    :no_real_people_data_in_development
  ]

  @doc "Runs the preflight for `types` (type descriptors). See the moduledoc."
  @spec preflight(Client.t(), t(), [String.t()]) :: {:ok, report()} | {:error, Error.t()}
  def preflight(%Client{} = client, %__MODULE__{} = kit, types) do
    with {:ok, meta} <- Client.meta(client),
         {:ok, type_checks} <- type_checks(client, types) do
      checks = meta_checks(meta, kit) ++ type_checks

      {:ok,
       %{
         ok?: Enum.all?(checks, &(&1.status == :ok)),
         checks: checks,
         manual: @manual
       }}
    end
  end

  defp meta_checks(%{status: 200, body: body}, kit) when is_map(body) do
    workflows = listed(body["post"])

    [%{check: :branch_api, status: :ok}] ++
      for name <- [kit.signup, kit.login] do
        status =
          cond do
            workflows == nil -> :unverified
            name in workflows -> :ok
            true -> :missing
          end

        %{check: :workflow, workflow: name, status: status}
      end
  end

  defp meta_checks(%{status: status}, kit) do
    [%{check: :branch_api, status: :missing, http_status: status}] ++
      for name <- [kit.signup, kit.login],
          do: %{check: :workflow, workflow: name, status: :unverified}
  end

  defp listed(list) when is_list(list) do
    Enum.flat_map(list, fn
      name when is_binary(name) -> [name]
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp listed(map) when is_map(map), do: Map.keys(map)
  defp listed(_), do: nil

  defp type_checks(client, types) do
    types
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn type, {:ok, acc} ->
      case Client.probe(client, type) do
        {:ok, _} ->
          {:cont, {:ok, [%{check: :data_api, type: type, status: :ok} | acc]}}

        {:error, %Error{kind: kind} = error}
        when kind in [:not_found, :http_error, :unauthorized, :forbidden] ->
          check = %{check: :data_api, type: type, status: :missing, error: error.context}
          {:cont, {:ok, [check | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, checks} -> {:ok, Enum.reverse(checks)}
      error -> error
    end
  end
end
