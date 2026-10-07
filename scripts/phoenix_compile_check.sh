#!/usr/bin/env bash
# Build and boot check for BubbleEx.Target.Phoenix (WTF-369): renders every
# fixture (scripts/phoenix_compile_check/render.exs list) as a complete
# Phoenix/Ash application into one scratch project, then for each:
#
#   * mix compile --warnings-as-errors (the generated and the scaffolded
#     code; the dependencies are the pinned BubbleEx.Target.Phoenix.deps/1,
#     locked by scripts/phoenix_compile_check/mix.lock)
#   * mix ash.codegen initial, then mix ash.codegen --check: the generated
#     resources give migrations and nothing is left pending; for
#     decided_cut3, scripts/phoenix_compile_check/index_snapshots.sh: a
#     pre-WTF-418 project's snapshots upgraded by the project's
#     priv/bubble/concurrent_index_snapshots.exs (WTF-499) and by mix
#     bubble.concurrent_index_snapshots give no migration
#   * with PHOENIX_COMPILE_CHECK_DB set (a PostgreSQL URL without a
#     database, with an explicit port that is not 5432 unless
#     PHOENIX_COMPILE_CHECK_ALLOW_5432=1, e.g.
#     ecto://postgres:postgres@127.0.0.1:55432; scripts/check_db.exs): mix test,
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
#     step_order) with their tagged tests (frontend_workflows.exs); for
#     phoenix_index_thing, a typed index page's /index/:bubble_thing route
#     and "Go to page" data (test/support/target/phoenix/index_thing_behavior.exs);
#     for phoenix_visibility, visibility conditionals per user and custom
#     state (test/support/target/phoenix/visibility_behavior.exs); for
#     phoenix_reusable_params, reusable element properties
#     (test/support/target/phoenix/reusable_params_behavior.exs); for
#     phoenix_list_ops, list operators of page data (WTF-495,
#     test/support/target/phoenix/list_ops_behavior.exs); for
#     phoenix_shapes, data shapes a page must never crash on (WTF-500,
#     test/support/target/phoenix/shapes_behavior.exs); for
#     phoenix_page_load, the queries of a signed-in page load (WTF-501,
#     test/support/target/phoenix/page_load_behavior.exs); for
#     phoenix_url, `Get data from page URL` (WTF-508,
#     test/support/target/phoenix/url_behavior.exs)
#   * the same checks with privacy: :enforced (WTF-423) on the fixtures
#     with privacy rules, pages and workflows (a second scratch project,
#     <scratch>_enforced), plus the generated privacy-matrix tests against
#     the app (scored by scripts/ash_compile_check/matrix_results.exs; the
#     private app too when BUBBLE_EX_PRIVATE_EXPORT is set) and
#     test/support/target/phoenix/enforced_behavior.exs, which must pass
#     there and fail, every test, against the :omit render of the same app
#     (PHOENIX_COMPILE_CHECK_ENFORCED_FIXTURES overrides the list)
#   * finally, scripts/phoenix_compile_check/task_cli.sh: mix wtf.task
#     complete/audit end to end on one generated project (WTF-375; its
#     tagged tests on the database named with --test-db, WTF-448), and
#     scripts/phoenix_compile_check/structural.sh: mix wtf.verify
#     structural on one (WTF-386)
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
# mix wtf.task names its test database explicitly (WTF-448); it refuses
# port 5432 unless told otherwise, like the check itself.
if [[ "${PHOENIX_COMPILE_CHECK_ALLOW_5432:-}" == 1 ]]; then export WTF_TASK_ALLOW_5432=1; fi
# The generated config/test.exs uses TEST_DATABASE_URL when set: only the
# check's own database may reach it.
unset TEST_DATABASE_URL

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

  # A fresh render must be lint-clean without touching generated files (or
  # invalidating the manifest's hashes).
  mix format --check-formatted
  mix compile --warnings-as-errors

  rm -rf priv/resource_snapshots
  find priv/repo/migrations -name '*.exs' ! -name '20260101000000_add_oban_jobs_table.exs' -delete
  mix ash.codegen initial >/dev/null
  mix ash.codegen --check

  # Upgrading a pre-WTF-418 project's snapshots to the concurrent index
  # hints (the project's priv/bubble/concurrent_index_snapshots.exs and mix
  # bubble.concurrent_index_snapshots): no migration.
  if [[ "$fixture" == decided_cut3 ]]; then
    "$root/scripts/phoenix_compile_check/index_snapshots.sh" "$scratch"
  fi

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

    # Enforcement is real (WTF-423): the enforced app's behavior tests
    # (below) must FAIL, every one of them, against this :omit render.
    if [[ "$fixture" == phoenix_enforced ]]; then
      cp "$root/test/support/target/phoenix/enforced_behavior.exs" test/enforced_behavior_test.exs
      out="$(mix test --no-color test/enforced_behavior_test.exs 2>&1 || true)"
      rm test/enforced_behavior_test.exs
      # ExUnit's summary: "N tests, M failures" up to Elixir 1.19,
      # "Result: X/Y passed", "Result: N passed" or "Result: 0 tests" from
      # 1.20.
      summary="$(grep -E '^([0-9]+ tests?, [0-9]+ failures?|Result: )' <<<"$out" | tail -1)"
      if [[ "$summary" =~ ^([0-9]+)\ tests?,\ ([0-9]+)\ failures? ]]; then
        tests="${BASH_REMATCH[1]}"
        failed="${BASH_REMATCH[2]}"
      elif [[ "$summary" =~ ^Result:\ ([0-9]+)/([0-9]+)\ passed ]]; then
        tests="${BASH_REMATCH[2]}"
        failed=$((BASH_REMATCH[2] - BASH_REMATCH[1]))
      elif [[ "$summary" =~ ^Result:\ ([0-9]+)\ passed ]]; then
        tests="${BASH_REMATCH[1]}"
        failed=0
      else
        tests=0
        failed=0
      fi
      if [[ -z "$summary" || "$tests" == 0 || "$tests" != "$failed" ]]; then
        echo "$out" | tail -40
        echo "the enforcement tests must all fail without policies (privacy: :omit): $summary" >&2
        exit 1
      fi

      # ... and fail on their assertions: what the policies would have
      # prevented happened. Not on a missing table, module or function
      # (a broken fixture fails every test too, proving nothing).
      # `assert`, `match`, `refute` (Expected false or nil) and a response
      # status: each failure's first line.
      asserted="$(grep -cE '^ +(Assertion with |match \(=\) failed|Expected false or nil, got|Expected truthy, got|\*\* \(RuntimeError\) expected response with status)' <<<"$out" || true)"
      if [[ "$asserted" != "$failed" ]] ||
        grep -qE 'undefined_table|UndefinedFunctionError|Postgrex\.Error|CompileError|KeyError|FunctionClauseError' <<<"$out"; then
        echo "$out" | tail -60
        echo "the enforcement tests must fail on their assertions without policies ($asserted of $failed did)" >&2
        exit 1
      fi
      echo "enforcement tests without policies: $summary (as required)"
    fi

    # Join-backed page reads and membership notifications (WTF-420).
    if [[ "$fixture" == decided_cut3 ]]; then
      cp "$root/test/support/target/phoenix/join_page_data_behavior.exs" \
        test/join_page_data_behavior_test.exs
      mix test test/join_page_data_behavior_test.exs
      rm test/join_page_data_behavior_test.exs
    fi

    # An index page with a type of content (WTF-454): /index/:bubble_thing
    # and "Go to page" data to it and to the current page.
    if [[ "$fixture" == phoenix_index_thing ]]; then
      cp "$root/test/support/target/phoenix/index_thing_behavior.exs" \
        test/index_thing_behavior_test.exs
      mix test test/index_thing_behavior_test.exs
      rm test/index_thing_behavior_test.exs
    fi

    # Visibility conditionals (WTF-477): the hidden attribute per user and
    # custom state.
    if [[ "$fixture" == phoenix_visibility ]]; then
      cp "$root/test/support/target/phoenix/visibility_behavior.exs" \
        test/visibility_behavior_test.exs
      mix test test/visibility_behavior_test.exs
      rm test/visibility_behavior_test.exs
    fi

    # Reusable element properties (WTF-493): an instance's values, its
    # defaults, read in texts, conditions, data sources and workflows.
    if [[ "$fixture" == phoenix_reusable_params ]]; then
      cp "$root/test/support/target/phoenix/reusable_params_behavior.exs" \
        test/reusable_params_behavior_test.exs
      mix test test/reusable_params_behavior_test.exs
      rm test/reusable_params_behavior_test.exs
    fi

    # List operators of page data (WTF-495): sorted, merged, unique,
    # filtered lists, read in the database as the user.
    if [[ "$fixture" == phoenix_list_ops ]]; then
      cp "$root/test/support/target/phoenix/list_ops_behavior.exs" \
        test/list_ops_behavior_test.exs
      mix test test/list_ops_behavior_test.exs
      rm test/list_ops_behavior_test.exs
    fi

    # Data shapes (WTF-500): option-set lists stored by position, hidden
    # fields, fields of a list of things, JSON-safe yes/no, two navigations.
    if [[ "$fixture" == phoenix_shapes ]]; then
      cp "$root/test/support/target/phoenix/shapes_behavior.exs" \
        test/shapes_behavior_test.exs
      mix test test/shapes_behavior_test.exs
      rm test/shapes_behavior_test.exs
    fi

    # A signed-in page load (WTF-501): each query, the current user and
    # their relationships read once per page load.
    if [[ "$fixture" == phoenix_page_load ]]; then
      cp "$root/test/support/target/phoenix/page_load_behavior.exs" \
        test/page_load_behavior_test.exs
      mix test test/page_load_behavior_test.exs
      rm test/page_load_behavior_test.exs
    fi

    # Get data from page URL (WTF-508): query parameters read as their
    # type, the path's segments and things read by ID as the user.
    if [[ "$fixture" == phoenix_url ]]; then
      cp "$root/test/support/target/phoenix/url_behavior.exs" test/url_behavior_test.exs
      mix test test/url_behavior_test.exs
      rm test/url_behavior_test.exs
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

