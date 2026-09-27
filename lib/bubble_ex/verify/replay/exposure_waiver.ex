defmodule BubbleEx.Verify.Replay.ExposureWaiver do
  @moduledoc """
  Explicit, short-lived owner acceptance of anonymous exposure on the
  mm-137 replay branch only. Type names are the exact descriptors used by
  `Names` (for example `"user"`), not Data API paths. This does not
  change the probe, target verification or request budgets.
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Replay.{Names, Target}

  @enforce_keys [:owner_accepted, :expires_at, :types]
  defstruct [:owner_accepted, :expires_at, :types]

  @type t :: %__MODULE__{owner_accepted: boolean(), expires_at: DateTime.t(), types: [String.t()]}

  @doc "Validate scope, consent, expiry and exact requested type descriptors."
  @spec validate(t(), Target.t(), Names.t(), [String.t()], DateTime.t()) ::
          :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = waiver, target, names, types, %DateTime{} = now) do
    if scoped?(target) and waiver.owner_accepted == true and
         valid_expiry?(waiver.expires_at, now) and valid_types?(waiver.types, names, types) do
      :ok
    else
      {:error,
       Error.new(:invalid_input, "invalid or expired owner anonymous exposure waiver", %{
         reason: :invalid_exposure_waiver
       })}
    end
  end

  defp scoped?(%Target{
         app: "mm-137",
         branch: "wtfreplay",
         branch_id: "33kpg",
         host: "beta.mocharymethod.com"
       }),
       do: true

  defp scoped?(_), do: false

  defp valid_expiry?(%DateTime{time_zone: "Etc/UTC"} = expiry, now),
    do:
      DateTime.compare(expiry, now) == :gt and
        DateTime.compare(expiry, DateTime.add(now, 604_800, :second)) != :gt

  defp valid_expiry?(_, _), do: false

  defp valid_types?(waived, names, types) when is_list(waived) and waived != [] do
    length(waived) == length(Enum.uniq(waived)) and
      Enum.all?(waived, fn type ->
        is_binary(type) and type in types and match?({:ok, _}, Names.type_path(names, type))
      end)
  end

  defp valid_types?(_, _, _), do: false

  @doc "Canonical input to the dry-run hash (no runtime clock)."
  @spec input(t() | nil) :: map() | nil
  def input(nil), do: nil

  def input(%__MODULE__{} = waiver),
    do: %{
      "owner_accepted" => waiver.owner_accepted,
      "expires_at" => DateTime.to_iso8601(waiver.expires_at),
      "types" => Enum.sort(waiver.types)
    }
end
