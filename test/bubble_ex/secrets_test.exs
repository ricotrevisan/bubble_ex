defmodule BubbleEx.SecretsTest do
  use ExUnit.Case, async: true

  alias BubbleEx.Error

  defmodule LeakyAdapter do
    @behaviour BubbleEx.Secrets

    @impl true
    def scan(%{"token" => token}, _opts) do
      {:error, Error.new(:cli_failed, "native scan failed for #{token}", %{token: token})}
    end
  end

  test "scan/2 redacts adapter errors without caller-supplied taints" do
    token = "private-native-token-value"

    assert {:error, %Error{kind: :cli_failed} = error} =
             BubbleEx.Secrets.scan(%{"token" => token}, adapter: LeakyAdapter)

    assert error.message == "secret scan failed safely"
    assert error.context == %{}
    refute :erlang.term_to_binary(error) =~ token
  end
end
