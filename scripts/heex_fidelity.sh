#!/usr/bin/env bash
# Frozen-case fidelity of the HEEx emitter (WTF-370): renders each frozen
# fidelity case's app through BubbleEx.Target.Phoenix into the Phoenix
# compile check's scratch project (scripts/phoenix_compile_check.sh; run it
# once first for the dependencies), serves the case's page from its
# generated LiveView, builds the project's Tailwind stylesheet and runs the
# same browser gate as the HTML exporter (test/support/fidelity/run.mjs,
# pinned Playwright and Chromium) against the committed Bubble references.
# bptvorpv also opens its overlays the way the runtime does
# (overlay-states.mjs). Never contacts Bubble.
#
#     scripts/heex_fidelity.sh                 # every case
#     HEEX_FIDELITY_CASES="bpgwgmpz" scripts/heex_fidelity.sh
#
# Candidates and reports go to _build/heex_fidelity/<case> (or
# $HEEX_FIDELITY_DIR); the summary compares them with the exporter's gate.
# Exits non-zero when the harness fails, or with HEEX_FIDELITY_STRICT=1
# (CI) when a case does not pass.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${PHOENIX_COMPILE_CHECK_DIR:-$root/_build/phoenix_compile_check}"
out="${HEEX_FIDELITY_DIR:-$root/_build/heex_fidelity}"
export MIX_ENV=test

cd "$root"
mix compile
cases="${HEEX_FIDELITY_CASES:-$(ls test/support/fidelity/cases)}"
mkdir -p "$out"

for id in $cases; do
  echo "== $id"
  cd "$root"
  mix run --no-compile scripts/phoenix_compile_check/render.exs "$scratch" "fidelity_$id"
  cd "$scratch"
  [[ -d deps ]] || mix deps.get
  mix compile --warnings-as-errors >/dev/null
  mix run "$root/scripts/heex_fidelity/candidate.exs" "$root" "$id" "$out/$id"
  cd "$root/test/support/fidelity"
  node run.mjs --case "cases/$id" --html "$out/$id/page.html" --report "$out/$id/report.json" || true
  if [[ -f "cases/$id/source/runtime/observation.json" ]]; then
    node overlay-states.mjs "cases/$id" "$out/$id/page.html" > "$out/$id/overlay-states.txt" 2>&1 || true
  fi
done

cd "$root"
mix run --no-compile scripts/heex_fidelity/summary.exs "$out" $cases
