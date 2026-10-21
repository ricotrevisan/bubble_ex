#!/usr/bin/env bash
# Real-browser check of "is hovered" conditionals lowered to the browser's
# hover (WTF-590): renders test/support/target/phoenix/hover.json as a
# Phoenix app (the compile check's render, privacy: :omit), serves it in
# dev on a scratch database, and hovers its elements in Chrome through
# browserq (`browserq exec <job> -- agent-browser ...`, the lab's browser
# queue). Each expectation is the element's computed style, so it holds
# only when the generated rule beats the element's own utilities and its
# `hidden` attribute:
#
#   1. page load: nothing hovered, bCardTools and bZeroShown hidden
#   2. bCardTitle hovered: its own color (This element is hovered), the
#      group holding it shows bCardTools (another element's hover, an
#      ancestor) and paints bCardDot (a sibling, within bCard)
#   3. bRowIcon hovered: bRow, which holds it, is painted; bCard's rules
#      are off again
#   4. bZeroLabel hovered: the zero-size hover group bZero holding it is
#      hovered too, and shows bZeroShown
#   5. the pointer elsewhere: everything as on page load
#   6. no hover sent anything to the server (no LiveView event)
#
# Not run in CI (it needs browserq). Needs a PostgreSQL URL without a
# database on a port other than 5432 (HOVER_CHECK_DB, e.g.
# ecto://postgres:postgres@127.0.0.1:55478) and the compile check's scratch
# project for the dependencies (run scripts/phoenix_compile_check.sh once).
#
#     HOVER_CHECK_DB=ecto://postgres:postgres@127.0.0.1:55478 \
#       scripts/hover_browser_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${PHOENIX_COMPILE_CHECK_DIR:-$root/_build/phoenix_compile_check}"
dir="${HOVER_CHECK_DIR:-$root/_build/hover_browser_check}"
port="${HOVER_CHECK_PORT:-4478}"
agent="${HOVER_CHECK_AGENT:-bubble_ex-hover-check}"
db="${HOVER_CHECK_DB:?set HOVER_CHECK_DB to a PostgreSQL URL (not port 5432)}"

if [[ "$db" =~ :5432(/|$) ]] || ! [[ "$db" =~ :[0-9]+(/|$) ]]; then
  echo "HOVER_CHECK_DB needs an explicit port other than 5432" >&2
  exit 1
fi

mkdir -p "$dir"
for shared in deps _build; do
  [[ -e "$dir/$shared" ]] || cp -r "$scratch/$shared" "$dir/$shared"
done

cd "$root"
mix compile
mix run --no-compile scripts/phoenix_compile_check/render.exs "$dir" phoenix_hover

cd "$dir"
cat >>config/dev.exs <<EOF

# scripts/hover_browser_check.sh
config :phx_check, PhxCheck.Repo, url: "$db/phx_check_hover_dev"
config :phx_check, PhxCheckWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: $port], watchers: []
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

# A computed style property ($2) of element $1.
style() {
  b eval "getComputedStyle(document.querySelector('[data-bubble-id=\"$1\"]')).getPropertyValue('$2')" | tr -d '"' | sed 's/^ *//;s/ *$//'
}

connected() {
  for _ in $(seq 1 50); do
    [[ "$(b eval "String(!!(window.liveSocket && liveSocket.isConnected() && document.querySelector('.phx-connected')))" | tr -d '"[:space:]')" == true ]] && return 0
    sleep 0.2
  done
  echo "the LiveView did not connect" >&2
  return 1
}

hover() { b hover "[data-bubble-id=\"$1\"]" >/dev/null; sleep 0.3; }

failures=0
expect() { # $1 element, $2 property, $3 expected value, $4 what
  local got
  got="$(style "$1" "$2")"
  if [[ "$got" == "$3" ]]; then
    echo "  PASS  $4 ($1 $2: $got)"
  else
    echo "  FAIL  $4 ($1 $2: $got, expected $3)"
    failures=$((failures + 1))
  fi
}

base() { # $1 what
  expect bCardTitle color "rgb(20, 20, 20)" "$1: bCardTitle's own color"
  expect bCardTools display none "$1: bCardTools hidden"
  expect bCardDot background-color "rgb(240, 240, 240)" "$1: bCardDot's own background"
  expect bRow background-color "rgb(240, 240, 240)" "$1: bRow's own background"
  expect bZeroShown display none "$1: bZeroShown hidden"
}

b open "http://127.0.0.1:$port/" >/dev/null
connected
# Count the LiveView events the page sends from here on.
b eval "window.__events = 0; const push = liveSocket.main.channel.push.bind(liveSocket.main.channel); liveSocket.main.channel.push = (event, ...rest) => { if (event === 'event') window.__events++; return push(event, ...rest) }; 'ok'" >/dev/null

hover bPlain
base "page load"

hover bCardTitle
expect bCardTitle color "rgb(200, 0, 0)" "This element is hovered: its color"
expect bCardTools display flex "the group holding it is hovered: bCardTools shown"
expect bCardToolsText display block "bCardTools' contents are rendered"
expect bCardDot background-color "rgb(0, 0, 200)" "a sibling's hover paints bCardDot"
expect bRow background-color "rgb(240, 240, 240)" "bRow untouched"

hover bRowIcon
expect bRow background-color "rgb(0, 150, 0)" "a child's hover paints the group holding it"
expect bCardTitle color "rgb(20, 20, 20)" "off bCard: bCardTitle's own color"
expect bCardTools display none "off bCard: bCardTools hidden"

hover bZeroLabel
expect bZeroShown display block "a zero-size hover group is hovered through its contents"

hover bPlain
base "the pointer elsewhere"

events="$(b eval "String(window.__events)" | tr -d '"[:space:]')"
if [[ "$events" == 0 ]]; then
  echo "  PASS  no hover sent a LiveView event"
else
  echo "  FAIL  $events LiveView events while hovering"
  failures=$((failures + 1))
fi

if [[ $failures -gt 0 ]]; then
  echo "hover browser check: $failures failed" >&2
  exit 1
fi

echo "hover browser check passed"
