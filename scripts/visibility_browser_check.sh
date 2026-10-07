#!/usr/bin/env bash
# Real-browser check of visibility conditionals and workflow steps
# (WTF-477, WTF-509): renders test/support/target/phoenix/visibility.json
# as a Phoenix app (the compile check's render, privacy: :omit), serves it
# in dev on a scratch database, and drives Chrome through browserq
# (`browserq exec <job> -- agent-browser ...`, the lab's browser queue).
#
# A workflow step's show or hide holds until a render changes the
# element's condition-derived visibility; then the condition wins (Bubble
# replay 2026-10-07). The replay's synthetic kit is the custom state
# `flag` (no on load) and three texts: T1 bKeep (visible on load, "when
# flag: visible", the same as on load), T2 bFlagged (hidden on load, "when
# flag: visible") and T3 bFlagOff (visible on load, "when flag: hidden");
# buttons set the flag (bSetFlag, bUnflag), hide T1 (bHideKeep, a step run
# in the browser), hide T2 (bHideFlagged), show T3 (bShowFlagOff):
#
#   1. a step shows an element with no conditionals (bWf); a re-render
#      keeps it
#   2. the replay's four sequences, each from a fresh page load: a step
#      holds until a re-render flips the element's conditional, which then
#      shows again what a step hid (T2) or hides what a step showed (T3);
#      T1's hide holds through every change (its condition repeats its
#      visibility on page load)
#   3. a workflow that sets the flag and then hides T2 (bFlagHide): the
#      step applies after the render that flips the condition, so it wins
#   4. a LiveView reconnect: a new mount (the flag resets), compared with
#      the last render like any other: steps on bWf and T1 hold, T2's step
#      is dropped by the flipped condition, and the conditions still drive
#      it afterwards
#   5. a full reload starts over: the visibility on page load
#   6. a conditional reading an input follows typing and its commit
#
# Not run in CI (it needs browserq). Needs a PostgreSQL URL without a
# database on a port other than 5432 (VISIBILITY_CHECK_DB, e.g.
# ecto://postgres:postgres@127.0.0.1:55477) and the compile check's scratch
# project for the dependencies (run scripts/phoenix_compile_check.sh once).
#
#     VISIBILITY_CHECK_DB=ecto://postgres:postgres@127.0.0.1:55477 \
#       scripts/visibility_browser_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${PHOENIX_COMPILE_CHECK_DIR:-$root/_build/phoenix_compile_check}"
dir="${VISIBILITY_CHECK_DIR:-$root/_build/visibility_browser_check}"
port="${VISIBILITY_CHECK_PORT:-4477}"
agent="${VISIBILITY_CHECK_AGENT:-bubble_ex-visibility-check}"
db="${VISIBILITY_CHECK_DB:?set VISIBILITY_CHECK_DB to a PostgreSQL URL (not port 5432)}"

if [[ "$db" =~ :5432(/|$) ]] || ! [[ "$db" =~ :[0-9]+(/|$) ]]; then
  echo "VISIBILITY_CHECK_DB needs an explicit port other than 5432" >&2
  exit 1
fi

mkdir -p "$dir"
for shared in deps _build; do
  [[ -e "$dir/$shared" ]] || cp -r "$scratch/$shared" "$dir/$shared"
done

cd "$root"
mix compile
mix run --no-compile scripts/phoenix_compile_check/render.exs "$dir" phoenix_visibility

cd "$dir"
cat >>config/dev.exs <<EOF

# scripts/visibility_browser_check.sh
config :phx_check, PhxCheck.Repo, url: "$db/phx_check_visibility_dev"
config :phx_check, PhxCheckWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: $port], watchers: []
config :phx_check, PhxCheckWeb.BubbleWorkflows, data_access: true
EOF

export MIX_ENV=dev
mix deps.get --check-locked >/dev/null
rm -rf priv/resource_snapshots
find priv/repo/migrations -name '*.exs' ! -name '20260101000000_add_oban_jobs_table.exs' -delete
mix ash.codegen initial >/dev/null
mix ecto.drop --quiet --force-drop >/dev/null 2>&1 || true
mix ecto.create --quiet
mix ecto.migrate --quiet
mix esbuild phx_check >/dev/null
mix tailwind phx_check >/dev/null

PORT="$port" mix phx.server >"$dir/server.log" 2>&1 &
server=$!
job=""
cleanup() {
  [[ -n "$job" ]] && browserq --agent "$agent" close "$job" >/dev/null 2>&1 || true
  kill "$server" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 120); do
  curl -sf "http://127.0.0.1:$port/" >/dev/null && break
  sleep 1
