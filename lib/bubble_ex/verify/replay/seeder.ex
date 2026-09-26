defmodule BubbleEx.Verify.Replay.Seeder do
  @moduledoc """
  Loads a `BubbleEx.Verify.Seed` into the replay branch (WTF-358 §3.6) and
  writes the seed ledger as it goes.

    1. **Users** (records of type `user`, by key): signed up through the
       kit's sign-up workflow with a per-run sink-domain email (the seed's
       reserved-domain address with `+<run id>` in its local part, so two
       runs never collide) and a random password, then logged in through
       the kit's login workflow for their token. Bubble emails never reach
       real people.
    2. **Records** (other types, by key): created through the Data API.
       A record whose `Created By` names a seeded user is created with that
       user's token, so Bubble sets its creator; others with the admin
       token. `Created By`, `Created Date`, `Modified Date` and `_id` are
       never sent. References to records not created yet are deferred.
    3. **Deferred fields**, and the users' own fields (email excluded),
       are set with ledger-only updates.
    4. **Explicit empties**: a seed field whose value is `nil` must be
       empty, but Bubble stores a field's default on creation. So after
       creation (and the deferred updates) each such field is cleared
       with a ledger-only update that sets it to `null`, and the clear is
       journaled (`Ledger.note_cleared/4`, field names only). A clear
       Bubble refuses does not stop the run: the record is listed in
       `state.uncleared` (`%{key => [field]}`) and the recorder makes the
       scenarios that depend on it incomplete. A budget that runs out
       still stops the run
    5. **Delete after seed** (`:delete_after_seed` keys): those records are
       deleted again through the ledger, so the references to them dangle.
       That is how a replay calibrates `dangling_ref_is_empty` (a V1 seed
       cannot hold a missing reference).

  Every create and sign-up is journaled as an intent (with the user's
  unique run email) **before** it is sent and confirmed with its Bubble ID
  after (`BubbleEx.Verify.Replay.Ledger`). A failure returns the ledger so
  far (`{:error, error, state}`): cleanup deletes what was confirmed and
  looks unconfirmed sign-ups up by their exact email
  (`BubbleEx.Verify.Replay.Cleanup`).
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Replay.{Client, Codec, Kit, Ledger, Names, Session}
  alias BubbleEx.Verify.{Seed, Value}

  @never_sent ["Created By", "Created Date", "Modified Date", "_id"]

  @type state :: %{
          ledger: Ledger.t(),
          session: Session.t(),
          uncleared: %{String.t() => [String.t()]}
        }

  @doc "Seeds `seed` into `ledger`'s run. See the moduledoc."
  @spec seed(Client.t(), Seed.t(), Ledger.t(), keyword()) ::
          {:ok, state()} | {:error, Error.t(), state()}
  def seed(%Client{} = client, %Seed{} = seed, %Ledger{} = ledger, opts \\ []) do
    kit = Keyword.get(opts, :kit, %Kit{})
    run_id = ledger.run_id
    state = %{ledger: ledger, session: %Session{}, deferred: %{}, uncleared: %{}}
    {users, records} = Enum.split_with(seed.records, &(&1.type == "user"))

    steps = [
      &users(client, kit, run_id, users, &1),
      &records(client, records, &1),
      &deferred(client, seed.records, &1),
      &clear_empties(client, seed.records, &1),
      &delete_after(client, Keyword.get(opts, :delete_after_seed, []), &1)
    ]

    steps
    |> Enum.reduce_while({:ok, state}, fn step, {:ok, state} ->
      case step.(state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error, state} -> {:halt, {:error, error, state}}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, Map.delete(state, :deferred)}
      {:error, error, state} -> {:error, error, Map.delete(state, :deferred)}
    end
  end

  defp each(items, state, fun) do
    Enum.reduce_while(items, {:ok, state}, fn item, {:ok, state} ->
      case fun.(item, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error, state}}
        {:error, error, state} -> {:halt, {:error, error, state}}
      end
    end)
  end

  # --- users -----------------------------------------------------------------------

  defp users(client, kit, run_id, users, state) do
    each(users, state, fn user, state ->
      email = run_email(user, run_id)
      password = Session.password()
      session = Session.put_user(state.session, user.key, email, password)
      state = %{state | session: session}
      params = %{"email" => email, "password" => password}

      # The intent (with the unique run email) is journaled before the
      # sign-up, so a lost answer can still be cleaned up by that email.
      with {:ok, ledger} <- Ledger.intend(state.ledger, user.key, "user", email),
           state = %{state | ledger: ledger},
           {:ok, id} <- signup(client, kit, params, state),
           {:ok, ledger} <- confirm(state, user.key, id),
           state = %{state | ledger: ledger},
           {:ok, token} <- login(client, kit, params, state) do
        {:ok, %{state | session: Session.put_token(state.session, user.key, token)}}
      end
    end)
  end

  defp confirm(state, key, id) do
    case Ledger.confirm(state.ledger, key, id) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, error} -> {:error, error, state}
    end
  end

  @doc false
  @spec run_email(map(), String.t()) :: String.t()
  def run_email(user, run_id) do
    case user.fields["email"] do
      {:text, email} ->
        [local, domain] = email |> String.split("@", parts: 2) |> pad()
        "#{local}+#{run_id}@#{domain}"

      _ ->
        "#{user.key}+#{run_id}@replay.wtf.invalid"
    end
  end

  defp pad([local, domain]), do: [local, domain]
  defp pad([local]), do: [local, "replay.wtf.invalid"]

  defp signup(client, kit, params, state) do
    case Client.call_kit(client, kit, :signup, params) do
      {:ok, %{status: 200, body: %{"response" => %{"user_id" => id}}}} ->
        {:ok, id}

      {:ok, %{status: status}} ->
        {:error,
         Error.new(:http_error, "the kit's sign-up workflow did not return a user_id", %{
           status: status,
           workflow: kit.signup
         }), state}

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp login(client, kit, params, state) do
    case Client.call_kit(client, kit, :login, params) do
      {:ok, %{status: 200, body: %{"response" => %{"token" => token}}}}
      when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %{status: status}} ->
        {:error,
         Error.new(:http_error, "the kit's login workflow did not return a token", %{
           status: status,
           workflow: kit.login
         }), state}

      {:error, error} ->
        {:error, error, state}
    end
  end

  # --- records -----------------------------------------------------------------------

  defp records(client, records, state),
    do: each(records, state, &create_record(client, &1, &2))

  defp create_record(client, record, state) do
    with {:ok, auth} <- creator(record, state),
         {now, later} = split_refs(record, state.ledger),
         {:ok, body} <- body(client.names, record, now, state.ledger),
         {:ok, ledger} <- Ledger.intend(state.ledger, record.key, record.type),
         state = %{state | ledger: ledger},
         {:ok, id} <- create(client, record, body, auth, state),
         {:ok, ledger} <- confirm(state, record.key, id) do
      deferred =
        if later == [], do: state.deferred, else: Map.put(state.deferred, record.key, later)

      {:ok, %{state | ledger: ledger, deferred: deferred}}
    end
  end

  defp creator(record, state) do
    case record.fields["Created By"] do
      {:ref, user} ->
        case Session.token(state.session, user) do
          nil ->
            {:error,
             Error.new(:invalid_input, "Created By must name a seeded user", %{
               record: record.key
             })}

          token ->
            {:ok, {:user, token}}
        end

      _ ->
        {:ok, :admin}
    end
  end

  # The sendable fields of `record`, split into those whose references
  # are all created and those that must wait.
  defp split_refs(record, ledger) do
    record
    |> sendable()
    |> Enum.split_with(fn {_field, value} ->
      Enum.all?(Value.refs(value), &Ledger.id(ledger, &1))
    end)
  end

  defp sendable(record) do
    for {field, value} <- Enum.sort(record.fields),
        value != nil,
        field not in @never_sent,
        not (record.type == "user" and field == "email"),
        do: {field, value}
  end

  defp body(names, record, fields, ledger) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {field, value}, {:ok, acc} ->
      with {:ok, key} <- Names.field_key(names, record.type, field),
           {:ok, json} <- Codec.encode(value, ledger) do
        {:cont, {:ok, Map.put(acc, key, json)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp deferred(client, records, state),
    do: each(records, state, &patch_deferred(client, &1, &2))

  # Users: every field but email. Others: the references deferred at creation.
  defp patch_deferred(client, record, state) do
    fields =
      if record.type == "user",
        do: sendable(record),
        else: Map.get(state.deferred, record.key, [])

    with {:ok, body} <- body(client.names, record, fields, state.ledger),
         :ok <- patch(client, state.ledger, record.key, body) do
      {:ok, state}
    end
  end

  defp patch(_client, _ledger, _key, body) when map_size(body) == 0, do: :ok
  defp patch(client, ledger, key, body), do: Client.update_seeded(client, ledger, key, body)

  # --- explicit empties ---------------------------------------------------------------

  @doc false
  @spec empties(map()) :: [String.t()]
  def empties(record) do
    for {field, nil} <- Enum.sort(record.fields),
        field not in @never_sent,
        not (record.type == "user" and field == "email"),
        do: field
  end

  defp clear_empties(client, records, state) do
    each(records, state, fn record, state ->
      case empties(record) do
        [] -> {:ok, state}
        fields -> clear(client, record, fields, state)
      end
    end)
  end

  defp clear(client, record, fields, state) do
    with {:ok, body} <- null_body(client.names, record, fields) do
      client
      |> Client.update_seeded(state.ledger, record.key, body)
      |> cleared(record.key, fields, state)
    end
  end

  defp cleared(:ok, key, fields, state) do
    with :ok <- Ledger.note_cleared(state.ledger, key, fields, true), do: {:ok, state}
  end

  defp cleared({:error, %Error{context: %{reason: :budget_exhausted}}} = error, _, _, _),
    do: error

  defp cleared({:error, _}, key, fields, state) do
    with :ok <- Ledger.note_cleared(state.ledger, key, fields, false),
         do: {:ok, %{state | uncleared: Map.put(state.uncleared, key, fields)}}
  end

  defp null_body(names, record, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Names.field_key(names, record.type, field) do
        {:ok, key} -> {:cont, {:ok, Map.put(acc, key, nil)}}
        error -> {:halt, error}
      end
    end)
  end

  defp delete_after(client, keys, state) do
    each(Enum.sort(keys), state, fn key, state ->
      with {:ok, ledger} <- Client.delete_seeded(client, state.ledger, key),
           do: {:ok, %{state | ledger: ledger}}
    end)
  end

  defp create(client, record, body, auth, state) do
    case Client.create(client, record.type, body, auth) do
      {:ok, id} -> {:ok, id}
      {:error, error} -> {:error, error, state}
    end
  end
end
