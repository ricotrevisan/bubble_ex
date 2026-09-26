defmodule BubbleEx.Verify.Replay.Session do
  @moduledoc """
  The per-run credentials of the seeded users: the generated password, the
  run's sink-domain email and the user token the replay kit's login
  workflow returned. In memory only (WTF-358 §6.3); `Inspect` shows user
  keys, never values, and `secrets/1` feeds the credential scan.
  """

  @type user :: %{email: String.t(), password: String.t(), token: String.t() | nil}
  @type t :: %__MODULE__{users: %{String.t() => user()}}

  defstruct users: %{}

  @doc "A random password for one run (never stored)."
  @spec password() :: String.t()
  def password, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "Adds a user's credentials."
  @spec put_user(t(), String.t(), String.t(), String.t()) :: t()
  def put_user(%__MODULE__{} = s, key, email, password),
    do: %{s | users: Map.put(s.users, key, %{email: email, password: password, token: nil})}

  @doc "Stores a user's token."
  @spec put_token(t(), String.t(), String.t()) :: t()
  def put_token(%__MODULE__{} = s, key, token),
    do: %{s | users: Map.update!(s.users, key, &%{&1 | token: token})}

  @doc "The token of user `key`, or nil."
  @spec token(t(), String.t()) :: String.t() | nil
  def token(%__MODULE__{users: users}, key), do: get_in(users, [key, :token])

  @doc "Every password and token of the session."
  @spec secrets(t()) :: [String.t()]
  def secrets(%__MODULE__{users: users}),
    do: users |> Map.values() |> Enum.flat_map(&[&1.password, &1.token]) |> Enum.filter(& &1)
end

defimpl Inspect, for: BubbleEx.Verify.Replay.Session do
  import Inspect.Algebra

  def inspect(session, opts) do
    concat([
      "#BubbleEx.Verify.Replay.Session<",
      to_doc(session.users |> Map.keys() |> Enum.sort(), opts),
      ", credentials: [REDACTED]>"
    ])
  end
end
