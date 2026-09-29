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
    2. the API metadata as admin: with `personas: true`, the signup and
       login workflows are listed among the exposed workflows (`post`,
       whose entries Bubble names by `endpoint`). A seed without users
       never calls them, so it does not need them
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
           back: `:exposed` (the field names, never values). Disable
           that type's exposure at once. Only an owner's
           `:exposure_waiver` can let it pass (see below)
         * no record came back: `:unproven` (nothing shows that the rules
           hide the fields: there may be no record they open yet), unless
           the type is proven hidden (`:anonymous_proof`) or the operator
           accepts it (`:allow_unproven`, reported with a warning)
         * records came back with only IDs and dates: Bubble omits empty
           fields, so this is `:ok` only when the metadata lists no other
           field for the type, or the type is proven hidden; otherwise
           `:may_leak` (with the metadata's other field names as
           `possible_fields`)
    5. with `personas: true` (the seed signs users up), **persona
       cleanup**: sign-ups are deleted, and unconfirmed ones found by
       email, only through the `User` Data API, so `user` must be among
       the types and pass checks 3 and 4. Otherwise the check is
       `:missing` and the run is refused: record logged-out only (a seed
       with no users), unless `user`'s `:exposed`/`:may_leak` finding is
       waived by the owner (below)

  **Owner exposure waiver.** Fail-closed is the default. The only
  override is `:exposure_waiver`, a `BubbleEx.Verify.Replay.ExposureWaiver`
  the app owner wrote as a private file and `ExposureWaiver.load_waiver/1`
  loaded. It is re-read and checked (target, types and their Data API
  paths, expiry) before anything is sent; a waiver that fails refuses the
  preflight with no request made. It turns only `:exposed` and `:may_leak`
  of the types it lists into accepted checks (`waived: true`); the check
  keeps its actual `status`, `probe_status`, counts and field names, and
  gets a warning. `:unproven`, `:missing` and every other type stay
  refused. `report.exposure_waiver` summarizes the waiver (its SHA-256
  included).

  Owner-only items (privacy rules unchanged from the parent version, the
  replay token is a dedicated one, the signup and login workflows need the
  admin token) cannot be read through the API; the report lists them as
  `:manual`. The report is `ok?` only when every read check is `:ok`
  or a waived exposure finding.
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Interpreter.Dataset
  alias BubbleEx.Verify.Replay.{Client, ExposureWaiver, Names}

  defstruct signup: "wtf_replay_signup",
            login: "wtf_replay_login",
            marker: "wtf_replay_marker"

  @type t :: %__MODULE__{signup: String.t(), login: String.t(), marker: String.t()}
  @type status :: :ok | :missing | :unverified | :exposed | :unproven | :may_leak
  @type report :: %{
          ok?: boolean(),
          checks: [map()],
          manual: [atom()],
          warnings: [map()],
          exposure_waiver: map() | nil
        }

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
    * `:exposure_waiver` - an owner's `ExposureWaiver` (see the moduledoc)
  """
  @spec preflight(Client.t(), t(), [String.t()], keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def preflight(%Client{} = client, %__MODULE__{} = kit, types, opts \\ []) do
    with :ok <- waiver_ok(client, types, opts),
         {:ok, schema} <- Client.verify(client, kit),
         {:ok, meta} <- Client.meta(client),
         {:ok, type_checks} <- type_checks(client, types, schema, opts) do
      personas? = Keyword.get(opts, :personas, false)

      checks =
        meta_checks(meta, kit, personas?) ++
          type_checks ++ persona_checks(personas?, type_checks)

      {:ok,
       %{
         ok?: Enum.all?(checks, &accepted?/1),
         checks: checks,
         manual: @manual,
         warnings: for(%{warning: w} = c <- checks, do: %{type: c[:type], warning: w}),
         exposure_waiver: ExposureWaiver.summary(opts[:exposure_waiver])
       }}
    end
  end

  # A waiver is checked against its file, before any request.
  defp waiver_ok(client, types, opts) do
    case Keyword.fetch(opts, :exposure_waiver) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, waiver} ->
        ExposureWaiver.check(
          waiver,
          client.target,
          client.names,
          Enum.uniq(types),
          DateTime.utc_now()
        )
    end
  end

  defp accepted?(%{status: :ok}), do: true

  defp accepted?(%{check: :anonymous_exposure, status: status, waived: true})
       when status in [:exposed, :may_leak],
       do: true

  defp accepted?(_check), do: false

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

  defp meta_checks(%{status: 200, body: body}, kit, personas?) when is_map(body) do
    workflows = listed(body["post"])

    [%{check: :branch_api, status: :ok}] ++
      for name <- kit_workflows(kit, personas?) do
        status =
          cond do
            workflows == nil -> :unverified
            name in workflows -> :ok
            true -> :missing
          end

        %{check: :workflow, workflow: name, status: status}
      end
  end

  defp meta_checks(%{status: status}, kit, personas?) do
    [%{check: :branch_api, status: :missing, http_status: status}] ++
      for name <- kit_workflows(kit, personas?),
          do: %{check: :workflow, workflow: name, status: :unverified}
  end

  defp kit_workflows(kit, true), do: [kit.signup, kit.login]
  defp kit_workflows(_kit, false), do: []

  defp listed(list) when is_list(list) do
    Enum.flat_map(list, fn
      name when is_binary(name) -> [name]
      %{"endpoint" => name} when is_binary(name) -> [name]
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp listed(map) when is_map(map), do: Map.keys(map)
  defp listed(_), do: nil

  # Field names the metadata lists for a type (`types.<path>.fields`, a
  # list of names or `%{"key"|"name" => …}` objects, or an object keyed by
  # name), or `:unknown`. Bubble lists `%{"id", "display", "type"}` objects,
  # built-in fields included (the built-in `id` "_id", displayed `unique
  # ID`, is the Data API's `_id`); the
  # Data API names fields by `display` when `app_data.use_captions_for_get`
  # is true, by `id` otherwise.
  defp schema_fields(schema, path) do
    key = if get_in(schema, ["app_data", "use_captions_for_get"]), do: "display", else: "id"

    case get_in(schema, ["types", path]) do
      %{"fields" => fields} when is_list(fields) ->
        names =
          Enum.map(fields, fn
            name when is_binary(name) -> name
            %{"key" => name} when is_binary(name) -> name
            %{"name" => name} when is_binary(name) -> name
            # The built-in ID (`id` "_id", displayed `unique ID`) is `_id`
            # in Data API answers, whatever key the metadata uses.
            %{"id" => "_id"} -> "_id"
            %{"id" => _} = field -> readable(field[key])
            _ -> :unreadable
          end)

        if :unreadable in names, do: :unknown, else: {:ok, names}

      %{"fields" => fields} when is_map(fields) ->
        {:ok, Map.keys(fields)}

      _ ->
        :unknown
    end
  end

  defp readable(name) when is_binary(name), do: name
  defp readable(_), do: :unreadable

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

      check = Map.merge(base, verdict(probe, schema_fields(schema, path), proven?, accepted?))
      {:ok, waive(check, opts[:exposure_waiver])}
    end
  end

  # Only `:exposed` and `:may_leak`, only for a listed type. The actual
  # finding stays; the check is marked and warned.
  defp waive(%{status: status, type: type} = check, waiver)
       when status in [:exposed, :may_leak] do
    if ExposureWaiver.waives?(waiver, type),
      do:
        Map.merge(check, %{
          waived: true,
          warning:
            "OWNER-WAIVED ANONYMOUS EXPOSURE: #{type} is #{status} to logged-out callers " <>
              "(#{check[:records]} record(s) read); its data on this branch may be publicly " <>
              "readable until the waiver expires and the exposure is removed"
        }),
      else: check
  end

  defp waive(check, _waiver), do: check

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
      other == [] ->
        Map.merge(counts(probe), %{status: :ok, anonymous: :ids_only})

      proven? ->
        Map.merge(counts(probe), %{status: :ok, anonymous: :proven_hidden})

      true ->
        Map.merge(counts(probe), %{
          status: :may_leak,
          anonymous: :ids_only,
          possible_fields: possible(other)
        })
    end
  end

  defp possible(fields) when is_list(fields), do: fields
  defp possible(_unknown), do: :unknown

  defp counts(probe),
    do:
      probe
      |> Map.take([:records, :remaining, :capped])
      |> Map.put(:probe_status, probe.status)

  # --- personas -----------------------------------------------------------------------

  defp persona_checks(false, _type_checks), do: []

  defp persona_checks(true, type_checks) do
    user = for %{type: "user"} = check <- type_checks, do: check

    status =
      if user != [] and Enum.all?(user, &accepted?/1), do: :ok, else: :missing

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
