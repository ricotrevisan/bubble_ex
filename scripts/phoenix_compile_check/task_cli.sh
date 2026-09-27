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
#     in the project) and records the tasks done, labelled advisory
#   * a hand edit of a generated file makes complete refuse and audit turn
#     the done tasks needs_reverify (both exit non-zero)
#   * with PHOENIX_COMPILE_CHECK_DB (mix test needs the database): a real
#     tagged test (`@moduletag bubble: "<task>"`) in the project; a failing
#     one makes complete refuse, a passing one completes the task, so the
#     `mix test --only` binding is exercised on every CI Elixir version;
#     then, on phoenix_api_clients (three API calls the generator leaves
#     out, WTF-412), complete generate:api_clients passes on the generated
#     calls' request-shape tests and the residue calls close through the
#     attested api_clients:residue task
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

grep -q 'advisory: not verified' <<<"$(wtf audit --app "$app")" || fail "the audit is not labelled advisory"

if [[ -n "${PHOENIX_COMPILE_CHECK_DB:-}" ]]; then
  tagged="$scratch/test/wtf_tagged_test.exs"
  write_tagged() {
    cat > "$tagged" <<ELIXIR
defmodule PhxCheck.WtfTaggedTest do
  use ExUnit.Case, async: true
  @moduletag bubble: "generate:api_clients"
  test "the tagged subject", do: assert(1 + 1 == $1)
end
ELIXIR
  }

  write_tagged 3
  if wtf complete generate:api_clients --agent ci --app "$app"; then
    rm -f "$tagged"
    fail "complete accepted a failing tagged test"
  fi

  write_tagged 2
  wtf complete generate:api_clients --agent ci --app "$app"
  rm -f "$tagged"

  # API calls the generator leaves out (WTF-412): phoenix_api_clients has
  # three residue calls with no generated test. generate:api_clients checks
  # only the generated calls, so it completes; the residue calls, used by
  # nothing, stay visible as api_clients:residue (attested).
  residue_fixture=phoenix_api_clients
  mix run --no-compile scripts/phoenix_compile_check/render.exs "$scratch" "$residue_fixture"
  rm -rf "$scratch/.wtf/tasks"
  mix run --no-compile scripts/phoenix_compile_check/render.exs plan "$scratch" "$residue_fixture" "$app"

  shown="$(wtf show generate:api_clients)"
  echo "$shown"
  grep -q 'residue: api_call:gResidue/cRaw' <<<"$shown" || fail "generate:api_clients hides its residue"

  wtf complete generate:option_sets --agent ci --app "$app"
  wtf complete generate:schema --agent ci --app "$app"
  wtf complete generate:api_clients --agent ci --app "$app"
  grep -q 'status done' <<<"$(wtf show generate:api_clients)" ||
    fail "generate:api_clients is not done with residue calls"

  wtf claim api_clients:residue --agent ci
  if refused="$(wtf complete api_clients:residue --agent ci --app "$app" 2>&1)"; then
    fail "api_clients:residue closed without an attestation"
  fi
  echo "$refused"
  grep -q 'FAIL .*attested' <<<"$refused" ||
    fail "api_clients:residue was refused, but not for its missing attestation"
  wtf complete api_clients:residue --agent ci --app "$app" \
    --attest "1=No kept workflow or page calls these three API calls."
  grep -q 'status done' <<<"$(wtf show api_clients:residue)" || fail "api_clients:residue is not done"
fi

echo "task CLI check passed"
