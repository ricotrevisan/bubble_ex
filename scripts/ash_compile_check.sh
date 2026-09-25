#!/usr/bin/env bash
# Compile check for BubbleEx.Target.Ash (WTF-342): renders every model
# fixture into a scratch Ash project with pinned ash/ash_postgres (the
# versions bubble_wtf uses), then runs
#
#   * mix compile --warnings-as-errors
#   * mix ash.codegen --dry-run (migration generation; needs no database)
#
# Set BUBBLE_EX_PRIVATE_EXPORT to also compile a private app export (e.g.
# mm-137). The scratch project lives in _build/ash_compile_check (or
# $ASH_COMPILE_CHECK_DIR) and is never committed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${ASH_COMPILE_CHECK_DIR:-$root/_build/ash_compile_check}"

mkdir -p "$scratch"
cp "$root/scripts/ash_compile_check/mix.exs" "$root/scripts/ash_compile_check/mix.lock" "$scratch/"

cd "$root"
MIX_ENV=test mix run scripts/ash_compile_check/render.exs "$scratch"

cd "$scratch"
mix deps.get
mix compile --warnings-as-errors --force

codegen="$(mix ash.codegen --dry-run compile_check 2>&1)" || {
  echo "$codegen"
  echo "ash.codegen failed" >&2
  exit 1
}

# Scalar references carry no database foreign key (WTF-338).
if grep -q "references(" <<<"$codegen"; then
  grep -n "references(" <<<"$codegen" | head -20
  echo "generated migrations contain foreign keys" >&2
  exit 1
fi

tables="$(grep -c "create table(" <<<"$codegen" || true)"
echo "ash compile check passed: generated migrations create $tables tables"
