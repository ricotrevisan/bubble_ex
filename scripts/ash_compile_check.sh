#!/usr/bin/env bash
# Compile and runtime check for BubbleEx.Target.Ash (WTF-342): renders every
# model and target fixture into a scratch Ash project whose dependencies are
# BubbleEx.Target.Ash.versions(privacy: :unverified) (mix.lock pins the rest), then
#
#   * mix compile --warnings-as-errors, which also compiles the
#     BubbleEx.Db.Ecto schemas and migrations of every schema golden fixture
#     (WTF-391: no repeated field, association or foreign key)
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
#     table (test/support/expression/expectations/privacy.json); then
#     scripts/ash_compile_check/policies.exs reads every resource through
#     its generated policies (WTF-356) logged out and as stored users, and
#     requires the policy fixture's reads, visible fields and auto-binding
#     updates to match its hand-authored expectation table
#     (test/support/target/ash/expectations/policies.json); both checks
#     also compare the privacy interpreter's verdicts on those tables
#     (BubbleEx.Verify.Interpreter, WTF-382; written by render.exs) with
#     what PostgreSQL selects; and
#     scripts/ash_compile_check/ecto_migrate.exs runs the Db.Ecto
#     migrations in one database per fixture and naming; and
#     scripts/ash_compile_check/decisions.exs checks the owner decision
#     fixtures (BubbleEx.Test.DecidedFixture, WTF-401): a derived field is
#     a calculation with no column that PostgreSQL reads back through its
#     relationship, refined numbers are bigint/numeric columns, and an
#     attribute renamed after the name lock keeps its column
#
# All of the above maps with privacy: :unverified (the policies). Then the
# same fixtures are rendered with privacy: :omit (Target.Ash's default, what
# an owner downloads) into a second scratch project pinned to
# versions(privacy: :omit) (no PicoSAT): render.exs fails on any policy
# machinery in the source; it must compile with --warnings-as-errors and
# generate migrations without foreign keys, and with ASH_COMPILE_CHECK_DB
# its migrations run, runtime.exs round-trips the sample rows,
# scripts/ash_compile_check/omit.exs checks that no resource has an
# authorizer, policies or private relationships and that every row reads
# back with authorization on and no actor; then decisions.exs checks the
# decided fixtures.
#
# Set BUBBLE_EX_PRIVATE_EXPORT to also check a private app export (e.g.
# mm-137). The scratch projects live in _build/ash_compile_check and
# _build/ash_compile_check_omit (or $ASH_COMPILE_CHECK_DIR and
# $ASH_COMPILE_CHECK_DIR_omit) and are never committed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${ASH_COMPILE_CHECK_DIR:-$root/_build/ash_compile_check}"

mkdir -p "$scratch"
cp "$root/scripts/ash_compile_check/mix.lock" "$root/scripts/ash_compile_check/runtime.exs" \
  "$root/scripts/ash_compile_check/filters.exs" \
  "$root/scripts/ash_compile_check/policies.exs" \
  "$root/scripts/ash_compile_check/ecto_migrate.exs" \
  "$root/scripts/ash_compile_check/decisions.exs" "$scratch/"
cp "$root/test/support/expression/expectations/privacy.json" "$scratch/expectations.json"
cp "$root/test/support/target/ash/expectations/policies.json" "$scratch/policy_expectations.json"

cd "$root"
MIX_ENV=test mix run scripts/ash_compile_check/render.exs "$scratch" unverified

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
no_foreign_keys() {
  if grep -q "references(" <<<"$1"; then
    grep -n "references(" <<<"$1" | head -20
    echo "generated migrations contain foreign keys" >&2
    exit 1
  fi
}

no_foreign_keys "$codegen"

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
  mix run policies.exs
  mix run ecto_migrate.exs
  mix run decisions.exs
else
  echo "runtime check skipped: set ASH_COMPILE_CHECK_DB to a PostgreSQL URL"
fi

# privacy: :omit, the default: the same fixtures without policies, in a
# project without PicoSAT.
omit="${scratch}_omit"
mkdir -p "$omit"
cp "$root/scripts/ash_compile_check/mix.lock" "$root/scripts/ash_compile_check/runtime.exs" \
  "$root/scripts/ash_compile_check/omit.exs" "$root/scripts/ash_compile_check/decisions.exs" "$omit/"

cd "$root"
MIX_ENV=test mix run scripts/ash_compile_check/render.exs "$omit" omit

cd "$omit"
mix deps.get

if [[ -d deps/picosat_elixir ]] || mix deps | grep -q picosat_elixir; then
  echo "the privacy: :omit project depends on picosat_elixir" >&2
  exit 1
fi

mix compile --warnings-as-errors --force
rm -rf priv
codegen="$(mix ash.codegen --dry-run compile_check 2>&1)" || {
  echo "$codegen"
  echo "ash.codegen failed (privacy: :omit)" >&2
  exit 1
}

no_foreign_keys "$codegen"
tables="$(grep -c "create table(" <<<"$codegen" || true)"
echo "ash compile check passed (privacy: :omit): generated migrations create $tables tables"

if [[ -n "${ASH_COMPILE_CHECK_DB:-}" ]]; then
  mix ash.codegen compile_check >/dev/null
  mix ecto.drop --quiet --force-drop >/dev/null 2>&1 || true
  mix ecto.create --quiet
  mix ecto.migrate --quiet
  mix run runtime.exs
  mix run omit.exs
  mix run decisions.exs
else
  echo "runtime check skipped (privacy: :omit): set ASH_COMPILE_CHECK_DB to a PostgreSQL URL"
fi