done

job=$(browserq --agent "$agent" start --engine chrome --wait 2m)
b() { browserq --agent "$agent" exec "$job" -- "$@"; }

# Whether element $1 is hidden (true/false): its `hidden` attribute, and
# its computed display must agree (the generated rule beats its utilities).
hidden() {
  b eval "(() => { const el = document.querySelector('[data-bubble-id=\"$1\"]'); const none = getComputedStyle(el).display === 'none'; return el.hidden === none ? String(none) : 'inconsistent' })()" | tr -d '"[:space:]'
}

connected() {
  for _ in $(seq 1 50); do
    [[ "$(b eval "String(!!(window.liveSocket && liveSocket.isConnected() && document.querySelector('.phx-connected')))" | tr -d '"[:space:]')" == true ]] && return 0
    sleep 0.2
  done
  echo "the LiveView did not connect" >&2
  return 1
}

click() { b click "[data-bubble-id=\"$1\"]" >/dev/null; sleep 0.5; }

failures=0
expect() { # $1 element, $2 expected hidden, $3 what
  local got
  got="$(hidden "$1")"
  if [[ "$got" == "$2" ]]; then
    echo "  PASS  $3 ($1 hidden=$got)"
  else
    echo "  FAIL  $3 ($1 hidden=$got, expected $2)"
    failures=$((failures + 1))
  fi
}

# T1 T2 T3 hidden flags ("true"/"false"), after the step named $4.
state() { # $1 $2 $3 expected bKeep bFlagged bFlagOff, $4 what
  expect bKeep "$1" "$4: T1"
  expect bFlagged "$2" "$4: T2"
  expect bFlagOff "$3" "$4: T3"
}

fresh() {
  b open "http://127.0.0.1:$port/" >/dev/null
  connected
}

fresh
expect bWf true "not visible on page load"
state false true false "page load"

click bShowWf
expect bWf false "a show step shows an element with no conditionals"
click bSetFlag
expect bWf false "a re-render keeps the show step"
click bUnflag

echo "replay 1: h1, sy, sn"
fresh
click bHideKeep
state true true false "hide T1"
click bSetFlag
state true false true "flag"
click bUnflag
state true true false "unflag"

echo "replay 2: sy, h1, sn, sy"
fresh
click bSetFlag
state false false true "flag"
click bHideKeep
state true false true "hide T1"
click bUnflag
state true true false "unflag"
click bSetFlag
state true false true "flag again"

echo "replay 3: sy, h2, sn, sy (the flip shows again what a step hid)"
fresh
click bSetFlag
click bHideFlagged
state false true true "hide T2"
click bUnflag
state false true false "unflag"
click bSetFlag
state false false true "flag again: T2 shown by its condition"

echo "replay 4: sy, s3, sn, sy"
fresh
click bSetFlag
click bShowFlagOff
state false false false "show T3"
click bUnflag
state false true false "unflag"
click bSetFlag
state false false true "flag again: T3 hidden by its condition"

echo "set the flag, then hide T2, in one workflow"
fresh
click bFlagHide
expect bFlagged true "the step after the flip wins"
click bUnflag
click bSetFlag
expect bFlagged false "the next flip shows it again"

echo "reconnect"
fresh
click bShowWf
click bHideKeep
click bSetFlag
click bHideFlagged
state true true true "before the reconnect"
b eval "liveSocket.disconnect(); setTimeout(() => liveSocket.connect(), 300); 'ok'" >/dev/null
sleep 1
connected
expect bWf false "a reconnect keeps the show step (no conditionals)"
# The new mount resets the flag: T2's condition flips (hidden), T3's too.
state true true false "after the reconnect (flag reset)"
click bSetFlag
state true false true "after the reconnect a flip still drives T2 and T3"

fresh
expect bWf true "a reload starts from the visibility on page load"
state false true false "a reload forgets the steps"

# A conditional reading an input re-renders as the user types (the
# input's change, WTF-474/475) and after it is committed (blur).
expect bOpen true "a conditional on an input's value, false on page load"
b fill '[data-bubble-id="bName"]' open >/dev/null
sleep 1
expect bOpen false "typing re-renders a conditional reading the input"
b click '[data-bubble-id="bSetFlag"]' >/dev/null
sleep 0.5
expect bOpen false "after the input is committed (blur) it still holds"

if [[ $failures -gt 0 ]]; then
  echo "visibility browser check: $failures failed" >&2
  exit 1
fi

echo "visibility browser check passed"
