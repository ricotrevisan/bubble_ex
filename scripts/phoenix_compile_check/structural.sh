#!/usr/bin/env bash
# End-to-end check of `mix wtf.verify structural` (WTF-386,
# BubbleEx.Target.Phoenix.Structural.project/2) on a generated Phoenix
# project: renders one fixture into the scratch project of
# scripts/phoenix_compile_check.sh (whose dependencies are already built),
# generates its initial migrations as an owner would, then, from the
# bubble_ex checkout with --root:
#
#   * a freshly generated project passes the manifest, compile,
#     `mix ash.codegen --check` and the owned-code bypass inventory, lint
#     fails only as the known WTF-416 failure, and the output says it is
#     structural and advisory
#   * a hand edit of a generated file fails generated_unchanged
#   * an unmarked `authorize?: false` in owned code fails bypass_inventory;
#     marked with `# bubble:ignores_privacy <workflow id>` inside the body
#     of a workflow that ignores privacy rules in Bubble, it passes
#   * a resource change without its migration fails migrations_in_sync
#   * --out writes the results (Verify.Result JSON) and the summary
#
#     scripts/phoenix_compile_check/structural.sh <scratch dir> [fixture]
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$1"
fixture="${2:-workflows_backend}"
app="phx-check"
export MIX_ENV=test

cd "$root"
mix run --no-compile scripts/phoenix_compile_check/render.exs "$scratch" "$fixture"

(
  cd "$scratch"
  rm -rf priv/resource_snapshots
  find priv/repo/migrations -name '*.exs' ! -name '20260101000000_add_oban_jobs_table.exs' -delete
  mix ash.codegen initial >/dev/null
)

verify() { mix wtf.verify structural --root "$scratch" --app "$app" "$@"; }
fail() { echo "structural check failed: $*" >&2; exit 1; }

# Every check but lint passes on a fresh project. lint fails until
# WTF-416 (the scaffolded and templated files are not yet `mix
# format`-clean) and must be reported as that known failure.
out="$(verify 2>&1 || true)"
echo "$out"
grep -q 'not behavioural' <<<"$out" || fail "the output does not say it is structural only"
grep -q 'advisory: not verified' <<<"$out" || fail "the output is not labelled advisory"
for check in generated_unchanged compiles migrations_in_sync bypass_inventory; do
  grep -q "^pass  structural.$check" <<<"$out" || fail "$check does not pass on a fresh project"
done
if grep -q '^fail  structural.lint' <<<"$out"; then
  grep -q 'known failure: lint (WTF-416)' <<<"$out" || fail "lint fails without naming WTF-416"
fi

domain="$scratch/lib/phx_check/domain.ex"
cp "$domain" "$scratch/domain.ex.orig"
echo "# a hand edit" >> "$domain"
if out="$(verify 2>&1)"; then fail "a hand-edited generated file passed"; fi
grep -q '^fail  structural.generated_unchanged' <<<"$out" || fail "generated_unchanged did not fail"
mv "$scratch/domain.ex.orig" "$domain"

# A workflow of the fixture that ignores privacy rules in Bubble.
listed="$(tr -d '\n ' < "$scratch/.wtf/workflows.json" | sed -n 's/.*"privacy_bypasses":\["\([^"]*\)".*/\1/p')"
[[ -n "$listed" ]] || fail "the fixture has no privacy bypass"

owned="$scratch/lib/phx_check/owned_bypass.ex"
cat > "$owned" <<ELIXIR
defmodule PhxCheck.OwnedBypass do
  @moduledoc false
  def read(query), do: Ash.read!(query, authorize?: false)
end
ELIXIR
if out="$(verify 2>&1)"; then rm -f "$owned"; fail "an unmarked bypass passed"; fi
grep -q 'bypass_unlisted .*lib/phx_check/owned_bypass.ex:3' <<<"$out" || fail "the bypass is not reported"

rm -f "$owned"

# Marked with the listed workflow inside that workflow's own body, it passes.
bodies="$(grep -rl "Runtime.start(input, context, \"$listed\", false)" "$scratch/lib")"
cp "$bodies" "$scratch/bodies.orig"
sed -i "/Runtime.start(input, context, \"$listed\", false)/a\\    # bubble:ignores_privacy $listed\\n    _ = [authorize?: false]" "$bodies"
out="$(verify --out "$scratch/_structural" 2>&1 || true)"
mv "$scratch/bodies.orig" "$bodies"
grep -q '^pass  structural.bypass_inventory' <<<"$out" || { echo "$out"; fail "a marked bypass does not pass"; }
[[ -f "$scratch/_structural/structural.bypass_inventory.json" ]] || fail "--out wrote no result"
[[ -f "$scratch/_structural/structural.summary.json" ]] || fail "--out wrote no summary"
rm -rf "$scratch/_structural"

# A migration missing for a resource: without its resource snapshot,
# `mix ash.codegen --check` sees pending changes.
snapshot="$(find "$scratch/priv/resource_snapshots" -name '*.json' | sort | head -1)"
cp "$snapshot" "$scratch/snapshot.orig"
rm -f "$snapshot"
if out="$(verify 2>&1)"; then mv "$scratch/snapshot.orig" "$snapshot"; fail "a missing migration passed"; fi
mv "$scratch/snapshot.orig" "$snapshot"
grep -q '^fail  structural.migrations_in_sync' <<<"$out" || fail "migrations_in_sync did not fail"

echo "structural check passed"
