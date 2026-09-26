defmodule BubbleEx.Target.Ash.Versions do
  @moduledoc """
  The dependency pins of the generated Ash source (see
  `BubbleEx.Target.Ash.versions/1`). A module of its own so renderers
  (`BubbleEx.Target.Phoenix`) can pin them without depending on the mapper.
  """

  # The versions scripts/ash_compile_check.sh compiles and runs the
  # generated source against. Ash policies need a SAT solver: PicoSAT, as
  # Ash recommends.
  @versions [ash: "3.33.11", ash_postgres: "2.13.1"]
  @policy_versions [picosat_elixir: "0.2.3"]

  @doc "See `BubbleEx.Target.Ash.versions/1`."
  @spec versions([{:privacy, :omit | :unverified}]) :: [{atom(), String.t()}]
  def versions(opts \\ []) when is_list(opts) do
    pins =
      case Keyword.get(opts, :privacy, :omit) do
        :omit -> @versions
        :unverified -> @versions ++ @policy_versions
        other -> raise ArgumentError, "unknown privacy mode #{inspect(other)}"
      end

    Enum.map(pins, fn {app, version} -> {app, "== " <> version} end)
  end
end