# privacy: :enforced (WTF-423): the policies compiled from Bubble, enforced
# by the generated app, in a project of its own (its dependencies add
# PicoSAT). For each fixture: lint, compile, migrations, and with a
# database `mix test` with the generated privacy-matrix tests (every fixture
# with privacy rules, and the private app: BubbleEx.Target.Ash.MatrixTests
# against the app's own Repo), scored by
# scripts/ash_compile_check/matrix_results.exs (every scenario passes or
# is an intended difference, BubbleEx.Verify.Difference); the behavior
# tests of the page, workflow and backend fixtures, which must pass with
# policies too; and test/support/target/phoenix/enforced_behavior.exs,
# which must pass here and fail without policies (above).
enforced_scratch="${scratch}_enforced"
enforced_fixtures="${PHOENIX_COMPILE_CHECK_ENFORCED_FIXTURES:-target_policies target_policy_defaults privacy_rules expr_app phoenix_enforced phoenix_page_data phoenix_frontend_workflows phoenix_index_thing phoenix_visibility phoenix_reusable_params phoenix_list_ops phoenix_shapes phoenix_page_load phoenix_url workflows_backend decided_cut3${BUBBLE_EX_PRIVATE_EXPORT:+ private_app}}"
mkdir -p "$enforced_scratch"
first=1

