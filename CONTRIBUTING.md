# Contributing to BubbleEx

## Prerequisites

- **Elixir ~> 1.17** — required to build and test the library.
- **trufflehog CLI** — optional. Only needed if you use the `BubbleEx.Secrets.Trufflehog` adapter. The pure-Elixir `BubbleEx.Secrets.Native` adapter works without any external tools. Install instructions: <https://github.com/trufflesecurity/trufflehog>.

## Setup

```bash
mix deps.get
```

That's it — no other setup is required for a standard development workflow.

## Quality Gate

Before pushing or opening a PR, run:

```bash
mix quality
```

This runs, in order: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo`, and `mix test`. All four must be green.

## Testing

Tests are offline by default and do not require external services or credentials. Integration tests (tagged `:integration`) hit live Bubble.io endpoints and are
excluded from the default run. Frozen-case fidelity tests (tagged `:fidelity`)
need pinned Playwright 1.55 and are also excluded from `mix quality`. To run
them:

```bash
cd test/support/fidelity && npm install && npx playwright install chromium
mix test --only fidelity
# or: mix bubble.fidelity
```

To run integration tests explicitly:

```bash
mix test --only integration
```

To run a single file or test:

```bash
mix test test/bubble_ex/apps/parser_test.exs
mix test test/bubble_ex/apps/parser_test.exs:42
```

## Pull Request Flow

1. Branch off `main`: `git checkout -b your-branch-name main`
2. Keep each PR to **one logical change**.
3. Ensure `mix quality` is green before pushing.
4. Open a PR against `main`. PRs are squash-merged.
