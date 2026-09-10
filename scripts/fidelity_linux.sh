#!/usr/bin/env bash
# Run Elixir locally and the pinned visual measurement browser on Linux.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shim_dir="$(mktemp -d)"
trap 'rm -rf "$shim_dir"' EXIT
export BUBBLE_FIDELITY_REPO_ROOT="$repo_root"
export BUBBLE_FIDELITY_DOCKER="$(command -v docker)"
cat > "$shim_dir/node" <<'SH'
#!/usr/bin/env bash
exec "$BUBBLE_FIDELITY_DOCKER" run --rm --platform linux/amd64 \
  -v "$BUBBLE_FIDELITY_REPO_ROOT:$BUBBLE_FIDELITY_REPO_ROOT" \
  -w "$PWD" mcr.microsoft.com/playwright:v1.55.1-noble node "$@"
SH
chmod +x "$shim_dir/node"
cd "$repo_root"
PATH="$shim_dir:$PATH" mix test --only fidelity "$@"
