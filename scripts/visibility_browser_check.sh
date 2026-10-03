#!/usr/bin/env bash
# Real-browser check of visibility conditionals and workflow steps
# (WTF-477): renders test/support/target/phoenix/visibility.json as a
# Phoenix app (the compile check's render, privacy: :omit), serves it in
# dev on a scratch database, and drives Chrome through browserq
# (`browserq exec <job> -- agent-browser ...`, the lab's browser queue):
#
#   1. a workflow step shows an element not visible on page load (bWf)
#   2. a server re-render (a custom state set by a workflow, which a
#      conditional reads: bFlagged shows) keeps the step's show
#   3. a step hides bFlagged; re-renders that flip its conditional
#      (unflag, flag) do not show it again: the step wins until reload
#   4. a LiveView reconnect keeps both steps (sticky JS attributes on the
#      same DOM elements) while the page's custom states reset to their
#      defaults (a new mount)
#   5. a full reload starts over: the visibility on page load
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

b open "http://127.0.0.1:$port/" >/dev/null
connected
expect bWf true "not visible on page load"
expect bFlagged true "conditional false on page load"

click bShowWf
expect bWf false "a show step shows it"

click bSetFlag
expect bFlagged false "a re-render shows what the conditional now shows"
expect bWf false "the re-render keeps the show step"

click bHideFlagged
expect bFlagged true "a hide step hides a conditionally shown element"
click bUnflag
click bSetFlag
expect bFlagged true "re-renders flipping its conditional do not undo the hide step"

b eval "liveSocket.disconnect(); setTimeout(() => liveSocket.connect(), 300); 'ok'" >/dev/null
sleep 1
connected
expect bWf false "a reconnect keeps the show step"
expect bFlagged true "a reconnect keeps the hide step"
click bSetFlag
expect bFlagged true "after a reconnect the hide step still wins over its conditional"

b open "http://127.0.0.1:$port/" >/dev/null
connected
expect bWf true "a reload starts from the visibility on page load"
click bSetFlag
expect bFlagged false "a reload forgets the hide step"

if [[ $failures -gt 0 ]]; then
  echo "visibility browser check: $failures failed" >&2
  exit 1
fi

echo "visibility browser check passed"
