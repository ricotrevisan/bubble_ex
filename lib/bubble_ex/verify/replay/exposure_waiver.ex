defmodule BubbleEx.Verify.Replay.ExposureWaiver do
  @moduledoc """
  Explicit, short-lived owner acceptance of anonymous exposure on the
  mm-137 replay branch only. Type names are the exact descriptors used by
  `Names` (for example `"user"`); `paths` binds each accepted descriptor to
  its exact Data API path. This does not change the probe, target verification
  or request budgets.
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Replay.{Names, Target}

  @enforce_keys [:owner_accepted, :expires_at, :types, :paths]
  defstruct [:owner_accepted, :expires_at, :types, :paths]

  @type t :: %__MODULE__{
          owner_accepted: boolean(),
          expires_at: DateTime.t(),
          types: [String.t()],
          paths: %{String.t() => String.t()}
        }

  @doc "Validate scope, consent, expiry and exact requested type descriptors."
  @spec validate(t(), Target.t(), Names.t(), [String.t()], DateTime.t()) ::
          :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = waiver, target, names, types, %DateTime{} = now) do
    if scoped?(target) and waiver.owner_accepted == true and
         valid_expiry?(waiver.expires_at, now) and
         valid_types?(waiver.types, waiver.paths, names, types) do
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

  defp valid_types?(waived, paths, names, types)
       when is_list(waived) and waived != [] and is_map(paths) do
    length(waived) == length(Enum.uniq(waived)) and
      MapSet.new(waived) == MapSet.new(Map.keys(paths)) and
      Enum.all?(waived, &valid_type?(&1, paths, names, types))
  end

  defp valid_types?(_, _, _, _), do: false

  defp valid_type?(type, paths, names, types) when is_binary(type) do
    type in types and match_path?(type, paths[type], Names.type_path(names, type))
  end

  defp valid_type?(_, _, _, _), do: false

  defp match_path?("user", "user", {:ok, "user"}), do: true
  defp match_path?("user", _, _), do: false
  defp match_path?(_, path, {:ok, path}) when is_binary(path) and path != "", do: true
  defp match_path?(_, _, _), do: false

  @doc "Refuse persona cleanup unless User resolves to Bubble's canonical Data API path."
  @spec validate_user_path(Names.t()) :: :ok | {:error, Error.t()}
  def validate_user_path(names) do
    if Names.type_path(names, "user") == {:ok, "user"},
      do: :ok,
      else:
        {:error,
         Error.new(:invalid_input, "User must map to the User Data API path", %{
           reason: :invalid_user_path
         })}
  end

  @doc "Canonical input to the dry-run hash (no runtime clock)."
  @spec input(t() | nil) :: map() | nil
  def input(nil), do: nil

  def input(%__MODULE__{} = waiver),
    do: %{
      "owner_accepted" => waiver.owner_accepted,
      "expires_at" => DateTime.to_iso8601(waiver.expires_at),
      "types" => Enum.sort(waiver.types),
      "paths" => waiver.paths
    }
end
