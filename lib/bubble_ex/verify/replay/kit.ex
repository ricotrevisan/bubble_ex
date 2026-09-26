defmodule BubbleEx.Verify.Replay.Kit do
  @moduledoc """
  The replay kit the owner adds to the `wtfreplay…` branch (decision D3 on
  WTF-358; the checklist is `docs/replay-kit.md`), and the harness
  preflight that checks it is there before any write.

    * `marker` - API workflow name (default `wtf_replay_marker`), run
      **without authentication**, no parameters, returning `branch` (the
      branch's name, typed as a literal) and `nonce` (an operator-chosen
      literal, the target's `:marker_nonce`). It exists only on the
      replay branch, so it ties the branch ID the operator supplied to the
      replay branch before any token is sent
    * `signup` - API workflow name (default `wtf_replay_signup`):
      parameters `email`, `password`; signs the user up and returns
      `user_id`
    * `login` - API workflow name (default `wtf_replay_login`): parameters
      `email`, `password`; logs the user in and returns `token` (and
      `user_id`, `expires`)

  `preflight/4` reads, and never writes:

    1. **target verification, without a token**
       (`BubbleEx.Verify.Replay.Client.verify/2`): Bubble's `/meta` shape,
       then the marker's exact branch name and nonce. Anything else stops
       the preflight with `reason: :unverified_target`; no token was sent
    2. the API metadata as admin: the signup and login workflows are
       listed among the exposed workflows (`post`)
    3. per type under test, a Data API search constrained to an ID that
       cannot exist (`Client.probe/2`, so no record is read): the type is
       exposed
    4. per exposed type, the **anonymous exposure probe**
       (`Client.anonymous_probe/3`, up to `:anonymous_cap` records). A
       branch shares the development database with `test`, and enabling
       the Data API exposes it to anyone as far as the privacy rules
       allow. The check fails closed:
         * `:denied` (401/403/404 to a logged-out caller): `:ok`
         * fields beyond `_id`, `Created Date` and `Modified Date` came
           back: `:exposed` (the field names, never values), never
           overridable. Disable that type's exposure at once
         * no record came back: `:unproven` (nothing shows that the rules
           hide the fields: there may be no record they open yet), unless
           the type is proven hidden (`:anonymous_proof`) or the operator
           accepts it (`:allow_unproven`, reported with a warning)
         * records came back with only IDs and dates: Bubble omits empty
           fields, so this is `:ok` only when the metadata lists no other
           field for the type, or the type is proven hidden; otherwise
           `:may_leak`
    5. with `personas: true` (the seed signs users up), **persona
       cleanup**: sign-ups are deleted, and unconfirmed ones found by
       email, only through the `User` Data API, so `user` must be among
       the types and pass checks 3 and 4. Otherwise the check is
       `:missing` and the run is refused: record logged-out only (a seed
       with no users)

  Owner-only items (privacy rules unchanged from the parent version, the
  replay token is a dedicated one, the signup and login workflows need the
  admin token) cannot be read through the API; the report lists them as
  `:manual`. The report is `ok?` only when every read check is `:ok`.
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Interpreter.Dataset
  alias BubbleEx.Verify.Replay.{Client, Names}

  defstruct signup: "wtf_replay_signup",
            login: "wtf_replay_login",
            marker: "wtf_replay_marker"

  @type t :: %__MODULE__{signup: String.t(), login: String.t(), marker: String.t()}
  @type status :: :ok | :missing | :unverified | :exposed | :unproven | :may_leak
  @type report :: %{ok?: boolean(), checks: [map()], manual: [atom()], warnings: [map()]}

  @manual [
    :privacy_rules_unchanged_from_parent,
    :dedicated_replay_admin_token,
    :kit_workflows_require_admin_token,
    :no_real_people_data_in_development
  ]

  @doc """
  Runs the preflight for `types` (type descriptors). See the moduledoc.

  Options:

    * `:personas` - the seed signs users up (default `false`)
    * `:anonymous_cap` - records read per anonymous probe (default 200)
    * `:anonymous_proof` - `%{Bubble type ID => :hidden}` (`"task"`,
      `"user"`): types a
      privacy analysis proved show a logged-out visitor no field (see
      `anonymous_proof/1`)
    * `:allow_unproven` - type descriptors the operator accepts although
      the anonymous probe found no record (each is reported in
      `warnings`)
  """
  @spec preflight(Client.t(), t(), [String.t()], keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def preflight(%Client{} = client, %__MODULE__{} = kit, types, opts \\ []) do
    with {:ok, schema} <- Client.verify(client, kit),
         {:ok, meta} <- Client.meta(client),
         {:ok, type_checks} <- type_checks(client, types, schema, opts) do
      checks =
        meta_checks(meta, kit) ++
          type_checks ++ persona_checks(Keyword.get(opts, :personas, false), type_checks)

      {:ok,
       %{
         ok?: Enum.all?(checks, &(&1.status == :ok)),
         checks: checks,
         manual: @manual,
         warnings: for(%{warning: w} = c <- checks, do: %{type: c[:type], warning: w})
       }}
    end
  end

  @doc """
  A conservative proof, from an app's Model, of the types whose privacy
  rules show a logged-out visitor nothing: every rule of the type, the
  `everyone` rule included, grants no field (`view_all` not true, no
  `view_fields`) and no search. A type without privacy rules, or with a
  rule that could grant something, is not proven, whatever its
  conditions. Returns `%{Bubble type ID => :hidden}` (`"task"`, `"user"`)
  for `:anonymous_proof`.
  """
  @spec anonymous_proof(BubbleEx.Model.t()) :: %{String.t() => :hidden}
  def anonymous_proof(%{data_types: data_types}) do
    for dt <- data_types,
        dt.privacy == :present,
        dt.rules != [],
        Enum.all?(dt.rules, &grants_nothing?/1),
        into: %{},
        do: {dt.id, :hidden}
  end

  defp grants_nothing?(%{permissions: nil}), do: false

  defp grants_nothing?(%{permissions: p}),
    do: p.view_all != true and p.search_for != true and p.view_fields in [nil, []]

  # --- metadata ----------------------------------------------------------------------

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

  # Field names the metadata lists for a type (`types.<path>.fields`, a
  # list of names or `%{"key"|"name" => …}` objects, or an object keyed by
  # name), or `:unknown`.
  defp schema_fields(schema, path) do
    case get_in(schema, ["types", path]) do
      %{"fields" => fields} when is_list(fields) ->
        names =
          Enum.map(fields, fn
            name when is_binary(name) -> name
            %{"key" => name} when is_binary(name) -> name
            %{"name" => name} when is_binary(name) -> name
            _ -> :unreadable
          end)

        if :unreadable in names, do: :unknown, else: {:ok, names}

      %{"fields" => fields} when is_map(fields) ->
        {:ok, Map.keys(fields)}

      _ ->
        :unknown
    end
  end

  # --- types -------------------------------------------------------------------------

  defp type_checks(client, types, schema, opts) do
    types
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn type, {:ok, acc} ->
      case Client.probe(client, type) do
        {:ok, _} ->
          exposed(anonymous_check(client, type, schema, opts), type, acc)

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

  defp exposed({:ok, check}, type, acc),
    do: {:cont, {:ok, [check, %{check: :data_api, type: type, status: :ok} | acc]}}

  defp exposed({:error, _} = error, _type, _acc), do: {:halt, error}

  defp anonymous_check(client, type, schema, opts) do
    with {:ok, probe} <-
           Client.anonymous_probe(client, type, Keyword.get(opts, :anonymous_cap, 200)),
         {:ok, path} <- Names.type_path(client.names, type) do
      proven? =
        Map.get(Keyword.get(opts, :anonymous_proof, %{}), Dataset.type_id(type)) == :hidden

      accepted? = type in Keyword.get(opts, :allow_unproven, [])
      base = %{check: :anonymous_exposure, type: type}

      {:ok, Map.merge(base, verdict(probe, schema_fields(schema, path), proven?, accepted?))}
    end
  end

  defp verdict(%{status: :denied, http_status: s}, _schema, _proven?, _accepted?),
    do: %{status: :ok, anonymous: :denied, http_status: s}

  defp verdict(%{extra_fields: [_ | _]} = probe, _schema, _proven?, _accepted?),
    do:
      Map.merge(counts(probe), %{
        status: :exposed,
        anonymous: :fields,
        extra_fields: probe.extra_fields
      })

  defp verdict(%{records: 0} = probe, _schema, proven?, accepted?) do
    cond do
      proven? ->
        Map.merge(counts(probe), %{status: :ok, anonymous: :proven_hidden})

      accepted? ->
        Map.merge(counts(probe), %{
          status: :ok,
          anonymous: :unproven,
          warning: "no record answered a logged-out caller; accepted by the operator unproven"
        })

      true ->
        Map.merge(counts(probe), %{status: :unproven, anonymous: :no_records})
    end
  end

  defp verdict(probe, schema, proven?, _accepted?) do
    other = with {:ok, names} <- schema, do: names -- Client.anonymous_fields()

    cond do
      other == [] -> Map.merge(counts(probe), %{status: :ok, anonymous: :ids_only})
      proven? -> Map.merge(counts(probe), %{status: :ok, anonymous: :proven_hidden})
      true -> Map.merge(counts(probe), %{status: :may_leak, anonymous: :ids_only})
    end
  end

  defp counts(probe), do: Map.take(probe, [:records, :remaining, :capped])

  # --- personas -----------------------------------------------------------------------

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
end
