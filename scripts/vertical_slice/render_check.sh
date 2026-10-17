#!/usr/bin/env bash
# CI fixture of the vertical slice's render step with API clients present
# (WTF-543): renders test/support/target/phoenix/api_calls.json (synthetic,
# host api.example.test; nothing is called) with
# scripts/vertical_slice/slice.exs render, then checks the slice config
# points the group's client at the closed local port and nothing else: the
# shared helpers (Slice.ApiClients.Data, .Decode) have no host.
#
#     scripts/vertical_slice/render_check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

MIX_ENV=test mix run scripts/vertical_slice/slice.exs render \
  test/support/target/phoenix/api_calls.json - "$out/slice" bCatalog

project="$out/slice/project"
for f in data.ex decode.ex example.ex; do
  test -f "$project/lib/slice/api_clients/$f" || { echo "missing lib/slice/api_clients/$f" >&2; exit 1; }
done

clients="$(grep -E '^config :slice, Slice\.ApiClients\.[A-Za-z0-9.]+, base_url:' "$project/config/dev.exs" || true)"
expected='config :slice, Slice.ApiClients.Example, base_url: "http://127.0.0.1:1", retry: false'

if [[ "$clients" != "$expected" ]]; then
  printf 'unexpected API client config in config/dev.exs:\n%s\n' "$clients" >&2
  exit 1
fi

echo "slice render with API clients: ok"
