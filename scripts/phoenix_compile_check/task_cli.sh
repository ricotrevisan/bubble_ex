#!/usr/bin/env bash
# End-to-end check of `mix wtf.task` (BubbleEx.Tasks, WTF-375) on a
# generated Phoenix project: renders one fixture into the scratch project of
# scripts/phoenix_compile_check.sh (whose dependencies are already built),
# writes its migration plan as .wtf/plan.json and the generator's
# determinism result, then, from the bubble_ex checkout with --root:
#
#   * next lists the generator tasks first
#   * complete --trusted verifies the signed plan and manifest, then runs
#     the real bindings (check_manifest, the signed determinism result
#     through Verify.Result.evaluate, mix compile --warnings-as-errors in
#     the project) and records the tasks done
#   * a hand edit of a generated file makes complete refuse and audit
#     --trusted turn the done tasks needs_reverify (both exit non-zero)
#   * an edited plan (plan_sha256 recomputed) is refused by a trusted run
#
#     scripts/phoenix_compile_check/task_cli.sh <scratch dir> [fixture]
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$1"
fixture="${2:-field_types}"
app="phx-check"
export MIX_ENV=test
# A throwaway signing key: in an owner's CI this is the secret WTF issues.
WTF_PLAN_SIGNING_KEY="$(head -c 32 /dev/urandom | base64)"
export WTF_PLAN_SIGNING_KEY

cd "$root"
mix run --no-compile scripts/phoenix_compile_check/render.exs "$scratch" "$fixture"
rm -rf "$scratch/.wtf/tasks"
mix run --no-compile scripts/phoenix_compile_check/render.exs plan "$scratch" "$fixture" "$app"

wtf() { mix wtf.task "$@" --root "$scratch"; }
fail() { echo "task CLI check failed: $*" >&2; exit 1; }

next="$(wtf next --n 3)"
echo "$next"
grep -q '^generate:option_sets ' <<<"$next" || fail "next does not start with the generators"

wtf complete generate:option_sets --agent ci --app "$app" --trusted
wtf complete generate:schema --agent ci --app "$app" --trusted
grep -q 'status done' <<<"$(wtf show generate:schema)" || fail "generate:schema is not done"

domain="$scratch/lib/phx_check/domain.ex"
cp "$domain" "$scratch/domain.ex.orig"
echo "# a hand edit" >> "$domain"

if wtf complete generate:api_clients --agent ci --app "$app" --trusted; then
  fail "complete accepted a hand-edited generated file"
fi

if wtf audit --app "$app" --trusted; then
  fail "audit accepted a hand-edited generated file"
fi

grep -q 'needs re-verifying (audit)' <<<"$(wtf show generate:schema)" ||
  fail "audit did not flip generate:schema"

mv "$scratch/domain.ex.orig" "$domain"
wtf complete generate:option_sets --agent ci --app "$app" --trusted
wtf complete generate:schema --agent ci --app "$app" --trusted
wtf audit --app "$app" --trusted

plan="$scratch/.wtf/plan.json"
cp "$plan" "$scratch/plan.json.orig"
WTF_PLAN_PATH="$plan" mix run --no-compile -e '
  path = System.fetch_env!("WTF_PLAN_PATH")
  map = path |> File.read!() |> Jason.decode!()
  map = Map.put(map, "tasks", Enum.map(map["tasks"], &if(&1["id"] == "generate:policies", do: %{&1 | "status" => "closed"}, else: &1)))
  map = Map.put(map, "plan_sha256", map |> Map.delete("plan_sha256") |> BubbleEx.CanonicalJson.sha256())
  File.write!(path, BubbleEx.CanonicalJson.encode(map))
'

if wtf audit --app "$app" --trusted; then
  fail "a trusted audit accepted an edited plan"
fi

mv "$scratch/plan.json.orig" "$plan"
echo "task CLI check passed"
