#!/bin/sh
# IDOR suite: fresh local D1 + `wrangler dev --env cloud --port 8801`, then test/idor.test.ts with two real Clerk dev users.
# Needs web/.dev.vars.cloud (CLERK_SECRET_KEY, RUNNER_TOKEN; never committed). Run from anywhere: sh web/test/idor.sh
set -eu
cd "$(dirname "$0")/.."
[ -f .dev.vars.cloud ] || { echo ".dev.vars.cloud missing (CLERK_SECRET_KEY, RUNNER_TOKEN)"; exit 1; }
port=8801
dir=$(mktemp -d "${TMPDIR:-/tmp}/kiroku-idor.XXXXXX")
npx wrangler d1 migrations apply kiroku_cloud --env cloud --local --persist-to "$dir" >/dev/null
npx wrangler dev --env cloud --port "$port" --inspector-port 8802 --persist-to "$dir" >"$dir/dev.log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; sleep 1; lsof -ti "tcp:$port" -sTCP:LISTEN | xargs kill 2>/dev/null || true; rm -rf "$dir"; }
trap cleanup EXIT INT TERM
i=0
until curl -sf "http://127.0.0.1:$port/api/config" >/dev/null; do
  i=$((i + 1)); [ "$i" -lt 90 ] || { cat "$dir/dev.log"; exit 1; }; sleep 1
done
set -a; . ./.dev.vars.cloud; set +a
BASE="http://127.0.0.1:$port" IDOR_DB_DIR="$dir" node test/idor.test.ts || { echo "--- wrangler dev log"; tail -40 "$dir/dev.log"; exit 1; }
