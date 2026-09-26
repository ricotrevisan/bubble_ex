#!/usr/bin/env bash
# Build and boot check for BubbleEx.Target.Phoenix (WTF-369): renders every
# fixture (scripts/phoenix_compile_check/render.exs list) as a complete
# Phoenix/Ash application into one scratch project, then for each:
#
#   * mix compile --warnings-as-errors (the generated and the scaffolded
#     code; the dependencies are the pinned BubbleEx.Target.Phoenix.deps/1,
#     locked by scripts/phoenix_compile_check/mix.lock)
#   * mix ash.codegen initial, then mix ash.codegen --check: the generated
#     resources give migrations and nothing is left pending
#   * with PHOENIX_COMPILE_CHECK_DB set (a PostgreSQL URL without a
#     database, e.g. ecto://postgres:postgres@localhost:5432): mix test,
#     the scaffolded smoke test, which migrates a fresh database, boots the
#     endpoint, renders the home and sign-in pages, calls the workflow API
#     and signs a stored user in with a magic link (Oban job, Swoosh email)
#
# Every fixture renders with the same module and app name, so the
# dependencies compile once. The scratch project lives in
# _build/phoenix_compile_check (or $PHOENIX_COMPILE_CHECK_DIR) and is never
# committed. Set PHOENIX_COMPILE_CHECK_FIXTURES to a space-separated list to
# check only some fixtures. When the pins change, refresh the lock with
# PHOENIX_COMPILE_CHECK_UPDATE_LOCK=1.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${PHOENIX_COMPILE_CHECK_DIR:-$root/_build/phoenix_compile_check}"
export MIX_ENV=test

cd "$root"
mix compile
fixtures="${PHOENIX_COMPILE_CHECK_FIXTURES:-$(mix run --no-compile scripts/phoenix_compile_check/render.exs list)}"
mkdir -p "$scratch"

first=1
for fixture in $fixtures; do
  echo "== $fixture"
  cd "$root"
  mix run --no-compile scripts/phoenix_compile_check/render.exs "$scratch" "$fixture"
  cd "$scratch"

  if [[ $first == 1 ]]; then
    if [[ -n "${PHOENIX_COMPILE_CHECK_UPDATE_LOCK:-}" ]]; then
      rm -f mix.lock
      mix deps.get
      cp mix.lock "$root/scripts/phoenix_compile_check/mix.lock"
    else
      mix deps.get --check-locked
    fi
    first=0
  fi

  mix compile --warnings-as-errors

  rm -rf priv/resource_snapshots
  find priv/repo/migrations -name '*.exs' ! -name '20260101000000_add_oban_jobs_table.exs' -delete
  mix ash.codegen initial >/dev/null
  mix ash.codegen --check

  if [[ -n "${PHOENIX_COMPILE_CHECK_DB:-}" ]]; then
    mix ecto.drop --quiet --force-drop >/dev/null 2>&1 || true
    mix test
  fi
done

if [[ -z "${PHOENIX_COMPILE_CHECK_DB:-}" ]]; then
  echo "smoke tests skipped: set PHOENIX_COMPILE_CHECK_DB to a PostgreSQL URL"
fi
echo "phoenix compile check passed"
