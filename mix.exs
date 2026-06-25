defmodule BubbleEx.MixProject do
  use Mix.Project

  @source_url "https://github.com/RicoTrevisan/bubble_ex"

  def project do
    [
      app: :bubble_ex,
      name: "BubbleEx",
      version: "0.3.0",
      elixir: "~> 1.17",
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:leex] ++ Mix.compilers(),
      package: package(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md"]
      ]
    ]
  end

  # Run the `quality` alias under MIX_ENV=test so its `test` step actually runs
  # the suite. Without this, Mix locks the env to :dev when the alias starts and
  # the `test` step aborts with "mix test is running in the dev environment".
  def cli do
    [preferred_envs: [quality: :test]]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo",
        "test"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
      # mod: {BubbleEx.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    # trufflehog (optional): only needed for BubbleEx.Secrets.Trufflehog.
    # The BubbleEx.Secrets.Native adapter requires no external CLI.
    [
      {:req, "~> 0.5"},
      {:jason, ">= 0.0.0"},
      {:floki, ">= 0.0.0"},
      {:telemetry, "~> 1.0"},
      {:mock, "~> 0.3", only: :test},
      {:meck, "~> 1.2", only: :test, override: true},
      {:plug, "~> 1.14", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # usage_rules is a dev-only helper for consulting docs and rules
      {:usage_rules, "~> 0.1", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      description: "An Elixir library to reverse engineer Bubble.io apps.",
      files: [
        "lib",
        "LICENSE",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "SECURITY.md"
      ],
      licenses: ["MIT"],
      maintainers: ["Rico Trevisan"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
