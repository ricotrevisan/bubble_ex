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
        extras: [
          "README.md",
          "CHANGELOG.md",
          "CONTRIBUTING.md",
          "SECURITY.md",
          "docs/editor-cli.md",
          "docs/replay-kit.md"
        ]
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
        "test --warnings-as-errors"
      ]
    ]
  end

  # xmerl checks the sanitized SVGs are well-formed XML (SvgSanitizerTest).
  defp test_applications(:test), do: [:xmerl]
  defp test_applications(_env), do: []

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger] ++ test_applications(Mix.env())
      # mod: {BubbleEx.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    # trufflehog (optional): only needed for BubbleEx.Secrets.Trufflehog.
    # The BubbleEx.Secrets.Native adapter requires no external CLI.
    [
      {:req, "~> 0.5"},
      # 1.10 CONNECT uses the numeric address, independently of TLS hostname.
      {:mint, "~> 1.10"},
      {:jason, ">= 0.0.0"},
      {:floki, ">= 0.0.0"},
      {:telemetry, "~> 1.0"},
      # Optional: only BubbleEx.Buildprint.V5 (Buildprint v5 workspaces, whose
      # app JSON sits in `.buildprint/index.sqlite`) needs SQLite. Apps that
      # read `.bubble` JSON or fetch payloads do not pull it in.
      {:exqlite, "~> 0.41", optional: true},
      {:mock, "~> 0.3", only: :test},
      {:meck, "~> 1.2", only: :test, override: true},
      # bubble_ex itself calls Plug only in tests (Req.Test stubs), but it
      # cannot be `only: :test`: phoenix_live_view (below) needs it at runtime.
      {:plug, "~> 1.14"},
      # The data loader's end-to-end check writes to PostgreSQL
      # (scripts/ash_compile_check/load.exs); the library itself takes a
      # query function (e.g. the generated app's `Repo.query/2`).
      {:postgrex, "== 0.22.4", only: :test},
      # A real time zone database for the generated runtime's date tests
      # (BubbleEx.Target.Elixir.FormatsTest: DST gaps and repeats). Test
      # only: the library itself does no time zone arithmetic.
      {:tz, "~> 0.28", only: :test},
      # Formats rendered HEEx with the same formatter as the generated app,
      # which pins `== 1.2.12` (BubbleEx.Target.Phoenix.Formatter
      # .live_view_version/0) and checks `mix format --check-formatted`.
      # HTMLFormatter output changes in patch releases (1.2.11 changed which
      # expressions it migrates, html_algebra.ex `safe_to_migrate?/2`,
      # #4409), so Formatter checks the loaded version at render: another
      # patch warns, another minor refuses. `~>` (not `==`) so apps using
      # bubble_ex can take LiveView patch and security releases; mix.lock
      # keeps this repository at the pin. Bump both with the Formatter pin.
      {:phoenix_live_view, "~> 1.2.12"},
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
