#!/usr/bin/env bash
# End-to-end check of `mix wtf.task` (BubbleEx.Tasks, WTF-375) on a
# generated Phoenix project: renders one fixture into the scratch project of
# scripts/phoenix_compile_check.sh (whose dependencies are already built),
# writes its migration plan as .wtf/plan.json and the generator's
# determinism result, then, from the bubble_ex checkout with --root:
#
#   * next lists the generator tasks first
#   * complete runs the real bindings (check_manifest, the determinism
#     result through Verify.Result.evaluate, mix compile --warnings-as-errors
#     in the project) and records the tasks done
#   * a hand edit of a generated file makes complete refuse and audit turn
#     the done tasks needs_reverify (both exit non-zero)
#
#     scripts/phoenix_compile_check/task_cli.sh <scratch dir> [fixture]
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$1"
fixture="${2:-field_types}"
app="phx-check"
export MIX_ENV=test

cd "$root"
mix run --no-compile scripts/phoenix_compile_check/render.exs "$scratch" "$fixture"
rm -rf "$scratch/.wtf/tasks"
mix run --no-compile scripts/phoenix_compile_check/render.exs plan "$scratch" "$fixture" "$app"

wtf() { mix wtf.task "$@" --root "$scratch"; }
fail() { echo "task CLI check failed: $*" >&2; exit 1; }

next="$(wtf next --n 3)"
echo "$next"
grep -q '^generate:option_sets ' <<<"$next" || fail "next does not start with the generators"

wtf complete generate:option_sets --agent ci --app "$app"
wtf complete generate:schema --agent ci --app "$app"
grep -q 'status done' <<<"$(wtf show generate:schema)" || fail "generate:schema is not done"

domain="$scratch/lib/phx_check/domain.ex"
cp "$domain" "$scratch/domain.ex.orig"
echo "# a hand edit" >> "$domain"

if wtf complete generate:api_clients --agent ci --app "$app"; then
  fail "complete accepted a hand-edited generated file"
fi

if wtf audit --app "$app"; then
  fail "audit accepted a hand-edited generated file"
fi

grep -q 'needs re-verifying (audit)' <<<"$(wtf show generate:schema)" ||
  fail "audit did not flip generate:schema"

mv "$scratch/domain.ex.orig" "$domain"
wtf complete generate:option_sets --agent ci --app "$app"
wtf complete generate:schema --agent ci --app "$app"
wtf audit --app "$app"
echo "task CLI check passed"