for fixture in $enforced_fixtures; do
  echo "== enforced_$fixture"
  cd "$root"
  mix run --no-compile scripts/phoenix_compile_check/render.exs "$enforced_scratch" "enforced_$fixture"
  cd "$enforced_scratch"

  if [[ $first == 1 ]]; then
    mix deps.get --check-locked
    first=0
  fi

  mix format --check-formatted
  mix compile --warnings-as-errors

  rm -rf priv/resource_snapshots
  find priv/repo/migrations -name '*.exs' ! -name '20260101000000_add_oban_jobs_table.exs' -delete
  mix ash.codegen initial >/dev/null
  mix ash.codegen --check

  if [[ -n "${PHOENIX_COMPILE_CHECK_DB:-}" ]]; then
    mix ecto.drop --quiet --force-drop >/dev/null 2>&1 || true
    WTF_VERIFY_OBSERVATIONS="$enforced_scratch/observations" mix test

    if [[ -f matrix_index.json ]]; then
      (cd "$root" && mix run --no-compile scripts/ash_compile_check/matrix_results.exs "$enforced_scratch")
    fi

    behavior=""
    case "$fixture" in
      phoenix_enforced) behavior=test/support/target/phoenix/enforced_behavior.exs ;;
      phoenix_page_data) behavior=test/support/target/phoenix/page_data_behavior.exs ;;
      phoenix_frontend_workflows) behavior=test/support/target/phoenix/frontend_workflows_behavior.exs ;;
      phoenix_index_thing) behavior=test/support/target/phoenix/index_thing_behavior.exs ;;
      phoenix_visibility) behavior=test/support/target/phoenix/visibility_behavior.exs ;;
      phoenix_reusable_params) behavior=test/support/target/phoenix/reusable_params_behavior.exs ;;
      phoenix_list_ops) behavior=test/support/target/phoenix/list_ops_behavior.exs ;;
      phoenix_shapes) behavior=test/support/target/phoenix/shapes_behavior.exs ;;
      phoenix_page_load) behavior=test/support/target/phoenix/page_load_behavior.exs ;;
      phoenix_url) behavior=test/support/target/phoenix/url_behavior.exs ;;
    esac

    if [[ -n "$behavior" ]]; then
      cp "$root/$behavior" test/behavior_test.exs
      mix test test/behavior_test.exs
      rm test/behavior_test.exs
    fi
  fi
done

# The task CLI (mix wtf.task) end to end on one generated project.
cd "$root"
scripts/phoenix_compile_check/task_cli.sh "$scratch"

# The structural verification pack (mix wtf.verify structural) end to end,
# on an :omit and an enforced project.
cd "$root"
scripts/phoenix_compile_check/structural.sh "$scratch"
cd "$root"
scripts/phoenix_compile_check/structural.sh "$enforced_scratch" enforced_phoenix_enforced

if [[ -z "${PHOENIX_COMPILE_CHECK_DB:-}" ]]; then
  echo "smoke tests skipped: set PHOENIX_COMPILE_CHECK_DB to a PostgreSQL URL"
fi
echo "phoenix compile check passed"
