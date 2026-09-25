defmodule AshCompileCheck.MixProject do
  # A scratch Ash project for scripts/ash_compile_check.sh: the generated
  # source of every model fixture is compiled against these pinned versions,
  # which match bubble_wtf's lock (mix.lock here is a subset of it).
  use Mix.Project

  def project do
    [app: :ash_compile_check, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [{:ash, "== 3.31.3"}, {:ash_postgres, "== 2.11.0"}]
  end
end
