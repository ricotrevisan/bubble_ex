#!/usr/bin/env bash
# The upgrade path of the concurrent index hints (WTF-418), on a generated
# project whose migrations were just generated (phoenix_compile_check.sh):
#
#   * its snapshots are turned into a pre-WTF-418 project's (the index
#     hints recorded "concurrently": false): mix ash.codegen --check must
#     then see pending changes (it would drop and rebuild them)
#   * mix bubble.concurrent_index_snapshots --dry-run writes nothing
#   * mix bubble.concurrent_index_snapshots records them as concurrent; run
#     again it changes nothing
#   * mix ash.codegen then detects no changes
#
#     scripts/phoenix_compile_check/index_snapshots.sh <project dir>
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
project="$1"
cd "$project"

mapfile -t snapshots < <(grep -rl '"concurrently": true' priv/resource_snapshots | sort)

if [[ ${#snapshots[@]} == 0 ]]; then
  echo "index snapshots: the fixture has no concurrent index to upgrade" >&2
  exit 1
fi

sed -i 's/"concurrently": true/"concurrently": false/' "${snapshots[@]}"

if mix ash.codegen --check >/dev/null 2>&1; then
  echo "index snapshots: old snapshots should leave the indexes pending" >&2
  exit 1
fi

old="$(cat "${snapshots[@]}" | sha256sum)"
(cd "$root" && mix bubble.concurrent_index_snapshots --root "$project" --dry-run)

if [[ "$(cat "${snapshots[@]}" | sha256sum)" != "$old" ]]; then
  echo "index snapshots: --dry-run wrote" >&2
  exit 1
fi

(cd "$root" && mix bubble.concurrent_index_snapshots --root "$project")
again="$(cd "$root" && mix bubble.concurrent_index_snapshots --root "$project")"

if ! grep -q "No snapshot records a generated index as not concurrent" <<<"$again"; then
  echo "$again"
  echo "index snapshots: a second run changed something" >&2
  exit 1
fi

codegen="$(mix ash.codegen --dry-run upgrade 2>&1)"

if ! grep -q "No changes detected" <<<"$codegen"; then
  echo "$codegen" | tail -40
  echo "index snapshots: mix ash.codegen still has changes after the upgrade" >&2
  exit 1
fi

mix ash.codegen --check >/dev/null
echo "index snapshots check passed: ${#snapshots[@]} snapshot(s) upgraded, no migration"
