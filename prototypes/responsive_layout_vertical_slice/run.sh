#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mix run --no-start --no-mix-exs render.exs
npx --yes playwright@1.55.0 install chromium >/dev/null
npx --yes -p playwright@1.55.0 -c \
  'PW_BIN=$(command -v playwright); NODE_PATH=$(dirname "$(dirname "$PW_BIN")") node verify.cjs'
