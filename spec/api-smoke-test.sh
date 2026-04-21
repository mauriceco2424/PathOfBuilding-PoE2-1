#!/usr/bin/env bash
# Phase 2 bootstrap-tier smoke test for PoB2 API handlers.
#
# Starts pob2-api-fork's stdio JSON-RPC server, pipes in a sequence of handler
# calls, and prints the responses. Run from repo root:
#
#   bash pob2-api-fork/spec/api-smoke-test.sh
#
# Expected: each handler returns ok=true with the documented payload. A failure
# at new_build / get_build_info means the Phase 1 shims or the Phase 2 handler
# port regressed — inspect pob2-api-fork/spec/smoke-stderr.log.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORK_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$FORK_ROOT/src"
STDERR_LOG="$HERE/smoke-stderr.log"

cd "$SRC"

# Build an ordered sequence of JSON-RPC calls. A single newline separates them.
REQUESTS=$(cat <<'EOF'
{"action":"ping"}
{"action":"version"}
{"action":"build_loaded"}
{"action":"new_build"}
{"action":"get_build_info"}
{"action":"get_stats"}
{"action":"set_level","params":{"level":90}}
{"action":"get_build_info"}
{"action":"gc_collect"}
{"action":"quit"}
EOF
)

echo "=== Starting PoB2 API server, sending ${REQUESTS//$'\n'/ | } ===" >&2

# LUA_PATH: runtime/lua is where our utf8/lua-utf8 shims and dkjson live.
#           src is where API/Server.lua, API/Handlers.lua, API/BuildOps.lua live.
# POB_API_STDIO=1 flips HeadlessWrapper into the stdio-server branch.
LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;./?.lua;./?/init.lua;;" \
  POB_API_STDIO=1 \
  luajit HeadlessWrapper.lua <<<"$REQUESTS" 2>"$STDERR_LOG"

echo "--- stderr (last 40 lines) ---" >&2
tail -40 "$STDERR_LOG" >&2
