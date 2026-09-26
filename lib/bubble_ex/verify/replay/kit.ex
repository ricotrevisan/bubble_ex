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

  `preflight/4` reads, and never writes:

    1. the API metadata of the branch (`/api/1.1/meta`): the branch and its
       API answer; the kit workflows are listed among the exposed
       workflows (`post`)
    2. per type under test, a Data API search constrained to an ID that
       cannot exist (`Client.probe/2`, so no record is read): the type is
       exposed
    3. per exposed type, the **anonymous exposure probe**
       (`Client.anonymous_probe/3`): a branch shares the development
       database with `test`, and enabling the Data API exposes it to
       anyone as far as the privacy rules allow. A type is safe only when
       a logged-out caller is refused or gets nothing beyond `_id`,
       `Created Date` and `Modified Date`; otherwise the check is
       `:exposed` (with the extra field names, never values) and the
       preflight fails. Disable that type's exposure at once
    4. with `personas: true` (the seed signs users up), **persona
       cleanup**: sign-ups are deleted, and unconfirmed ones found by
       email, only through the `User` Data API, so `user` must be among
       the types and pass checks 2 and 3. Otherwise the check is
       `:missing` and the run is refused: record logged-out only (a seed
       with no users)

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

  @doc """
  Runs the preflight for `types` (type descriptors). See the moduledoc.
  Options: `:personas` (default `false`), `:anonymous_limit` (records per
  anonymous probe, default 25).
  """
  @spec preflight(Client.t(), t(), [String.t()], keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def preflight(%Client{} = client, %__MODULE__{} = kit, types, opts \\ []) do
    limit = Keyword.get(opts, :anonymous_limit, 25)

    with {:ok, meta} <- Client.meta(client),
         {:ok, type_checks} <- type_checks(client, types, limit) do
      checks =
        meta_checks(meta, kit) ++
          type_checks ++ persona_checks(Keyword.get(opts, :personas, false), type_checks)

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

  defp exposed({:ok, check}, type, acc),
    do: {:cont, {:ok, [check, %{check: :data_api, type: type, status: :ok} | acc]}}

  defp exposed({:error, _} = error, _type, _acc), do: {:halt, error}

  defp anonymous_check(client, type, limit) do
    case Client.anonymous_probe(client, type, limit) do
      {:ok, %{status: :denied, http_status: s}} ->
        {:ok,
         %{
           check: :anonymous_exposure,
           type: type,
           status: :ok,
           anonymous: :denied,
           http_status: s
         }}

      {:ok, %{status: :answered, extra_fields: []} = probe} ->
        {:ok,
         %{
           check: :anonymous_exposure,
           type: type,
           status: :ok,
           anonymous: :ids_only,
           records: probe.records,
           remaining: probe.remaining
         }}

      {:ok, %{status: :answered} = probe} ->
        {:ok,
         %{
           check: :anonymous_exposure,
           type: type,
           status: :exposed,
           anonymous: :fields,
           records: probe.records,
           remaining: probe.remaining,
           extra_fields: probe.extra_fields
         }}

      {:error, _} = error ->
        error
    end
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

  defp persona_checks(false, _type_checks), do: []

  defp persona_checks(true, type_checks) do
    user = for %{type: "user"} = check <- type_checks, do: check.status

    status =
      if user != [] and Enum.all?(user, &(&1 == :ok)), do: :ok, else: :missing

    [
      %{
        check: :persona_cleanup,
        status: status,
        detail:
          if(status == :ok,
            do: nil,
            else:
              "signed-up personas can be deleted only through a safely exposed User Data API; " <>
                "record logged-out only (a seed without users) instead"
          )
      }
    ]
  end

  defp type_checks(client, types, limit) do
    types
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn type, {:ok, acc} ->
      case Client.probe(client, type) do
        {:ok, _} ->
          exposed(anonymous_check(client, type, limit), type, acc)

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
