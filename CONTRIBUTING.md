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

Before publishing, also check the package as a production dependency:

```bash
scripts/package_consumer_smoke.sh
```

This builds the Hex package, unpacks it into a temporary directory, and compiles
and runs it from a fresh Mix project outside the checkout. The check downloads
production dependencies and removes its temporary files when it finishes.

When changing `BubbleEx.Target.Ash` (or the expression compiler that feeds
`BubbleEx.Target.Ash.Expressions`), also compile its output:

```bash
scripts/ash_compile_check.sh
```

This renders every fixture into a scratch Ash project
(`_build/ash_compile_check`, dependencies from `BubbleEx.Target.Ash.versions/0`),
runs `mix compile --warnings-as-errors` and dry-runs `mix ash.codegen`, which
needs no database. Each fixture's compiled privacy-rule conditions are printed
as `expr(...)` into a `PrivacyFilters` module and must build AshPostgres
queries. With `ASH_COMPILE_CHECK_DB` set to a PostgreSQL URL (e.g.
`ecto://postgres:postgres@localhost:5432`) it also runs the migrations,
round-trips sample rows through every resource and runs every privacy filter
against them, requiring PostgreSQL and Ash's in-memory evaluation to agree,
then reads every resource through its generated privacy policies and checks
the policy fixture against its hand-authored persona table
(`test/support/target/ash/expectations/policies.json`), and checks the owner
decision fixtures (`BubbleEx.Test.DecidedFixture`): derived fields have no
column and read back through their relationship, refined numbers are
bigint / numeric columns.
With `BUBBLE_EX_PRIVATE_EXPORT`
set it also checks a private app export. CI runs it as the `ash-compile-check`
job.

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

Real-app privacy/expression acceptance (tagged `:private_fixture`) reads a
private local export and is also excluded by default. Never commit real-app
captures:

```bash
BUBBLE_EX_PRIVATE_EXPORT=path/to/export mix test --only private_fixture
```

With `BUBBLE_EX_PRIVATE_DECISIONS` naming a JSON array of decision records
made against that export (kept outside the repository: it names private
Bubble IDs), the run also maps the export with those decisions and compares
the Project's hash and counts with
`test/support/target/ash/counts/mm-137.decided.json`.

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
