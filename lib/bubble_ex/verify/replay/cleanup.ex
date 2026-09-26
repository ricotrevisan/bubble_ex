defmodule BubbleEx.Verify.Replay.Cleanup do
  @moduledoc """
  Deletes what a replay run created, and only that (WTF-358 §6.1 rule 2).

    1. **Unconfirmed sign-ups** (an intent with the run's unique email but
       no confirmed ID: the answer was lost, a 5xx, an odd `user_id`) are
       looked up by that exact email, and only when it carries the run's
       `+<run id>@` tag. One match is confirmed in the ledger (then
       deleted); none means the sign-up never happened; several are
       reported, never deleted.
    2. **Confirmed entries** are deleted newest first, from the client's
       cleanup allowance, through `Client.delete_seeded/3`.
    3. Whatever could not be deleted, and every other unconfirmed entry
       (a create whose answer was lost: it is never searched for), is
       returned as a leftover with its type and, when known, Bubble ID.

  `resume/2` does the same from a persisted journal after a crash:
  `Ledger.load/1`, a check that the journal is for the client's app and
  branch, then `run/2`. It never searches for anything but an unconfirmed
  sign-up's exact email.
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Replay.{Client, Kit, Ledger, Target}

  @type leftover :: %{
          key: String.t(),
          type: String.t(),
          id: String.t() | nil,
          why: atom()
        }

  @doc "Cleans up `ledger`. Returns the ledger after cleanup and the leftovers."
  @spec run(Client.t(), Ledger.t()) :: {Ledger.t(), [leftover()]}
  def run(%Client{} = client, %Ledger{} = ledger) do
    {ledger, unresolved} =
      Enum.reduce(Ledger.unconfirmed(ledger), {ledger, []}, fn entry, {ledger, left} ->
        case resolve(client, ledger, entry) do
          {:ok, ledger} -> {ledger, left}
          {:leftover, why} -> {ledger, left ++ [leftover(entry, why)]}
        end
      end)

    {ledger, failed} =
      Enum.reduce(Ledger.live(ledger), {ledger, []}, fn entry, {ledger, left} ->
        case Client.delete_seeded(client, ledger, entry.key) do
          {:ok, ledger} -> {ledger, left}
          {:error, error} -> {ledger, left ++ [leftover(entry, error.kind)]}
        end
      end)

    {ledger, unresolved ++ failed}
  end

  @doc "Loads the journal at `path` and cleans it up (see the moduledoc)."
  @spec resume(Client.t(), String.t(), Kit.t()) ::
          {:ok, %{ledger: Ledger.t(), leftovers: [leftover()]}} | {:error, Error.t()}
  def resume(%Client{target: %Target{} = target} = client, path, kit \\ %Kit{}) do
    with {:ok, ledger} <- Ledger.load(path) do
      if {ledger.app, ledger.branch, ledger.branch_id, ledger.host} ==
           {target.app, target.branch, target.branch_id, target.host} do
        resume_verified(client, ledger, kit)
      else
        {:error,
         Error.new(:invalid_input, "the journal is for another app, branch or host", %{
           reason: :wrong_target
         })}
      end
    end
  end

  defp resume_verified(client, ledger, kit) do
    with {:ok, _} <- verified(client, kit) do
      {ledger, leftovers} = run(client, ledger)
      {:ok, %{ledger: ledger, leftovers: leftovers}}
    end
  end

  # A fresh client proves the target (no token) before deleting anything.
  defp verified(client, kit) do
    if Client.verified?(client), do: {:ok, :verified}, else: Client.verify(client, kit)
  end

  defp resolve(client, ledger, %{type: "user", email: email} = entry) when is_binary(email) do
    if String.contains?(email, "+#{ledger.run_id}@") do
      lookup(client, ledger, entry)
    else
      {:leftover, :unconfirmed}
    end
  end

  defp resolve(_client, _ledger, _entry), do: {:leftover, :unconfirmed}

  defp lookup(client, ledger, entry) do
    case Client.find_user_by_email(client, entry.email) do
      {:ok, []} ->
        {:ok, Ledger.abandon(ledger, entry.key)}

      {:ok, [%{"_id" => id}]} ->
        case Ledger.confirm(ledger, entry.key, id) do
          {:ok, ledger} -> {:ok, ledger}
          {:error, _} -> {:leftover, :unconfirmed}
        end

      {:ok, [_ | _]} ->
        {:leftover, :ambiguous}

      {:error, error} ->
        {:leftover, error.kind}
    end
  end

  defp leftover(entry, why), do: %{key: entry.key, type: entry.type, id: entry.id, why: why}
end
