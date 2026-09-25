#!/usr/bin/env bash
# Compile and runtime check for BubbleEx.Target.Ash (WTF-342): renders every
# model and target fixture into a scratch Ash project whose dependencies are
# BubbleEx.Target.Ash.versions/0 (mix.lock pins the rest), then
#
#   * mix compile --warnings-as-errors
#   * mix ash.codegen --dry-run: migration generation needs no database; it
#     must create no foreign keys and store lists of dates at microsecond
#     precision
#   * scripts/ash_compile_check/filters.exs: every compiled privacy-rule
#     condition (rendered as expr(...) into <namespace>.PrivacyFilters and
#     compiled above) builds an AshPostgres query, logged out and with a
#     sample actor
#   * with ASH_COMPILE_CHECK_DB set (a PostgreSQL URL without a database,
#     e.g. ecto://postgres:postgres@localhost:5432): generates and runs the
#     migrations in one database per fixture, then scripts/ash_compile_check/
#     runtime.exs inserts and reads back sample rows for every resource and
#     runs every privacy filter against them for each actor; then it seeds
#     the expression fixture's discriminating rows and requires every privacy
#     filter to select exactly the records in its hand-authored expectation
#     table (test/support/expression/expectations/privacy.json)
#
# Set BUBBLE_EX_PRIVATE_EXPORT to also check a private app export (e.g.
# mm-137). The scratch project lives in _build/ash_compile_check (or
# $ASH_COMPILE_CHECK_DIR) and is never committed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${ASH_COMPILE_CHECK_DIR:-$root/_build/ash_compile_check}"

mkdir -p "$scratch"
cp "$root/scripts/ash_compile_check/mix.lock" "$root/scripts/ash_compile_check/runtime.exs" \
  "$root/scripts/ash_compile_check/filters.exs" "$scratch/"
cp "$root/test/support/expression/expectations/privacy.json" "$scratch/expectations.json"

cd "$root"
MIX_ENV=test mix run scripts/ash_compile_check/render.exs "$scratch"

cd "$scratch"
mix deps.get
mix compile --warnings-as-errors --force

# Generate from scratch: earlier runs' snapshots would hide the tables.
rm -rf priv
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

# Lists of dates keep microseconds (timestamp(6)[], not timestamp(0)[]).
if grep -q "{:array, :utc_datetime}" <<<"$codegen"; then
  grep -n "{:array, :utc_datetime}" <<<"$codegen" | head -20
  echo "generated migrations store a list of dates at second precision" >&2
  exit 1
fi

if ! grep -q "{:array, :utc_datetime_usec}" <<<"$codegen"; then
  echo "no list-of-dates column was generated; the fixtures should have one" >&2
  exit 1
fi

tables="$(grep -c "create table(" <<<"$codegen" || true)"
echo "ash compile check passed: generated migrations create $tables tables"

# Compiled privacy-rule conditions (WTF-368) resolve against the resources.
mix run filters.exs

if [[ -n "${ASH_COMPILE_CHECK_DB:-}" ]]; then
  mix ash.codegen compile_check >/dev/null
  mix ecto.drop --quiet --force-drop >/dev/null 2>&1 || true
  mix ecto.create --quiet
  mix ecto.migrate --quiet
  mix run runtime.exs
else
  echo "runtime check skipped: set ASH_COMPILE_CHECK_DB to a PostgreSQL URL"
fi
