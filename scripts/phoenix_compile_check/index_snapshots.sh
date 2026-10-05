#!/usr/bin/env bash
# The upgrade path of the concurrent index hints (WTF-418), on a generated
# project whose migrations were just generated (phoenix_compile_check.sh),
# twice: with the script the project ships (WTF-499, for owners without
# bubble_ex) and with bubble_ex's task. Each time:
#
#   * its snapshots are turned into a pre-WTF-418 project's (the index
#     hints recorded "concurrently": false): mix ash.codegen --check must
#     then see pending changes (it would drop and rebuild them)
#   * --dry-run writes nothing
#   * the upgrade records them as concurrent; run again it changes nothing
#   * mix ash.codegen then detects no changes
#
#     scripts/phoenix_compile_check/index_snapshots.sh <project dir>
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
project="$1"
cd "$project"

script=priv/bubble/concurrent_index_snapshots.exs

if [[ ! -f "$script" ]]; then
  echo "index snapshots: the project does not ship $script" >&2
  exit 1
fi

mapfile -t snapshots < <(grep -rl '"concurrently": true' priv/resource_snapshots | sort)

if [[ ${#snapshots[@]} == 0 ]]; then
  echo "index snapshots: the fixture has no concurrent index to upgrade" >&2
  exit 1
fi

# in the project, without bubble_ex
project_upgrade() { mix run --no-start "$script" "$@"; }
# from a bubble_ex checkout
task_upgrade() { (cd "$root" && mix bubble.concurrent_index_snapshots --root "$project" "$@"); }

check() {
  local name="$1" upgrade="$2"

  sed -i 's/"concurrently": true/"concurrently": false/' "${snapshots[@]}"

  if mix ash.codegen --check >/dev/null 2>&1; then
    echo "index snapshots ($name): old snapshots should leave the indexes pending" >&2
    exit 1
  fi

  local old
  old="$(cat "${snapshots[@]}" | sha256sum)"
  "$upgrade" --dry-run

  if [[ "$(cat "${snapshots[@]}" | sha256sum)" != "$old" ]]; then
    echo "index snapshots ($name): --dry-run wrote" >&2
    exit 1
  fi

  "$upgrade"
  local again
  again="$("$upgrade")"

  if ! grep -q "No snapshot records a generated index as not concurrent" <<<"$again"; then
    echo "$again"
    echo "index snapshots ($name): a second run changed something" >&2
    exit 1
  fi

  local codegen
  codegen="$(mix ash.codegen --dry-run upgrade 2>&1)"

  if ! grep -q "No changes detected" <<<"$codegen"; then
    echo "$codegen" | tail -40
    echo "index snapshots ($name): mix ash.codegen still has changes after the upgrade" >&2
    exit 1
  fi

  mix ash.codegen --check >/dev/null
}

check "$script" project_upgrade
check "mix bubble.concurrent_index_snapshots" task_upgrade

# A skipped snapshot (keys out of order) fails the project's script.
first="${snapshots[0]}"
# (the trailing "x" keeps the file's trailing newline)
saved="$(cat "$first"; echo x)"
sed -i 's/"concurrently": true/"concurrently": false/' "$first"
mix run --no-start -e '
  [file] = System.argv()
  {:ok, ordered} = Jason.decode(File.read!(file), objects: :ordered_objects)
  File.write!(file, Jason.encode!(%{ordered | values: Enum.reverse(ordered.values)}))
' -- "$first"
reordered="$(cat "$first")"

if out="$(project_upgrade 2>&1)"; then
  echo "$out"
  echo "index snapshots: a skipped snapshot should fail $script" >&2
  exit 1
fi

if ! grep -q "Skipped $first" <<<"$out" || [[ "$(cat "$first")" != "$reordered" ]]; then
  echo "$out"
  echo "index snapshots: $script should report and leave the skipped snapshot" >&2
  exit 1
fi

printf '%s' "${saved%x}" >"$first"
mix ash.codegen --check >/dev/null

echo "index snapshots check passed: ${#snapshots[@]} snapshot(s) upgraded by $script and by mix bubble.concurrent_index_snapshots, no migration"
