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
#     and signs a stored user in with a magic link (Oban job, Swoosh email),
#     and the generated API client tests; for phoenix_api_clients also
#     `mix wtf.task complete` of its api_call tasks, whose request_shape
#     check runs the tests tagged with each call (request_shape.exs); for
#     expr_app, its page and reusable surface tests run by their task CLI
#     tags (`mix test --only bubble:page:<id>`); for
#     phoenix_frontend_workflows, the workflows' behavior tests
#     (test/support/target/phoenix/frontend_workflows_behavior.exs) and
#     `mix wtf.task complete` of its workflow tasks (compiles, lint,
#     step_order) with their tagged tests (frontend_workflows.exs)
#   * finally, scripts/phoenix_compile_check/task_cli.sh: mix wtf.task
#     complete/audit end to end on one generated project (WTF-375)
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

    # The surface tests are selected by the task CLI's tags (WTF-370,
    # BubbleEx.Target.Phoenix.Checks): `mix test --only bubble:<subject>`
    # exits non-zero when no test ran.
    if [[ "$fixture" == "expr_app" ]]; then
      mix test --only "bubble:page:bP1"
      mix test --only "bubble:reusable:bU1"
    fi

    # The plan's request_shape check binds to the generated API client
    # tests: mix wtf.task completes the fixture's api_call tasks (WTF-374).
    if [[ "$fixture" == phoenix_api_clients ]]; then
      (cd "$root" && mix run --no-compile scripts/phoenix_compile_check/request_shape.exs \
        "$scratch" test/support/target/phoenix/api_clients.json)
    fi

    # Frontend workflows (WTF-372): their behavior in the generated app,
    # then mix wtf.task completes the fixture's workflow tasks (compiles,
    # lint, step_order) and runs their tagged tests.
    if [[ "$fixture" == phoenix_frontend_workflows ]]; then
      cp "$root/test/support/target/phoenix/frontend_workflows_behavior.exs" \
        test/frontend_workflows_behavior_test.exs
      mix test test/frontend_workflows_behavior_test.exs
      rm test/frontend_workflows_behavior_test.exs
      (cd "$root" && mix run --no-compile scripts/phoenix_compile_check/frontend_workflows.exs \
        "$scratch" test/support/target/phoenix/frontend_workflows.json)
    fi

    # Page data (WTF-420): what the generated pages load, and never load.
    if [[ "$fixture" == phoenix_page_data ]]; then
      cp "$root/test/support/target/phoenix/page_data_behavior.exs" \
        test/page_data_behavior_test.exs
      mix test test/page_data_behavior_test.exs
      rm test/page_data_behavior_test.exs
    fi
  fi
done

# The task CLI (mix wtf.task) end to end on one generated project.
cd "$root"
scripts/phoenix_compile_check/task_cli.sh "$scratch"

if [[ -z "${PHOENIX_COMPILE_CHECK_DB:-}" ]]; then
  echo "smoke tests skipped: set PHOENIX_COMPILE_CHECK_DB to a PostgreSQL URL"
fi
echo "phoenix compile check passed"
