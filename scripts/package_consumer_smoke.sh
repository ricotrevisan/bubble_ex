#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/bubble-ex-package-smoke.XXXXXX")"
trap 'rm -rf "$scratch_root"' EXIT

package_dir="$scratch_root/bubble_ex-package"
consumer_dir="$scratch_root/bubble_ex-consumer"

(
  cd "$repo_root"
  MIX_ENV=prod mix hex.build --unpack --output "$package_dir"
)

mix new "$consumer_dir" --app bubble_ex_consumer --module BubbleExConsumer >/dev/null

cat >"$consumer_dir/mix.exs" <<'EOF'
defmodule BubbleExConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :bubble_ex_consumer,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: [{:bubble_ex, path: System.fetch_env!("BUBBLE_EX_PACKAGE_DIR")}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
EOF

cat >"$consumer_dir/package_smoke.exs" <<'EOF'
case BubbleEx.Secrets.scan(%{"_id" => "consumer-smoke", "value" => "safe"},
       adapter: BubbleEx.Secrets.Native
     ) do
  {:ok, []} -> IO.puts("package consumer smoke test passed")
  result -> raise "unexpected BubbleEx result: #{inspect(result)}"
end
EOF

(
  cd "$consumer_dir"
  export BUBBLE_EX_PACKAGE_DIR="$package_dir"
  export MIX_ENV=prod
  mix deps.get
  mix compile --warnings-as-errors
  mix run package_smoke.exs
)
