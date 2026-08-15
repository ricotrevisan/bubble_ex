defmodule BubbleEx.Frontend.Fidelity.NoSecrets do
  @moduledoc false
  @behaviour BubbleEx.Secrets

  @impl true
  def scan(_payload, _opts), do: {:ok, []}
end
