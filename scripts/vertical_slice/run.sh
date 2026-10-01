#!/usr/bin/env bash
# A vertical slice (WTF-378): one page of a Bubble app taken end to end.
#
#     scripts/vertical_slice/run.sh EXPORT DECISIONS SLUG [PAGE]
#
#   EXPORT     a Buildprint v5 workspace or a `.bubble` JSON file (read only)
#   DECISIONS  the owner's decision records (JSON list), or `-`
#   SLUG       a name for the run: the output goes to $SLICE_ROOT/SLUG
#   PAGE       a page's Bubble ID, or `median` (default; see pages.exs)
#
# Steps, each logged under $SLICE_ROOT/SLUG/logs:
#
#   1. a throwaway PostgreSQL (docker, 127.0.0.1:$SLICE_DB_PORT, never
#      5432) for the slice's `slice_dev` and `slice_test` databases
#   2. render the project (slice.exs render: privacy :omit, or
#      SLICE_PRIVACY=enforced for the compiled policies, the decisions
#      applied, the plan, the determinism result, the generation-time
#      structural summary), then compile it with --warnings-as-errors,
#      check its format, generate and check its migrations, migrate, build
#      its assets
#   3. load synthetic records through the data loader (slice.exs seed)
#   4. serve it (data access on, API clients pointed at a closed port) and
#      drive the page in Chromium (drive.mjs): signed out, a magic-link
#      sign-in from the local mailbox (as synthetic user SLICE_PERSONA),
#      then every wired element
#   5. `mix wtf.task` (next, the generator tasks, the page's tasks; their
#      tests on the throwaway `slice_test`, named with --test-db) and
#      `mix wtf.verify structural`
#
# The server and the database are always stopped and removed on exit
# (SLICE_KEEP=1 keeps them for inspection). The script writes only under
# $SLICE_ROOT/SLUG (created 0700; $SLICE_ROOT itself is created 0700 when
# missing and never changed otherwise) and the project's own deps/_build;
# nothing contacts Bubble or a third-party API (the browser resolves no
# other host and aborts every other origin; the images the pages link from
# other hosts, as in Bubble, are counted as external_images_expected, not
# as blocked_requests). Downloading the pinned
# Tailwind and esbuild binaries is the only other network use.
#
# Environment: SLICE_DB_PORT (required: the throwaway PostgreSQL's port on
# 127.0.0.1, never 5432), SLICE_ROOT (default
# ~/.local/share/bubble_ex/slices), SLICE_PORT (4378), SLICE_SEED_N
# (records per type, 3), SLICE_PRIVACY (omit, the default, or enforced),
# SLICE_PERSONA (the synthetic user signed in, 1 to SLICE_SEED_N, default
# 1), SLICE_TASKS (generator tasks to complete, default
# "generate:option_sets generate:schema generate:styles").
set -euo pipefail

if [[ $# -lt 3 ]]; then
  sed -n '2,12p' "$0" >&2
  exit 2
fi

export_path="$1"
decisions="$2"
slug="$3"
page="${4:-median}"

root="$(cd "$(dirname "$0")/../.." && pwd)"
slice_root="${SLICE_ROOT:-$HOME/.local/share/bubble_ex/slices}"
out="$slice_root/$slug"
project="$out/project"
logs="$out/logs"
db_port="${SLICE_DB_PORT:-}"
http_port="${SLICE_PORT:-4378}"
seed_n="${SLICE_SEED_N:-3}"
tasks="${SLICE_TASKS:-generate:option_sets generate:schema generate:styles}"
container="bubble-ex-slice-${slug//[^A-Za-z0-9_-]/-}-db"

[[ "$slug" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "SLUG: letters, digits, - and _ only" >&2; exit 2; }
[[ "$db_port" =~ ^[0-9]+$ && "$db_port" != 5432 ]] ||
  { echo "SLICE_DB_PORT must be set explicitly, to a port other than 5432" >&2; exit 2; }
[[ "$http_port" =~ ^[0-9]+$ ]] || { echo "SLICE_PORT must be a number" >&2; exit 2; }

# Only what the script creates is made private; an existing $SLICE_ROOT
# keeps its mode.
[[ -d "$slice_root" ]] || mkdir -m 700 -p "$slice_root"
mkdir -p "$out" "$logs" "$out/artifacts"
chmod 700 "$out" "$logs" "$out/artifacts"

export SLICE_DB="ecto://postgres:postgres@127.0.0.1:$db_port"
# mix wtf.task runs the project's tests only on the database it is given
# (--test-db, passed as TEST_DATABASE_URL, WTF-448): the throwaway
# slice_test. Nothing from the caller's shell reaches the project's config.
slice_test_db="$SLICE_DB/slice_test"
unset TEST_DATABASE_URL DATABASE_URL WTF_TASK_TEST_DB
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ -z "${SLICE_KEEP:-}" ]]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  else
    echo "SLICE_KEEP: the database $container is left running"
  fi
}
trap cleanup EXIT

step() { echo "== $*"; }

# --- 1. the database ------------------------------------------------------------------------
step "database $container on 127.0.0.1:$db_port"
# The database must be the script's own container: labelled for this
# slug, and the one publishing 127.0.0.1:$db_port. A port held by anything
# else (another container, a local PostgreSQL) stops the run.
owned() {
  [[ "$(docker inspect -f '{{index .Config.Labels "bubble_ex.slice"}}' "$container" 2>/dev/null)" == "$slug" ]] &&
    [[ "$(docker port "$container" 5432/tcp 2>/dev/null)" == "127.0.0.1:$db_port" ]]
}
if ss -ltn 2>/dev/null | grep -qE "[:.]$db_port\s"; then
  owned || { echo "port $db_port is taken by something other than $container" >&2; exit 1; }
else
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run -d --name "$container" --label "bubble_ex.slice=$slug" -e POSTGRES_PASSWORD=postgres \
    -p "127.0.0.1:$db_port:5432" postgres:17 >/dev/null
  owned || { echo "$container does not publish 127.0.0.1:$db_port" >&2; exit 1; }
fi
# Over TCP: the image's init-time server listens on the socket only.
ready=""
for _ in $(seq 1 60); do
  if docker exec "$container" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ -n "$ready" ]] || { echo "$container did not become ready" >&2; exit 1; }

# --- 2. render, compile, migrate --------------------------------------------------------------
cd "$root"
export MIX_ENV=test
mix compile >/dev/null
step "render"
mix run --no-compile scripts/vertical_slice/slice.exs render "$export_path" "$decisions" "$out" "$page" |
  tee "$logs/render.log"

cd "$project"
(
  export MIX_ENV=dev
  step "deps"
  mix deps.get > "$logs/deps.log" 2>&1
  step "compile (--warnings-as-errors)"
  if mix compile --warnings-as-errors > "$logs/compile.log" 2>&1; then
    echo "compile ok"
  else
    echo "compile FAILED (see logs/compile.log)"
    grep -A6 "warning:\|error" "$logs/compile.log" | grep -v "deps/" | head -40 || true
    exit 1
  fi
  step "format"
  mix format --check-formatted > "$logs/format.log" 2>&1 && echo "format ok" || echo "format FAILED (logs/format.log)"
  step "migrations"
  rm -rf priv/resource_snapshots
  find priv/repo/migrations -name '*.exs' ! -name '20260101000000_add_oban_jobs_table.exs' -delete
  mix ash.codegen initial > "$logs/codegen.log" 2>&1
  mix ash.codegen --check >> "$logs/codegen.log" 2>&1 && echo "migrations in sync"
  mix ecto.drop --force-drop > "$logs/migrate.log" 2>&1 || true
  mix ecto.create >> "$logs/migrate.log" 2>&1
  mix ecto.migrate >> "$logs/migrate.log" 2>&1 && echo "migrated"
  step "assets"
  mix assets.setup > "$logs/assets.log" 2>&1
  mix assets.build >> "$logs/assets.log" 2>&1 && echo "assets built"
)

# --- 3. synthetic data ------------------------------------------------------------------------
cd "$root"
step "seed ($seed_n records per type)"
mix run --no-compile scripts/vertical_slice/slice.exs seed "$export_path" "$decisions" "$out" "$seed_n" |
  tee "$logs/seed.log"
read -r page_path thing email page_id < <(mix run --no-compile scripts/vertical_slice/slice.exs target "$out")

# --- 4. serve and drive -----------------------------------------------------------------------
step "serve on 127.0.0.1:$http_port"
if ss -ltn 2>/dev/null | grep -q ":$http_port "; then
  echo "port $http_port is taken" >&2
  exit 1
fi
(cd "$project" && MIX_ENV=dev PORT="$http_port" exec mix phx.server) > "$logs/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 180); do
  curl -s -o /dev/null "http://127.0.0.1:$http_port/" && break
  kill -0 "$server_pid" 2>/dev/null || { echo "the server exited (logs/server.log)" >&2; exit 1; }
  sleep 1
done

step "drive $page_path"
[[ -d test/support/fidelity/node_modules/playwright ]] || (cd test/support/fidelity && npm ci --silent)
thing_args=()
[[ "$thing" != "-" ]] && thing_args=(--thing "$thing")
node scripts/vertical_slice/drive.mjs --base "http://127.0.0.1:$http_port" --path "$page_path" \
  "${thing_args[@]}" --email "$email" --out "$out/artifacts" --log "$logs/server.log" \
  --assets "$project/.wtf/assets.json" |
  tee "$logs/drive.log"

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

# --- 5. the task CLI and structural verification ---------------------------------------------
step "mix wtf.task"
wtf() { mix wtf.task "$@" --root "$project"; }
wtf next --n 20 > "$logs/wtf-task-next.log" 2>&1 || true
for t in $tasks; do
  if wtf complete "$t" --agent vertical-slice --app slice --test-db "$slice_test_db" \
    > "$logs/wtf-task-$t.log" 2>&1; then
    echo "done   $t"
  else
    echo "open   $t (logs/wtf-task-$t.log)"
  fi
done
wtf show "surface:page/$page_id" > "$logs/wtf-task-surface.log" 2>&1 || true
wtf audit --app slice --test-db "$slice_test_db" > "$logs/wtf-task-audit.log" 2>&1 || true

step "mix wtf.verify structural"
mix wtf.verify structural --root "$project" --app slice --out "$out/structural" \
  > "$logs/wtf-verify.log" 2>&1 || true
grep -E '^(pass|fail|skip|not_run)' "$logs/wtf-verify.log" || tail -20 "$logs/wtf-verify.log"

chmod -R go-rwx "$out"
echo "slice output: $out"
